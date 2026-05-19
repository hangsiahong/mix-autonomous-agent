#!/bin/bash
# Tool: recap
# Quickly summarize the current session or a specific session without a full search.

session_id="${TOOL_session_id}"
last_n="${TOOL_last_n:-20}"
history_file=""

if [[ -z "$session_id" ]]; then
    # "Recap my last session" with no argument: prefer the most-recently
    # ARCHIVED history (brain/state/sessions/) over the active one. After
    # /new the active history is fresh/empty, so picking it gives garbage.
    history_file=$(find brain/state/sessions/ -name "history_*.json" -size +10c \
                   -printf "%T@ %p\n" 2>/dev/null | sort -n | tail -1 | awk '{print $2}')
    if [[ -z "$history_file" ]]; then
        # No archives yet — fall back to the active session.
        history_file=$(find brain/state/ -maxdepth 1 -name "history_*.json" -size +10c \
                       -printf "%T@ %p\n" 2>/dev/null | sort -n | tail -1 | awk '{print $2}')
    fi
    if [[ -z "$history_file" ]]; then
        echo "Error: No session history found yet."
        exit 1
    fi
else
    history_file="brain/state/history_${session_id}.json"
    if [[ ! -f "$history_file" ]]; then
        # Maybe an archived sid like tg_123_1779201488 — look in sessions/.
        history_file="brain/state/sessions/history_${session_id}.json"
    fi
fi

if [[ ! -f "$history_file" ]]; then
    echo "Error: Session history file for '${session_id:-(auto)}' not found."
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
