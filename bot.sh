#!/bin/bash

# bot.sh - AMA Entry Point

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/core/mix/00_header.sh"
source "${DIR}/core/mix/01_config.sh"
source "${DIR}/core/telegram.sh"
source "${DIR}/core/mix/11_history.sh"
source "${DIR}/core/mix/13_tool_execution.sh"
source "${DIR}/core/mix/16_api.sh"
source "${DIR}/core/mix/17_response_parser.sh"
source "${DIR}/core/mix/18_streaming_api_call.sh"
source "${DIR}/core/mix/22_process_one_tool_call.sh"
source "${DIR}/core/mix/24_agent_loop.sh"

OFFSET_FILE="${DIR}/brain/last_offset"
[ ! -f "$OFFSET_FILE" ] && echo "0" > "$OFFSET_FILE"

echo "AMA Bot Starting..."

while true; do
    OFFSET=$(cat "$OFFSET_FILE")
    UPDATES=$(tg_poll "$OFFSET")
    
    OK=$(echo "$UPDATES" | jq -r '.ok')
    if [[ "$OK" != "true" ]]; then
        sleep 5; continue
    fi

    echo "$UPDATES" | jq -c '.result[]' | while read -r update; do
        UPDATE_ID=$(echo "$update" | jq -r '.update_id')
        CHAT_ID=$(echo "$update" | jq -r '.message.chat.id // .callback_query.message.chat.id')
        TEXT=$(echo "$update" | jq -r '.message.text // .callback_query.data')

        if [[ "$TEXT" != "null" ]]; then
            echo "Msg from $CHAT_ID: $TEXT"
            run_agent "$CHAT_ID" "$TEXT"
        fi

        echo $((UPDATE_ID + 1)) > "$OFFSET_FILE"
    done
    sleep 1
done