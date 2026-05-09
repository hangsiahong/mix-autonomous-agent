#!/bin/bash
# tools/bash.sh - Run a bash command in the project directory

cmd="${TOOL_command}"

if [[ -z "$cmd" ]]; then
    echo "Error: No command provided."
    exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# Safety: block obviously destructive patterns
if echo "$cmd" | grep -qE '^\s*(rm\s+-rf\s+/|mkfs|dd\s+if=|:\(\)\{.*\}|shutdown|reboot|halt)'; then
    echo "Error: Command blocked for safety."
    exit 1
fi

timeout 30 bash -c "$cmd" 2>&1
