#!/bin/bash
# extensions/cron/run.sh — fires due scheduled tasks by running the agent
# inline (hermes-style) and delivering the result directly to Telegram via
# tg_send. We source the full mix + telegram engines so run_agent is callable
# from cron's process tree without depending on bot.sh's main poll loop.
#
# Why not the old queue approach: queue_<sid> is only consumed by an already-
# running run_agent at end-of-turn. Most sessions are idle most of the time,
# so scheduled fires sat in the queue forever and the user never saw the
# notification. Fired tasks now spawn their own run_agent — the agent's
# normal tg_send path delivers to Telegram regardless of chat activity.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$DIR" || exit 1

# Dedup lock: prevent overlapping cron ticks. Open fd FIRST, then flock the
# fd — reverse order silently no-ops.
_CRON_LOCK="${DIR}/brain/state/.cron.lock"
mkdir -p "$(dirname "$_CRON_LOCK")"
exec 9>"$_CRON_LOCK"
if ! flock -n 9; then
    exit 0
fi

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${DIR}/tools"

# Load env first (TG_TOKEN, MODEL, PROVIDER, BASE_URL etc.)
if [[ -f "${DIR}/.env" ]]; then
    set -a; source "${DIR}/.env"; set +a
fi

# Full engine load — needed so run_agent + tg_send are callable from this
# process. Sourcing cost is ~100-300ms per tick; acceptable at 5-min cadence.
# Failures here mean scheduled tasks can't fire; log and bail.
if ! source "${DIR}/core/mix/init.sh" 2>>"${DIR}/brain/state/cron.log"; then
    echo "[$(date)] Cron: failed to source core/mix/init.sh" >> "${DIR}/brain/state/cron.log"
    exit 1
fi
source "${DIR}/core/config.sh"
source "${DIR}/core/telegram/init.sh"
source "${DIR}/core/ui.sh"

_log="${DIR}/brain/state/cron.log"
echo "[$(date)] Cron tick" >> "$_log"

# ── Learned-examples distillation ─────────────────────────────────────────────
# Regenerates brain/learned_examples.md from brain/state/learning_examples.jsonl
# (user reactions on bot messages). Cheap, no LLM call. Skips when source is
# absent. Runs every cron tick — file write is idempotent and fast.
if [[ -f "${DIR}/brain/state/learning_examples.jsonl" ]]; then
    python3 "${DIR}/tools/distill_examples.py" >> "$_log" 2>&1 || true
fi

# ── Janitor: rotate logs, prune stale state ───────────────────────────────────
# Idempotent — runs every tick. Conservative TTL defaults (see tools/janitor.py
# top-of-file). Quiet by default so we don't spam cron.log on no-op ticks.
# Failures are absorbed; cleanup is best-effort.
python3 "${DIR}/tools/janitor.py" sweep --quiet >> "$_log" 2>&1 || true

# ── Scheduled task firing ─────────────────────────────────────────────────────
# scheduler.sh run_due emits records separated by \x1f (ASCII RS). Field order:
#   FIRE \x1f id \x1f chat_id \x1f thread_id \x1f skill \x1f model \x1f provider \x1f prompt
# Using \x1f (not \t) keeps empty fields from collapsing.
#
# Hermes-style inline execution: each due task spawns its own detached
# run_agent. The agent's normal tg_send/tg_edit path delivers the result to
# Telegram — no dependency on bot.sh's main loop picking up a queue file.
# Detach pattern is `( ( ... ) & )` per [[feedback-bash-detach-idiom]] so
# the agent survives this script's exit (cron tick returns immediately;
# the agent runs to completion in the background).
US=$(printf '\037')
_SCHED_FIRES=$(TOOL_action=run_due bash "${DIR}/tools/scheduler.sh" 2>/dev/null)

if [[ -n "$_SCHED_FIRES" ]]; then
    while IFS="$US" read -r _marker _id _chat_id _thread_id _skill _model _provider _prompt; do
        [[ "$_marker" != "FIRE" ]] && continue
        [[ -z "$_id" || -z "$_chat_id" ]] && continue

        # Session id matches router.sh's scheme so the override sidecar path
        # (read by 24_agent_loop.sh) lines up with what we write below.
        _sid="tg_${_chat_id}"
        [[ -n "$_thread_id" ]] && _sid="tg_${_chat_id}_${_thread_id}"

        # Override sidecar (model/provider/skill pin) — 24_agent_loop.sh reads
        # it when input starts with "[SCHEDULED #N]". Persists across fires;
        # scheduler.sh `remove` cleans it up when the task is deleted.
        if [[ -n "$_model" || -n "$_provider" || -n "$_skill" ]]; then
            _override_file="${DIR}/brain/state/sched_override_${_sid}_${_id}.json"
            M="$_model" P="$_provider" S="$_skill" python3 - "$_override_file" <<'PYEOF'
import json, os, sys
d = {}
if os.environ.get('M'): d['model']    = os.environ['M']
if os.environ.get('P'): d['provider'] = os.environ['P']
if os.environ.get('S'): d['skill']    = os.environ['S']
open(sys.argv[1], 'w').write(json.dumps(d))
PYEOF
        fi

        # Spawn the agent detached. run_agent will:
        #   1. acquire flock on the session (waits if user is mid-chat)
        #   2. show "🕒 Queued" or "⏳ Thinking…" in Telegram immediately
        #   3. apply the override sidecar (model/provider/skill swap)
        #   4. execute the turn loop, calling tg_send/tg_edit for output
        # mark_done is optimistic — fired now so the next_run advances even
        # if the agent crashes mid-run. Cron's normal retry doesn't apply
        # (mark_failed is never called from this path); failures show up
        # in Telegram as error messages from the agent itself.
        _scheduled_input="[SCHEDULED #${_id}] ${_prompt}"
        ( ( set -m; run_agent "$_chat_id" "$_scheduled_input" "" "[]" "$_thread_id" "$_sid" "" "AMA_SCHEDULED" "$_skill" "0" ) & ) \
            >/dev/null 2>&1
        TOOL_action=mark_done TOOL_id="$_id" bash "${DIR}/tools/scheduler.sh" >/dev/null 2>&1
        echo "[$(date)] Scheduler: spawned task #${_id} → session $_sid (chat=$_chat_id thread=${_thread_id:-none})" >> "$_log"
    done <<< "$_SCHED_FIRES"
fi
