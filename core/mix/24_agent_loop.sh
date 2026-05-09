# Main Loop
run_agent() {
    local chat_id="$1"
    local input="$2"
    
    load_history "$chat_id"
    append_text "user" "$input"
    compact_history "$chat_id"
    
    local turn=0
    while [ "$turn" -lt "$MAX_TURNS" ]; do
        turn=$((turn + 1))
        
        # 1. Create a "thinking" message in Telegram
        local msg_id=$(tg_send "$chat_id" "Thinking...")
        
        # 2. Call API (Streaming)
        local result=$(call_api_stream "$chat_id" "$msg_id" )
        
        local tool_calls=$(echo "$result" | grep "^TC:" | cut -c4-)
        local text=$(echo "$result" | grep "^TEXT:" | cut -c6-)
        
        # Append assistant response to history
        if [[ -n "$text" && "$text" != "null" ]]; then
            append_text "assistant" "$text"
        fi
        
        if [[ -n "$tool_calls" && "$tool_calls" != "[]" && "$tool_calls" != "null" ]]; then
            # Record tool calls in history
            append_tool_call "$tool_calls"
            
            # Process tool calls
            echo "$tool_calls" | jq -c '.[]' | while read -r tc; do
                local name=$(echo "$tc" | jq -r '.name')
                local output=$(process_tc "$chat_id" "$msg_id" "$tc")
                append_tool_result "tc_$(date +%s%N)" "$name" "$output"
            done
            
            # Continue loop
            continue
        fi
        
        # No tool calls, we are done
        break
    done
    
    save_history "$chat_id"
}
