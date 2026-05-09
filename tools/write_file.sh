#!/bin/bash
# Tool: write_file
# Create or overwrite a file with the given content.

path="${TOOL_path}"
content="${TOOL_content}"
append="${TOOL_append:-false}"

if [[ -z "$path" ]]; then
    echo "Error: path is required."
    exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVED_PATH="$(realpath -m "$path")"

if [[ "$RESOLVED_PATH" != "$PROJECT_ROOT"* ]]; then
    echo "Error: Access denied. Path must be within the project directory."
    exit 1
fi

mkdir -p "$(dirname "$RESOLVED_PATH")"

if [[ "$append" == "true" ]]; then
    printf '%s' "$content" >> "$RESOLVED_PATH"
    echo "Appended to $path ($(wc -c < "$RESOLVED_PATH") bytes total)"
else
    printf '%s' "$content" > "$RESOLVED_PATH"
    echo "Written: $path ($(wc -c < "$RESOLVED_PATH") bytes)"
fi
