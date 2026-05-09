#!/bin/bash
# core/telegram/router.sh - Command routing

tg_handle_update() {
    local update="$1"
    local chat_id=$(echo "$update" | jq -r '.message.chat.id // .callback_query.message.chat.id')
    local text=$(echo "$update" | jq -r '.message.text // .callback_query.data')
    local user_id=$(echo "$update" | jq -r '.message.from.id // .callback_query.from.id')
    
    # Ignore empty messages
    [[ "$text" == "null" ]] && return

    # Handle Slash Commands
    if [[ "$text" == /* ]]; then
        local cmd=$(echo "$text" | cut -d' ' -f1)
        local args=$(echo "$text" | cut -d' ' -f2-)
        
        case "$cmd" in
            /start)
                tg_send "$chat_id" "AMA (Autonomous Minimalist Agent) ready. Use /help for commands."
                ;;
            /help)
                tg_send "$chat_id" "Commands: /start, /help, /reset, /status"
                ;;
            /reset)
                rm -f "${DIR}/brain/state/history_${chat_id}.json"
                tg_send "$chat_id" "Conversation history reset."
                ;;
            /status)
                tg_send "$chat_id" "Provider: ${PROVIDER:-openai (default)}\nModel: ${MODEL:-gpt-4o-mini}"
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
