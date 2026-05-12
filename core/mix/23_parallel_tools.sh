#!/bin/bash
# core/mix/23_parallel_tools.sh - Parallel tool execution logic

# Regex for tools that are safe to run in parallel (read-only)
PARALLEL_SAFE_TOOLS="^(web_search|fetch_url|list_files|search_files|memory_recall|sys_info|repo_map|read_error_log|insights|recap|session_search|browser)$"

# Function to check if a batch of tool calls is safe for parallel execution
is_batch_parallel_safe() {
    local tc_json="$1"
    python3 -c "
import json, sys, re
try:
    calls = json.loads(sys.argv[1])
    safe_pattern = re.compile(sys.argv[2])
    for tc in calls:
        name = tc.get('function', {}).get('name', '') or tc.get('name', '')
        if not safe_pattern.match(name):
            sys.exit(1)
    sys.exit(0)
except:
    sys.exit(1)
" "$tc_json" "$PARALLEL_SAFE_TOOLS"
    return $?
}

# Parallel batch executor
execute_parallel_batch() {
    local chat_id="$1"
    local msg_id="$2"
    local thread_id="$3"
    local tc_json="$4"
    local session_id="$5"

    local batch_dir="${DIR}/brain/state/batches/batch_$(date +%s%N)"
    mkdir -p "$batch_dir"

    # 1. Start all tools in background
    local tc_ids=""
    local tc_names=""
    
    # We use python to iterate and launch since bash iteration over JSON is slow/complex
    local launch_script='
import json, sys, os, subprocess
calls = json.loads(open(sys.argv[1]).read())
batch_dir = sys.argv[2]
for tc in calls:
    tc_id = tc.get("id", f"tc_{os.getpid()}_{len(os.listdir(batch_dir))}")
    name = tc.get("function", {}).get("name") or tc.get("name", "unknown")
    
    # Write TC to file for the worker
    with open(f"{batch_dir}/{tc_id}.tc.json", "w") as f:
        json.dump(tc, f)
    
    # Print for the shell to track
    print(f"{tc_id}|{name}")
'
    local launched_info
    launched_info=$(python3 -c "$launch_script" <(printf '%s' "$tc_json") "$batch_dir")

    # 2. Worker logic (runs in background for each tool)
    run_parallel_worker() {
        local tc_id="$1"
        local name="$2"
        local b_dir="$3"
        local c_id="$4"
        local m_id="$5"
        local t_id="$6"

        local tc_file="${b_dir}/${tc_id}.tc.json"
        local out_file="${b_dir}/${tc_id}.out"
        local status_file="${b_dir}/${tc_id}.status"

        echo "RUNNING" > "$status_file"
        
        # We need process_tc to NOT update Telegram directly in parallel mode
        # or it will race. But for now, let's allow it and see.
        # Actually, let's use a suppressed version of process_tc or env var.
        
        local tc_content=$(cat "$tc_file")
        # Run the tool (silencing the tg_edit calls inside process_tc if we can)
        export AMA_PARALLEL=true
        local output
        output=$(process_tc "$c_id" "$m_id" "$tc_content" "$t_id")
        
        echo "$output" > "$out_file"
        echo "DONE" > "$status_file"
    }

    # Launch workers
    while IFS='|' read -r tc_id name; do
        run_parallel_worker "$tc_id" "$name" "$batch_dir" "$chat_id" "$msg_id" "$thread_id" &
    done <<< "$launched_info"

    # 3. Wait and update UI
    local all_done=false
    while [[ "$all_done" == false ]]; do
        sleep 1
        all_done=true
        local status_summary=""
        
        while IFS='|' read -r tc_id name; do
            local status_file="${batch_dir}/${tc_id}.status"
            local status=$(cat "$status_file" 2>/dev/null || echo "PENDING")
            if [[ "$status" == "RUNNING" ]]; then
                status_summary+="⚒ <code>${name}</code>...&#10;"
                all_done=false
            elif [[ "$status" == "DONE" ]]; then
                status_summary+="✅ <code>${name}</code>&#10;"
            else
                all_done=false
            fi
        done <<< "$launched_info"

        # Update Telegram with the aggregate status
        local _prefix="${_AMA_REASONING_HTML:+${_AMA_REASONING_HTML}&#10;&#10;}"
        tg_edit "$chat_id" "$msg_id" "${_prefix}${status_summary}" "HTML" > /dev/null 2>&1
    done

    # 4. Collect results and cleanup
    while IFS='|' read -r tc_id name; do
        local output=$(cat "${batch_dir}/${tc_id}.out" 2>/dev/null)
        append_tool_result "$tc_id" "$name" "$output"
    done <<< "$launched_info"

    rm -rf "$batch_dir"
}
