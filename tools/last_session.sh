#!/bin/bash
# Tool: last_session
# Fast recall of recent session recaps — reads directly from session_recaps.jsonl.
# No embeddings, no LanceDB, no latency. Use this instead of session_search
# when the user asks "what did we do last session?" or similar.
#
# Inputs:
#   TOOL_n       — number of sessions to show (default 3, max 10)
#   TOOL_session — specific session_id to look up (optional)

N="${TOOL_n:-3}"
SESSION="${TOOL_session:-}"
RECAPS_FILE="brain/state/session_recaps.jsonl"

if [[ ! -f "$RECAPS_FILE" ]]; then
    echo "No session recaps found yet."
    exit 0
fi

python3 -c "
import json, sys, os

recaps_file = sys.argv[1]
n = int(os.environ.get('TOOL_n', 3))
session_filter = os.environ.get('TOOL_session', '')

try:
    lines = open(recaps_file).readlines()
except Exception as e:
    print(f'Error reading recaps: {e}')
    sys.exit(1)

# Parse and optionally filter
entries = []
for line in lines:
    try:
        e = json.loads(line)
        if session_filter and e.get('session_id') != session_filter:
            continue
        entries.append(e)
    except:
        pass

# Show most recent N
recent = entries[-n:]
if not recent:
    print('No recaps found' + (f' for session {session_filter}' if session_filter else '') + '.')
    sys.exit(0)

for i, e in enumerate(reversed(recent), 1):
    ts = e.get('ts', '?')[:10]
    sid = e.get('session_id', '?')
    recap = e.get('recap', '').strip()
    print(f'--- Session {i} ({ts} | {sid}) ---')
    print(recap)
    print()
" "$RECAPS_FILE"
