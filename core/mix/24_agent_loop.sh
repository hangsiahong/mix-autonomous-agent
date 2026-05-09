# Main Loop
run_agent() {
    local chat_id="$1"
    local input="$2"
    local user_id="$3"
    
    load_history "$chat_id"
    
    # Inject context hint about IDs
    local context_hint="[Context: chat_id=$chat_id, user_id=$user_id]"
    append_text "user" "$context_hint $input"
    compact_history "$chat_id"
    
    local turn=0
    while [ "$turn" -lt "$MAX_TURNS" ]; do
        turn=$((turn + 1))
        local TURN_CALLS=""
        
        # 1. Create a "thinking" message in Telegram
        local msg_id=$(tg_send "$chat_id" "Thinking...")
        
        # Update title if it's the first turn
        if [[ "$turn" -eq 1 ]]; then
            # Generate title in background
            ( generate_title "$chat_id" & )
        fi
        local result=$(call_api_stream "$chat_id" "$msg_id" )
        
        local tool_calls=$(echo "$result" | grep "^TC:" | cut -c4-)
        local text=$(echo "$result" | grep "^TEXT:" | cut -c6-)
        local usage=$(echo "$result" | grep "^USAGE:" | cut -c7-)
        
        # Log usage
        if [[ -n "$usage" ]]; then
            log_usage "$chat_id" "$usage" "$MODEL"
        fi
        
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
    
    # Run self-reflection in the background
    ( reflect_turn "$chat_id" & )
}
