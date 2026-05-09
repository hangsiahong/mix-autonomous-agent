#!/bin/bash
path="${TOOL_path}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVED_PATH="$(realpath -m "$path")"

if [[ "$RESOLVED_PATH" != "$PROJECT_ROOT"* ]]; then
    echo "Error: Access denied. You can only read files within the project directory ($PROJECT_ROOT)."
    exit 1
fi

if [[ -f "$path" ]]; then
    cat "$path"
    # Inject subdirectory context discovery
    bash "$(dirname "${BASH_SOURCE[0]}")/context_discovery.sh" "$path"
else
    echo "Error: File $path not found."
    exit 1
fi
