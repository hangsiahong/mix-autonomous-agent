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

        # Status is tracked in-shell via pid_to_tc / tc_done (event-driven via
        # wait -n -p); no need to fan-out via status files anymore.
        local tc_content=$(cat "$tc_file")
        export AMA_PARALLEL=true
        local output
        output=$(process_tc "$c_id" "$m_id" "$tc_content" "$t_id")
        echo "$output" > "$out_file"
    }

    # Launch workers, recording pid → tc_id so we can identify finishers.
    local -A pid_to_tc=()
    local -A tc_done=()
    while IFS='|' read -r tc_id name; do
        run_parallel_worker "$tc_id" "$name" "$batch_dir" "$chat_id" "$msg_id" "$thread_id" &
        pid_to_tc[$!]="$tc_id"
    done <<< "$launched_info"

    # 3. Event-driven collection: wait -n returns the moment any worker exits;
    #    -p captures its pid so we know which tc to mark done and can repaint
    #    the UI immediately instead of after a fixed sleep tick.
    while (( ${#pid_to_tc[@]} > 0 )); do
        local _finished_pid=""
        wait -n -p _finished_pid 2>/dev/null || true

        # Defensive fallback: if -p didn't yield a tracked pid (race, signal,
        # or stray background job), scan for dead workers we still track.
        if [[ -z "$_finished_pid" || -z "${pid_to_tc[$_finished_pid]:-}" ]]; then
            _finished_pid=""
            for pid in "${!pid_to_tc[@]}"; do
                if ! kill -0 "$pid" 2>/dev/null; then
                    _finished_pid="$pid"
                    break
                fi
            done
        fi
        if [[ -z "$_finished_pid" ]]; then
            # Should not reach: workers are all still alive yet wait -n
            # claimed something finished. Brief yield to avoid a spin.
            sleep 0.2
            continue
        fi

        local _tc="${pid_to_tc[$_finished_pid]}"
        tc_done[$_tc]=1
        unset 'pid_to_tc[$_finished_pid]'

        # Repaint UI with one more tool marked ✅.
        local status_summary=""
        while IFS='|' read -r tc_id name; do
            if [[ -n "${tc_done[$tc_id]:-}" ]]; then
                status_summary+="✅ <code>${name}</code>&#10;"
            else
                status_summary+="⚒ <code>${name}</code>...&#10;"
            fi
        done <<< "$launched_info"
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
