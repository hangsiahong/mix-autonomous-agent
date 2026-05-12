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
        local cmd=$(echo "$text" | awk '{print $1}')
        local args=$(echo "$text" | sed "s|^$cmd||" | sed 's|^[[:space:]]*||')
        
        case "$cmd" in
            /start)
                tg_send "$chat_id" "AMA (Autonomous Mix Agent) ready. Use /help for commands." "$thread_id"
                ;;
            /help)
                tg_send "$chat_id" "<b>Commands</b>
/stop — stop this session's running task
/stop all — stop ALL running tasks across all sessions
/reset or /new — clear session history and start fresh
/status — show current model, session info, system stats
/skills — list available skills
/insights — token usage statistics
/restart — restart the bot (admin only)
/shutdown — shut down the bot (admin only)" "$thread_id" "HTML"
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
roots = [('core/skills', 'core'), ('brain/skills', 'user')]
lines = []
for root, label in roots:
    if not os.path.isdir(root): continue
    for name in sorted(os.listdir(root)):
        if os.path.isdir(os.path.join(root, name)):
            lines.append(f'• <b>{name}</b> ({label})')
print('\n'.join(lines) if lines else '  (none)')
" 2>/dev/null)
                    local msg="<b>Available Skills</b>
${_skill_list}

Active: <code>${skill:-none}</code>

Use <code>/skill &lt;name&gt;</code> to activate.
Use <code>/skill off</code> to clear."
                    tg_send "$chat_id" "$msg" "$thread_id" "HTML"
                elif [[ "$sname" == "off" || "$sname" == "none" ]]; then
                    set_topic_config "$chat_id" "$thread_id" "skill" ""
                    tg_send "$chat_id" "Skill cleared. Running in default mode." "$thread_id" "HTML"
                else
                    # Validate skill exists
                    if [[ -d "core/skills/$sname" || -d "brain/skills/$sname" ]]; then
                        set_topic_config "$chat_id" "$thread_id" "skill" "$sname"
                        tg_send "$chat_id" "Skill set to: <code>$sname</code>" "$thread_id" "HTML"
                    else
                        tg_send "$chat_id" "Skill '<code>$sname</code>' not found. Use /skills to list available skills." "$thread_id" "HTML"
                    fi
                fi
                ;;
            /insights)
                local report=$(bash tools/insights.sh)
                tg_send "$chat_id" "$report" "$thread_id"
                ;;
            /stop)
                local _stop_args=$(echo "$args" | awk '{print $1}')
                if [[ "$_stop_args" == "all" ]]; then
                    # /stop all — kill every running session + flag all queued ones
                    local _stopped=0
                    for _pf in "${DIR}/brain/state"/run_*.pid; do
                        [[ -f "$_pf" ]] || continue
                        # Derive session_id from filename: run_<session_id>.pid
                        local _sf="${_pf%.pid}"
                        _sf="${_sf##*/run_}"
                        # Set stop flag so any queued process for this session exits too
                        touch "${DIR}/brain/state/stop_${_sf}" 2>/dev/null || true
                        local _pf_data; _pf_data=$(cat "$_pf" 2>/dev/null) || continue
                        local _ppid _pmsg _pchat _pthread
                        IFS='|' read -r _ppid _pmsg _pchat _pthread <<< "$_pf_data"
                        if kill -0 "$_ppid" 2>/dev/null; then
                            kill -TERM "-${_ppid}" 2>/dev/null || kill -TERM "$_ppid" 2>/dev/null
                            if [[ -n "$_pmsg" && "$_pmsg" != "pending" && -n "$_pchat" ]]; then
                                tg_edit "$_pchat" "$_pmsg" "🛑 <i>Stopped.</i>" "HTML" > /dev/null 2>&1 || true
                            fi
                            _stopped=$((_stopped + 1))
                        fi
                        rm -f "$_pf"
                    done
                    if [[ "$_stopped" -gt 0 ]]; then
                        tg_send "$chat_id" "🛑 Stopped $_stopped running task(s)." "$thread_id"
                    else
                        tg_send "$chat_id" "No active tasks to stop." "$thread_id"
                    fi
                else
                    # /stop — kill this session only
                    local pid_file="${DIR}/brain/state/run_${session_id}.pid"
                    local stop_flag="${DIR}/brain/state/stop_${session_id}"
                    # Always set stop flag first — catches queued processes that get the
                    # lock AFTER we kill the running one (they check the flag and exit)
                    touch "$stop_flag"
                    if [[ -f "$pid_file" ]]; then
                        local _pid_data; _pid_data=$(cat "$pid_file" 2>/dev/null)
                        local run_pid _msg_id _orig_chat _orig_thread
                        IFS='|' read -r run_pid _msg_id _orig_chat _orig_thread <<< "$_pid_data"
                        echo "AMA: Stopping session $session_id (PID $run_pid)"
                        # Kill the whole process group — takes down bash + python subprocesses
                        kill -TERM "-${run_pid}" 2>/dev/null || kill -TERM "$run_pid" 2>/dev/null
                        rm -f "$pid_file"
                        # Edit the dangling "Thinking…" or "Working…" bot message
                        if [[ -n "$_msg_id" && "$_msg_id" != "pending" ]]; then
                            tg_edit "${_orig_chat:-$chat_id}" "$_msg_id" "🛑 <i>Stopped.</i>" "HTML" > /dev/null 2>&1 || true
                        fi
                        tg_send "$chat_id" "🛑 Task stopped." "$thread_id"
                    else
                        # No running process — but we set the stop flag above, which will
                        # catch any queued process when it tries to acquire the lock
                        tg_send "$chat_id" "🛑 Stopped (was queued)." "$thread_id"
                    fi
                fi
                ;;
            /shutdown)
                if [[ "$user_id" == "${TG_ADMIN}" ]]; then
                    tg_send "$chat_id" "Shutting down bot. Goodbye." "$thread_id"
                    local _bot_pid
                    _bot_pid=$(cat "${DIR}/brain/state/bot.pid" 2>/dev/null)
                    rm -f "${DIR}/brain/state/bot.pid"
                    [[ -n "$_bot_pid" ]] && kill -TERM "$_bot_pid" 2>/dev/null
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
                ( set -m; run_agent "$chat_id" "$text" "$user_id" "$media_json" "$thread_id" "$session_id" "$chat_title" "$username" "$skill" ) &
                ;;
        esac
    else
        # Normal text -> Run Agent
        ( set -m; run_agent "$chat_id" "$text" "$user_id" "$media_json" "$thread_id" "$session_id" "$chat_title" "$username" "$skill" ) &
    fi
}
