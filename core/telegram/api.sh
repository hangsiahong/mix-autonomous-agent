#!/bin/bash
# core/telegram/api.sh - Raw API wrappers

tg_api() {
    local method="$1"
    local data="$2"
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/${method}" \
         -H "Content-Type: application/json" \
         -d "$data"
}

tg_send() {
    local chat_id="$1"
    local text="$2"
    local thread_id="$3"
    local parse_mode="${4:-Markdown}"
    local payload=$(jq -n --arg cid "$chat_id" --arg txt "$text" --arg pm "$parse_mode" \
        '{chat_id: $cid, text: $txt, parse_mode: $pm}')
    if [[ -n "$thread_id" && "$thread_id" != "null" ]]; then
        payload=$(echo "$payload" | jq --arg tid "$thread_id" '.message_thread_id = $tid')
    fi
    tg_api "sendMessage" "$payload" | jq -r '.result.message_id // empty'
}

tg_edit() {
    local chat_id="$1"
    local message_id="$2"
    local text="$3"
    local parse_mode="${4:-Markdown}"
    tg_api "editMessageText" "$(jq -n --arg cid "$chat_id" --arg mid "$message_id" --arg txt "$text" --arg pm "$parse_mode" \
        '{chat_id: $cid, message_id: $mid, text: $txt, parse_mode: $pm}')"
}

tg_delete() {
    local chat_id="$1"
    local message_id="$2"
    tg_api "deleteMessage" "$(jq -n --arg cid "$chat_id" --arg mid "$message_id" \
        '{chat_id: $cid, message_id: $mid}')"
}

tg_send_photo() {
    local chat_id="$1"
    local photo="$2"
    local caption="$3"
    tg_api "sendPhoto" "$(jq -n --arg cid "$chat_id" --arg ph "$photo" --arg cap "$caption" \
        '{chat_id: $cid, photo: $ph, caption: $cap}')"
}

tg_get_file() {
    local file_id="$1"
    tg_api "getFile" "$(jq -n --arg fid "$file_id" '{file_id: $fid}')"
}

tg_download() {
    local file_path="$1"
    local local_dest="$2"
    curl -s -o "$local_dest" "https://api.telegram.org/file/bot${TG_TOKEN}/${file_path}"
}
