#!/bin/bash
# extensions/cron/run.sh — fires due scheduled tasks by injecting them into the
# running bot's per-session queue file. The bot's long-poll loop processes the
# queue when the session lock frees. Cron does NOT spawn its own agent — the
# previous path tried to invoke core/mix/run_agent.sh (which doesn't exist) and
# silently lost every scheduled fire.

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

# Load env (TG_TOKEN etc.) without sourcing the full mix engine — the queue
# path doesn't need it, and sourcing 30+ shell files per tick is wasteful.
if [[ -f "${DIR}/.env" ]]; then
    set -a; source "${DIR}/.env"; set +a
fi

_log="${DIR}/brain/state/cron.log"
echo "[$(date)] Cron tick" >> "$_log"

# ── Learned-examples distillation ─────────────────────────────────────────────
# Regenerates brain/learned_examples.md from brain/state/learning_examples.jsonl
# (user reactions on bot messages). Cheap, no LLM call. Skips when source is
# absent. Runs every cron tick — file write is idempotent and fast.
if [[ -f "${DIR}/brain/state/learning_examples.jsonl" ]]; then
    python3 "${DIR}/tools/distill_examples.py" >> "$_log" 2>&1 || true
fi

# ── Scheduled task firing ─────────────────────────────────────────────────────
# scheduler.sh run_due emits records separated by \x1f (ASCII RS). Field order:
#   FIRE \x1f id \x1f chat_id \x1f thread_id \x1f skill \x1f model \x1f provider \x1f prompt
# Using \x1f (not \t) keeps empty fields from collapsing.
US=$(printf '\037')
_SCHED_FIRES=$(TOOL_action=run_due bash "${DIR}/tools/scheduler.sh" 2>/dev/null)

if [[ -n "$_SCHED_FIRES" ]]; then
    while IFS="$US" read -r _marker _id _chat_id _thread_id _skill _model _provider _prompt; do
        [[ "$_marker" != "FIRE" ]] && continue
        [[ -z "$_id" || -z "$_chat_id" ]] && continue

        # Session id matches router.sh's scheme
        _sid="tg_${_chat_id}"
        [[ -n "$_thread_id" ]] && _sid="tg_${_chat_id}_${_thread_id}"

        # Write the override sidecar FIRST so it's in place when run_agent
        # picks up the queued message. 24_agent_loop.sh reads it on session
        # start when input starts with "[SCHEDULED #N]". Sidecar persists
        # across fires (override is identical every fire) and is cleaned up
        # by scheduler.sh `remove` when the task is deleted.
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

        # Append the prompt to the session's queue. The bot's run_agent loop
        # pops one queued line at end-of-turn and re-enters. mark_done is
        # optimistic — if the agent crashes mid-run, mark_failed isn't called.
        # (Acceptable: cron tick will fire it again on next interval.)
        _queue_file="${DIR}/brain/state/queue_${_sid}"
        if printf '%s\n' "[SCHEDULED #${_id}] ${_prompt}" >> "$_queue_file"; then
            TOOL_action=mark_done TOOL_id="$_id" bash "${DIR}/tools/scheduler.sh" >/dev/null 2>&1
            echo "[$(date)] Scheduler: fired task #${_id} → queue_${_sid}" >> "$_log"
        else
            _result=$(TOOL_action=mark_failed TOOL_id="$_id" TOOL_reason="queue_write_failed" \
                      bash "${DIR}/tools/scheduler.sh" 2>/dev/null)
            echo "[$(date)] Scheduler: task #${_id} failed: $_result" >> "$_log"
            if [[ "$_result" == PAUSED* ]]; then
                _home_chat=$(python3 -c "import json; print(json.load(open('${DIR}/brain/config.json')).get('home_chat',''))" 2>/dev/null)
                if [[ -n "$_home_chat" && -n "${TG_TOKEN:-}" ]]; then
                    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
                        -H "Content-Type: application/json" \
                        -d "{\"chat_id\":\"$_home_chat\",\"text\":\"⏸ <b>Scheduled task #${_id} paused</b> after 2 consecutive failures. Use <code>/schedule resume ${_id}</code> to re-enable.\",\"parse_mode\":\"HTML\"}" \
                        > /dev/null 2>&1 || true
                fi
            fi
        fi
    done <<< "$_SCHED_FIRES"
fi
