#!/bin/bash
# Tool: memory_remember
# Args: text (string), metadata_json (string)

text="${TOOL_text}"
meta="${TOOL_metadata_json:-"{}"}"

# Inject saved_at timestamp into metadata
meta=$(echo "$meta" | python3 -c "
import json, sys, time
try:
    m = json.load(sys.stdin)
except Exception:
    m = {}
m.setdefault('saved_at', int(time.time()))
print(json.dumps(m))
" 2>/dev/null || echo "$meta")

python3 "$(dirname "$0")/memory_helper.py" save "$text" "$meta"
