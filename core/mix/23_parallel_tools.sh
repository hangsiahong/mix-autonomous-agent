#!/bin/bash
# core/mix/23_parallel_tools.sh - Parallel tool execution logic

# Tools that are always safe to run in parallel (pure reads, no shared state)
PARALLEL_SAFE_TOOLS="^(web_search|fetch_url|list_files|search_files|memory_recall|memory_remember|last_session|sys_info|repo_map|read_error_log|insights|recap|session_search|browser)$"

# Bash commands that write to disk — unsafe to parallelize with other writes
_BASH_WRITE_PATTERN='(^|[;&|`\s])(echo\s.*[>]|printf\s.*[>]|tee\s|cat\s.*[>]|mv\s|cp\s|rm\s|mkdir|touch|chmod|chown|sed\s+-i|awk\s+.*>|git\s+(add|commit|push|checkout|reset|rm)|pip\s+install|npm\s+(install|run)|yarn\s+(install|run))'

# Function to check if a batch of tool calls is safe for parallel execution
is_batch_parallel_safe() {
    local tc_json="$1"
    python3 -c "
import json, sys, re

calls = json.loads(sys.argv[1])
safe_pattern = re.compile(sys.argv[2])
write_pattern = re.compile(sys.argv[3], re.IGNORECASE)

try:
    write_targets = []  # track files written to detect collisions
    for tc in calls:
        name = tc.get('function', {}).get('name', '') or tc.get('name', '')
        args = tc.get('function', {}).get('arguments', '{}') or tc.get('arguments', '{}')
        if isinstance(args, str):
            try: args = json.loads(args)
            except: args = {}

        if safe_pattern.match(name):
            continue  # always safe

        if name == 'bash':
            cmd = args.get('command', '')
            if write_pattern.search(cmd):
                sys.exit(1)  # bash write — not safe to parallelize
            continue  # bash read-only command — safe

        if name in ('write_file', 'edit_code', 'patch', 'ast_edit'):
            # Safe only if writing to different paths than any other writer
            path = args.get('path') or args.get('file_path') or args.get('target', '')
            if path in write_targets:
                sys.exit(1)  # same file written twice — collision
            if path:
                write_targets.append(path)
            continue

        sys.exit(1)  # unknown tool — be conservative

    sys.exit(0)
except SystemExit:
    raise
except Exception:
    sys.exit(1)
" "$tc_json" "$PARALLEL_SAFE_TOOLS" "$_BASH_WRITE_PATTERN"
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
