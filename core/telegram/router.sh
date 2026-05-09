#!/bin/bash
# core/telegram/router.sh - Command routing

tg_handle_update() {
    local update="$1"
    local chat_id=$(echo "$update" | jq -r '.message.chat.id // .callback_query.message.chat.id')
    local text=$(echo "$update" | jq -r '.message.text // .callback_query.data')
    local user_id=$(echo "$update" | jq -r '.message.from.id // .callback_query.from.id')
    
    # Ignore empty messages
    [[ "$text" == "null" ]] && return

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
                tg_send "$chat_id" "Provider: ${PROVIDER:-openai (default)}\nModel: ${MODEL:-gpt-4o-mini}"
                ;;
            /sethome)
                set_home_chat "$chat_id"
                tg_send "$chat_id" "🏠 Home chat set to this chat ($chat_id)."
                ;;
            /whitelist)
                if [[ -n "$args" ]]; then
                    add_to_whitelist "$args"
                    tg_send "$chat_id" "✅ Whitelisted ID: $args"
                else
                    tg_send "$chat_id" "Usage: /whitelist <id>"
                fi
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
                run_agent "$chat_id" "$text"
                ;;
        esac
    else
        # Normal text -> Run Agent
        run_agent "$chat_id" "$text"
    fi
}
