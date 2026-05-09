#!/bin/bash
# Tool: memory_remember
# Args: text (string), metadata_json (string)

text="${TOOL_text}"
meta="${TOOL_metadata_json:-"{}"}"

python3 "$(dirname "$0")/memory_helper.py" save "$text" "$meta"
