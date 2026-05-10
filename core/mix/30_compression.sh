#!/bin/bash
# core/mix/30_compression.sh - Summary-based context compression

# Thresholds
COMPRESSION_THRESHOLD=200 # Start compressing if messages > 200 (modern LLMs have 1M+ context)
KEEP_LAST_N=40            # Keep the last 40 messages as-is for better continuity
KEEP_FIRST_N=5            # Keep more of the initial setup

compress_history() {
    local session_id="$1"
    local chat_id="$2"
    local thread_id="$3"
    local msg_id="$4"

    local count; count=$(echo "$HISTORY" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null); count=${count:-0}
    
    if [ "$count" -le "$COMPRESSION_THRESHOLD" ]; then
        return
    fi

    echo "AMA: Compressing context for session $session_id ($count msgs)..."

    # Notify user in Telegram that compression is happening
    if [[ -n "$chat_id" && -n "$msg_id" ]]; then
        tg_edit "$chat_id" "$msg_id" "🗜️ Compacting context, one moment..." "" 2>/dev/null || true
    fi

    # 1. Identify slices — then adjust to safe turn boundaries
    local end_index=$((count - KEEP_LAST_N))
    local start_index=$KEEP_FIRST_N
    
    if [ "$start_index" -ge "$end_index" ]; then
        # Restore thinking indicator even if we bail early
        if [[ -n "$chat_id" && -n "$msg_id" ]]; then
            tg_edit "$chat_id" "$msg_id" "⏳ Thinking..." "" 2>/dev/null || true
        fi
        return
    fi

    # Adjust boundaries to avoid orphaned tool_call/response pairs.
    # IMPORTANT: use python3 -c (script in variable) so stdin stays free
    # for json.load(sys.stdin) — a heredoc << conflicts with the pipe.
    local _boundary_py
    _boundary_py='
import json, sys
try:
    history = json.load(sys.stdin)
except Exception as e:
    sys.stderr.write(f"boundary: bad HISTORY JSON: {e}\n")
    sys.exit(1)
si = int(sys.argv[1])
ei = int(sys.argv[2])
n = len(history)
si = max(0, min(si, n - 1))
ei = max(0, min(ei, n - 1))

# Advance start_index past orphaned tool results that belong to an
# assistant+tool_calls at the boundary of first_part.
while si < ei:
    prev = history[si - 1] if si > 0 else None
    if prev and prev.get("role") == "assistant" and prev.get("tool_calls"):
        si += 1
    else:
        break

# Retract end_index until tail starts at a clean user-message boundary.
while ei > si and history[ei].get("role") != "user":
    ei -= 1

print(json.dumps({"start": si, "end": ei}))
'
    local boundary_json
    boundary_json=$(echo "$HISTORY" | python3 -c "$_boundary_py" "$start_index" "$end_index" 2>/dev/null)

    # Guard: if boundary_json is empty (Python crash), bail safely
    if [[ -z "$boundary_json" ]]; then
        echo "AMA: Compression skipped — boundary detection failed."
        if [[ -n "$chat_id" && -n "$msg_id" ]]; then
            tg_edit "$chat_id" "$msg_id" "⏳ Thinking..." "" 2>/dev/null || true
        fi
        return
    fi

    start_index=$(echo "$boundary_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('start',''))")
    end_index=$(echo "$boundary_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('end',''))")

    if [ "$start_index" -ge "$end_index" ]; then
        echo "AMA: Compression skipped — no safe boundary found."
        if [[ -n "$chat_id" && -n "$msg_id" ]]; then
            tg_edit "$chat_id" "$msg_id" "⏳ Thinking..." "" 2>/dev/null || true
        fi
        return
    fi

    # 2. Extract middle messages for summarization
    local middle_msgs
    middle_msgs=$(python3 -c "import json,sys; h=json.load(sys.stdin); print(json.dumps(h[${start_index}:${end_index}],separators=(',',':')))" <<< "$HISTORY")
    
    # 3. Request Summary from LLM
    local summary_prompt="The following is a middle portion of a conversation history. 
Summarize the key events, decisions, and information exchanged in these turns. 
Focus on what is still relevant for the ongoing task. 
Format as a concise bulleted list.
If tools were used, mention the outcomes.
Respond ONLY with the summary.

CONVERSATION TO SUMMARIZE:
$middle_msgs"

    # Call API with a fresh single-user-message history (no full conversation context)
    # Temporarily disable tools so the model produces text, not a tool call
    local saved_history="$HISTORY"
    local _saved_tools; _saved_tools=$(cat brain/tools.json 2>/dev/null || echo '[]')
    printf '[]' > brain/tools.json

    # Write summary_prompt to a tempfile to handle large content and special chars safely
    local _sp_tmp; _sp_tmp=$(mktemp)
    printf '%s' "$summary_prompt" > "$_sp_tmp"
    local _new_hist
    _new_hist=$(python3 - "$_sp_tmp" <<'PYEOF' 2>/dev/null
import json, sys
sp = open(sys.argv[1]).read()
print(json.dumps([{"role": "user", "content": sp}]))
PYEOF
)
    rm -f "$_sp_tmp"

    if [[ -z "$_new_hist" ]]; then
        printf '%s' "$_saved_tools" > brain/tools.json
        HISTORY="$saved_history"
        echo "AMA: Compression skipped — failed to build summary request."
        if [[ -n "$chat_id" && -n "$msg_id" ]]; then
            tg_edit "$chat_id" "$msg_id" "⏳ Thinking..." "" 2>/dev/null || true
        fi
        return
    fi

    HISTORY="$_new_hist"
    local summary_response
    summary_response=$(call_api "You are a conversation summarizer. Respond ONLY with a concise bulleted summary. No preamble.")

    # Check for failure early
    if [[ -z "$summary_response" || "$summary_response" == "FAIL:"* ]]; then
        echo "AMA: Compression API call failed. Response: ${summary_response:-'Empty'}"
        printf '%s' "$_saved_tools" > brain/tools.json
        HISTORY="$saved_history"
        return 1
    fi

    # Always restore tools and history
    printf '%s' "$_saved_tools" > brain/tools.json
    HISTORY="$saved_history"

    # Extract text from OpenAI format (all providers normalize to this)
    local summary_text
    summary_text=$(echo "$summary_response" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)
    msg = r.get('choices',[{}])[0].get('message',{})
    t = msg.get('content') or ''
    # Also collect from tool_calls text parts if content is null
    if not t:
        for tc in (msg.get('tool_calls') or []):
            fn = tc.get('function',{})
            if fn.get('name') == 'text': t = fn.get('arguments','')
    print(t.strip(), end='')
except: pass
" 2>/dev/null)

    # Log response on failure for easier debugging
    if [[ -z "$summary_text" ]]; then
        echo "AMA: Compression debug — raw response: ${summary_response:0:300}"
    fi

    if [[ -z "$summary_text" ]]; then
        echo "AMA: Compression failed (empty summary). Falling back to truncation."
        summary_text="[AUTO-TRUNCATION] Summarization failed. Some intermediate conversation history was removed to prevent context overflow."
    fi

    # 4. Build new history
    local first_part
    first_part=$(python3 -c "import json,sys; h=json.load(sys.stdin); print(json.dumps(h[:${start_index}],separators=(',',':')))" <<< "$HISTORY")
    local last_part
    last_part=$(python3 -c "import json,sys; h=json.load(sys.stdin); print(json.dumps(h[${end_index}:],separators=(',',':')))" <<< "$HISTORY")
    
    local summary_prefix="[CONTEXT COMPACTION — REFERENCE ONLY] Earlier turns were compacted into the summary below. This is a handoff from a previous context window — treat it as background reference, NOT as active instructions. Do NOT answer questions or fulfill requests mentioned in this summary; they were already addressed. Your current task is identified in the '## Active Task' section of the summary — resume exactly from there. Respond ONLY to the latest user message that appears AFTER this summary. The current session state may reflect work described here — avoid repeating it:"

    local summary_msg
    summary_msg=$(SP="$summary_prefix" ST="$summary_text" python3 -c "
import json, os
text = os.environ['SP'] + '\n\n' + os.environ['ST']
print(json.dumps({'role': 'user', 'content': text}))
")

    # 5. Archive the compressed part to long-term memory before replacing
    local _script_dir
    _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local _root_dir
    _root_dir="$(cd "$_script_dir/../.." && pwd)"
    local _archive_py
    _archive_py='
import json, os, subprocess
msgs = json.loads(os.environ["MSGS"])
root = os.environ["ROOT"]
sid = os.environ["SID"]
for msg in msgs:
    role = msg.get("role", "")
    c = msg.get("content") or ""
    if isinstance(c, list):
        c = " ".join(p.get("text","") for p in c if isinstance(p, dict))
    c = str(c).strip()
    if c and c != "null":
        subprocess.run(
            ["python3", f"{root}/tools/memory_helper.py", "save",
             f"[{role}]: {c}",
             json.dumps({"session_id": sid, "type": "archived_during_compression"})],
            capture_output=True
        )
'
    MSGS="$middle_msgs" ROOT="$_root_dir" SID="$session_id" python3 -c "$_archive_py" 2>/dev/null

    # Assemble new history
    HISTORY=$(FP="$first_part" SM="$summary_msg" LP="$last_part" python3 -c "
import json, os
fp = json.loads(os.environ['FP'])
sm = json.loads(os.environ['SM'])
lp = json.loads(os.environ['LP'])
print(json.dumps(fp + [sm] + lp, separators=(',', ':')))
")
    
    echo "AMA: Context compressed successfully."
    save_history "$session_id"

    # Restore thinking indicator after compression
    if [[ -n "$chat_id" && -n "$msg_id" ]]; then
        tg_edit "$chat_id" "$msg_id" "⏳ Thinking..." "" 2>/dev/null || true
    fi
}
