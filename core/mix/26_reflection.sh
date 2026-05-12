#!/bin/bash
# core/mix/26_reflection.sh - Autonomous Self-Reflection

reflect_turn() {
    local chat_id="$1"
    local thread_id="$2"
    local session_id="$3"

    # Only reflect if the user isn't just saying 'hi'
    local last_user_msg
    last_user_msg=$(python3 -c "
import json, sys
h = json.loads(open(sys.argv[1]).read())
user_msgs = [m for m in h if m.get('role') == 'user']
if user_msgs:
    print(user_msgs[-1].get('content', ''))
" <(printf '%s' "$HISTORY") 2>/dev/null)
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
Is there anything you should proactively do to help the user?

You are LIMITED to read-only and memory tools ONLY:
1. Save an important fact about the user using 'memory_remember'.
2. Search memory with 'memory_search' or 'memory_recall'.
3. Check error log with 'read_error_log' if you suspect issues.

DO NOT use: edit_code, write_file, bash, process, custom_tool_manager, skill_manager, or any tool that modifies files or runs code.
DO NOT propose code changes or improvements to your own source files.

If no memory-worthy observation exists, respond with 'NO_ACTION'.
"

    # Save current history
    local temp_history="$HISTORY"

    # Override HISTORY to only include safe/read-only tools for reflection
    local _safe_tools
    _safe_tools=$(python3 -c "
import json, sys
try:
    tools = json.load(open('brain/tools.json'))
    blocked = {'bash','process','edit_code','write_file','patch','delete_file',
               'custom_tool_manager','skill_manager','skill_install','image_generate'}
    safe = [t for t in tools if t.get('name','') not in blocked]
    print(json.dumps(safe, separators=(',',':')))
except:
    print('[]')
" 2>/dev/null)

    # Call API (Non-streaming for reflection)
    # Temporarily use only safe read-only tools during reflection
    # Use a file-based backup so it survives crashes (variable would be lost)
    cp brain/tools.json brain/tools.json.bak 2>/dev/null || true
    printf '%s' "$_safe_tools" > brain/tools.json

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

        # Only send to user if there's real value AND it's not just a narrated plan.
        # Suppress messages that are pure intentions without tool results yet.
        local _has_tools=false
        [[ "$tool_calls" != "[]" && "$tool_calls" != "null" && -n "$tool_calls" ]] && _has_tools=true

        if [[ -n "$text" && "$text" != "null" && "$text" != "" && "$text" != "NO_ACTION" && "$_has_tools" == false ]]; then
            # Only send text-only proactive messages if they contain actual findings/fixes,
            # not just descriptions of what the agent "will" do next.
            if echo "$text" | grep -qiE "I('ll| will| would| am going to)|Let me |I'll check|I should|Next,|First,"; then
                : # suppress — it's narrating a plan, not reporting a result
            else
                tg_send "$chat_id" "[Proactive] $text" "$thread_id"
            fi
        fi

        if [[ "$tool_calls" != "[]" && "$tool_calls" != "null" && -n "$tool_calls" ]]; then
            local _tc_lines
            _tc_lines=$(echo "$tool_calls" | python3 -c "
import json, sys
for tc in json.loads(open(sys.argv[1]).read()):
    name = (tc.get('function') or {}).get('name','')
    args = (tc.get('function') or {}).get('arguments','{}')
    tc_json = json.dumps(tc, separators=(',',':'))
    print(name + '\x1f' + args + '\x1f' + tc_json)
" 2>/dev/null)
            while IFS= read -r _line; do
                local name args tc_json
                IFS=$'\x1f' read -r name args tc_json <<< "$_line"
                # Hard block: never allow mutating tools in reflection
                case "$name" in
                    bash|process|edit_code|write_file|patch|delete_file|custom_tool_manager|skill_manager|skill_install)
                        echo "Reflection: Blocked unsafe tool '$name'" >&2
                        continue
                        ;;
                esac
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

    # Restore full tools.json and history
    if [[ -f brain/tools.json.bak ]]; then
        mv brain/tools.json.bak brain/tools.json
    fi
    HISTORY="$temp_history"
}
