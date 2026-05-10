#!/bin/bash
# core/access_control.sh - Tool execution permissions
source "${_CONFIG_DIR:-core}/config.sh"

# Sensitive tools that require explicit approval. Anything that mutates
# the filesystem, executes arbitrary shell, modifies the agent itself, or
# changes registered tool definitions belongs here.
SENSITIVE_TOOLS=(
    "bash" "process"
    "write_file" "edit_code" "patch" "delete_file"
    "custom_tool_manager" "skill_manager"
)
PERMISSION_STORE="brain/state/permissions.json"

check_tool_permission() {
    local tool_name="$1"
    local chat_id="$2"
    local thread_id="$3"
    
    # Non-sensitive tools are allowed by default
    local is_sensitive=false
    for t in "${SENSITIVE_TOOLS[@]}"; do
        [[ "$t" == "$tool_name" ]] && is_sensitive=true && break
    done
    
    [[ "$is_sensitive" == "false" ]] && return 0
    
    # Check if tool is whitelisted for this session
    local session_id="tg_${chat_id}"
    [[ -n "$thread_id" ]] && session_id="tg_${chat_id}_${thread_id}"
    
    if [[ -f "$PERMISSION_STORE" ]]; then
        local allowed
        allowed=$(SID="$session_id" TOOL="$tool_name" PSTORE="$PERMISSION_STORE" python3 -c "
import json, os
try:
    d = json.load(open(os.environ['PSTORE']))
    print(d.get(os.environ['SID'],{}).get(os.environ['TOOL'],'ask') or 'ask')
except:
    print('ask')
" 2>/dev/null)
        if [[ "$allowed" == "always" ]]; then
            return 0
        fi
    fi
    
    # In safety-first mode, we deny sensitive tools unless approved.
    # Check if the user ID is whitelisted via config
    if ! is_whitelisted "$chat_id"; then
        echo "Error: Only whitelisted users can use sensitive tools. Please whitelist user $chat_id."
        return 1
    fi
    
    echo "PERMISSION_GRANTED: $tool_name" >&2
    return 0
}

grant_permission() {
    local session_id="$1"
    local tool_name="$2"
    local level="${3:-always}" # always, once
    
    mkdir -p "$(dirname "$PERMISSION_STORE")"
    [[ ! -f "$PERMISSION_STORE" ]] && echo "{}" > "$PERMISSION_STORE"
    
    SID="$session_id" TOOL="$tool_name" LVL="$level" PSTORE="$PERMISSION_STORE" python3 -c "
import json, os
f = os.environ['PSTORE']
try: d = json.load(open(f))
except: d = {}
sid = os.environ['SID']
if sid not in d:
    d[sid] = {}
d[sid][os.environ['TOOL']] = os.environ['LVL']
open(f, 'w').write(json.dumps(d))
"
}
