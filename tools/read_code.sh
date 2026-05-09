#!/bin/bash
path="${TOOL_path}"
if [[ -f "$path" ]]; then
    cat "$path"
else
    echo "Error: File $path not found."
    exit 1
fi
