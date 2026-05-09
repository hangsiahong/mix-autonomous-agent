#!/bin/bash

# bot.sh - AMA Entry Point

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

echo "AMA Bot Starting..."

while true; do
    echo "Polling..."
    OFFSET=$(cat "$OFFSET_FILE")
    UPDATES=$(tg_poll "$OFFSET")
    
    if [[ -z "$UPDATES" ]]; then
        sleep 5; continue
    fi

    OK=$(echo "$UPDATES" | jq -r '.ok' 2>/dev/null)
    if [[ "$OK" != "true" ]]; then
        sleep 5; continue
    fi

    echo "$UPDATES" | jq -c '.result[]' | while read -r update; do
        UPDATE_ID=$(echo "$update" | jq -r '.update_id')
        echo "Processing update $UPDATE_ID..."
        tg_handle_update "$update"
        echo $((UPDATE_ID + 1)) > "$OFFSET_FILE"
    done
    sleep 1
done