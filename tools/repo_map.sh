#!/bin/bash
# tools/repo_map.sh - Recursive file listing for context

MAX_DEPTH=3
[ -n "$TOOL_depth" ] && MAX_DEPTH="$TOOL_depth"

echo "Current Project Structure (max depth $MAX_DEPTH):"
if command -v tree >/dev/null 2>&1; then
    tree -L "$MAX_DEPTH" --noreport -I "node_modules|.git|brain/state|brain/history"
else
    find . -maxdepth "$MAX_DEPTH" -not -path '*/.*' | sed -e "s/[^-][^\/]*\// |/g" -e "s/|\([^ ]\)/|-\1/"
fi
