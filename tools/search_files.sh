#!/bin/bash
# Tool: search_files
# Search for a text pattern across project files using grep.

pattern="${TOOL_pattern}"
path="${TOOL_path:-.}"
file_glob="${TOOL_file_glob:-*}"
ignore_case="${TOOL_ignore_case:-false}"

if [[ -z "$pattern" ]]; then
    echo "Error: pattern is required."
    exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVED_PATH="$(realpath -m "$path")"

if [[ "$RESOLVED_PATH" != "$PROJECT_ROOT"* ]]; then
    echo "Error: Access denied. Path must be within the project directory."
    exit 1
fi

flags="-rn"
[[ "$ignore_case" == "true" ]] && flags="$flags -i"

results=$(grep $flags --include="$file_glob" -- "$pattern" "$RESOLVED_PATH" 2>/dev/null \
    | grep -v '/\.git/' \
    | head -60)

if [[ -z "$results" ]]; then
    echo "No matches for '$pattern'."
else
    echo "$results"
    total=$(echo "$results" | wc -l)
    echo "(${total} match(es))"
fi
