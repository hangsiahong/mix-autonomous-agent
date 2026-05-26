#!/bin/bash
# core/mix/13_tool_execution.sh — invoke a single tool by name.
#
# `run_tool <name> <args_json> <chat_id> <thread_id>` resolves the tool to
# `tools/<name>.sh` (falling back to `tools/custom/<name>.sh` for agent-
# created tools), exports each JSON arg as `TOOL_<key>` env var, exports
# chat/thread context for Telegram-aware tools (clarify, send_file), and
# runs the script. Returns whatever the script prints on stdout/stderr.
#
# Permission gating happens via `check_tool_permission` (core/access_control.sh)
# before any execution.

run_tool() {
    local name="$1"
    local args_json="$2"
    local chat_id="$3"
    local thread_id="$4"
    
    # Check permissions
    if ! check_tool_permission "$name" "$chat_id" "$thread_id"; then
        echo "Error: Permission denied for tool '${name}'."
        return 1
    fi
    
    local script="tools/${name}.sh"
    # Support custom tools added by agent
    if [[ ! -f "$script" ]]; then
        script="tools/custom/${name}.sh"
    fi

    if [[ ! -f "$script" ]]; then
        echo "Error: Tool $name not found."
        return 1
    fi

    # Normalize args: if it's a JSON-encoded string of JSON (double-encoded),
    # unwrap it so downstream parsing always sees a JSON object literal.
    local args="$args_json"
    local _args_type
    _args_type=$(python3 -c "import json,sys; v=json.loads(open(sys.argv[1]).read()); print('string' if isinstance(v,str) else 'other')" <(printf '%s' "$args") 2>/dev/null)
    if [[ "$_args_type" == "string" ]]; then
        args=$(python3 -c "import json,sys; print(json.loads(open(sys.argv[1]).read()))" <(printf '%s' "$args"))
    fi

    # Export args as TOOL_ vars
    eval "$(echo "$args" | python3 -c "
import json, sys, shlex
d = json.loads(sys.stdin.read())
for k, v in d.items():
    v_str = v if isinstance(v, str) else json.dumps(v)
    print(f'export TOOL_{k}={shlex.quote(v_str)}')
")"
    # Export context so tools like clarify can send Telegram messages.
    # SESSION_ID is also exposed for tools that need per-session state files
    # (tool_search needs it to track which deferred tools have been activated).
    export TOOL_CHAT_ID="$chat_id"
    export TOOL_THREAD_ID="$thread_id"
    export TOOL_SESSION_ID="${AMA_SESSION_ID:-${chat_id}${thread_id:+_${thread_id}}}"
    
    local output status
    # Prefer in-shell function dispatch when a tools/_fn/<name>.fn.sh defined
    # tool_<name>; $() still forks but skips the bash exec + script load.
    # Falls through to subprocess for python tools, custom tools, and any
    # bash tool that hasn't been converted yet.
    if declare -F "tool_${name}" >/dev/null 2>&1; then
        output=$("tool_${name}" 2>&1)
        status=$?
    else
        output=$(bash "$script" 2>&1)
        status=$?
    fi
    
    # Unset
    eval "$(echo "$args" | python3 -c "
import json, sys
for k in json.loads(sys.stdin.read()):
    print(f'unset TOOL_{k}')
")"
    unset TOOL_CHAT_ID TOOL_THREAD_ID TOOL_SESSION_ID
    
    echo "$output"
}
