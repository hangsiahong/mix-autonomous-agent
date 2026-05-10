#!/bin/bash
# core/telegram/router.sh - Command routing

tg_handle_update() {
    local update="$1"

    # Parse all update fields in one Python call (avoids 7+ jq invocations).
    # shlex.quote is used so eval is safe regardless of message content.
    local _vars
    _vars=$(UPDATE="$update" python3 -c "
import json, os, shlex
try:
    u = json.loads(os.environ['UPDATE'])
except Exception:
    u = {}
msg = u.get('message') or {}
cbq = u.get('callback_query') or {}
src_msg = msg if msg else (cbq.get('message') or {})
src_from = (msg.get('from') or cbq.get('from')) or {}
chat = src_msg.get('chat') or {}
vals = {
    'chat_id':    str(chat.get('id', '') or ''),
    'thread_id':  str(src_msg.get('message_thread_id', '') or ''),
    'chat_type':  str(chat.get('type', 'private') or 'private'),
    'chat_title': str(chat.get('title', '') or ''),
    'text':       str(msg.get('text', '') or msg.get('caption', '') or cbq.get('data', '') or ''),
    'user_id':    str(src_from.get('id', '') or ''),
    'username':   str(src_from.get('username', '') or ''),
}
for k, v in vals.items():
    print(f'{k}={shlex.quote(v)}')
" 2>/dev/null) || true
    eval "$_vars"
    
    # Build Session ID
    local session_id="tg_${chat_id}"
    if [[ -n "$thread_id" ]]; then
        session_id="tg_${chat_id}_${thread_id}"
    fi

    # Extract Media
    local media_out=$(tg_extract_media "$update")
    local media_json=$(echo "$media_out" | grep -v "MEDIA_FILE:" || echo "[]")
    local media_file=$(echo "$media_out" | grep "MEDIA_FILE:" | cut -d: -f2- || true)

    if [[ -n "$media_file" ]]; then
        text="$text [Attached File: $media_file]"
    fi

    # Ignore empty messages unless there is media
    [[ "$text" == "null" || -z "$text" ]] && [[ "$media_json" == "[]" ]] && return

    # Whitelist Check
    if ! is_whitelisted "$chat_id" && ! is_whitelisted "$user_id"; then
        # Check if it's the admin trying to whitelist this chat
        if [[ "$user_id" == "${TG_ADMIN}" && "$text" == "/whitelist"* ]]; then
             : # Allow admin to use /whitelist even if not whitelisted (though admin should be)
        else
            echo "Access denied for chat_id $chat_id / user_id $user_id. User text: $text"
            # Do NOT send a reply to unauthorized users to prevent spam/discovery
            return
        fi
    fi

    # Auto-load AMA skill if mentioning AMA or autonomous-agent
    local topic_cfg=$(get_topic_config "$chat_id" "$thread_id")
    local skill=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('skill','') or '')" "$topic_cfg" 2>/dev/null)
    if [[ -z "$skill" ]] && [[ "$text" =~ ([[:space:]]|^)[Aa][Mm][Aa]([[:space:]]|$) || "$text" =~ "autonomous-agent" ]]; then
        skill="ama"
    fi

    # Handle Slash Commands
    if [[ "$text" == /* ]]; then
        local cmd=$(echo "$text" | cut -d' ' -f1)
        local args=$(echo "$text" | cut -d' ' -f2-)
        
        case "$cmd" in
            /start)
                tg_send "$chat_id" "AMA (Autonomous Mix Agent) ready. Use /help for commands." "$thread_id"
                ;;
            /help)
                tg_send "$chat_id" "Commands: /start, /help, /reset, /status, /sethome, /whitelist <id>, /stop, /restart" "$thread_id"
                ;;
            /whitelist)
                local target_id=$(echo "$args" | awk '{print $1}')
                if [[ "$user_id" == "${TG_ADMIN}" && -n "$target_id" ]]; then
                    add_to_whitelist "$target_id"
                    tg_send "$chat_id" "User/Chat $target_id added to whitelist." "$thread_id"
                else
                    tg_send "$chat_id" "Usage: /whitelist <id> (Admin only)" "$thread_id"
                fi
                ;;
            /reset|/new)
                # Archive current session to trajectories before clearing so session_search can still find it
                local _hist_file="${DIR}/brain/state/history_${session_id}.json"
                if [[ -f "$_hist_file" ]]; then
                    local _archive_dir="${DIR}/brain/state/sessions"
                    mkdir -p "$_archive_dir"
                    local _ts; _ts=$(date +%s)
                    cp "$_hist_file" "${_archive_dir}/history_${session_id}_${_ts}.json"
                    rm -f "$_hist_file"
                fi
                tg_send "$chat_id" "🆕 New session started. Past conversations are archived and searchable with \`session_search\`." "$thread_id"
                ;;
            /status)
                local title="Untitled"
                if [ -f "brain/state/titles.json" ]; then
                    title=$(SID="$session_id" python3 -c "
import json, os
try:
    d = json.load(open('brain/state/titles.json'))
    print(d.get(os.environ['SID'], 'Untitled') or 'Untitled')
except: print('Untitled')" 2>/dev/null)
                fi
                local sysinfo=$(bash tools/sys_info.sh)
                tg_send "$chat_id" "Title: $title\nProvider: ${PROVIDER:-openai (default)}\nModel: ${MODEL:-gpt-4o-mini}\nSession: $session_id\nUser: ${username:-$user_id}\nType: $chat_type\nSkill: ${skill:-none}\n\n$sysinfo" "$thread_id"
                ;;
            /skills|/skill)
                local sname=$(echo "$args" | awk '{print $1}')
                if [[ -z "$sname" ]]; then
                    # List all available skills from core + brain
                    local _skill_list
                    _skill_list=$(python3 -c "
import os, json
roots = ['core/skills', 'brain/skills']
seen = set()
lines = []
for root in roots:
    if not os.path.isdir(root): continue
    for name in sorted(os.listdir(root)):
        path = os.path.join(root, name)
        if os.path.isdir(path) and name not in seen:
            seen.add(name)
            src = 'core' if root.startswith('core') else 'user'
            lines.append(f'  • {name} [{src}]')
print('\\n'.join(lines) if lines else '  (none)')
" 2>/dev/null)
                    tg_send "$chat_id" "<b>Available skills</b>\n${_skill_list}\n\nActive: <code>${skill:-none}</code>\nUse /skill <name> to activate, /skill off to clear." "$thread_id"
                elif [[ "$sname" == "off" || "$sname" == "none" ]]; then
                    set_topic_config "$chat_id" "$thread_id" "skill" ""
                    tg_send "$chat_id" "Skill cleared. Running in default mode." "$thread_id"
                else
                    # Validate skill exists
                    if [[ -d "core/skills/$sname" || -d "brain/skills/$sname" ]]; then
                        set_topic_config "$chat_id" "$thread_id" "skill" "$sname"
                        tg_send "$chat_id" "Skill set to: <code>$sname</code>" "$thread_id"
                    else
                        tg_send "$chat_id" "Skill '<code>$sname</code>' not found. Use /skills to list available skills." "$thread_id"
                    fi
                fi
                ;;
            /insights)
                local report=$(bash tools/insights.sh)
                tg_send "$chat_id" "$report" "$thread_id"
                ;;
            /stop)
                if [[ "$user_id" == "${TG_ADMIN}" ]]; then
                    tg_send "$chat_id" "Shutting down. Goodbye." "$thread_id"
                    local _bot_pid
                    _bot_pid=$(cat "${DIR}/brain/state/bot.pid" 2>/dev/null)
                    rm -f "${DIR}/brain/state/bot.pid"
                    # Kill the whole process group so running agents are also stopped
                    if [[ -n "$_bot_pid" ]]; then
                        kill -TERM "-$_bot_pid" 2>/dev/null || kill -TERM "$_bot_pid" 2>/dev/null
                    fi
                    kill -TERM "$$" 2>/dev/null
                    exit 0
                else
                    tg_send "$chat_id" "Admin only." "$thread_id"
                fi
                ;;
            /restart)
                if [[ "$user_id" == "${TG_ADMIN}" ]]; then
                    tg_send "$chat_id" "Restarting via pm2... be right back." "$thread_id"
                    # If running under pm2, let it handle the restart
                    if pm2 restart ama-bot >> "${DIR}/logs/bot.log" 2>&1; then
                        exit 0
                    fi
                    # Fallback: not under pm2 — manual restart
                    nohup bash "${DIR}/bot.sh" >> "${DIR}/logs/bot.log" 2>&1 &
                    local _bot_pid
                    _bot_pid=$(cat "${DIR}/brain/state/bot.pid" 2>/dev/null)
                    sleep 1
                    rm -f "${DIR}/brain/state/bot.pid"
                    if [[ -n "$_bot_pid" ]]; then
                        kill -TERM "-$_bot_pid" 2>/dev/null || kill -TERM "$_bot_pid" 2>/dev/null
                    fi
                    kill -TERM "$$" 2>/dev/null
                    exit 0
                else
                    tg_send "$chat_id" "Admin only." "$thread_id"
                fi
                ;;
            /login)
                if [[ "${PROVIDER}" == "copilot" ]]; then
                    copilot_login "$chat_id" # Copilot login usually happens in DM anyway
                else
                    tg_send "$chat_id" "Provider is not set to copilot." "$thread_id"
                fi
                ;;
            *)
                # Pass unknown commands to agent
                run_agent "$chat_id" "$text" "$user_id" "$media_json" "$thread_id" "$session_id" "$chat_title" "$username" "$skill"
                ;;
        esac
    else
        # Normal text -> Run Agent
        run_agent "$chat_id" "$text" "$user_id" "$media_json" "$thread_id" "$session_id" "$chat_title" "$username" "$skill"
    fi
}
