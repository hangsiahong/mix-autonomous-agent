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
    local skill="${9}"
    local user_msg_id="${10:-}"  # Telegram message_id of the user's message (for reply-to + reactions)

    local pid_file="${DIR}/brain/state/run_${session_id}.pid"
    local stop_flag="${DIR}/brain/state/stop_${session_id}"
    local steer_file="${DIR}/brain/state/steer_${session_id}"
    local queue_file="${DIR}/brain/state/queue_${session_id}"
    local model_file="${DIR}/brain/state/model_${session_id}"

    # 1. Immediate Feedback: Decide status based on lock availability
    mkdir -p "${DIR}/brain/state/locks"
    local lock_file="${DIR}/brain/state/locks/${session_id}.lock"
    local initial_status="Thinking"
    local msg_id

    # React 👀 on the user's message to signal we received it (hermes pattern)
    [[ -n "$user_msg_id" && "$user_msg_id" != "0" ]] && tg_react "$chat_id" "$user_msg_id" "👀"

    # Try non-blocking lock to check if busy
    if ! flock -n "${lock_file}" true 2>/dev/null; then
        initial_status="Queued"
        msg_id=$(tg_send_r "$chat_id" "🕒 <i>Queued</i>" "$thread_id" "HTML" "$user_msg_id")
    else
        msg_id=$(tg_send_r "$chat_id" "⏳ <i>Thinking…</i>" "$thread_id" "HTML" "$user_msg_id")
    fi

    # Session Lock block
    (
        # Wait for the lock — write PID file INSIDE lock so it always points
        # to the RUNNING process, never a queued one that hasn't started yet
        flock -x 200
        echo "$$|${msg_id}|${chat_id}|${thread_id}" > "$pid_file"
        trap 'rm -f "$pid_file"' EXIT INT TERM

        # Stop flag handling:
        # - Queued processes: /stop was issued while waiting → exit immediately
        # - Non-queued (fresh start): clean up any stale flag and continue normally
        if [[ "$initial_status" == "Queued" && -f "$stop_flag" ]]; then
            rm -f "$stop_flag"
            tg_edit "$chat_id" "$msg_id" "🛑 <i>Stopped.</i>" "HTML" > /dev/null 2>&1
            exit 0
        else
            rm -f "$stop_flag" 2>/dev/null || true  # clean up stale flag from prior /stop
        fi

        # Optimization: Only edit if we were actually queued
        if [[ "$initial_status" == "Queued" ]]; then
            tg_edit "$chat_id" "$msg_id" "⏳ <i>Thinking…</i>" "HTML" > /dev/null 2>&1
        fi

        tg_send_action "$chat_id" "typing" "$thread_id"
        load_history "$session_id"
        
        # Context Injection
        local context_prompt="## Current Session Context\n"
        context_prompt+="- **Platform**: Telegram\n"
        [[ -n "$chat_title" ]] && context_prompt+="- **Chat**: $chat_title (ID: $chat_id)\n"
        [[ -n "$thread_id" ]] && context_prompt+="- **Topic/Thread ID**: $thread_id\n"
        context_prompt+="- **User**: ${username:-$user_id}\n"
        context_prompt+="- **Session Key**: $session_id\n"
        
        if [[ -z "$skill" ]]; then
            local topic_config=$(get_topic_config "$chat_id" "$thread_id")
            if [[ -n "$topic_config" && "$topic_config" != "null" ]]; then
                skill=$(python3 -c "import json,sys; print(json.loads(open(sys.argv[1]).read()).get('skill',''))" <(printf '%s' "$topic_config") 2>/dev/null)
                local topic_name=$(python3 -c "import json,sys; print(json.loads(open(sys.argv[1]).read()).get('name',''))" <(printf '%s' "$topic_config") 2>/dev/null)
                [[ -n "$topic_name" ]] && context_prompt+="- **Topic Name**: $topic_name\n"
            fi
        fi
        [[ -n "$skill" ]] && context_prompt+="- **Active Skill**: $skill\n"

        # Apply per-session model override (/model command — hermes pattern)
        if [[ -f "$model_file" ]]; then
            local _session_model; _session_model=$(cat "$model_file" 2>/dev/null)
            [[ -n "$_session_model" ]] && MODEL="$_session_model"
        fi

        # Ensure session exists in SQLite DB (hermes: create_session is idempotent)
        ( python3 tools/session_db.py create "$session_id" "${user_id:-}" "${MODEL:-}" \
            > /dev/null 2>&1 & )

        append_text "user" "[SYSTEM: Context Updated]\n$context_prompt\n\n$input" "$media_json"
        ( generate_title "$session_id" & )

        compact_history "$session_id" "$chat_id" "$thread_id" "$msg_id"

        # Emergency Safety Truncation
        local char_count=${#HISTORY}
        if [[ "$char_count" -gt 200000 ]]; then
            HISTORY=$(python3 -c "import json,sys; h=json.loads(open(sys.argv[1]).read()); print(json.dumps(h[:5] + [{'role':'system','content':'[Safety: Mid-history purged due to size]'}]+ h[-10:],separators=(',',':')))" <(printf '%s' "$HISTORY"))
            save_history "$session_id"
        fi

        local turn=0
        local total_tool_calls=0
        local all_tool_names=""
        local loop_completed=false
        while [ "$turn" -lt "$MAX_TURNS" ]; do
            turn=$((turn + 1))
            [[ "$turn" -gt 1 ]] && tg_send_action "$chat_id" "typing" "$thread_id"
            export _AMA_REASONING_HTML="${_AMA_REASONING_HTML:-}"

            local result
            result=$(call_api_stream "$chat_id" "$msg_id" "$skill")
            
            if [[ -z "$result" || "$result" == "FAIL:"* ]]; then
                local err_info="${result#FAIL:}"
                tg_edit "$chat_id" "$msg_id" "Error: Failed to get response from AI. ${err_info:-'Please try again later.'}"
                break
            fi

            local tool_calls=$(echo "$result" | grep "^TC:" | cut -c4-)
            local usage=$(echo "$result" | grep "^USAGE:" | cut -c7-)
            local text
            text=$(printf '%s' "$result" | python3 -c "import sys, re; c = sys.stdin.read(); m = re.search(r'(?m)^TEXT:(.*?)(?=\nUSAGE:|\Z)', c, re.DOTALL); print(m.group(1) if m else '', end='')" 2>/dev/null)
            
            [[ -n "$usage" ]] && log_usage "$session_id" "$usage" "$MODEL"
            [[ -n "$text" && "$text" != "null" ]] && append_text "assistant" "$text"

            if [[ -n "$tool_calls" && "$tool_calls" != "[]" && "$tool_calls" != "null" ]]; then
                if [[ -n "$text" && "$text" != "null" ]]; then
                    local _esc_reason=$(printf '%s' "$text" | head -c 500 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
                    [[ ${#text} -gt 480 ]] && _esc_reason="${_esc_reason}..."
                    export _AMA_REASONING_HTML="$_esc_reason"
                    tg_edit "$chat_id" "$msg_id" "$_esc_reason" "HTML" > /dev/null 2>&1
                fi
                append_tool_call "$tool_calls"

                local batch_names=$(python3 -c "import sys, json; calls = json.loads(open(sys.argv[1]).read()); print(', '.join(c.get('function', {}).get('name', '?') for c in calls))" <(printf '%s' "$tool_calls") 2>/dev/null || echo "")
                local batch_count=$(python3 -c "import sys, json; print(len(json.loads(open(sys.argv[1]).read())))" <(printf '%s' "$tool_calls") 2>/dev/null || echo 0)
                total_tool_calls=$((total_tool_calls + batch_count))
                [[ -n "$batch_names" ]] && all_tool_names+="${all_tool_names:+, }$batch_names"

                if [[ $batch_count -gt 1 ]] && is_batch_parallel_safe "$tool_calls"; then
                    execute_parallel_batch "$chat_id" "$msg_id" "$thread_id" "$tool_calls" "$session_id"
                else
                    while IFS='|' read -r name tc_id; do
                        [[ -z "$name" ]] && continue
                        [[ -z "$tc_id" ]] && tc_id="tc_$(date +%s%N)"
                        local single_tc=$(python3 -c "import json, sys, os; calls = json.loads(open(sys.argv[1]).read()); target_id = os.environ.get('TC_ID',''); match = next((t for t in calls if t.get('id') == target_id), None); print(json.dumps(match or calls[0], separators=(',',':')) if calls else '')" <(printf '%s' "$tool_calls") TC_ID="$tc_id" 2>/dev/null)
                        local output=$(process_tc "$chat_id" "$msg_id" "$single_tc" "$thread_id")
                        append_tool_result "$tc_id" "$name" "$output"
                    done < <(python3 -c "
import sys, json
for tc in json.loads(open(sys.argv[1]).read()):
    name = tc.get('function', {}).get('name') or tc.get('name', '') or 'unknown_tool'
    print(f'{name.strip()}|{tc.get(\"id\", \"\").strip()}')
" <(printf '%s' "$tool_calls"))
                fi
                # Drain pending /steer into last tool result (hermes pattern)
                if [[ -f "$steer_file" ]]; then
                    local _steer_text; _steer_text=$(cat "$steer_file" 2>/dev/null)
                    rm -f "$steer_file"
                    if [[ -n "$_steer_text" ]]; then
                        # Append steer as "User guidance" to the last tool result in history
                        HISTORY=$(python3 -c "
import json, sys
h = json.loads(open(sys.argv[1]).read())
steer = open(sys.argv[2]).read().strip()
# Find last tool message and append guidance
for i in range(len(h)-1, -1, -1):
    if h[i].get('role') == 'tool':
        c = h[i].get('content', '')
        h[i]['content'] = str(c) + '\n\nUser guidance: ' + steer
        break
print(json.dumps(h, separators=(',',':')))
" <(printf '%s' "$HISTORY") <(printf '%s' "$_steer_text") 2>/dev/null || printf '%s' "$HISTORY")
                    fi
                fi

                # Show completed tool names then reset to thinking for next turn
                local _between_msg
                _between_msg=$(TOOL_NAMES="$batch_names" python3 -c "
import os, re
EMOJI = {'bash':'🛠️','web_search':'🔍','fetch_url':'🌐','read_file':'📖','write_file':'✍️',
         'edit_code':'📝','search_files':'🔎','todo':'📋','memory':'🧠','memory_remember':'🧠',
         'memory_recall':'🧠','process':'⚙️','browser':'🌍','image_generate':'🎨','patch':'🩹',
         'repo_map':'🗺️','clarify':'💬','session_search':'🗂️','sys_info':'📊','recap':'📝',
         'custom_tool_manager':'🔧','skill_manager':'🎯','skill_install':'📦','insights':'📈',
         'kanban_show':'📌','kanban_create':'📌','kanban_complete':'✅','kanban_block':'🚧'}
names = [n.strip() for n in os.environ.get('TOOL_NAMES','').split(',') if n.strip()]
lines = ['<code>' + EMOJI.get(n,'🧩') + ' ' + n.replace('_',' ') + '</code>' for n in names[:4]]
print('<i>Thinking…</i>\n' + '\n'.join(lines) if lines else '⏳ <i>Thinking…</i>')
" 2>/dev/null || echo "⏳ <i>Thinking…</i>")
                tg_edit "$chat_id" "$msg_id" "$_between_msg" "HTML" > /dev/null 2>&1
                export _AMA_REASONING_HTML=""
                continue
            fi
            # Steer arrived but no tools were called this turn — inject into next turn
            # instead of losing it silently (hermes: steer waits for next tool batch)
            if [[ -f "$steer_file" ]]; then
                local _steer_leftover; _steer_leftover=$(cat "$steer_file" 2>/dev/null)
                rm -f "$steer_file"
                if [[ -n "$_steer_leftover" ]]; then
                    # Add as a user guidance message so next turn picks it up
                    append_text "user" "[User guidance for next response: $_steer_leftover]"
                    tg_edit "$chat_id" "$msg_id" "⏳ <i>Applying guidance…</i>" "HTML" > /dev/null 2>&1
                    continue  # Run another turn with the steer applied
                fi
            fi
            loop_completed=true
            break
        done

        if [[ "$loop_completed" == true ]]; then
            if [[ $total_tool_calls -gt 0 && -n "$text" ]]; then
                local footer_parts=$(echo "$all_tool_names" | tr ',' '\n' | sed 's/^ *//' | grep -v '^$' | sort | uniq -c | sort -rn | awk '{cnt=$1; name=$2; for(i=3;i<=NF;i++) name=name" "$i; if(cnt>1) print name" ×"cnt; else print name}' | paste -sd ', ')
                local full_md="${text}"$'\n\n'"_🔧 ${total_tool_calls} tool call$([[ $total_tool_calls -ne 1 ]] && echo 's'): ${footer_parts}_"
                tg_edit "$chat_id" "$msg_id" "$(md_to_tg_html "$full_md")" "HTML" > /dev/null
            elif [[ -n "$text" && "$text" != "null" && $total_tool_calls -eq 0 ]]; then
                tg_edit "$chat_id" "$msg_id" "$(md_to_tg_html "$text")" "HTML" > /dev/null
            fi
            # React ✅ on the user's original message (hermes: done signal)
            [[ -n "$user_msg_id" && "$user_msg_id" != "0" ]] && tg_react "$chat_id" "$user_msg_id" "✅"
        else
            # Loop hit max turns without clean exit
            tg_edit "$chat_id" "$msg_id" "$(md_to_tg_html "${text:-}")\n\n⚠️ _Max turns reached. Use /retry to continue or /new for fresh session._" "HTML" > /dev/null 2>&1 || true
            [[ -n "$user_msg_id" && "$user_msg_id" != "0" ]] && tg_react "$chat_id" "$user_msg_id" "👎"
        fi

        save_history "$session_id"
        log_trajectory "$session_id" "completed"
        ( reflect_turn "$chat_id" "$thread_id" "$session_id" & )
        [[ "$loop_completed" == true && $total_tool_calls -gt 0 ]] && \
            ( save_session_recap "$session_id" "$chat_id" "$thread_id" & )
        # Pre-warm memory for next turn in background (hermes queue_prefetch_all pattern)
        # Result stored in prefetch cache so next _api_build_payload finds it instantly
        if [[ "${MEMORY_PREFETCH:-1}" != "0" && -n "$text" ]]; then
            local _prefetch_cache="${DIR}/brain/state/prefetch_${session_id}"
            local _next_query
            _next_query=$(printf '%s' "$text" | head -c 300)
            ( timeout 8 python3 tools/memory_helper.py search "$_next_query" 3 \
                > "$_prefetch_cache" 2>/dev/null || rm -f "$_prefetch_cache" ) &
        fi
    ) 200>"$lock_file"

    # Process queued message after lock is released (hermes /queue pattern)
    if [[ -f "$queue_file" ]]; then
        local _queued_text
        _queued_text=$(head -1 "$queue_file" 2>/dev/null)
        # Pop the first line
        python3 -c "
import sys
lines = open(sys.argv[1]).readlines()
if len(lines) > 1:
    open(sys.argv[1],'w').writelines(lines[1:])
else:
    import os; os.unlink(sys.argv[1])
" "$queue_file" 2>/dev/null || rm -f "$queue_file"
        if [[ -n "$_queued_text" ]]; then
            ( set -m; run_agent "$chat_id" "$_queued_text" "$user_id" "[]" "$thread_id" "$session_id" "$chat_title" "$username" "$skill" ) &
        fi
    fi
}
