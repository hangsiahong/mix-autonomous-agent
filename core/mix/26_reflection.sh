#!/bin/bash
# core/mix/26_reflection.sh - Autonomous Self-Reflection

reflect_turn() {
    local chat_id="$1"
    local thread_id="$2"
    local session_id="$3"
    
    # Only reflect if the user isn't just saying 'hi'
    local last_user_msg
    last_user_msg=$(echo "$HISTORY" | python3 -c "
import json, sys
h = json.load(sys.stdin)
users = [m for m in h if m.get('role') == 'user']
if not users:
    print('')
else:
    c = users[-1].get('content') or ''
    if isinstance(c, list):
        c = ' '.join(p.get('text','') for p in c if isinstance(p,dict))
    print(c or '')
" 2>/dev/null)
    if [[ ${#last_user_msg} -lt 20 ]]; then
        return
    fi

    # Skip reflection for local/offline models — too slow for background calls
    if [[ "$PROVIDER" == "ollama" ]]; then
        return
    fi

    echo "AMA: Starting self-reflection for $session_id..."
    
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
5. Check 'read_error_log' if you suspect issues with API or tools.
6. Propose a new feature to the user.

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
        local parsed=$(parse_resp "$response")
        
        local text=$(echo "$parsed" | grep "^TEXT:" | cut -c6-)
        local tool_calls=$(echo "$parsed" | grep "^TC:" | cut -c4-)
        
        if [[ "$text" == "NO_ACTION" ]]; then
            break
        fi

        # If it generated a message for the user, we should send it
        if [[ -n "$text" && "$text" != "null" && "$text" != "" && "$text" != "NO_ACTION" ]]; then
            tg_send "$chat_id" "[Proactive] $text" "$thread_id"
        fi

        if [[ "$tool_calls" != "[]" && "$tool_calls" != "null" && -n "$tool_calls" ]]; then
            local _tc_lines
            _tc_lines=$(echo "$tool_calls" | python3 -c "
import json, sys
for tc in json.load(sys.stdin):
    name = (tc.get('function') or {}).get('name','')
    args = (tc.get('function') or {}).get('arguments','{}')
    tc_json = json.dumps(tc, separators=(',',':'))
    print(name + '\x1f' + args + '\x1f' + tc_json)
" 2>/dev/null)
            while IFS= read -r _line; do
                local name args tc_json
                IFS=$'\x1f' read -r name args tc_json <<< "$_line"
                echo "Reflection: Executing $name"
                log_tool_usage "$session_id" "$name"
                local output
                output=$(run_tool "$name" "$args")

                # Append to history so the next reflection turn knows what happened
                append_tool_call "[$tc_json]"
                append_tool_result "ref_$(date +%s)" "$name" "$output"
            done <<< "$_tc_lines"
            continue
        fi
        break
    done
    
    # Restore history (reflection turns are hidden from the user session history)
    HISTORY="$temp_history"
}
