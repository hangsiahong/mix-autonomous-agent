#!/bin/bash
# Tool: memory_recall
# Args: query (string), limit (int)

query="${TOOL_query}"
limit="${TOOL_limit:-3}"

python3 "$(dirname "$0")/memory_helper.py" search "$query" "$limit"
