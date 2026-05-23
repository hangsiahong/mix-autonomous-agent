#!/bin/bash
# tools/self_update.sh — pull upstream code in place and reload cleanly.
# Single engine for /update slash command AND agent-callable self_update tool.
#
# Args (via TOOL_ env vars — kept lowercase per AMA tool convention):
#   branch    Optional. Switch to this branch before pulling.
#   force     Optional ("1"/"true"). git stash dirty tree before pull.
#   rollback  Optional ("1"/"true"). Revert to SHA recorded by the last update.
#
# Restart strategy:
#   - requirements.txt changed OR pm2.config.js changed → pm2 restart ama-bot
#   - else → SIGHUP $(cat brain/state/bot.pid) (same path as /reload)
#
# State files (gitignored under brain/state/):
#   last_update_prev_sha   SHA before last successful pull (for rollback)
#   last_update.lock       advisory flock — prevents overlapping /update calls

_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT_DIR="$(cd "$_TOOLS_DIR/.." && pwd)"
cd "$_ROOT_DIR" || { echo "Error: cannot cd to repo root."; exit 0; }

if [[ ! -d .git ]]; then
    echo "Error: not a git repository — self-update needs a git checkout."
    echo "If you installed AMA via zip/tarball, clone it instead:"
    echo "  git clone https://github.com/hangsiahong/mix-autonomous-agent.git"
    exit 0
fi

branch="${TOOL_branch:-}"
force="${TOOL_force:-}"
rollback="${TOOL_rollback:-}"

_state_dir="${_ROOT_DIR}/brain/state"
_prev_sha_file="${_state_dir}/last_update_prev_sha"
_lock="${_state_dir}/last_update.lock"
mkdir -p "$_state_dir"

# Advisory lock — one /update at a time. Open fd FIRST then flock the fd,
# matching the pattern used in extensions/cron/run.sh.
exec 8>"$_lock"
if ! flock -n 8; then
    echo "Another /update is in progress — try again in a few seconds."
    exit 0
fi

_restart_bot() {
    # Mirrors router.sh:1569-1590 /restart logic.
    if pm2 restart ama-bot >> "${_ROOT_DIR}/logs/bot.log" 2>&1; then
        echo "Restart: pm2 restart ama-bot issued."
    else
        local _bot_pid; _bot_pid=$(cat "${_state_dir}/bot.pid" 2>/dev/null)
        nohup bash "${_ROOT_DIR}/bot.sh" >> "${_ROOT_DIR}/logs/bot.log" 2>&1 &
        [[ -n "$_bot_pid" ]] && kill -TERM "$_bot_pid" 2>/dev/null
        echo "Restart: manual nohup (not under pm2)."
    fi
}

_reload_bot() {
    local _bot_pid; _bot_pid=$(cat "${_state_dir}/bot.pid" 2>/dev/null)
    if [[ -n "$_bot_pid" ]] && kill -0 "$_bot_pid" 2>/dev/null; then
        kill -HUP "$_bot_pid"
        echo "Reload: SIGHUP sent to bot PID $_bot_pid."
    else
        echo "Reload: bot PID not found — start the bot manually."
    fi
}

# ── Rollback path ────────────────────────────────────────────────────────────
if [[ "$rollback" == "1" || "$rollback" == "true" ]]; then
    if [[ ! -f "$_prev_sha_file" ]]; then
        echo "No prior update recorded — nothing to roll back to."
        exit 0
    fi
    _target=$(cat "$_prev_sha_file")
    _cur=$(git rev-parse --short HEAD)
    if ! git diff-index --quiet HEAD --; then
        echo "Working tree dirty — refusing rollback (would lose your changes)."
        echo "Stash or commit, then retry."
        exit 0
    fi
    if ! git reset --hard "$_target" >/dev/null 2>&1; then
        echo "Rollback failed: cannot reset to $_target."
        exit 0
    fi
    rm -f "$_prev_sha_file"   # one-shot
    echo "Rolled back: $_cur → $(git rev-parse --short HEAD)"
    _restart_bot
    exit 0
fi

# ── Normal path ──────────────────────────────────────────────────────────────
_cur_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
_cur_sha=$(git rev-parse --short HEAD 2>/dev/null)

echo "Fetching from origin..."
if ! _fetch_out=$(git fetch --quiet origin 2>&1); then
    echo "git fetch failed: $_fetch_out"
    exit 0
fi

_stashed=""
_maybe_stash() {
    # Stash if dirty + force; abort if dirty + no force. Sets _stashed on success.
    if git diff-index --quiet HEAD --; then return 0; fi
    if [[ "$force" != "1" && "$force" != "true" ]]; then
        echo "Uncommitted changes detected — refusing to proceed."
        echo "Files modified:"
        git status --short | head -10
        echo "Re-run with force=true to stash these and continue."
        return 1
    fi
    local _msg="ama-self-update auto-stash $(date +%Y%m%d_%H%M%S)"
    if git stash push -m "$_msg" -q; then
        _stashed="$_msg"
    fi
    return 0
}

# Optional branch switch
if [[ -n "$branch" && "$branch" != "$_cur_branch" ]]; then
    if ! git rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
        echo "Branch '$branch' not found on origin. Available remote branches:"
        git branch -r | sed 's|^[[:space:]]*origin/||' | grep -v '^HEAD' | head -10
        exit 0
    fi
    if ! _maybe_stash; then exit 0; fi
    if ! git checkout "$branch" >/dev/null 2>&1; then
        echo "git checkout $branch failed."
        exit 0
    fi
    _cur_branch="$branch"
fi

# Stash dirty tree before pull (if needed)
if ! _maybe_stash; then exit 0; fi

# Record pre-pull SHA for rollback BEFORE we touch anything
git rev-parse HEAD > "$_prev_sha_file"

# Hash files we care about, pre-pull
_req_before=$(sha256sum requirements.txt 2>/dev/null | awk '{print $1}')
_pm2_before=$(sha256sum pm2.config.js   2>/dev/null | awk '{print $1}')

# Pull (fast-forward only — non-FF means user has local commits; abort with hint)
_pull_out=$(git pull --ff-only origin "$_cur_branch" 2>&1)
_pull_rc=$?
if [[ $_pull_rc -ne 0 ]]; then
    echo "git pull --ff-only failed (likely non-fast-forward):"
    echo "$_pull_out" | tail -5
    echo
    echo "You have local commits on '$_cur_branch'. Rebase manually or push them first."
    exit 0
fi

_new_sha=$(git rev-parse --short HEAD)

if [[ "$_cur_sha" == "$_new_sha" ]]; then
    echo "Already up to date — branch $_cur_branch at $_new_sha."
    [[ -n "$_stashed" ]] && echo "Your local changes were stashed: $_stashed (git stash list)"
    exit 0
fi

# Detect what changed
_req_after=$(sha256sum requirements.txt 2>/dev/null | awk '{print $1}')
_pm2_after=$(sha256sum pm2.config.js   2>/dev/null | awk '{print $1}')
_deps_changed=0; [[ "$_req_before" != "$_req_after" ]] && _deps_changed=1
_pm2_changed=0;  [[ "$_pm2_before" != "$_pm2_after" ]] && _pm2_changed=1

_files_changed=$(git diff --name-only "$_cur_sha" "$_new_sha" 2>/dev/null | wc -l)

# Reinstall deps if requirements.txt changed
if [[ "$_deps_changed" == "1" ]]; then
    echo "requirements.txt changed — running pip install --user..."
    pip install --user --break-system-packages -r requirements.txt --quiet 2>&1 | tail -3
fi

# Summary
echo
echo "Updated: $_cur_sha → $_new_sha on $_cur_branch"
echo "Files changed: $_files_changed"
[[ "$_deps_changed" == "1" ]] && echo "Python deps reinstalled."
[[ "$_pm2_changed" == "1" ]] && echo "pm2.config.js changed."
[[ -n "$_stashed" ]] && echo "Local changes stashed: $_stashed (git stash list to recover)"

# Decide reload mode
if [[ "$_deps_changed" == "1" || "$_pm2_changed" == "1" ]]; then
    _restart_bot
else
    _reload_bot
fi
