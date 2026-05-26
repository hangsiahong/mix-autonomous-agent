#!/bin/bash
# core/mix/30_compression.sh - Summary-based context compression

# Thresholds — token_counter.py provides model-aware values (55% of context window)
# Fallback hardcoded threshold used only when token_counter.py is unavailable
_COMPRESSION_THRESHOLD_FALLBACK=70000
KEEP_LAST_N=40                     # Keep the last 40 messages verbatim for continuity
KEEP_FIRST_N=5                     # Keep early setup messages
TOOL_RESULT_PRUNE_CHARS=400        # Truncate tool results > this before feeding to summarizer

compress_history() {
    local session_id="$1"
    local chat_id="$2"
    local thread_id="$3"
    local msg_id="$4"

    # Single Python call: token count + threshold + message count (avoids 3 separate subprocess spawns)
    local rough_tokens _threshold count
    { read rough_tokens; read _threshold; read count; } < <(
        printf '%s' "$HISTORY" | python3 tools/token_counter.py check "${MODEL:-}" 2>/dev/null
    )
    rough_tokens=${rough_tokens:-0}
    _threshold=${_threshold:-$_COMPRESSION_THRESHOLD_FALLBACK}
    count=${count:-0}

    if [ "$rough_tokens" -lt "$_threshold" ]; then
        return
    fi

    # Anti-thrash guard (hermes-style): if the last two auto-compressions
    # each saved <10% of tokens, summarization has hit diminishing returns.
    # Likely cause: history is dominated by recent verbatim content
    # (KEEP_LAST_N) that the summarizer can't touch. Skip auto-compress and
    # surface the limit to the user instead of looping into another expensive
    # API call that won't help.
    local _ct_state="brain/state/compression_history_${session_id}.json"
    if [[ -f "$_ct_state" ]]; then
        local _thrash; _thrash=$(python3 -c "
import json, sys
try:
    d = json.loads(open(sys.argv[1]).read())
    ratios = d.get('ratios', [])
    if len(ratios) >= 2 and ratios[-1] < 0.10 and ratios[-2] < 0.10:
        print('1')
    else:
        print('0')
except Exception:
    print('0')
" "$_ct_state" 2>/dev/null)
        if [[ "$_thrash" == "1" ]]; then
            echo "AMA: Compression skipped — last 2 compressions each saved <10%. Surfacing to user."
            if [[ -n "$chat_id" && -n "$msg_id" ]]; then
                tg_send "$chat_id" "🪨 <i>Context is dense — recent compressions barely shrunk it. Consider <code>/new</code> for a fresh session, or trim manually with <code>/undo</code>.</i>" "$thread_id" "HTML" 2>/dev/null || true
                tg_edit "$chat_id" "$msg_id" "⏳ Thinking..." "" 2>/dev/null || true
            fi
            return
        fi
    fi
    local _ct_tokens_before="$rough_tokens"

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

    { read start_index; read end_index; } < <(python3 -c "
import json,sys
b=json.loads(open(sys.argv[1]).read())
print(b.get('start',''))
print(b.get('end',''))" <(printf '%s' "$boundary_json") 2>/dev/null)

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
    local _sp_tmp; _sp_tmp=$(_ama_mktemp)
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

    # Record savings ratio so the anti-thrash guard above can detect when
    # compression has hit diminishing returns. State is per-session JSON
    # with a capped ring of the last 5 ratios.
    local _ct_tokens_after
    _ct_tokens_after=$(printf '%s' "$HISTORY" | python3 tools/token_counter.py check "${MODEL:-}" 2>/dev/null | head -1)
    _ct_tokens_after=${_ct_tokens_after:-0}
    BEFORE="$_ct_tokens_before" AFTER="$_ct_tokens_after" STATE="$_ct_state" python3 -c '
import os, json, sys
before = max(int(os.environ.get("BEFORE","0") or 0), 1)
after  = int(os.environ.get("AFTER","0") or 0)
ratio  = max(0.0, (before - after) / before)
path   = os.environ["STATE"]
try:
    d = json.loads(open(path).read())
except Exception:
    d = {}
ratios = d.get("ratios", [])
ratios.append(round(ratio, 4))
ratios = ratios[-5:]
d["ratios"] = ratios
tmp = path + ".tmp"
open(tmp, "w").write(json.dumps(d))
os.replace(tmp, path)
' 2>/dev/null || true

    # Record compression lineage in SQLite (hermes parent_session_id pattern)
    # Create a new session ID for the post-compression context, link to old one
    local _compressed_sid="${session_id}_c$(date +%s)"
    (
        python3 tools/session_db.py end "$session_id" "compression" > /dev/null 2>&1
        python3 tools/session_db.py create "$_compressed_sid" > /dev/null 2>&1
        python3 tools/session_db.py link "$_compressed_sid" "$session_id" > /dev/null 2>&1
    ) &

    # Restore thinking indicator after compression
    if [[ -n "$chat_id" && -n "$msg_id" ]]; then
        tg_edit "$chat_id" "$msg_id" "⏳ Thinking..." "" 2>/dev/null || true
    fi
}
