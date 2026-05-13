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
    local reply_to_id="${5:-}"   # optional: reply_to_message_id (hermes-style threading)
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
    if [[ -n "$reply_to_id" && "$reply_to_id" != "null" && "$reply_to_id" != "0" ]]; then
        payload=$(RID="$reply_to_id" python3 -c "
import json, os, sys
d = json.load(sys.stdin)
try: d['reply_to_message_id'] = int(os.environ['RID'])
except: pass
print(json.dumps(d))" <<< "$payload")
    fi
    _tg_send_payload "$payload" > /dev/null
}

# Like tg_send but returns the message_id (callers need it for later edits)
tg_send_r() {
    local chat_id="$1"
    local text="$2"
    local thread_id="$3"
    local parse_mode="${4:-Markdown}"
    local reply_to_id="${5:-}"   # optional: reply_to_message_id
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
    if [[ -n "$reply_to_id" && "$reply_to_id" != "null" && "$reply_to_id" != "0" ]]; then
        payload=$(RID="$reply_to_id" python3 -c "
import json, os, sys
d = json.load(sys.stdin)
try: d['reply_to_message_id'] = int(os.environ['RID'])
except: pass
print(json.dumps(d))" <<< "$payload")
    fi
    _tg_send_payload "$payload"
}

# Set a reaction emoji on a message (hermes-style: 👀 thinking, ✅ done, 👎 error)
tg_react() {
    local chat_id="$1"
    local message_id="$2"
    local emoji="$3"    # e.g. "👀" "✅" "👎" — pass "" to clear all reactions
    [[ -z "${TG_REACTIONS:-}" || "${TG_REACTIONS}" == "false" || "${TG_REACTIONS}" == "0" ]] && return 0
    [[ -z "$chat_id" || -z "$message_id" || "$message_id" == "0" ]] && return 0
    local payload
    if [[ -z "$emoji" ]]; then
        payload=$(TG_CID="$chat_id" TG_MID="$message_id" python3 -c "
import json,os; print(json.dumps({'chat_id':os.environ['TG_CID'],'message_id':int(os.environ['TG_MID']),'reaction':[],'is_big':False}))")
    else
        payload=$(TG_CID="$chat_id" TG_MID="$message_id" TG_EM="$emoji" python3 -c "
import json,os; print(json.dumps({'chat_id':os.environ['TG_CID'],'message_id':int(os.environ['TG_MID']),'reaction':[{'type':'emoji','emoji':os.environ['TG_EM']}],'is_big':False}))")
    fi
    tg_api "setMessageReaction" "$payload" > /dev/null 2>&1 || true
}

_tg_send_payload() {
    local payload="$1"
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
    # 30s timeout + 20MB size limit — prevents hangs and OOM on large files
    curl -sf --max-time 30 --limit-rate 10M -o "$local_dest" \
        "https://api.telegram.org/file/bot${TG_TOKEN}/${file_path}"
}

tg_set_commands() {
    local commands='[
        {"command": "start",    "description": "Start the bot"},
        {"command": "help",     "description": "Show all available commands"},
        {"command": "new",      "description": "Start a fresh session (archives history)"},
        {"command": "retry",    "description": "Re-run the last message"},
        {"command": "undo",     "description": "Remove the last exchange from history"},
        {"command": "stop",     "description": "Stop the running task — /stop all to kill everything"},
        {"command": "steer",    "description": "Inject guidance mid-run: /steer <note>"},
        {"command": "queue",    "description": "Queue a message for after current run: /queue <text>"},
        {"command": "model",    "description": "Switch model this session: /model <name>"},
        {"command": "history",  "description": "Show recent conversation turns: /history [n]"},
        {"command": "topic",    "description": "Name this thread/topic: /topic <name>"},
        {"command": "status",   "description": "Show model, session info, system stats"},
        {"command": "usage",    "description": "Show token usage for this session"},
        {"command": "skill",    "description": "View or set active skill: /skill <name> or off"},
        {"command": "skills",   "description": "List all available skills"},
        {"command": "providers",            "description": "Show all providers (main + pool) with status"},
        {"command": "models",               "description": "List available models or switch: /models <name>"},
        {"command": "google_login",         "description": "Connect a Google account (OAuth free tier)"},
        {"command": "google_login_callback","description": "Complete Google login: /google_login_callback <redirect URL>"},
        {"command": "insights", "description": "Token and tool usage statistics"},
        {"command": "whitelist","description": "Whitelist a user or chat ID (admin)"},
        {"command": "restart",  "description": "Restart the bot (admin)"},
        {"command": "shutdown", "description": "Shut down the bot (admin)"}
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

tg_send_document() {
    local chat_id="$1"
    local document="$2"  # local file path
    local caption="$3"
    local thread_id="$4"

    local curl_args=(
        -s
        -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendDocument"
        -F "chat_id=${chat_id}"
        -F "document=@${document}"
    )
    if [[ -n "$caption" ]]; then
        curl_args+=(-F "caption=${caption}")
    fi
    if [[ -n "$thread_id" && "$thread_id" != "null" ]]; then
        curl_args+=(-F "message_thread_id=${thread_id}")
    fi
    curl "${curl_args[@]}"
}
