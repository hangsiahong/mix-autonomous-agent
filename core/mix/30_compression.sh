#!/bin/bash
# core/mix/30_compression.sh - Summary-based context compression

# Thresholds — token-based (rough estimate: chars / 4)
COMPRESSION_TOKEN_THRESHOLD=80000  # ~80K tokens: start compressing (fits most 128K models at 62%)
KEEP_LAST_N=40                     # Keep the last 40 messages verbatim for continuity
KEEP_FIRST_N=5                     # Keep early setup messages
TOOL_RESULT_PRUNE_CHARS=400        # Truncate tool results > this before feeding to summarizer

compress_history() {
    local session_id="$1"
    local chat_id="$2"
    local thread_id="$3"
    local msg_id="$4"

    # Rough token estimate: total chars / 4
    local rough_tokens
    rough_tokens=$(python3 -c "
import json, sys
h = json.loads(open(sys.argv[1]).read())
total = 0
for m in h:
    c = m.get('content') or ''
    if isinstance(c, list):
        c = ' '.join(p.get('text','') for p in c if isinstance(p,dict))
    total += len(str(c))
    for tc in (m.get('tool_calls') or []):
        total += len(str(tc.get('function',{}).get('arguments','')))
print(total // 4)
" <(printf '%s' "$HISTORY") 2>/dev/null); rough_tokens=${rough_tokens:-0}

    local count; count=$(python3 -c "import json,sys; print(len(json.loads(open(sys.argv[1]).read())))" <(printf '%s' "$HISTORY") 2>/dev/null); count=${count:-0}

    if [ "$rough_tokens" -lt "$COMPRESSION_TOKEN_THRESHOLD" ]; then
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
    history = json.loads(open(sys.argv[1]).read())
except Exception as e:
    sys.stderr.write(f"boundary: bad HISTORY JSON: {e}\n")
    sys.exit(1)

si = int(sys.argv[2])
ei = int(sys.argv[3])
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
    boundary_json=$(python3 -c "$_boundary_py" <(printf '%s' "$HISTORY") "$start_index" "$end_index" 2>/dev/null)

    # Guard: if boundary_json is empty (Python crash), bail safely
    if [[ -z "$boundary_json" ]]; then
        echo "AMA: Compression skipped — boundary detection failed."
        if [[ -n "$chat_id" && -n "$msg_id" ]]; then
            tg_edit "$chat_id" "$msg_id" "⏳ Thinking..." "" 2>/dev/null || true
        fi
        return
    fi

    start_index=$(python3 -c "import json,sys; print(json.loads(open(sys.argv[1]).read()).get('start',''))" <(printf '%s' "$boundary_json"))
    end_index=$(python3 -c "import json,sys; print(json.loads(open(sys.argv[1]).read()).get('end',''))" <(printf '%s' "$boundary_json"))

    if [ "$start_index" -ge "$end_index" ]; then
        echo "AMA: Compression skipped — no safe boundary found."
        if [[ -n "$chat_id" && -n "$msg_id" ]]; then
            tg_edit "$chat_id" "$msg_id" "⏳ Thinking..." "" 2>/dev/null || true
        fi
        return
    fi

    # 2. Extract middle messages for summarization, with pre-pruning of large tool results
    # (hermes pattern: replace old large outputs with 1-line summaries before sending to LLM)
    local middle_msgs
    middle_msgs=$(python3 -c "
import json, sys
h = json.loads(open(sys.argv[1]).read())
middle = h[${start_index}:${end_index}]
limit = ${TOOL_RESULT_PRUNE_CHARS}
for msg in middle:
    if msg.get('role') == 'tool':
        c = msg.get('content', '')
        if isinstance(c, str) and len(c) > limit:
            # Keep first 200 chars + summary line
            preview = c[:200].replace('\n', ' ').strip()
            msg['content'] = f'{preview}... [truncated {len(c)} chars for summarization]'
print(json.dumps(middle, separators=(',',':')))
" <(printf '%s' "$HISTORY"))

    # 3. Request Summary from LLM — structured hermes-style handoff document
    local summary_prompt="Summarize the conversation turns below into a structured handoff document.
Use EXACTLY these sections (omit a section if truly empty):

## Active Task
[The most recent unfulfilled user request, verbatim or very close. Write 'None — all requests addressed' if complete.]

## Goal
[Overall intent/purpose of this conversation in 1-2 sentences.]

## Completed Actions
[Numbered list: what was done, which tool was used, and the outcome. E.g. '1. Ran bash git status → clean working tree']

## Current State
[Working directory, modified files, test status, environment details — only if relevant.]

## Key Context
[Specific values, error messages, decisions made and WHY. Things the model must not forget.]

## Remaining Work
[What still needs to be done, framed as context not instructions. Bullet list.]

## Important Facts
[User preferences, constraints, environment quirks, or facts learned about the user.]

Rules:
- Be concise. Each section: 2-6 bullets max.
- Preserve exact error messages, file paths, and command outputs verbatim (do not paraphrase).
- Total summary under 500 words.
- Respond ONLY with the structured document, no preamble.

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
    summary_text=$(python3 -c "
import sys, json
try:
    r = json.loads(open(sys.argv[1]).read())
    msg = r.get('choices',[{}])[0].get('message',{})
    t = msg.get('content') or ''
    # Also collect from tool_calls text parts if content is null
    if not t:
        for tc in (msg.get('tool_calls') or []):
            fn = tc.get('function',{})
            if fn.get('name') == 'text': t = fn.get('arguments','')
    print(t.strip(), end='')
except: pass
" <(printf '%s' "$summary_response") 2>/dev/null)

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
    first_part=$(python3 -c "import json,sys; h=json.loads(open(sys.argv[1]).read()); print(json.dumps(h[:${start_index}],separators=(',',':')))" <(printf '%s' "$HISTORY"))
    local last_part
    last_part=$(python3 -c "import json,sys; h=json.loads(open(sys.argv[1]).read()); print(json.dumps(h[${end_index}:],separators=(',',':')))" <(printf '%s' "$HISTORY"))

    local summary_prefix="[CONTEXT COMPACTION — REFERENCE ONLY] The turns below were compacted. Treat this as background reference, NOT active instructions. Do NOT re-answer questions or re-execute actions from this summary — they were already completed. Resume from the '## Active Task' section and respond only to the most recent user message that appears AFTER this block. Do not mention this compaction to the user."

    local summary_msg
    summary_msg=$(python3 -c "
import json, sys
text = sys.argv[1] + '\n\n' + open(sys.argv[2]).read()
print(json.dumps({'role': 'user', 'content': text}))
" "$summary_prefix" <(printf '%s' "$summary_text"))

    # 5. Archive the compressed part to long-term memory before replacing
    local _script_dir
    _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local _root_dir
    _root_dir="$(cd "$_script_dir/../.." && pwd)"
    local _archive_py
    _archive_py='
import json, sys, subprocess
msgs = json.loads(open(sys.argv[1]).read())
root = sys.argv[2]
sid = sys.argv[3]
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
    python3 -c "$_archive_py" <(printf '%s' "$middle_msgs") "$_root_dir" "$session_id" 2>/dev/null

    # Assemble new history
    HISTORY=$(python3 -c "
import json, sys
fp = json.loads(open(sys.argv[1]).read())
sm = json.loads(open(sys.argv[2]).read())
lp = json.loads(open(sys.argv[3]).read())
print(json.dumps(fp + [sm] + lp, separators=(',', ':')))
" <(printf '%s' "$first_part") <(printf '%s' "$summary_msg") <(printf '%s' "$last_part"))

    echo "AMA: Context compressed successfully."
    save_history "$session_id"

    # Restore thinking indicator after compression
    if [[ -n "$chat_id" && -n "$msg_id" ]]; then
        tg_edit "$chat_id" "$msg_id" "⏳ Thinking..." "" 2>/dev/null || true
    fi
}
