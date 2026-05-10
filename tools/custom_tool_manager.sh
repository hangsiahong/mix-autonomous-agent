#!/bin/bash
# tools/custom_tool_manager.sh — Create/list/delete agent-authored tools.
#
# Inputs:
#   TOOL_action          — create | list | delete
#   TOOL_name            — tool name (lowercase letters, digits, underscore)
#   TOOL_description     — human-readable description (create only)
#   TOOL_code            — tool body (a bash script) (create only)
#   TOOL_parameters_json — JSON Schema for parameters (create only)
#
# Safety:
#   • Names restricted to [a-z0-9_]+, no path traversal.
#   • Refuses to overwrite a built-in tool (anything in tools/*.sh).
#   • New scripts are syntax-checked with `bash -n` before being installed.
#   • Scanned for obviously dangerous patterns reusing the bash.sh blocklist.
#   • parameters_json must be valid JSON Schema.

set -u

_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT_DIR="$(cd "$_TOOLS_DIR/.." && pwd)"

action="${TOOL_action:-}"
name="${TOOL_name:-}"
description="${TOOL_description:-}"
code="${TOOL_code:-}"
parameters_json="${TOOL_parameters_json:-}"

TOOLS_FILE="${_ROOT_DIR}/brain/tools.json"
CUSTOM_DIR="${_ROOT_DIR}/tools/custom"
BUILTIN_DIR="${_ROOT_DIR}/tools"

mkdir -p "$CUSTOM_DIR"

_validate_name() {
    if [[ -z "$name" ]]; then
        echo "Error: 'name' is required."
        return 1
    fi
    if ! [[ "$name" =~ ^[a-z][a-z0-9_]{1,40}$ ]]; then
        echo "Error: name must match ^[a-z][a-z0-9_]{1,40}$ (got: $name)"
        return 1
    fi
    return 0
}

_validate_code_safety() {
    # Reuse the danger patterns defined in bash.sh by sourcing them inline.
    # Custom tools shouldn't contain destructive shell either.
    local body="$1"
    local _danger=(
        '\brm[[:space:]]+(-[a-zA-Z]*[rfRF][a-zA-Z]*[[:space:]]+)+(/|/\*|~|\$HOME)'
        '\bmkfs(\.|[[:space:]])'
        '\bdd[[:space:]].*of=/dev/[sh]d'
        ':\(\)\{[[:space:]]*:[[:space:]]*\|[[:space:]]*:[[:space:]]*&[[:space:]]*\}'
        '\b(shutdown|reboot|halt|poweroff)\b'
        '/dev/tcp/'
        '\b(nc|ncat|netcat)\b[^|;&]*-e[[:space:]]+'
        '(cat|tee|cp|scp)[[:space:]]+[^|;&]*(/etc/(passwd|shadow|sudoers)|~/\.ssh/|/\.aws/credentials|\.env)'
    )
    for pat in "${_danger[@]}"; do
        if echo "$body" | grep -qE "$pat"; then
            echo "Error: refused — generated code contains a blocked pattern (${pat:0:50}...)"
            return 1
        fi
    done
    return 0
}

case "$action" in
create)
    _validate_name || exit 1

    if [[ -z "$code" ]]; then
        echo "Error: 'code' is required for create."
        exit 1
    fi

    # Refuse to shadow a built-in tool.
    if [[ -f "${BUILTIN_DIR}/${name}.sh" ]]; then
        echo "Error: '${name}' is a built-in tool — choose a different name."
        exit 1
    fi

    # Validate JSON Schema.
    if [[ -n "$parameters_json" ]]; then
        if ! echo "$parameters_json" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d, dict); assert d.get('type') == 'object', 'top-level must be {type: object}'" 2>/dev/null; then
            echo "Error: parameters_json must be a JSON Schema object with type=object."
            exit 1
        fi
    else
        parameters_json='{"type":"object","properties":{},"required":[]}'
    fi

    # Static-scan the code body for obviously unsafe patterns.
    _validate_code_safety "$code" || exit 1

    target="${CUSTOM_DIR}/${name}.sh"

    # Ensure shebang.
    body="$code"
    if ! [[ "$body" =~ ^#! ]]; then
        body="#!/bin/bash"$'\n'"$body"
    fi

    # Syntax check via temp file.
    tmp=$(mktemp -t "amatool_${name}_XXXX.sh")
    printf '%s' "$body" > "$tmp"
    if ! bash -n "$tmp" 2>/tmp/_amatool_err; then
        echo "Error: bash syntax check failed:"
        cat /tmp/_amatool_err
        rm -f "$tmp"
        exit 1
    fi

    mv "$tmp" "$target"
    chmod +x "$target"

    # Register / update in tools.json (atomic via temp file).
    tmp_tools=$(mktemp)
    NAME="$name" DESC="$description" PARAMS="$parameters_json" SRC="$TOOLS_FILE" \
    python3 -c "
import json, os, sys
src = os.environ['SRC']
try:
    tools = json.load(open(src))
except Exception:
    tools = []
entry = {
    'name': os.environ['NAME'],
    'description': os.environ['DESC'] or 'Custom tool',
    'parameters': json.loads(os.environ['PARAMS']),
}
for i, t in enumerate(tools):
    if t.get('name') == entry['name']:
        tools[i] = entry
        break
else:
    tools.append(entry)
json.dump(tools, open(src + '.tmp', 'w'), indent=2)
" || { echo "Error: failed to update tools.json"; exit 1; }

    if [[ -f "${TOOLS_FILE}.tmp" ]]; then
        mv "${TOOLS_FILE}.tmp" "$TOOLS_FILE"
    fi

    echo "✅ Tool '${name}' created at tools/custom/${name}.sh and registered."
    ;;

delete)
    _validate_name || exit 1
    target="${CUSTOM_DIR}/${name}.sh"
    if [[ ! -f "$target" ]]; then
        echo "Error: tool '${name}' not found in custom tools."
        exit 1
    fi
    rm -f "$target"
    NAME="$name" SRC="$TOOLS_FILE" python3 -c "
import json, os
src = os.environ['SRC']
tools = json.load(open(src))
tools = [t for t in tools if t.get('name') != os.environ['NAME']]
json.dump(tools, open(src, 'w'), indent=2)
"
    echo "✅ Tool '${name}' deleted and unregistered."
    ;;

list)
    if [[ -d "$CUSTOM_DIR" ]] && compgen -G "$CUSTOM_DIR/*.sh" > /dev/null; then
        echo "Custom tools:"
        for f in "$CUSTOM_DIR"/*.sh; do
            n=$(basename "$f" .sh)
            echo "  • $n"
        done
    else
        echo "No custom tools registered."
    fi
    ;;

*)
    echo "Error: unknown action '$action'. Use create | list | delete."
    exit 1
    ;;
esac
