#!/bin/bash
# core/telegram/router.sh - Command routing

tg_handle_update() {
    local update="$1"
    local chat_id=$(echo "$update" | jq -r '.message.chat.id // .callback_query.message.chat.id')
    local text=$(echo "$update" | jq -r '.message.text // .message.caption // .callback_query.data // empty')
    local user_id=$(echo "$update" | jq -r '.message.from.id // .callback_query.from.id')
    
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
            echo "Access denied for chat_id $chat_id / user_id $user_id"
            return
        fi
    fi

    # Handle Slash Commands
    if [[ "$text" == /* ]]; then
        local cmd=$(echo "$text" | cut -d' ' -f1)
        local args=$(echo "$text" | cut -d' ' -f2-)
        
        case "$cmd" in
            /start)
                tg_send "$chat_id" "AMA (Autonomous Minimalist Agent) ready. Use /help for commands."
                ;;
            /help)
                tg_send "$chat_id" "Commands: /start, /help, /reset, /status, /sethome, /whitelist <id>"
                ;;
            /reset)
                rm -f "${DIR}/brain/state/history_${chat_id}.json"
                tg_send "$chat_id" "Conversation history reset."
                ;;
            /status)
                local title="Untitled"
                if [ -f "brain/state/titles.json" ]; then
                    title=$(jq -r --arg id "$chat_id" '.[$id] // "Untitled"' brain/state/titles.json)
                fi
                local sysinfo=$(bash tools/sys_info.sh)
                tg_send "$chat_id" "Title: $title\nProvider: ${PROVIDER:-openai (default)}\nModel: ${MODEL:-gpt-4o-mini}\nChat ID: $chat_id\nUser ID: $user_id\n\n$sysinfo"
                ;;
            /insights)
                local report=$(bash tools/insights.sh)
                tg_send "$chat_id" "$report"
                ;;
            /login)
                if [[ "${PROVIDER}" == "copilot" ]]; then
                    copilot_login "$chat_id"
                else
                    tg_send "$chat_id" "Provider is not set to copilot."
                fi
                ;;
            *)
                # Pass unknown commands to agent
                run_agent "$chat_id" "$text" "$user_id" "$media_json"
                ;;
        esac
    else
        # Normal text -> Run Agent
        run_agent "$chat_id" "$text" "$user_id" "$media_json"
    fi
}
