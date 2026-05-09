#!/bin/bash
# core/mix/26_reflection.sh - Autonomous Self-Reflection

reflect_turn() {
    local chat_id="$1"
    local thread_id="$2"
    local session_id="$3"
    
    # Only reflect if the user isn't just saying 'hi'
    local last_user_msg=$(echo "$HISTORY" | jq -r 'map(select(.role == "user")) | last | .content')
    if [[ ${#last_user_msg} -lt 10 ]]; then
        return
    fi

    echo "AMA: Starting self-reflection for $session_id..."
    
    # ... (rest of function)
        # If it generated a message for the user, we should send it
        if [[ -n "$text" && "$text" != "null" && "$text" != "NO_ACTION" ]]; then
            tg_send "$chat_id" "[Proactive] $text" "$thread_id"
        fi

        if [[ "$tool_calls" != "[]" && "$tool_calls" != "null" ]]; then
             echo "$tool_calls" | jq -c '.[]' | while read -r tc; do
                local name=$(echo "$tc" | jq -r '.function.name')
                local args=$(echo "$tc" | jq -r '.function.arguments')
                echo "Reflection: Executing $name"
                log_tool_usage "$session_id" "$name"
                local output=$(run_tool "$name" "$args")
                
                # Append to history so the next reflection turn knows what happened
                append_tool_call "[$tc]"
                append_tool_result "ref_$(date +%s)" "$name" "$output"
            done
            continue
        fi
        break
    done
    
    # Restore history (reflection turns are hidden from the user session history)
    HISTORY="$temp_history"
}
