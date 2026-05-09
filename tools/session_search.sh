#!/bin/bash
# Tool: session_search
# Search past conversation history for a keyword or phrase.

query="${TOOL_query}"
session="${TOOL_session:-}"   # Optional: specific session ID, or all if empty
limit="${TOOL_limit:-20}"

if [[ -z "$query" ]]; then
    echo "Error: 'query' is required."
    exit 1
fi

if [[ -n "$session" ]]; then
    files="brain/state/history_${session}.json"
else
    files=brain/state/history_*.json
fi

found=0
query_lower=$(echo "$query" | tr '[:upper:]' '[:lower:]')

for file in $files; do
    [[ -f "$file" ]] || continue
    session_name=$(basename "$file" .json | sed 's/^history_//')

    matches=$(python3 - "$query_lower" "$file" << 'PYEOF'
import json, sys

query = sys.argv[1]
fpath = sys.argv[2]
try:
    with open(fpath) as f:
        history = json.load(f)
except Exception as e:
    sys.exit(0)

results = []
for msg in history:
    role = msg.get("role", "?")
    content = msg.get("content", "")
    if isinstance(content, list):
        content = " ".join(
            p.get("text", "") for p in content if isinstance(p, dict) and "text" in p
        )
    if not content:
        continue
    lo = content.lower()
    if query in lo:
        idx = lo.find(query)
        start = max(0, idx - 80)
        end = min(len(content), idx + 140)
        snippet = content[start:end].replace("\n", " ").strip()
        results.append(f"[{role}] ...{snippet}...")

for r in results:
    print(r)
PYEOF
)

    if [[ -n "$matches" ]]; then
        echo "=== $session_name ==="
        echo "$matches" | head -"$limit"
        found=$((found + 1))
    fi
done

if [[ "$found" -eq 0 ]]; then
    echo "No matches found for '$query' in session history."
fi
