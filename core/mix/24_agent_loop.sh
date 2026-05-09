# Main Loop
run_agent() {
    local chat_id="$1"
    local input="$2"
    local user_id="$3"
    local media_json="$4"
    local thread_id="$5"
    local session_id="$6"
    local chat_title="$7"
    local username="$8"
    local skill="${9}" # Skill passed from router
    
    load_history "$session_id"
    
    # Context Injection (Inspired by Hermes-Agent)
    local context_prompt="## Current Session Context\n"
    context_prompt+="- **Platform**: Telegram\n"
    [[ -n "$chat_title" ]] && context_prompt+="- **Chat**: $chat_title (ID: $chat_id)\n"
    [[ -n "$thread_id" ]] && context_prompt+="- **Topic/Thread ID**: $thread_id\n"
    context_prompt+="- **User**: ${username:-$user_id}\n"
    context_prompt+="- **Session Key**: $session_id\n"
    
    # Skill Binding (Inspired by Hermes-Agent)
    # If skill was not passed (not auto-detected), try looking up from config
    if [[ -z "$skill" ]]; then
        local topic_config=$(get_topic_config "$chat_id" "$thread_id")
        if [[ -n "$topic_config" && "$topic_config" != "null" ]]; then
            skill=$(echo "$topic_config" | jq -r '.skill // empty')
            local topic_name=$(echo "$topic_config" | jq -r '.name // empty')
            [[ -n "$topic_name" ]] && context_prompt+="- **Topic Name**: $topic_name\n"
        fi
    fi
    [[ -n "$skill" ]] && context_prompt+="- **Active Skill**: $skill\n"
    
    # Inject context hint
    append_text "user" "[SYSTEM: Context Updated]\n$context_prompt\n\n$input" "$media_json"
    compact_history "$session_id"
    
    local turn=0
    while [ "$turn" -lt "$MAX_TURNS" ]; do
        turn=$((turn + 1))
        local TURN_CALLS=""
        
        # 1. Create a "thinking" message in Telegram
        tg_send_action "$chat_id" "typing" "$thread_id"
        local msg_id=$(tg_send "$chat_id" "Thinking..." "$thread_id")
        
        # Update title if it's the first turn
        if [[ "$turn" -eq 1 ]]; then
            # Generate title in background
            ( generate_title "$session_id" & )
        fi
        local result=$(call_api_stream "$chat_id" "$msg_id" "$skill")
        
        if [[ -z "$result" || "$result" == "FAIL:"* ]]; then
            tg_edit "$chat_id" "$msg_id" "Error: Failed to get response from AI. Please try again later."
            break
        fi

        local tool_calls=$(echo "$result" | grep "^TC:" | cut -c4-)
        local text=$(echo "$result" | grep "^TEXT:" | cut -c6-)
        local usage=$(echo "$result" | grep "^USAGE:" | cut -c7-)
        
        # Log usage
        if [[ -n "$usage" ]]; then
            log_usage "$session_id" "$usage" "$MODEL"
        fi
        
        # Append assistant response to history
        if [[ -n "$text" && "$text" != "null" ]]; then
            append_text "assistant" "$text"
        fi
        
        if [[ -n "$tool_calls" && "$tool_calls" != "[]" && "$tool_calls" != "null" ]]; then
            # Record tool calls in history
            append_tool_call "$tool_calls"
            
            # Process tool calls
            local py_script=$(cat << 'EOF'
import sys, json
try:
    calls = json.loads(sys.argv[1])
    for tc in calls:
        name = tc.get("function", {}).get("name") or tc.get("name", "")
        tc_id = tc.get("id", "")
        if not name:
            name = "unknown_tool"
        print(f"{name.strip()}|{tc_id.strip()}")
except:
    pass
EOF
)
            while IFS='|' read -r name tc_id; do
                [[ -z "$name" ]] && continue
                if [[ -z "$tc_id" ]]; then
                    tc_id="tc_$(date +%s%N)"
                fi
                
                # Check for explicit errors parsing the JSON
                if [[ "$name" == "unknown_tool" ]]; then
                     output="Error: Tool name could not be parsed from JSON payload."
                else
                     # Find original tool call JSON to pass to process_tc
                     local single_tc=$(echo "$tool_calls" | jq -c --arg id "$tc_id" '.[] | select(.id == $id)')
                     # If the ID wasn't in the original payload, fallback to taking the first matching by name
                     if [[ -z "$single_tc" || "$single_tc" == "null" ]]; then
                         single_tc=$(echo "$tool_calls" | jq -c '.[]' | head -n 1) # simple fallback
                     fi
                     output=$(process_tc "$chat_id" "$msg_id" "$single_tc" "$thread_id")
                fi

                append_tool_result "$tc_id" "$name" "$output"
            done < <(python3 -c "$py_script" "$tool_calls")
            
            # Continue loop
            # Provide an empty message placeholder for the next assistant stream since 
            # the last message edit showed "✅ Tool X completed."
            # The next stream turn will update the thinking placeholder.
            continue
        fi
        
        # No tool calls, we are done
        break
    done
    
    save_history "$session_id"
    log_trajectory "$session_id" "completed"
    
    # Run self-reflection in the background
    ( reflect_turn "$chat_id" "$thread_id" "$session_id" & )
}
