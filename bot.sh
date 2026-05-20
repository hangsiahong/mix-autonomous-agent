#!/bin/bash

# bot.sh - AMA Entry Point

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load environment variables
if [ -f "${DIR}/.env" ]; then
    set -a
    source "${DIR}/.env"
    set +a
fi

source "${DIR}/core/mix/init.sh"
source "${DIR}/core/config.sh"
source "${DIR}/core/telegram/init.sh"
source "${DIR}/core/ui.sh"

# Load extensions
if [ -d "${DIR}/extensions" ]; then
    for ext in "${DIR}/extensions"/*/init.sh; do
        [ -f "$ext" ] && source "$ext"
    done
fi

OFFSET_FILE="${DIR}/brain/last_offset"
[ ! -f "$OFFSET_FILE" ] && echo "0" > "$OFFSET_FILE"

# Single-instance lock — broad-sweep: kill ANY other bot.sh process (not just
# the one in bot.pid). Live testing hit 13 zombie bots; each turn was 13× API
# calls, instant rate-limit storms, curator never finishing. The previous lock
# only killed brain/state/bot.pid which missed orphans (PPID=1 from earlier
# crashes / disowned shells).
LOCK_FILE="${DIR}/brain/state/bot.pid"
_OTHER_BOTS=$(pgrep -f "bash bot.sh" 2>/dev/null | grep -v "^$$$" || true)
if [ -n "$_OTHER_BOTS" ]; then
    echo "AMA: Found other bot.sh instances → terminating before start: $(echo $_OTHER_BOTS | tr '\n' ' ')"
    echo "$_OTHER_BOTS" | xargs -r kill -TERM 2>/dev/null || true
    sleep 1
    # Force-kill any survivor
    _STRAGGLER=$(pgrep -f "bash bot.sh" 2>/dev/null | grep -v "^$$$" || true)
    [ -n "$_STRAGGLER" ] && echo "$_STRAGGLER" | xargs -r kill -KILL 2>/dev/null || true
    sleep 1
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"; exit 0' EXIT INT TERM

# Hot-reload on SIGHUP: re-sources all core files without restarting the long-poll loop.
# Bash only runs trap handlers between commands, so this is safe — no mid-command interruption.
# Trigger: kill -HUP $(cat brain/state/bot.pid)  or  /reload command in Telegram.
_hot_reload() {
    echo "AMA: Hot-reload triggered (SIGHUP) — re-sourcing core files..."
    # Re-load env in case .env changed
    if [ -f "${DIR}/.env" ]; then
        set -a; source "${DIR}/.env"; set +a
    fi
    source "${DIR}/core/mix/init.sh"
    source "${DIR}/core/config.sh"
    source "${DIR}/core/telegram/init.sh"
    source "${DIR}/core/ui.sh"
    if [ -d "${DIR}/extensions" ]; then
        for ext in "${DIR}/extensions"/*/init.sh; do
            [ -f "$ext" ] && source "$ext"
        done
    fi
    echo "AMA: Hot-reload complete. New function definitions active from next call."
}
trap '_hot_reload' HUP

echo "AMA Bot Starting..."

# Validate critical JSON files and restore from backup if corrupt.
# Protects against the agent writing malformed JSON to brain/config.json
# or brain/tools.json getting corrupted mid-session.
for _jf in "brain/config.json" "brain/tools.json"; do
    if [[ -f "$_jf" ]]; then
        if ! python3 -c "import json; json.load(open('$_jf'))" 2>/dev/null; then
            echo "AMA: WARNING — $_jf is invalid JSON!"
            if [[ -f "${_jf}.bak" ]] && python3 -c "import json; json.load(open('${_jf}.bak'))" 2>/dev/null; then
                cp "${_jf}.bak" "$_jf"
                echo "AMA: Restored $_jf from backup."
            else
                echo "AMA: No valid backup found for $_jf — attempting git restore."
                git checkout "$_jf" 2>/dev/null && echo "AMA: Restored $_jf from git." || \
                    echo "AMA: Could not restore $_jf — bot may behave incorrectly."
            fi
        fi
    fi
done

tg_set_commands

# Recover tools.json if it was wiped (e.g. old bot killed mid-reflection before this fix)
_tools_cur=$(python3 -c "import json; d=json.load(open('brain/tools.json')); print(len(d))" 2>/dev/null || echo 0)
if [[ "$_tools_cur" -eq 0 ]]; then
    # Try legacy .bak file first, then fall back to git
    _latest_bak=$(ls -t brain/tools.json.bak.* 2>/dev/null | head -1)
    if [[ -n "$_latest_bak" ]]; then
        echo "AMA: Recovering tools.json from backup"
        mv "$_latest_bak" brain/tools.json
    else
        echo "AMA: tools.json is empty — restoring from git"
        git checkout brain/tools.json 2>/dev/null || true
    fi
fi
rm -f brain/tools.json.bak.* 2>/dev/null || true
unset _tools_cur _latest_bak

# Clean up stale PID files left by a previous (crashed/killed) instance
for _stale in "${DIR}/brain/state"/run_*.pid; do
    [[ -f "$_stale" ]] || continue
    _spid=$(cut -d'|' -f1 "$_stale" 2>/dev/null)
    if [[ -n "$_spid" ]] && ! kill -0 "$_spid" 2>/dev/null; then
        rm -f "$_stale"
    fi
done
unset _stale _spid

# Drain stale Telegram messages accumulated while bot was offline
_DRAIN=$(curl -s "https://api.telegram.org/bot${TG_TOKEN}/getUpdates?timeout=0&limit=100&offset=$(cat "$OFFSET_FILE")")
_DRAIN_LAST=$(echo "$_DRAIN" | python3 -c "import json,sys; r=json.load(sys.stdin); res=r.get('result',[]); print(res[-1].get('update_id','') if res else '')" 2>/dev/null)
if [[ -n "$_DRAIN_LAST" ]]; then
    _DRAIN_COUNT=$(echo "$_DRAIN" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('result',[])))" 2>/dev/null || echo 0)
    echo "AMA: Draining $_DRAIN_COUNT stale update(s) up to ID $_DRAIN_LAST..."
    echo $((_DRAIN_LAST + 1)) > "$OFFSET_FILE"
fi
unset _DRAIN _DRAIN_LAST _DRAIN_COUNT

# Enable job control so every backgrounded `( run_agent ... ) &` (both the
# autonomy-job dispatch below and the per-update dispatch inside the pipe
# subshell further down) becomes a process-group leader. Tested: bash's `set
# -m` does NOT propagate the PGID-splitting behavior into child subshells via
# inheritance alone — each subshell that backgrounds work needs its own
# `set -m`. See the duplicate `set -m` inside the `while read -r update` loop.
set -m

while true; do
    # Check for background autonomy jobs
    mkdir -p "${DIR}/brain/jobs"
    for job in "${DIR}/brain/jobs"/job_*.env; do
        if [ -f "$job" ]; then
            # Load job parameters
            source "$job"
            echo "AMA: Triggering autonomous continuation for session $session_id..."
            # Run agent in background group
            ( set -m; run_agent "$chat_id" "$text" "$user_id" "[]" "$thread_id" "$session_id" "" "AMA_AUTONOMOUS" "" ) &
            # Remove job file so it doesn't loop
            rm -f "$job"
        fi
    done

    OFFSET=$(cat "$OFFSET_FILE")
    UPDATES=$(tg_poll "$OFFSET")
    
    if [[ -z "$UPDATES" ]]; then
        sleep 5; continue
    fi

    OK=$(echo "$UPDATES" | python3 -c "import json,sys; print(json.load(sys.stdin).get('ok','false'))" 2>/dev/null)
    if [[ "$OK" != "True" && "$OK" != "true" ]]; then
        ERR_CODE=$(echo "$UPDATES" | python3 -c "import json,sys; print(json.load(sys.stdin).get('error_code',0))" 2>/dev/null)
        if [[ "$ERR_CODE" == "409" ]]; then
            echo "AMA: 409 Conflict — another instance owns the poll. Exiting." >&2
            exit 1
        fi
        echo "DEBUG: Poll failed or not JSON: $UPDATES" >&2
        sleep 5; continue
    fi

    echo "$UPDATES" | python3 -c "
import json, sys
for u in json.load(sys.stdin).get('result', []):
    print(json.dumps(u))
" | while read -r update; do
        # Job control on inside this pipe subshell — makes every backgrounded
        # `( run_agent ... ) &` a process-group leader (PGID == PID). Required
        # for kill_tree's group-kill fast path in router.sh to safely target
        # a single agent's tree without hitting bot.sh's group. Tested: without
        # this, sibling agents dispatched from this same loop iteration share
        # the pipe-subshell's PGID, making group-kill a foot-gun.
        # Setting once persists across iterations (it's a shell option).
        set -m
        if [[ -z "$update" || "$update" == "null" ]]; then continue; fi
        UPDATE_ID=$(echo "$update" | python3 -c "import json,sys; print(json.load(sys.stdin).get('update_id',''))" 2>/dev/null)
        if [[ -z "$UPDATE_ID" || "$UPDATE_ID" == "null" ]]; then
            echo "DEBUG: Bad update: $update" >&2
            continue
        fi
        echo "Processing update $UPDATE_ID..."
        # T1-2: Global + per-user agent cap — reject when overloaded
        # Parse sender once; used for both per-user cap and drop notification
        _update_user=$(echo "$update" | python3 -c "
import json,sys
u=json.loads(sys.stdin.read())
msg=u.get('message') or {}
cbq=u.get('callback_query') or {}
frm=(msg.get('from') or cbq.get('from')) or {}
print(str(frm.get('id','')))" 2>/dev/null)
        _update_chat=$(echo "$update" | python3 -c "
import json,sys
u=json.loads(sys.stdin.read())
print((u.get('message') or {}).get('chat',{}).get('id',''))" 2>/dev/null)

        _live_agents=0
        _user_agents=0
        for _pf in "${DIR}/brain/state"/run_*.pid; do
            [[ -f "$_pf" ]] || continue
            _ppid=$(cut -d'|' -f1 "$_pf" 2>/dev/null)
            if kill -0 "$_ppid" 2>/dev/null; then
                _live_agents=$((_live_agents + 1))
                # Field 5 = user_id (added alongside the existing 4 fields)
                _pf_user=$(cut -d'|' -f5 "$_pf" 2>/dev/null)
                [[ "$_pf_user" == "$_update_user" ]] && _user_agents=$((_user_agents + 1))
            else
                rm -f "$_pf"
            fi
        done

        # Global cap
        _max_agents="${MAX_CONCURRENT_AGENTS:-10}"
        if [[ "$_live_agents" -ge "$_max_agents" ]]; then
            echo "AMA: Global queue full ($_live_agents/$_max_agents). Dropping $UPDATE_ID." >&2
            [[ -n "$_update_chat" ]] && tg_send "$_update_chat" "⚠️ Bot is at capacity. Please try again shortly." "" || true
            echo $((UPDATE_ID + 1)) > "$OFFSET_FILE"
            continue
        fi

        # Per-user cap — prevents one user from monopolising the pool (important for groups)
        _max_per_user="${MAX_AGENTS_PER_USER:-3}"
        if [[ -n "$_update_user" && "$_user_agents" -ge "$_max_per_user" ]]; then
            echo "AMA: User $_update_user at per-user limit ($_user_agents/$_max_per_user). Dropping $UPDATE_ID." >&2
            [[ -n "$_update_chat" ]] && tg_send "$_update_chat" "⚠️ You already have $_user_agents tasks running. Please wait for one to finish before sending more." "" || true
            echo $((UPDATE_ID + 1)) > "$OFFSET_FILE"
            continue
        fi
        tg_handle_update "$update"
        echo $((UPDATE_ID + 1)) > "$OFFSET_FILE"
    done
    sleep 1
done