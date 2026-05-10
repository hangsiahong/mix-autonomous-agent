#!/bin/bash
# Tool: recap
# Quickly summarize the current session or a specific session without a full search.

session_id="${TOOL_session_id}"
last_n="${TOOL_last_n:-20}"

# If no session_id provided, try to find the current active one from environment or state
if [[ -z "$session_id" ]]; then
    # In this harness, we can often find it via the history files
    # We look for the most recently modified history file in brain/state/ or brain/state/sessions/
    session_id=$(ls -t brain/state/history_*.json brain/state/sessions/history_*.json 2>/dev/null | head -n 1 | sed 's/.*history_//;s/\.json//')
fi

if [[ -z "$session_id" ]]; then
    echo "Error: No session_id provided and could not detect active session."
    exit 1
fi

history_file="brain/state/history_${session_id}.json"
if [[ ! -f "$history_file" ]]; then
    history_file="brain/state/sessions/history_${session_id}.json"
fi

if [[ ! -f "$history_file" ]]; then
    echo "Error: Session history file for '$session_id' not found."
    exit 1
fi

python3 - <<PYEOF
import json, os

path = "$history_file"
last_n = int("$last_n")

try:
    with open(path) as f:
        history = json.load(f)
except Exception as e:
    print(f"Error reading history: {e}")
    exit(1)

# Get the last N messages
relevant = history[-last_n:] if len(history) > last_n else history

print(f"--- Recap of Session: {os.path.basename(path)} (Last {len(relevant)} messages) ---\n")

for msg in relevant:
    role = msg.get("role", "unknown").upper()
    content = msg.get("content", "")
    if content is None:
        content = ""
    
    # Handle list-style content (Gemini format)
    if isinstance(content, list):
        text_parts = []
        for part in content:
            if isinstance(part, dict) and "text" in part:
                text_parts.append(part["text"])
        content = " ".join(text_parts)
    
    # Handle tool calls
    tool_calls = msg.get("tool_calls")
    if tool_calls:
        if content is None: content = ""
        for tc in tool_calls:
            func = tc.get("function", {})
            name = func.get("name", "unknown")
            args = func.get("arguments", "{}")
            content += f"\n[TOOL_CALL: {name}({args})]"
            
    if msg.get("name"): # Tool result
        role = f"TOOL_RESULT ({msg['name']})"

    # Truncate very long content for the recap summary
    if content and len(content) > 1000:
        content = content[:1000] + "... [truncated]"
        
    print(f"**{role}**: {content}\n")
PYEOF
