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
    NEW_ENTRY=$(NAME="$name" DESC="$description" PARAMS="$parameters_json" python3 -c "
import json, os
print(json.dumps({
    'name': os.environ['NAME'],
    'description': os.environ['DESC'],
    'parameters': json.loads(os.environ['PARAMS'])
}))
")

    # Check if already exists, update or append
    UPDATED=$(NAME="$name" ENTRY="$NEW_ENTRY" python3 -c "
import json, os, sys
tools = json.load(sys.stdin)
name = os.environ['NAME']
entry = json.loads(os.environ['ENTRY'])
found = False
for i, t in enumerate(tools):
    if t.get('name') == name:
        tools[i] = entry
        found = True
        break
if not found:
    tools.append(entry)
print(json.dumps(tools))
" <<< "$EXISTING")
    
    echo "$UPDATED" > "$TOOLS_FILE"
    echo "Tool $name created and registered successfully."

elif [[ "$action" == "delete" ]]; then
    if [[ -f "${CUSTOM_DIR}/${name}.sh" ]]; then
        rm "${CUSTOM_DIR}/${name}.sh"
        
        # Unregister from tools.json
        EXISTING=$(cat "$TOOLS_FILE")
        UPDATED=$(NAME="$name" python3 -c "
import json, os, sys
tools = json.load(sys.stdin)
name = os.environ['NAME']
print(json.dumps([t for t in tools if t.get('name') != name]))
" <<< "$EXISTING")
        echo "$UPDATED" > "$TOOLS_FILE"
        echo "Tool $name deleted and unregistered."
    else
        echo "Error: Tool $name not found in custom tools."
    fi

elif [[ "$action" == "list" ]]; then
    ls "$CUSTOM_DIR"
fi
