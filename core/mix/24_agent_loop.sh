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
    
    # Send a single placeholder message for the entire turn (openclaw pattern:
    # one draft message, continuously edited, finalized with the answer)
    tg_send_action "$chat_id" "typing" "$thread_id"
    local msg_id
    msg_id=$(tg_send "$chat_id" "⏳ Thinking..." "$thread_id")
    ( generate_title "$session_id" & )

    local turn=0
    local total_tool_calls=0
    local all_tool_names=""
    local loop_completed=false
    while [ "$turn" -lt "$MAX_TURNS" ]; do
        turn=$((turn + 1))
        local TURN_CALLS=""

        # On continuation turns (tool sub-rounds), refresh typing indicator only --
        # do NOT send a new Telegram message; reuse the same msg_id
        if [[ "$turn" -gt 1 ]]; then
            tg_send_action "$chat_id" "typing" "$thread_id"
        fi

        local result
        result=$(call_api_stream "$chat_id" "$msg_id" "$skill")
        
        if [[ -z "$result" || "$result" == "FAIL:"* ]]; then
            tg_edit "$chat_id" "$msg_id" "Error: Failed to get response from AI. Please try again later."
            break
        fi

        local tool_calls=$(echo "$result" | grep "^TC:" | cut -c4-)
        local usage=$(echo "$result" | grep "^USAGE:" | cut -c7-)
        # Use Python to extract multiline TEXT content (grep only gets the first line)
        local text
        text=$(printf '%s' "$result" | python3 -c "
import sys, re
c = sys.stdin.read()
m = re.search(r'(?m)^TEXT:(.*?)(?=\nUSAGE:|\Z)', c, re.DOTALL)
if m:
    print(m.group(1), end='')
" 2>/dev/null)
        
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
            # Track tool names and count for footer
            local batch_names batch_count
            batch_names=$(echo "$tool_calls" | python3 -c "
import sys, json
calls = json.load(sys.stdin)
print(', '.join(c.get('function', {}).get('name', '?') for c in calls))
" 2>/dev/null || echo "")
            batch_count=$(echo "$tool_calls" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
            total_tool_calls=$((total_tool_calls + batch_count))
            [[ -n "$batch_names" ]] && all_tool_names+="${all_tool_names:+, }$batch_names"

            while IFS='|' read -r name tc_id; do
                [[ -z "$name" ]] && continue
                if [[ -z "$tc_id" ]]; then
                    tc_id="tc_$(date +%s%N)"
                fi

                if [[ "$name" == "unknown_tool" ]]; then
                    output="Error: Tool name could not be parsed from JSON payload."
                else
                    local single_tc
                    single_tc=$(echo "$tool_calls" | jq -c --arg id "$tc_id" '.[] | select(.id == $id)')
                    if [[ -z "$single_tc" || "$single_tc" == "null" ]]; then
                        single_tc=$(echo "$tool_calls" | jq -c '.[]' | head -n 1)
                    fi
                    output=$(process_tc "$chat_id" "$msg_id" "$single_tc" "$thread_id")
                fi

                append_tool_result "$tc_id" "$name" "$output"
            done < <(python3 -c "$py_script" "$tool_calls")
            continue
        fi
        
        # No tool calls — final answer received
        loop_completed=true
        break
    done

    # Append tool-use footer to the final message (openclaw-style: one clean answer + attribution)
    if [[ "$loop_completed" == true && $total_tool_calls -gt 0 && -n "$text" ]]; then
        # Build deduped footer: "tool_a ×3, tool_b ×1" style
        local footer_parts
        footer_parts=$(echo "$all_tool_names" | tr ',' '\n' | sed 's/^ *//' | grep -v '^$' | sort | uniq -c | sort -rn | \
            awk '{cnt=$1; name=$2; for(i=3;i<=NF;i++) name=name" "$i; if(cnt>1) print name" ×"cnt; else print name}' | \
            paste -sd ', ')
        local footer_label
        footer_label="${total_tool_calls} tool call$([[ $total_tool_calls -ne 1 ]] && echo 's')"
        local full_md="${text}"$'\n\n'"_🔧 ${footer_label}: ${footer_parts}_"
        local html_out
        html_out=$(md_to_tg_html "$full_md")
        tg_edit "$chat_id" "$msg_id" "$html_out" "HTML" > /dev/null
    fi

    save_history "$session_id"
    log_trajectory "$session_id" "completed"
    
    # Run self-reflection in the background
    ( reflect_turn "$chat_id" "$thread_id" "$session_id" & )
}
