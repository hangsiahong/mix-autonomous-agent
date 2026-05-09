#!/bin/bash
dir="${TOOL_directory:-.}"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVED_PATH="$(realpath -m "$dir")"

if [[ "$RESOLVED_PATH" != "$PROJECT_ROOT"* ]]; then
    echo "Error: Access denied. You can only list files within the project directory ($PROJECT_ROOT)."
    exit 1
fi

find "$dir" -maxdepth 2 -not -path '*/.*'
