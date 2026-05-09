#!/bin/bash
# tools/custom_tool_manager.sh - Help agent create and register new tools

_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT_DIR="$(cd "$_TOOLS_DIR/.." && pwd)"

action="${TOOL_action}" # create, list, delete
name="${TOOL_name}"
description="${TOOL_description}"
code="${TOOL_code}"
parameters_json="${TOOL_parameters_json}"

TOOLS_FILE="${_ROOT_DIR}/brain/tools.json"
CUSTOM_DIR="${_ROOT_DIR}/tools/custom"

mkdir -p "$CUSTOM_DIR"

if [[ "$action" == "create" ]]; then
    # 1. Create the script
    echo "$code" > "${CUSTOM_DIR}/${name}.sh"
    chmod +x "${CUSTOM_DIR}/${name}.sh"
    
    # 2. Register in tools.json
    # Read existing tools
    EXISTING=$(cat "$TOOLS_FILE")
    
    # Create new tool entry
    NEW_ENTRY=$(jq -n \
        --arg name "$name" \
        --arg desc "$description" \
        --argjson params "$parameters_json" \
        '{name: $name, description: $desc, parameters: $params}')
    
    # Check if already exists, update or append
    UPDATED=$(echo "$EXISTING" | jq --arg name "$name" --argjson entry "$NEW_ENTRY" \
        'if any(.[]; .name == $name) then map(if .name == $name then $entry else . end) else . + [$entry] end')
    
    echo "$UPDATED" > "$TOOLS_FILE"
    echo "Tool $name created and registered successfully."

elif [[ "$action" == "list" ]]; then
    ls "$CUSTOM_DIR"
fi
