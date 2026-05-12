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

# Single-instance lock
LOCK_FILE="${DIR}/brain/state/bot.pid"
if [ -f "$LOCK_FILE" ]; then
    OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "AMA: Another instance is already running (PID $OLD_PID). Killing it..."
        kill "$OLD_PID" 2>/dev/null
        sleep 2
    fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"; exit 0' EXIT INT TERM

echo "AMA Bot Starting..."
tg_set_commands

# Drain stale Telegram messages accumulated while bot was offline
_DRAIN=$(curl -s "https://api.telegram.org/bot${TG_TOKEN}/getUpdates?timeout=0&limit=100&offset=$(cat "$OFFSET_FILE")")
_DRAIN_LAST=$(echo "$_DRAIN" | python3 -c "import json,sys; r=json.load(sys.stdin); res=r.get('result',[]); print(res[-1].get('update_id','') if res else '')" 2>/dev/null)
if [[ -n "$_DRAIN_LAST" ]]; then
    _DRAIN_COUNT=$(echo "$_DRAIN" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('result',[])))" 2>/dev/null || echo 0)
    echo "AMA: Draining $_DRAIN_COUNT stale update(s) up to ID $_DRAIN_LAST..."
    echo $((_DRAIN_LAST + 1)) > "$OFFSET_FILE"
fi
unset _DRAIN _DRAIN_LAST _DRAIN_COUNT

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
        if [[ -z "$update" || "$update" == "null" ]]; then continue; fi
        UPDATE_ID=$(echo "$update" | python3 -c "import json,sys; print(json.load(sys.stdin).get('update_id',''))" 2>/dev/null)
        if [[ -z "$UPDATE_ID" || "$UPDATE_ID" == "null" ]]; then
            echo "DEBUG: Bad update: $update" >&2
            continue
        fi
        echo "Processing update $UPDATE_ID..."
        # T1-2: Global agent process cap — reject new messages when overloaded
        # Count live run_*.pid files (each = one active agent process)
        local _live_agents; _live_agents=$(ls "${DIR}/brain/state"/run_*.pid 2>/dev/null | wc -l)
        local _max_agents="${MAX_CONCURRENT_AGENTS:-10}"
        if [[ "$_live_agents" -ge "$_max_agents" ]]; then
            echo "AMA: Queue full ($_live_agents active agents, max $_max_agents). Dropping update $UPDATE_ID." >&2
            # Optionally notify user (extract chat_id from update)
            local _drop_chat; _drop_chat=$(echo "$update" | python3 -c "import json,sys; u=json.load(sys.stdin); print((u.get('message') or {}).get('chat',{}).get('id',''))" 2>/dev/null)
            [[ -n "$_drop_chat" ]] && tg_send "$_drop_chat" "⚠️ Bot is busy with too many requests. Please try again in a moment." "" || true
            echo $((UPDATE_ID + 1)) > "$OFFSET_FILE"
            continue
        fi
        tg_handle_update "$update"
        echo $((UPDATE_ID + 1)) > "$OFFSET_FILE"
    done
    sleep 1
done