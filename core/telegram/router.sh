#!/bin/bash
# core/telegram/router.sh - Command routing

tg_handle_update() {
    local update="$1"
    local chat_id=$(echo "$update" | jq -r '.message.chat.id // .callback_query.message.chat.id')
    local thread_id=$(echo "$update" | jq -r '.message.message_thread_id // .callback_query.message.message_thread_id // empty')
    local chat_type=$(echo "$update" | jq -r '.message.chat.type // .callback_query.message.chat.type // "private"')
    local chat_title=$(echo "$update" | jq -r '.message.chat.title // .callback_query.message.chat.title // empty')
    local text=$(echo "$update" | jq -r '.message.text // .message.caption // .callback_query.data // empty')
    local user_id=$(echo "$update" | jq -r '.message.from.id // .callback_query.from.id')
    local username=$(echo "$update" | jq -r '.message.from.username // .callback_query.from.username // empty')
    
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
            tg_send "$chat_id" "Access denied. Chat ID: $chat_id. User ID: $user_id" "$thread_id"
            return
        fi
    fi

    # Auto-load AMA skill if mentioning AMA or autonomous-agent
    local topic_cfg=$(get_topic_config "$chat_id" "$thread_id")
    local skill=$(echo "$topic_cfg" | jq -r '.skill // empty')
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
                tg_send "$chat_id" "Commands: /start, /help, /reset, /status, /sethome, /whitelist <id>"
                ;;
            /reset|/new)
                rm -f "${DIR}/brain/state/history_${session_id}.json"
                tg_send "$chat_id" "Conversation history reset." "$thread_id"
                ;;
            /status)
                local title="Untitled"
                if [ -f "brain/state/titles.json" ]; then
                    title=$(jq -r --arg id "$session_id" '.[$id] // "Untitled"' brain/state/titles.json)
                fi
                local sysinfo=$(bash tools/sys_info.sh)
                tg_send "$chat_id" "Title: $title\nProvider: ${PROVIDER:-openai (default)}\nModel: ${MODEL:-gpt-4o-mini}\nSession: $session_id\nUser: ${username:-$user_id}\nType: $chat_type\nSkill: ${skill:-none}\n\n$sysinfo" "$thread_id"
                ;;
            /skill)
                local sname=$(echo "$args" | awk '{print $1}')
                if [[ -z "$sname" ]]; then
                    tg_send "$chat_id" "Current skill: ${skill:-none}\nUsage: /skill <name>" "$thread_id"
                else
                    set_topic_config "$chat_id" "$thread_id" "skill" "$sname"
                    tg_send "$chat_id" "Skill set to: $sname" "$thread_id"
                fi
                ;;
            /insights)
                local report=$(bash tools/insights.sh)
                tg_send "$chat_id" "$report" "$thread_id"
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
