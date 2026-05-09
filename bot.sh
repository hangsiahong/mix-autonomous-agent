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
_DRAIN_LAST=$(echo "$_DRAIN" | jq -r '.result[-1].update_id // empty' 2>/dev/null)
if [[ -n "$_DRAIN_LAST" ]]; then
    echo "AMA: Draining $(echo "$_DRAIN" | jq '.result | length') stale update(s) up to ID $_DRAIN_LAST..."
    echo $((_DRAIN_LAST + 1)) > "$OFFSET_FILE"
fi
unset _DRAIN _DRAIN_LAST

while true; do
    OFFSET=$(cat "$OFFSET_FILE")
    UPDATES=$(tg_poll "$OFFSET")
    
    if [[ -z "$UPDATES" ]]; then
        sleep 5; continue
    fi

    OK=$(echo "$UPDATES" | jq -r '.ok' 2>/dev/null)
    if [[ "$OK" != "true" ]]; then
        ERR_CODE=$(echo "$UPDATES" | jq -r '.error_code // 0' 2>/dev/null)
        if [[ "$ERR_CODE" == "409" ]]; then
            echo "AMA: 409 Conflict — another instance owns the poll. Exiting." >&2
            exit 1
        fi
        echo "DEBUG: Poll failed or not JSON: $UPDATES" >&2
        sleep 5; continue
    fi

    echo "$UPDATES" | jq -c '.result[]' | while read -r update; do
        if [[ -z "$update" || "$update" == "null" ]]; then continue; fi
        UPDATE_ID=$(echo "$update" | jq -r '.update_id' 2>/dev/null)
        if [[ -z "$UPDATE_ID" || "$UPDATE_ID" == "null" ]]; then
            echo "DEBUG: Bad update: $update" >&2
            continue
        fi
        echo "Processing update $UPDATE_ID..."
        tg_handle_update "$update"
        echo $((UPDATE_ID + 1)) > "$OFFSET_FILE"
    done
    sleep 1
done