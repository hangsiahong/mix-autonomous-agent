#!/bin/bash
# Tool: delegate_watch
# Watches an async delegate session in the background and writes a follow-up
# message to the AMA queue when the task completes, errors, or times out.
# This triggers a new agent turn automatically — no user input needed.
#
# Spawned automatically by delegate(mode=async, notify_session=...).
# Runs detached so it outlives the parent agent turn.
#
# Inputs (env vars set by delegate.py):
#   DELEGATE_SESSION  — tmux session name (e.g. ama_a4cdb6e8)
#   NOTIFY_SESSION    — AMA session_id to write follow-up to (e.g. tg_670967877)
#   AMA_DIR           — project root
#   POLL_INTERVAL     — seconds between checks (default: 30)
#   WATCH_TIMEOUT     — max seconds to wait before giving up (default: 600)

AMA_DIR="${AMA_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
session="${DELEGATE_SESSION}"
notify="${NOTIFY_SESSION}"
interval="${POLL_INTERVAL:-30}"
timeout="${WATCH_TIMEOUT:-600}"

if [[ -z "$session" || -z "$notify" ]]; then
    echo "delegate_watch: missing DELEGATE_SESSION or NOTIFY_SESSION" >&2
    exit 1
fi

queue_file="${AMA_DIR}/brain/state/queue_${notify}"
sentinel="${AMA_DIR}/brain/state/delegate_${session}.done"
log_file="${AMA_DIR}/brain/state/delegate_${session}.log"

elapsed=0
while [[ $elapsed -lt $timeout ]]; do
    # Sentinel written by delegate.py's bash -c wrapper
    if [[ -f "$sentinel" ]]; then
        exit_code=$(tr -d '[:space:]' < "$sentinel" 2>/dev/null)
        if [[ "$exit_code" == "0" ]]; then
            printf '%s\n' "Delegate session $session completed ✅. Fetch results with: delegate(mode=check, session=$session)" >> "$queue_file"
        else
            printf '%s\n' "Delegate session $session finished with errors (exit $exit_code) ❌. Check output: delegate(mode=check, session=$session)" >> "$queue_file"
        fi
        exit 0
    fi

    # tmux session died without writing sentinel (crash / OOM)
    if ! tmux has-session -t "$session" 2>/dev/null; then
        printf '%s\n' "Delegate session $session ended unexpectedly 💥. Check output: delegate(mode=check, session=$session)" >> "$queue_file"
        exit 1
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
done

# Timed out
printf '%s\n' "Delegate session $session timed out after ${timeout}s ⏰. delegate(mode=check, session=$session) for partial output." >> "$queue_file"
