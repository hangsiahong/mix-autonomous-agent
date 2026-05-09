#!/bin/bash
# core/mix/26_reflection.sh - Autonomous Self-Reflection

reflect_turn() {
    local chat_id="$1"
    
    # Only reflect if the user isn't just saying 'hi'
    local last_user_msg=$(echo "$HISTORY" | jq -r 'map(select(.role == "user")) | last | .content')
    if [[ ${#last_user_msg} -lt 10 ]]; then
        return
    fi

    echo "AMA: Starting self-reflection..."
    
    # Create a hidden reflection prompt
    local reflection_sys_prompt="You are the Reflection Core of AMA. 
Review the conversation above.
Is there anything you should proactively do to improve yourself or help the user better?
You have full access to tools. 

Possibilities:
1. Create a new custom tool using 'custom_tool_manager' if the user is asking for something you can automate.
2. Update your SOUL.md or AGENT.md if you've learned something about your identity.
3. Save an important fact to memory using 'memory_remember'.
4. Fix a bug in your core logic using 'edit_code'.
5. Propose a new feature to the user.

If no action is needed, respond with 'NO_ACTION'.
If you decide to take action, execute the tools and explain why in the thought.
"

    # Save current history
    local temp_history="$HISTORY"

    # Call API (Non-streaming for reflection)
    local turn=0
    while [ "$turn" -lt 5 ]; do
        turn=$((turn + 1))
        
        # Call API with system prompt override
        local response=$(call_api "$reflection_sys_prompt")
        
        local text=$(echo "$response" | jq -r '.choices[0].message.content // ""')
        local tool_calls=$(echo "$response" | jq -c '.choices[0].message.tool_calls // []')
        
        if [[ "$text" == "NO_ACTION" ]]; then
            break
        fi

        # If it generated a message for the user, we should send it
        if [[ -n "$text" && "$text" != "null" && "$text" != "NO_ACTION" ]]; then
            tg_send "$chat_id" "[Proactive] $text"
        fi

        if [[ "$tool_calls" != "[]" && "$tool_calls" != "null" ]]; then
             echo "$tool_calls" | jq -c '.[]' | while read -r tc; do
                local name=$(echo "$tc" | jq -r '.function.name')
                local args=$(echo "$tc" | jq -r '.function.arguments')
                echo "Reflection: Executing $name"
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
