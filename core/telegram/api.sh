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
    local payload
    payload=$(TG_CID="$chat_id" TG_TXT="$text" TG_PM="$parse_mode" python3 -c "
import json, os
d = {'chat_id': os.environ['TG_CID'], 'text': os.environ['TG_TXT'], 'parse_mode': os.environ['TG_PM']}
print(json.dumps(d))")
    if [[ -n "$thread_id" && "$thread_id" != "null" ]]; then
        payload=$(TID="$thread_id" python3 -c "
import json, os, sys
d = json.load(sys.stdin)
try: d['message_thread_id'] = int(os.environ['TID'])
except: d['message_thread_id'] = os.environ['TID']
print(json.dumps(d))" <<< "$payload")
    fi
    tg_api "sendMessage" "$payload" | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('result',{}).get('message_id','') or '')
except: pass"
}

tg_edit() {
    local chat_id="$1"
    local message_id="$2"
    local text="$3"
    local parse_mode="${4:-Markdown}"
    local _payload
    _payload=$(TG_CID="$chat_id" TG_MID="$message_id" TG_TXT="$text" TG_PM="$parse_mode" python3 -c "
import json, os
print(json.dumps({'chat_id': os.environ['TG_CID'], 'message_id': os.environ['TG_MID'],
    'text': os.environ['TG_TXT'], 'parse_mode': os.environ['TG_PM']}))")
    tg_api "editMessageText" "$_payload"
}

tg_delete() {
    local chat_id="$1"
    local message_id="$2"
    tg_api "deleteMessage" "$(TG_CID="$chat_id" TG_MID="$message_id" python3 -c \
        "import json,os; print(json.dumps({'chat_id':os.environ['TG_CID'],'message_id':os.environ['TG_MID']}))")" 
}

tg_send_photo() {
    local chat_id="$1"
    local photo="$2"     # can be a local file path OR a public URL/file_id
    local caption="$3"
    local thread_id="$4"

    if [[ "$photo" == /* || "$photo" == ./* ]]; then
        # Local file — use multipart form upload (telegram-bot-bash pattern)
        # This avoids base64/ARG_MAX issues and works for large files
        local curl_args=(
            -s
            -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendPhoto"
            -F "chat_id=${chat_id}"
            -F "photo=@${photo}"
        )
        if [[ -n "$caption" ]]; then
            curl_args+=(-F "caption=${caption}")
        fi
        if [[ -n "$thread_id" && "$thread_id" != "null" ]]; then
            curl_args+=(-F "message_thread_id=${thread_id}")
        fi
        curl "${curl_args[@]}"
    else
        # URL or file_id — send as JSON
        local payload
        payload=$(TG_CID="$chat_id" TG_PH="$photo" TG_CAP="$caption" python3 -c "
import json, os
print(json.dumps({'chat_id':os.environ['TG_CID'],'photo':os.environ['TG_PH'],'caption':os.environ['TG_CAP']}))")        
        if [[ -n "$thread_id" && "$thread_id" != "null" ]]; then
            payload=$(TID="$thread_id" python3 -c "
import json, os, sys
d = json.load(sys.stdin)
try: d['message_thread_id'] = int(os.environ['TID'])
except: d['message_thread_id'] = os.environ['TID']
print(json.dumps(d))" <<< "$payload")
        fi
        tg_api "sendPhoto" "$payload"
    fi
}

tg_get_file() {
    local file_id="$1"
    tg_api "getFile" "$(TG_FID="$file_id" python3 -c "import json,os; print(json.dumps({'file_id':os.environ['TG_FID']}))")" 
}

tg_download() {
    local file_path="$1"
    local local_dest="$2"
    curl -sf -o "$local_dest" "https://api.telegram.org/file/bot${TG_TOKEN}/${file_path}"
}

tg_set_commands() {
    local commands='[
        {"command": "start", "description": "Start the bot"},
        {"command": "help", "description": "Show help"},
        {"command": "new", "description": "Reset conversation history"},
        {"command": "reset", "description": "Reset conversation history"},
        {"command": "status", "description": "Show agent status"},
        {"command": "skill", "description": "View or set active skill"},
        {"command": "insights", "description": "Show usage insights"}
    ]'
    tg_api "setMyCommands" "$(CMDS="$commands" python3 -c "import json,os; print(json.dumps({'commands':json.loads(os.environ['CMDS'])}))")" > /dev/null
}

tg_send_action() {
    local chat_id="$1"
    local action="$2"
    local thread_id="$3"
    
    local payload
    payload=$(TG_CID="$chat_id" TG_ACT="$action" python3 -c "
import json, os
print(json.dumps({'chat_id':os.environ['TG_CID'],'action':os.environ['TG_ACT']}))")    
    if [[ -n "$thread_id" && "$thread_id" != "null" ]]; then
        payload=$(TID="$thread_id" python3 -c "
import json, os, sys
d = json.load(sys.stdin)
try: d['message_thread_id'] = int(os.environ['TID'])
except: d['message_thread_id'] = os.environ['TID']
print(json.dumps(d))" <<< "$payload")
    fi
    
    tg_api "sendChatAction" "$payload" > /dev/null
}
