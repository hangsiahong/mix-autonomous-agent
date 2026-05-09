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

payload=$(CID="$chat_id" TXT="❓ $question" python3 -c "
import json, os
print(json.dumps({'chat_id': os.environ['CID'], 'text': os.environ['TXT'], 'parse_mode': 'Markdown'}))
")

if [[ -n "$thread_id" && "$thread_id" != "null" ]]; then
    payload=$(TID="$thread_id" python3 -c "
import json, os, sys
d = json.load(sys.stdin)
d['message_thread_id'] = int(os.environ['TID'])
print(json.dumps(d))
" <<< "$payload")
fi

curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "$payload" > /dev/null

echo "CLARIFY_SENT"
echo "Question sent to user. Stop this turn and wait for their reply."
