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
session_filter = os.environ.get('TOOL_session', '').strip()

try:
    lines = open(recaps_file).readlines()
except Exception as e:
    print(f'Error reading recaps: {e}')
    sys.exit(1)

# Parse + optional filter. session_filter matches by PREFIX so passing the
# stable chat sid (e.g. 'tg_670967877') returns all archived sessions for
# that chat, regardless of the timestamp suffix added at /new boundaries.
entries = []
for line in lines:
    try:
        e = json.loads(line)
        sid = e.get('session_id', '')
        if session_filter and not (sid == session_filter or sid.startswith(session_filter + '_')):
            continue
        entries.append(e)
    except Exception:
        pass

recent = entries[-n:]
if not recent:
    msg = 'No recaps found'
    if session_filter:
        msg += f\" for session matching '{session_filter}'\"
    print(msg + '.')
    sys.exit(0)

for i, e in enumerate(reversed(recent), 1):
    ts = e.get('ts', '?')
    # 'YYYY-MM-DDTHH:MM:SS' → 'YYYY-MM-DD HH:MM' for readability
    when = (ts[:10] + ' ' + ts[11:16]) if len(ts) >= 16 else ts[:10]
    sid = e.get('session_id', '?')
    recap = e.get('recap', '').strip()
    print(f'--- Session {i} ({when} UTC | {sid}) ---')
    print(recap)
    print()
" "$RECAPS_FILE"
