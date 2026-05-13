#!/bin/bash
# Tool: delegate_watch
# Watches an async delegate session and keeps the user informed:
#   - Progress pings every PROGRESS_INTERVAL seconds while running
#   - Final notification on completion, error, or timeout
#
# Spawned automatically by delegate(mode=async, notify_session=...).
# Runs detached so it outlives the parent agent turn.
#
# Inputs (env vars set by delegate.py):
#   DELEGATE_SESSION    — tmux session name (e.g. ama_a4cdb6e8)
#   NOTIFY_SESSION      — AMA session_id to notify (e.g. tg_670967877)
#   AMA_DIR             — project root
#   POLL_INTERVAL       — seconds between completion checks (default: 15)
#   PROGRESS_INTERVAL   — seconds between "still running" pings (default: 180 = 3 min)
#   WATCH_TIMEOUT       — max seconds before giving up (default: 1800 = 30 min)

AMA_DIR="${AMA_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
session="${DELEGATE_SESSION}"
notify="${NOTIFY_SESSION}"
poll="${POLL_INTERVAL:-15}"
progress_interval="${PROGRESS_INTERVAL:-180}"
timeout="${WATCH_TIMEOUT:-1800}"

if [[ -z "$session" || -z "$notify" ]]; then
    echo "delegate_watch: missing DELEGATE_SESSION or NOTIFY_SESSION" >&2
    exit 1
fi

queue_file="${AMA_DIR}/brain/state/queue_${notify}"
sentinel="${AMA_DIR}/brain/state/delegate_${session}.done"
log_file="${AMA_DIR}/brain/state/delegate_${session}.log"

elapsed=0
last_progress=0

_tail_log() {
    # Last 3 lines of log, single-line summary
    if [[ -f "$log_file" && -s "$log_file" ]]; then
        tail -3 "$log_file" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-120
    else
        echo "(working...)"
    fi
}

while [[ $elapsed -lt $timeout ]]; do
    # ── Completion check ──────────────────────────────────────────────────────
    if [[ -f "$sentinel" ]]; then
        exit_code=$(tr -d '[:space:]' < "$sentinel" 2>/dev/null)
        mins=$(( elapsed / 60 ))
        secs=$(( elapsed % 60 ))
        duration="${mins}m${secs}s"
        if [[ "$exit_code" == "0" ]]; then
            printf '%s\n' "Delegate session $session completed ✅ (${duration}). Report results with: delegate(mode=check, session=$session)" >> "$queue_file"
        else
            printf '%s\n' "Delegate session $session finished with errors ❌ (exit $exit_code, ${duration}). Check: delegate(mode=check, session=$session)" >> "$queue_file"
        fi
        exit 0
    fi

    # ── Crash check ──────────────────────────────────────────────────────────
    if ! tmux has-session -t "$session" 2>/dev/null; then
        printf '%s\n' "Delegate session $session ended unexpectedly 💥 (${elapsed}s). delegate(mode=check, session=$session)" >> "$queue_file"
        exit 1
    fi

    # ── Progress ping (hermes-style: notify every N minutes while running) ───
    since_last=$(( elapsed - last_progress ))
    if [[ $elapsed -gt 0 && $since_last -ge $progress_interval ]]; then
        mins=$(( elapsed / 60 ))
        last_line=$(_tail_log)
        printf '%s\n' "Delegate session $session still running ⏳ (${mins}min elapsed). Last output: ${last_line}" >> "$queue_file"
        last_progress=$elapsed
    fi

    sleep "$poll"
    elapsed=$(( elapsed + poll ))
done

# ── Timeout ──────────────────────────────────────────────────────────────────
printf '%s\n' "Delegate session $session timed out ⏰ after ${timeout}s. delegate(mode=check, session=$session) for partial output." >> "$queue_file"
