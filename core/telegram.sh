#!/bin/bash

# core/telegram.sh - Telegram Bot API wrapper

if [[ -f ".env" ]]; then
    source .env
fi

TG_API="https://api.telegram.org/bot${TG_TOKEN}"

tg_send() {
    local chat_id="$1"
    local text="$2"
    local resp
    resp=$(curl -s -X POST "${TG_API}/sendMessage" \
        -d "chat_id=${chat_id}" \
        -d "text=${text}" \
        -d "parse_mode=Markdown")
    echo "$resp" | jq -r '.result.message_id // empty'
}

tg_edit() {
    local chat_id="$1"
    local message_id="$2"
    local text="$3"
    curl -s -X POST "${TG_API}/editMessageText" \
        -d "chat_id=${chat_id}" \
        -d "message_id=${message_id}" \
        -d "text=${text}" \
        -d "parse_mode=Markdown" > /dev/null
}

tg_poll() {
    local offset="$1"
    curl -s "${TG_API}/getUpdates?offset=${offset}&timeout=30"
}

tg_get_file() {
    local file_id="$1"
    local file_path=$(curl -s "${TG_API}/getFile?file_id=${file_id}" | jq -r '.result.file_path')
    echo "https://api.telegram.org/file/bot${TG_TOKEN}/${file_path}"
}
