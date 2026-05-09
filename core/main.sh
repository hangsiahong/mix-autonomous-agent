#!/bin/bash

# core/main.sh - Main Agent Loop

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${DIR}/core/telegram.sh"
source "${DIR}/core/llm.sh"
source "${DIR}/core/executor.sh"

SYSTEM_PROMPT=$(cat "${DIR}/brain/system_prompt.txt")
TOOLS_JSON=$(cat "${DIR}/brain/tools.json")
STATE_DIR="${DIR}/brain/state"
mkdir -p "$STATE_DIR"

process_message() {
    local chat_id="$1"
    local user_text="$2"
    local history_file="${STATE_DIR}/history_${chat_id}.json"

    # Initialize history if it doesn't exist
    if [[ ! -f "$history_file" ]]; then
        echo "[]" > "$history_file"
    fi

    # Append user message to history
    local history=$(cat "$history_file")
    history=$(echo "$history" | jq --arg msg "$user_text" '. + [{role: "user", content: $msg}]')
    
    # Prepend system prompt for LLM call
    local messages=$(echo "$history" | jq --arg sys "$SYSTEM_PROMPT" '[{role: "system", content: $sys}] + .')

    while true; do
        echo "Calling LLM..."
        local response=$(llm_complete "$messages" "$TOOLS_JSON")
        
        local text_resp=$(llm_parse_response "$response")
        local tool_calls=$(llm_parse_tools "$response")

        if [[ -n "$text_resp" ]]; then
            echo "Bot: $text_resp"
            tg_send "$chat_id" "$text_resp"
            # Append bot response to history
            history=$(echo "$history" | jq --arg msg "$text_resp" '. + [{role: "assistant", content: $msg}]')
        fi

        if [[ -n "$tool_calls" && "$tool_calls" != "null" ]]; then
            echo "Tools found: $tool_calls"
            # Append assistant message with tool calls to history
            history=$(echo "$history" | jq --argjson tools "$tool_calls" '. + [{role: "assistant", content: null, tool_calls: $tools}]')
            
            # Handle each tool call
            while read -r tool; do
                local name=$(echo "$tool" | jq -r '.name')
                local args=$(echo "$tool" | jq -c '.args')
                
                echo "Executing $name..."
                local result=$(execute_tool "$name" "$args")
                local output=$(echo "$result" | jq -r '.output')
                
                history=$(echo "$history" | jq --arg name "$name" --arg out "$output" '. + [{role: "tool", name: $name, content: $out}]')
            done < <(echo "$tool_calls" | jq -c '.')

            # Update messages for next turn
            messages=$(echo "$history" | jq --arg sys "$SYSTEM_PROMPT" '[{role: "system", content: $sys}] + .')
            
            # Continue the loop to let LLM process tool results
            continue
        fi

        # No more tool calls, break the loop
        break
    done

    # Save updated history (keep last 20 messages to avoid context bloat)
    echo "$history" | jq 'last(20)' > "$history_file"
}

# Main polling loop (to be called from bot.sh or run directly)
# For now, this is a helper. bot.sh will handle the high-level loop.
