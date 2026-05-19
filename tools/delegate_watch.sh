#!/bin/bash
# Tool: delegate_watch
# Watches an async delegate session and sends Telegram messages directly
# (not via queue — direct messages fire immediately, no user trigger needed).
#
# Spawned by delegate(mode=async, notify_session=...). Runs detached.
#
# Inputs (env vars):
#   DELEGATE_SESSION    — tmux session name (e.g. ama_a4cdb6e8)
#   NOTIFY_SESSION      — AMA session_id (e.g. tg_670967877 or tg_670967877_123)
#   NOTIFY_MSG_ID       — message_id to reply-to (optional)
#   AMA_DIR             — project root
#   TG_TOKEN            — Telegram bot token (inherited from bot env)
#   POLL_INTERVAL       — seconds between completion checks (default: 15)
#   PROGRESS_INTERVAL   — seconds between progress pings (default: 180)
#   WATCH_TIMEOUT       — max seconds before giving up (default: 1800)

AMA_DIR="${AMA_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
session="${DELEGATE_SESSION}"
notify="${NOTIFY_SESSION}"
reply_to="${NOTIFY_MSG_ID:-}"
poll="${POLL_INTERVAL:-15}"
progress_interval="${PROGRESS_INTERVAL:-180}"
timeout="${WATCH_TIMEOUT:-1800}"

if [[ -z "$session" || -z "$notify" ]]; then
    echo "delegate_watch: missing DELEGATE_SESSION or NOTIFY_SESSION" >&2
    exit 1
fi

sentinel="${AMA_DIR}/brain/state/delegate_${session}.done"
log_file="${AMA_DIR}/brain/state/delegate_${session}.log"
queue_file="${AMA_DIR}/brain/state/queue_${notify}"

# Parse chat_id and thread_id from notify session (format: tg_CHATID or tg_CHATID_THREADID)
_parse_session() {
    local sid="${1#tg_}"          # strip tg_ prefix
    chat_id="${sid%%_*}"          # everything before first _
    thread_id="${sid#*_}"         # everything after first _
    [[ "$thread_id" == "$chat_id" ]] && thread_id=""  # no underscore = no thread
}
_parse_session "$notify"

# Send a Telegram message directly; fallback to queue on failure
_tg_send() {
    local text="$1"
    if [[ -n "$TG_TOKEN" && -n "$chat_id" ]]; then
        local payload="{\"chat_id\":\"$chat_id\",\"text\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$text" 2>/dev/null || echo "\"$text\""),\"parse_mode\":\"HTML\"}"
        [[ -n "$thread_id" ]] && payload=$(echo "$payload" | python3 -c "import json,sys; d=json.load(sys.stdin); d['message_thread_id']=int('$thread_id'); print(json.dumps(d))" 2>/dev/null || echo "$payload")
        [[ -n "$reply_to" ]] && payload=$(echo "$payload" | python3 -c "import json,sys; d=json.load(sys.stdin); d['reply_parameters']={'message_id':int('$reply_to')}; print(json.dumps(d))" 2>/dev/null || echo "$payload")
        curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
            -H "Content-Type: application/json" -d "$payload" > /dev/null 2>&1 && return 0
    fi
    # Fallback: write to queue (processed on next user turn)
    printf '%s\n' "$text" >> "$queue_file"
}

_tail_log() {
    [[ -f "$log_file" && -s "$log_file" ]] \
        && tail -3 "$log_file" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-100 \
        || echo "working..."
}

elapsed=0
last_progress=0

while [[ $elapsed -lt $timeout ]]; do
    # ── Completion ────────────────────────────────────────────────────────────
    if [[ -f "$sentinel" ]]; then
        exit_code=$(tr -d '[:space:]' < "$sentinel" 2>/dev/null)
        mins=$(( elapsed / 60 )); secs=$(( elapsed % 60 ))
        if [[ "$exit_code" == "0" ]]; then
            _tg_send "⏱ <code>${mins}m${secs}s</code> — delegate <code>${session}</code> finished ✅
The agent will report results in the next message."
        else
            _tg_send "⏱ <code>${mins}m${secs}s</code> — delegate <code>${session}</code> errored ❌ (exit ${exit_code})
The agent will show the output in the next message."
        fi
        # Also queue so the agent turn picks up and reports
        printf '%s\n' "Delegate session $session completed (exit $exit_code, ${mins}m${secs}s). Report results now using delegate(mode=check, session=$session)" >> "$queue_file"
        exit 0
    fi

    # ── Crash ─────────────────────────────────────────────────────────────────
    if ! tmux has-session -t "$session" 2>/dev/null; then
        _tg_send "💥 Delegate <code>${session}</code> ended unexpectedly. Will check output."
        printf '%s\n' "Delegate session $session ended unexpectedly. Run delegate(mode=check, session=$session) to see output." >> "$queue_file"
        exit 1
    fi

    # ── Progress ping ─────────────────────────────────────────────────────────
    since_last=$(( elapsed - last_progress ))
    if [[ $elapsed -gt 0 && $since_last -ge $progress_interval ]]; then
        mins=$(( elapsed / 60 ))
        last_line=$(_tail_log)
        _tg_send "⏳ <code>${session}</code> still running (${mins}min)
↳ <code>${last_line}</code>"
        last_progress=$elapsed
    fi

    sleep "$poll"
    elapsed=$(( elapsed + poll ))
done

# ── Timeout ───────────────────────────────────────────────────────────────────
_tg_send "⏰ Delegate <code>${session}</code> timed out after ${timeout}s."
printf '%s\n' "Delegate session $session timed out. delegate(mode=check, session=$session) for partial output." >> "$queue_file"
