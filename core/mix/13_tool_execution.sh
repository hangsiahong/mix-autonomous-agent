# Tool execution
run_tool() {
    local name="$1"
    local args_json="$2"
    
    local script="tools/${name}.sh"
    # Support custom tools added by agent
    if [[ ! -f "$script" ]]; then
        script="tools/custom/${name}.sh"
    fi

    if [[ ! -f "$script" ]]; then
        echo "Error: Tool $name not found."
        return 1
    fi
    
    # Export args as TOOL_ vars
    eval $(echo "$args_json" | jq -r 'to_entries | .[] | "export TOOL_\(.key)=\( .value | @sh )"')
    
    local output
    output=$(bash "$script" 2>&1)
    local status=$?
    
    # Unset
    eval $(echo "$args_json" | jq -r 'to_entries | .[] | "unset TOOL_\(.key)"')
    
    echo "$output"
}
