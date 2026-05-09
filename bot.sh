#!/bin/bash

# bot.sh - Entry point for the Telegram Agent

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/core/main.sh"

OFFSET_FILE="${DIR}/brain/last_offset"
if [[ ! -f "$OFFSET_FILE" ]]; then
    echo "0" > "$OFFSET_FILE"
fi

echo "Starting AMA Bot..."

while true; do
    OFFSET=$(cat "$OFFSET_FILE")
    UPDATES=$(tg_poll "$OFFSET")
    
    # Check for success
    OK=$(echo "$UPDATES" | jq -r '.ok')
    if [[ "$OK" != "true" ]]; then
        echo "Error polling Telegram. Retrying in 5s..."
        sleep 5
        continue
    fi

    # Process updates
    echo "$UPDATES" | jq -c '.result[]' | while read -r update; do
        UPDATE_ID=$(echo "$update" | jq -r '.update_id')
        CHAT_ID=$(echo "$update" | jq -r '.message.chat.id // .callback_query.message.chat.id')
        TEXT=$(echo "$update" | jq -r '.message.text // .callback_query.data')

        if [[ "$TEXT" != "null" ]]; then
            echo "Message from $CHAT_ID: $TEXT"
            process_message "$CHAT_ID" "$TEXT"
        fi

        # Update offset
        NEW_OFFSET=$((UPDATE_ID + 1))
        echo "$NEW_OFFSET" > "$OFFSET_FILE"
    done

    sleep 1
done
