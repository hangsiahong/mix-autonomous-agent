# Tool execution
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
    
    # If args is a JSON string containing an escaped JSON object, parse it
    local _args_type
    _args_type=$(echo "$args" | python3 -c "import json,sys; v=json.load(sys.stdin); print('string' if isinstance(v,str) else 'other')" 2>/dev/null)
    if [[ "$_args_type" == "string" ]]; then
        args=$(echo "$args" | python3 -c "import json,sys; print(json.load(sys.stdin))")
    fi
    
    # Export args as TOOL_ vars
    eval "$(echo "$args" | python3 -c "
import json, sys, shlex
d = json.load(sys.stdin)
for k, v in d.items():
    v_str = v if isinstance(v, str) else json.dumps(v)
    print(f'export TOOL_{k}={shlex.quote(v_str)}')
")"
    # Export context so tools like clarify can send Telegram messages
    export TOOL_CHAT_ID="$chat_id"
    export TOOL_THREAD_ID="$thread_id"
    
    local output
    output=$(bash "$script" 2>&1)
    local status=$?
    
    # Unset
    eval "$(echo "$args" | python3 -c "
import json, sys
for k in json.load(sys.stdin):
    print(f'unset TOOL_{k}')
")"
    unset TOOL_CHAT_ID TOOL_THREAD_ID
    
    echo "$output"
}
