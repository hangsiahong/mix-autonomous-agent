#!/bin/bash
# Tool: clarify
# Send a clarifying question to the user in the current Telegram chat and stop
# processing the current turn. Use this before taking irreversible actions.

question="${TOOL_question}"
chat_id="${TOOL_CHAT_ID}"
thread_id="${TOOL_THREAD_ID}"

if [[ -z "$question" ]]; then
    echo "Error: 'question' is required."
    exit 1
fi

if [[ -z "$TG_TOKEN" || -z "$chat_id" ]]; then
    # Fallback: just print the question if context isn't available
    echo "QUESTION: $question"
    exit 0
fi

payload=$(jq -n \
    --arg cid "$chat_id" \
    --arg text "❓ $question" \
    --arg pm "Markdown" \
    '{chat_id: $cid, text: $text, parse_mode: $pm}')

if [[ -n "$thread_id" && "$thread_id" != "null" ]]; then
    payload=$(echo "$payload" | jq --arg tid "$thread_id" '.message_thread_id = ($tid | tonumber)')
fi

curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "$payload" > /dev/null

echo "CLARIFY_SENT"
echo "Question sent to user. Stop this turn and wait for their reply."
