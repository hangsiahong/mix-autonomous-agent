#!/bin/bash
# extensions/cron/run.sh

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Dedup lock: prevent multiple concurrent cron instances (happens on bot restart).
# Must `exec 9>` to OPEN the fd before flock can act on it — the previous order
# (flock-then-exec) made the first flock always fail (no such fd), causing the
# whole script to exit 0 silently. Scheduled tasks never fired as a result.
_CRON_LOCK="${DIR}/brain/state/.cron.lock"
mkdir -p "$(dirname "$_CRON_LOCK")"
exec 9>"$_CRON_LOCK"
if ! flock -n 9; then
    exit 0  # Another cron tick is already running, skip silently
fi

source "${DIR}/core/mix/00_header.sh"
source "${DIR}/core/mix/16_api.sh"
source "${DIR}/core/mix/34_error_classifier.sh"
source "${DIR}/core/mix/38_rate_limit.sh"
source "${DIR}/core/mix/01_config.sh"

# _now must be defined FIRST — used in every cooldown calculation below
_now=$(date +%s)

echo "[$(date)] Running background maintenance..."

# 1. Error pattern detection + self-heal trigger (self-healing loop)
# Alert cooldown: only alert once per hour to avoid spam
_ALERT_MARKER="${DIR}/brain/state/.error_alert_last_sent"
_alert_last=0
[[ -f "$_ALERT_MARKER" ]] && _alert_last=$(cat "$_ALERT_MARKER" 2>/dev/null || echo 0)
_alert_age=$(( (_now - _alert_last) / 60 ))  # minutes since last alert

if python3 "${DIR}/tools/error_analyzer.py" report --hours 24 > /tmp/ama_error_report.txt 2>&1; then
    echo "[$(date)] Error report: no critical patterns"
else
    # Exit code 1 = needs_attention
    echo "[$(date)] Error report flagged issues"
    # Only create heal request if one doesn't already exist (don't spam)
    if [[ ! -f "${DIR}/brain/state/heal_request.json" ]]; then
        python3 "${DIR}/tools/error_analyzer.py" create_request 24 2>/dev/null && \
            echo "[$(date)] Heal request created for next agent session"
    else
        echo "[$(date)] Heal request already pending — skipping re-creation"
    fi
    # Only alert admin once per hour
    if [[ "$_alert_age" -ge 60 || "$_alert_last" -eq 0 ]]; then
        _home_chat=$(python3 -c "import json; print(json.load(open('${DIR}/brain/config.json')).get('home_chat',''))" 2>/dev/null)
        if [[ -n "$_home_chat" && -n "${TG_TOKEN:-}" ]]; then
            _report_summary=$(python3 "${DIR}/tools/error_analyzer.py" patterns --hours 24 2>/dev/null | head -5)
            curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
                -H "Content-Type: application/json" \
                -d "{\"chat_id\":\"$_home_chat\",\"text\":\"🔧 <b>AMA Error Patterns</b>\\n<pre>${_report_summary}</pre>\\nSelf-heal will run next session.\",\"parse_mode\":\"HTML\"}" \
                > /dev/null 2>&1 || true
            echo "$_now" > "$_ALERT_MARKER"
            echo "[$(date)] Admin alert sent"
        fi
    else
        echo "[$(date)] Alert suppressed (sent ${_alert_age}m ago, cooldown=60m)"
    fi
fi
rm -f /tmp/ama_error_report.txt

# 2a. Cleanup user-uploaded files older than 2 hours
_uploads_dir="${DIR}/brain/state/uploads"
if [[ -d "$_uploads_dir" ]]; then
    find "$_uploads_dir" -maxdepth 1 -type f -mmin +120 -delete 2>/dev/null
    echo "[$(date)] Upload cleanup: removed files older than 2h from brain/state/uploads/"
fi

# 2a2. Cleanup skill index caches for idle sessions (older than 24h)
find "${DIR}/brain/state" -maxdepth 1 \( -name "skill_cache_*.txt" -o -name "skill_mtime_*" \) -mmin +1440 -delete 2>/dev/null

# 2a3. Cleanup passive context buffers for idle sessions (older than 24h)
# These accumulate in mention_only/silent groups — remove when session is long-gone
find "${DIR}/brain/state" -maxdepth 1 -name "passive_*.jsonl" -mmin +1440 -delete 2>/dev/null && \
    echo "[$(date)] Passive context cleanup: removed stale passive_*.jsonl files"

# 2b. Cleanup log files (keep last N lines)
for logfile in "${DIR}/brain/state/trajectories.jsonl" \
               "${DIR}/brain/state/tool_usage.jsonl" \
               "${DIR}/brain/state/usage_log.jsonl" \
               "${DIR}/brain/state/error_log.jsonl" \
               "${DIR}/logs/curator.log" \
               "${DIR}/logs/scheduler_debug.log" \
               "${DIR}/logs/bot.log"; do
    if [[ -f "$logfile" ]]; then
        local_keep=500
        [[ "$logfile" == *tool_usage* || "$logfile" == *error_log* ]] && local_keep=200
        [[ "$logfile" == *.log ]] && local_keep=300
        line_count=$(wc -l < "$logfile")
        if [[ $line_count -gt $((local_keep + 100)) ]]; then
            tail -n "$local_keep" "$logfile" > "${logfile}.tmp" && mv "${logfile}.tmp" "$logfile"
            echo "[$(date)] Trimmed $logfile to $local_keep lines"
        fi
    fi
done

# 2c. Operational debt — closes today's friction points (zombie bots, stale
# pids, orphan queues, dead locks). All deterministic, all cheap. Each block
# is idempotent: if there's nothing to clean, no-op.

# Zombie bot.sh: any `bash bot.sh` process not matching brain/state/bot.pid.
# bot.sh's startup guard already does this on launch — this cron pass catches
# the case where the user spawns a duplicate manually and forgets.
if [[ -f "${DIR}/brain/state/bot.pid" ]]; then
    _canonical_pid=$(cat "${DIR}/brain/state/bot.pid" 2>/dev/null)
    _zombies=$(pgrep -f "bash ${DIR}/bot.sh\|bash bot.sh" 2>/dev/null | grep -v "^${_canonical_pid}$" || true)
    # Also filter out the cron loop's bash subshell (child of canonical bot) — pstree style
    if [[ -n "$_zombies" && -n "$_canonical_pid" ]]; then
        # Get bot's direct children so we don't kill our own cron-loop sibling
        _bot_kids=$(ps --ppid "$_canonical_pid" -o pid= 2>/dev/null | tr -s ' \n' ' ')
        _grandkids=""
        for _k in $_bot_kids; do
            _grandkids+="$(ps --ppid "$_k" -o pid= 2>/dev/null | tr -s ' \n' ' ')"
        done
        _safe_kids=" $_bot_kids $_grandkids "
        for _zpid in $_zombies; do
            if [[ "$_safe_kids" == *" $_zpid "* ]]; then continue; fi
            kill -TERM "$_zpid" 2>/dev/null && \
                echo "[$(date)] Killed zombie bot.sh process $_zpid (not bot.pid=$_canonical_pid)"
        done
    fi
fi

# Stale run_<sid>.pid: agent worker pid files whose process is dead. Left
# behind when a worker dies mid-turn or gets SIGKILL'd. Causes router's
# /stop and /status commands to think there's an active agent when there
# isn't.
for _pf in "${DIR}/brain/state/"run_*.pid; do
    [[ -f "$_pf" ]] || continue
    _pid_data=$(cat "$_pf" 2>/dev/null)
    _agent_pid=$(echo "$_pid_data" | cut -d'|' -f1)
    if [[ -n "$_agent_pid" ]] && ! kill -0 "$_agent_pid" 2>/dev/null; then
        rm -f "$_pf"
        echo "[$(date)] Cleaned stale run pid: $(basename "$_pf") (pid $_agent_pid dead)"
    fi
done

# Orphan queue files: a queue_<sid> file with no recent activity (>2h old)
# and no matching live history. Means session abandoned mid-queue. Drain it.
find "${DIR}/brain/state" -maxdepth 1 -name "queue_*" -type f -mmin +120 2>/dev/null | while read -r _qf; do
    rm -f "$_qf" && echo "[$(date)] Drained orphan queue: $(basename "$_qf") (idle >2h)"
done

# Orphan sched_override sidecars: scheduler.sh `remove` already cleans them,
# but if the user manually edits scheduled_tasks.json, sidecars linger.
if [[ -f "${DIR}/brain/state/scheduled_tasks.json" ]]; then
    _active_ids=$(python3 -c "
import json
try:
    print(' '.join(str(t.get('id','')) for t in json.load(open('${DIR}/brain/state/scheduled_tasks.json'))))
except: pass" 2>/dev/null)
    for _sf in "${DIR}/brain/state/"sched_override_*.json; do
        [[ -f "$_sf" ]] || continue
        # extract id (last _N.json before extension)
        _sf_id=$(basename "$_sf" .json | grep -oE '_[0-9]+$' | tr -d '_')
        [[ -z "$_sf_id" ]] && continue
        if ! echo " $_active_ids " | grep -q " $_sf_id "; then
            rm -f "$_sf" && echo "[$(date)] Cleaned orphan sidecar: $(basename "$_sf") (no matching task id)"
        fi
    done
fi

# Stale session locks: brain/state/locks/<sid>.lock files. flock releases on
# process exit but the FILE persists. If the locked-fd holder is dead, the
# lock is already released — we just remove the now-empty file.
for _lf in "${DIR}/brain/state/locks/"*.lock; do
    [[ -f "$_lf" ]] || continue
    # If no process has the file open (lsof empty) AND it's been touched
    # >1h ago, safe to remove.
    if ! lsof "$_lf" >/dev/null 2>&1; then
        if [[ $(find "$_lf" -mmin +60 2>/dev/null) ]]; then
            rm -f "$_lf" && echo "[$(date)] Removed unheld session lock: $(basename "$_lf")"
        fi
    fi
done

# Stale .cron.lock: ours specifically. If our exec 9>$LOCK at the top of
# this script took the lock and we're still running, no other process holds
# it. If a prior cron crashed mid-tick, the lock file persists but isn't
# held — flock would have re-acquired it for us. So this file is fine as-is;
# only clean it if it's a stale pre-fix-era leftover (older than 1 day).
if [[ -f "${DIR}/brain/state/.cron.lock" ]]; then
    if [[ $(find "${DIR}/brain/state/.cron.lock" -mtime +1 2>/dev/null) ]]; then
        # Won't actually free anything we're using — we hold the lock as fd 9
        # within this script's process, and removing a held file leaves the
        # lock active. But it cleans the file timestamp.
        :  # no-op, kept here as documentation
    fi
fi

# Orphan prefetch caches: brain/state/prefetch_<sid> files older than 24h
find "${DIR}/brain/state" -maxdepth 1 -name "prefetch_*" -mmin +1440 -delete 2>/dev/null

# Old archived session histories: brain/state/sessions/history_*_*.json
# accumulate forever. Keep last 30 days.
if [[ -d "${DIR}/brain/state/sessions" ]]; then
    _old=$(find "${DIR}/brain/state/sessions" -maxdepth 1 -name "history_*.json" -mtime +30 2>/dev/null | wc -l)
    if [[ "$_old" -gt 0 ]]; then
        find "${DIR}/brain/state/sessions" -maxdepth 1 -name "history_*.json" -mtime +30 -delete 2>/dev/null
        echo "[$(date)] Archived sessions cleanup: removed $_old history file(s) older than 30 days"
    fi
fi

# 3. Monthly memory pruning — remove memories unused for 30+ days
MEMORY_PRUNE_MARKER="${DIR}/brain/state/.memory_last_pruned"
_last_prune=0
if [[ -f "$MEMORY_PRUNE_MARKER" ]]; then
    _last_prune=$(cat "$MEMORY_PRUNE_MARKER" 2>/dev/null || echo 0)
fi
_days_since=$(( (_now - _last_prune) / 86400 ))
if [[ $_days_since -ge 30 ]]; then
    echo "[$(date)] Running monthly memory pruning (${_days_since} days since last prune)..."
    _prune_result=$(python3 "${DIR}/tools/memory_helper.py" prune 30 2>/dev/null)
    echo "[$(date)] $_prune_result"
    echo "$_now" > "$MEMORY_PRUNE_MARKER"
fi

# 4. Weekly memory consolidation (openclaw dreaming pattern):
#    Distill session recaps into concise facts and merge into brain/state/MEMORY.md
MEMORY_CONSOLIDATE_MARKER="${DIR}/brain/state/.memory_last_consolidated"
_last_consolidate=0
if [[ -f "$MEMORY_CONSOLIDATE_MARKER" ]]; then
    _last_consolidate=$(cat "$MEMORY_CONSOLIDATE_MARKER" 2>/dev/null || echo 0)
fi
_days_since_consolidate=$(( (_now - _last_consolidate) / 86400 ))
if [[ $_days_since_consolidate -ge 7 ]]; then
    echo "[$(date)] Running weekly memory consolidation..."
    _recap_file="${DIR}/brain/state/session_recaps.jsonl"
    if [[ -f "$_recap_file" && -s "$_recap_file" ]]; then
        _mem_file="${DIR}/brain/state/MEMORY.md"
        _current_memory=""
        [[ -f "$_mem_file" ]] && _current_memory=$(cat "$_mem_file")

        _consolidation_result=$(python3 -c "
import json, sys, subprocess, os
recap_file = sys.argv[1]
mem_file = sys.argv[2]
api_key = os.environ.get('API_KEY') or os.environ.get('GEMINI_KEY') or ''
model = os.environ.get('MODEL', 'gemini-2.5-flash')
base_url = os.environ.get('BASE_URL', 'https://generativelanguage.googleapis.com/v1beta/openai')

# Read last 20 recaps
try:
    lines = open(recap_file).readlines()
    recaps = []
    for line in lines[-20:]:
        e = json.loads(line)
        recaps.append(e.get('recap','').strip())
    recaps_text = '\n\n---\n\n'.join(recaps[:10])
except Exception as e:
    print(f'Error reading recaps: {e}', file=sys.stderr)
    sys.exit(1)

current_memory = open(mem_file).read().strip() if os.path.exists(mem_file) else ''

prompt = f'''You are a memory consolidator. Review these session recaps and extract NEW facts worth keeping long-term.

CURRENT MEMORY.md (what is already known):
{current_memory[:2000] if current_memory else '(empty)'}

RECENT SESSION RECAPS:
{recaps_text[:3000]}

Your task: Output ONLY new facts not already in MEMORY.md. Format as a concise bullet list.
Rules:
- Only include stable, reusable facts (user preferences, environment facts, recurring patterns)
- Skip one-off tasks, completed work, or things that change frequently
- Max 10 new bullets. If nothing new, output exactly: NO_NEW_FACTS
'''

import requests
resp = requests.post(
    f'{base_url}/chat/completions',
    headers={'Authorization': f'Bearer {api_key}', 'Content-Type': 'application/json'},
    json={'model': model, 'messages': [{'role':'user','content':prompt}], 'max_tokens': 500},
    timeout=30
)
if resp.ok:
    result = resp.json().get('choices',[{}])[0].get('message',{}).get('content','').strip()
    if result and result != 'NO_NEW_FACTS' and len(result) > 10:
        print(result)
    else:
        print('NO_NEW_FACTS')
else:
    print(f'API error {resp.status_code}', file=sys.stderr)
    sys.exit(1)
" "$_recap_file" "$_mem_file" 2>/dev/null)

        if [[ -n "$_consolidation_result" && "$_consolidation_result" != "NO_NEW_FACTS" ]]; then
            # Append new facts to MEMORY.md
            _ts=$(date '+%Y-%m-%d')
            {
                [[ -s "$_mem_file" ]] && cat "$_mem_file" && echo ""
                echo ""
                echo "## Consolidated from session recaps ($_ts)"
                echo "$_consolidation_result"
            } > "${_mem_file}.tmp" && mv "${_mem_file}.tmp" "$_mem_file"
            echo "[$(date)] Memory consolidated: new facts added to MEMORY.md"
        else
            echo "[$(date)] Memory consolidation: no new facts to add"
        fi
    fi
    echo "$_now" > "$MEMORY_CONSOLIDATE_MARKER"
fi


# 5. Scheduled tasks (user-defined recurring jobs from /schedule + scheduler tool)
# Runs each tick: asks the scheduler tool which tasks are due, fires them one by
# one with their pinned model/provider/skill via env override. After each run
# reports success/failure back so the scheduler can update next_run + handle the
# retry-once-then-alert policy.
_SCHED_FIRES=$(TOOL_action=run_due bash "${DIR}/tools/scheduler.sh" 2>/dev/null)
if [[ -n "$_SCHED_FIRES" ]]; then
    # Need bot.sh runtime for run_agent — but cron runs separately. So instead
    # of invoking run_agent directly, we *inject* the prompt into the session's
    # queue file. The next time the bot polls and the lock frees, run_agent
    # picks it up. This is the same mechanism /queue uses.
    #
    # Trade-off: scheduled task fires on the bot's next idle cycle, not exactly
    # at the scheduled second. Acceptable — cron tick is 5min anyway.

    # IFS=$'\x1f' (ASCII RS), matching scheduler.sh's emit. Plain \t would
    # collapse adjacent empty fields and shift columns.
    while IFS=$'\x1f' read -r _marker _id _chat_id _thread_id _skill _model _provider _prompt; do
        [[ "$_marker" != "FIRE" ]] && continue
        [[ -z "$_id" || -z "$_chat_id" ]] && continue

        # Build a session_id matching router.sh's scheme
        _sid="tg_${_chat_id}"
        [[ -n "$_thread_id" ]] && _sid="tg_${_chat_id}_${_thread_id}"

        _queue_file="${DIR}/brain/state/queue_${_sid}"
        mkdir -p "$(dirname "$_queue_file")"

        # Don't pile up duplicates. If there's already an unconsumed
        # [SCHEDULED #N] entry for THIS task in the queue, skip — the user is
        # idle, the previous fire is still waiting to be processed. Otherwise
        # a 2m task left idle for 30m floods the user with 15 reminders the
        # moment they next type. (Caught live 2026-05-19.)
        if [[ -f "$_queue_file" ]] && grep -qF "[SCHEDULED #${_id}] " "$_queue_file"; then
            # Still bump next_run so the task doesn't fire again on the very
            # next tick — let mark_done update the timestamp.
            TOOL_action=mark_done TOOL_id="$_id" bash "${DIR}/tools/scheduler.sh" >/dev/null 2>&1
            echo "[$(date)] Scheduler: task #${_id} already queued for ${_sid} — skipping duplicate fire"
            continue
        fi

        # Tag the message so the agent and the user can see this came from
        # the scheduler, not a real Telegram message.
        printf '%s\n' "[SCHEDULED #${_id}] ${_prompt}" >> "$_queue_file" \
            && TOOL_action=mark_done TOOL_id="$_id" bash "${DIR}/tools/scheduler.sh" >/dev/null 2>&1 \
            && echo "[$(date)] Scheduler: fired task #${_id} → queue_${_sid}" \
            || {
                _result=$(TOOL_action=mark_failed TOOL_id="$_id" TOOL_reason="queue_write_failed" bash "${DIR}/tools/scheduler.sh" 2>/dev/null)
                echo "[$(date)] Scheduler: task #${_id} failed: $_result"
                # Alert TG_ADMIN on PAUSED state (after 2 consecutive failures)
                if [[ "$_result" == PAUSED* ]]; then
                    _home_chat=$(python3 -c "import json; print(json.load(open('${DIR}/brain/config.json')).get('home_chat',''))" 2>/dev/null)
                    if [[ -n "$_home_chat" && -n "${TG_TOKEN:-}" ]]; then
                        curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
                            -H "Content-Type: application/json" \
                            -d "{\"chat_id\":\"$_home_chat\",\"text\":\"⏸ <b>Scheduled task #${_id} paused</b> after 2 consecutive failures. Use <code>/schedule resume ${_id}</code> to re-enable.\",\"parse_mode\":\"HTML\"}" \
                            > /dev/null 2>&1 || true
                    fi
                fi
            }

        # Store the model/provider override so the bot picks it up when run_agent
        # processes this queued message. We write a sidecar that 24_agent_loop.sh
        # reads at session-start time (alongside model_${sid}).
        # NOTE: this overrides the session model for this single turn only —
        # cleaned up by run_agent after the queued message is consumed.
        if [[ -n "$_model" || -n "$_provider" || -n "$_skill" ]]; then
            _override_file="${DIR}/brain/state/sched_override_${_sid}_${_id}.json"
            # Env vars MUST come BEFORE `python3` so they enter the env;
            # placing them after the command's argv passes them as positional
            # parameters (which Python ignores) and the sidecar ends up empty.
            M="$_model" P="$_provider" S="$_skill" python3 -c "
import json, os, sys
d = {}
if os.environ.get('M'): d['model'] = os.environ['M']
if os.environ.get('P'): d['provider'] = os.environ['P']
if os.environ.get('S'): d['skill'] = os.environ['S']
open(sys.argv[1],'w').write(json.dumps(d))" "$_override_file"
        fi
    done <<< "$_SCHED_FIRES"
fi

echo "[$(date)] Maintenance complete."
