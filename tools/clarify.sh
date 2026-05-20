#!/bin/bash
# Tool: clarify
# Ask the user a question. Two modes:
#   1. Plain text — pass only `question`. Sends text, stops turn, waits for free-text reply.
#   2. Multi-choice — pass `question` + `options` (JSON array of strings). Renders inline
#      keyboard buttons on Telegram; the tap is dispatched as the next user message.
#
# Use multi-choice when you've enumerated 2-6 specific paths and want a fast tap
# from the user instead of free-text. Always include an option for the path that
# you'd take if the user said "yes default", and let the user type "Other:
# <something>" if none of the buttons fit.

set -e

question="${TOOL_question}"
options_json="${TOOL_options:-}"
chat_id="${TOOL_CHAT_ID}"
thread_id="${TOOL_THREAD_ID}"
session_id="${AMA_SESSION_ID:-${TOOL_SESSION_ID:-}}"

if [[ -z "$question" ]]; then
    echo "Error: 'question' is required."
    exit 1
fi

# Headless / no-telegram fallback: just print
if [[ -z "$TG_TOKEN" || -z "$chat_id" ]]; then
    echo "QUESTION: $question"
    [[ -n "$options_json" && "$options_json" != "null" && "$options_json" != "[]" ]] && \
        echo "OPTIONS: $options_json"
    exit 0
fi

# Decide if we have valid options (1-6 non-empty strings)
have_opts=0
if [[ -n "$options_json" && "$options_json" != "null" && "$options_json" != "[]" ]]; then
    opt_count=$(OPTS="$options_json" python3 -c '
import json, os, sys
try:
    arr = json.loads(os.environ["OPTS"])
    if isinstance(arr, list) and 1 <= len(arr) <= 6 and all(isinstance(x, str) and x.strip() for x in arr):
        print(len(arr))
    else:
        print(0)
except Exception:
    print(0)
' 2>/dev/null)
    [[ "${opt_count:-0}" -gt 0 ]] && have_opts=1
fi

# Multi-choice path — needs session_id so the callback can look up the label
if [[ "$have_opts" == "1" && -n "$session_id" ]]; then
    DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    mkdir -p "${DIR}/brain/state"
    state_file="${DIR}/brain/state/clarify_${session_id}.json"

    # Unique question id so a later clarify overwriting this state file
    # cleanly invalidates any old buttons (router checks qid match on tap).
    _qid=$(date +%s%N)

    # Save state: callback handler in router.sh reads this to resolve index → label
    SID="$session_id" QID="$_qid" Q="$question" OPTS="$options_json" CID="$chat_id" TID="${thread_id:-}" python3 <<'PYEOF'
import json, os, time
state = {
    "session_id": os.environ["SID"],
    "qid":        os.environ["QID"],
    "question":   os.environ["Q"],
    "options":    json.loads(os.environ["OPTS"]),
    "chat_id":    os.environ["CID"],
    "thread_id":  os.environ.get("TID", ""),
    "ts":         int(time.time()),
}
open(f"brain/state/clarify_{os.environ['SID']}.json", "w").write(json.dumps(state))
PYEOF

    # Build the inline_keyboard payload: one button per row (max readable on mobile)
    payload=$(SID="$session_id" QID="$_qid" Q="$question" OPTS="$options_json" CID="$chat_id" TID="${thread_id:-}" python3 -c '
import json, os
opts = json.loads(os.environ["OPTS"])
sid = os.environ["SID"]
qid = os.environ["QID"]
kbd = []
for i, label in enumerate(opts):
    # Telegram button text limit: ~64 chars. Trim long labels.
    txt = label.strip()[:60]
    # callback_data limit: 64 bytes. "clarify:<sid>:<qid>:<idx>" — qid is ~19 digits, idx is 1.
    kbd.append([{"text": txt, "callback_data": f"clarify:{sid}:{qid}:{i}"}])
d = {
    "chat_id":    os.environ["CID"],
    "text":       "❓ " + os.environ["Q"],
    "parse_mode": "Markdown",
    "reply_markup": {"inline_keyboard": kbd},
}
tid = os.environ.get("TID", "")
if tid and tid != "null":
    try: d["message_thread_id"] = int(tid)
    except ValueError: pass
print(json.dumps(d))
')

    msg_id=$(curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" -d "$payload" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("result",{}).get("message_id","") or "")' 2>/dev/null)

    # Stash the question message id alongside state (for clean button removal later)
    if [[ -n "$msg_id" ]]; then
        SID="$session_id" MID="$msg_id" python3 <<'PYEOF'
import json, os
p = "brain/state/clarify_" + os.environ["SID"] + ".json"
try:
    s = json.load(open(p))
    s["msg_id"] = int(os.environ["MID"])
    open(p, "w").write(json.dumps(s))
except Exception: pass
PYEOF
    fi

    echo "CLARIFY_SENT_WITH_BUTTONS"
    echo "Multi-choice question sent — $opt_count option(s). Stop this turn. The user's tap (or free-text reply) will start the next turn."
    exit 0
fi

# Plain text fallback — preserve the existing simple behavior
payload=$(CID="$chat_id" TXT="❓ $question" python3 -c '
import json, os
print(json.dumps({"chat_id": os.environ["CID"], "text": os.environ["TXT"], "parse_mode": "Markdown"}))
')

if [[ -n "$thread_id" && "$thread_id" != "null" ]]; then
    payload=$(TID="$thread_id" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
d["message_thread_id"] = int(os.environ["TID"])
print(json.dumps(d))
' <<< "$payload")
fi

curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "$payload" > /dev/null

echo "CLARIFY_SENT"
echo "Question sent to user. Stop this turn and wait for their reply."
