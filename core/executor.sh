#!/bin/bash

# core/executor.sh - Tool Execution Engine

execute_tool() {
    local name="$1"
    local args_json="$2"

    local script="tools/${name}.sh"

    if [[ ! -f "$script" ]]; then
        echo "Error: Tool ${name} not found."
        return 1
    fi

    # Convert JSON args to environment variables
    # We prefix with TOOL_ to avoid name collisions
    eval $(echo "$args_json" | jq -r 'to_entries | .[] | "export TOOL_\(.key)=\"\(.value)\""')

    # Execute and capture output
    local output
    output=$(bash "$script" 2>&1)
    local status=$?

    # Cleanup exported env vars (optional but cleaner)
    eval $(echo "$args_json" | jq -r 'to_entries | .[] | "unset TOOL_\(.key)"')

    # Return structured result
    jq -n \
        --arg name "$name" \
        --arg output "$output" \
        --argjson status "$status" \
        '{name: $name, output: $output, status: $status}'
}
