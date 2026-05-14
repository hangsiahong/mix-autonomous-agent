#!/bin/bash
# Tool: send_file
# Send a file from the server to the current Telegram chat.
# Supports any file type: HTML, PDF, images, CSV, zip, etc.
# Files > 50MB cannot be sent via Telegram Bot API.

path="${TOOL_path:-}"
caption="${TOOL_caption:-}"
chat_id="${TOOL_chat_id:-$TOOL_CHAT_ID}"
thread_id="${TOOL_thread_id:-$TOOL_THREAD_ID}"

if [[ -z "$path" ]]; then
    echo "Error: 'path' is required."
    exit 1
fi

# Resolve relative paths against project root
if [[ "$path" != /* ]]; then
    path="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/${path}"
fi

if [[ ! -f "$path" ]]; then
    echo "Error: file not found: $path"
    exit 1
fi

if [[ -z "$TG_TOKEN" || -z "$chat_id" ]]; then
    echo "Error: TG_TOKEN or chat_id not available."
    exit 1
fi

# Pick sendPhoto for images (better preview in Telegram), sendDocument for everything else
filename="${path##*/}"
ext="${filename##*.}"
method="sendDocument"
field="document"
case "${ext,,}" in
    jpg|jpeg|png|webp) method="sendPhoto"; field="photo" ;;
    gif)               method="sendAnimation"; field="animation" ;;
esac

# File size check (Telegram limit: 50MB)
size=$(stat -c%s "$path" 2>/dev/null || stat -f%z "$path" 2>/dev/null || echo 0)
if [[ "$size" -gt 52428800 ]]; then
    echo "Error: file too large for Telegram ($(( size / 1024 / 1024 ))MB, limit 50MB). Consider zipping or splitting it."
    exit 1
fi

curl_args=(
    -s -X POST
    "https://api.telegram.org/bot${TG_TOKEN}/${method}"
    -F "chat_id=${chat_id}"
    -F "${field}=@${path}"
)
[[ -n "$caption" ]]    && curl_args+=(-F "caption=${caption}")
[[ -n "$thread_id" && "$thread_id" != "null" && "$thread_id" != "0" ]] \
                       && curl_args+=(-F "message_thread_id=${thread_id}")

response=$(curl "${curl_args[@]}")
ok=$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('ok',''))" 2>/dev/null)

if [[ "$ok" == "True" ]]; then
    echo "File sent: $filename"
else
    err=$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('description','unknown error'))" 2>/dev/null)
    echo "Error sending file: $err"
    exit 1
fi
