#!/bin/bash
# core/mix/11_history.sh — conversation history persistence + smart trimming.
#
# Every message exchanged in a session lives in $HISTORY (a JSON array of
# OpenAI-format `{role, content, ...}` messages). This file owns:
#
#   append_text()        — append a user/assistant text message
#   append_tool_call()   — append an assistant message with tool_calls
#   append_tool_result() — append a tool-role result, with smart fold to
#                          80-line head+tail + summary line for long outputs
#   save_history()       — atomic write to brain/state/history_<sid>.json
#                          (refuses to write empty HISTORY — see live incident
#                          2026-05-19 where a 0-byte file then broke every
#                          subsequent turn)
#   load_history()       — read from disk; handle missing, empty, and corrupt
#                          files by returning HISTORY="[]"; also auto-reset
#                          on idle (SESSION_IDLE_HOURS) and trim incomplete
#                          tool-call exchanges Gemini would reject
#   compact_history()    — cheap decay pass + LLM-based compression at
#                          context threshold
#   decay_history()      — progressive decay: collapse tool results older
#                          than DECAY_KEEP turns, redact verbose write args
#   _apply_provider_history_filter() — delegate to ${PROVIDER}_filter_history
#                          for provider-specific shape (e.g. Google's
#                          thoughtSignature preservation)

append_text() {
    local role="$1"
    local content="$2"
    local media_json="$3" # Optional JSON array for multi-modal [{type: "image_url", ...}]

    if [[ -n "$media_json" && "$media_json" != "null" && "$media_json" != "[]" ]]; then
        # Multi-modal: use Python + process substitution to avoid ARG_MAX
        HISTORY=$(python3 -c '
import json, sys
h = json.loads(open(sys.argv[1]).read())
media = json.loads(open(sys.argv[2]).read())
text = open(sys.argv[3]).read()
role = sys.argv[4]
parts = [{"type": "text", "text": text}] + media
h.append({"role": role, "content": parts})
print(json.dumps(h, separators=(",", ":")))
' <(printf '%s' "$HISTORY") <(printf '%s' "$media_json") <(printf '%s' "$content") "$role")
    else
        HISTORY=$(python3 -c "
import json, sys
h = json.loads(open(sys.argv[1]).read())
role = sys.argv[2]
content = open(sys.argv[3]).read()
h.append({'role': role, 'content': content})
print(json.dumps(h, separators=(',', ':')))
" <(printf '%s' "$HISTORY") "$role" <(printf '%s' "$content"))
    fi
}

append_tool_call() {
    local tool_calls="$1"
    HISTORY=$(python3 -c "
import json, sys
h = json.loads(open(sys.argv[1]).read())
tc = json.loads(open(sys.argv[2]).read())
h.append({'role': 'assistant', 'content': None, 'tool_calls': tc})
print(json.dumps(h, separators=(',', ':')))
" <(printf '%s' "$HISTORY") <(printf '%s' "$tool_calls"))
}

append_tool_result() {
    local id="$1"
    local name="$2"
    local output="$3"
    # Smart folding: keep signal-dense head+tail, summarize discarded middle
    # (AMA Level-4 improvement: reduce cognitive load by removing noise, not just chars)
    local _MAX_LINES=80
    local _HEAD_LINES=30
    local _TAIL_LINES=20
    HISTORY=$(python3 -c "
import json, sys, re

h = json.loads(open(sys.argv[1]).read())
out = open(sys.argv[2]).read()
max_lines = int(sys.argv[5])
head_n   = int(sys.argv[6])
tail_n   = int(sys.argv[7])

lines = out.splitlines()

if len(lines) > max_lines:
    head = lines[:head_n]
    tail = lines[-tail_n:]
    middle = lines[head_n:-tail_n]
    mid_text = '\n'.join(middle)

    # Analyze what was in the middle
    errors   = sum(1 for l in middle if re.search(r'\b(error|exception|traceback|fatal|failed)\b', l, re.I))
    warnings = sum(1 for l in middle if re.search(r'\bwarning\b', l, re.I))

    parts = [f'{len(middle)} lines folded']
    if errors:   parts.append(f'{errors} error(s)')
    if warnings: parts.append(f'{warnings} warning(s)')

    # Git diff: add stat summary
    if '@@' in mid_text or 'diff --git' in mid_text:
        adds = sum(1 for l in middle if l.startswith('+') and not l.startswith('+++'))
        dels = sum(1 for l in middle if l.startswith('-') and not l.startswith('---'))
        parts.append(f'git: +{adds}/-{dels} lines')

    # Pip install: surface what was installed
    for l in reversed(middle):
        if 'Successfully installed' in l:
            parts.append(l.strip()[:80])
            break

    fold_line = '--- [' + ' | '.join(parts) + '] ---'
    out = '\n'.join(head) + '\n' + fold_line + '\n' + '\n'.join(tail)
elif len(out) > 8000:
    # Char-level cap if line count is low but output is huge (e.g. minified JS)
    out = out[:5000] + f'\n\n[...{len(out)-6000} chars truncated...]\n\n' + out[-1000:]

h.append({'role': 'tool', 'tool_call_id': sys.argv[3], 'name': sys.argv[4], 'content': out})
print(json.dumps(h, separators=(',', ':')))
" <(printf '%s' "$HISTORY") <(printf '%s' "$output") "$id" "$name" \
    "$_MAX_LINES" "$_HEAD_LINES" "$_TAIL_LINES")
}

save_history() {
    local session_id="$1"
    local _hfile="brain/state/history_${session_id}.json"
    # Refuse to write empty/null HISTORY. Live incident 2026-05-19: a turn
    # that crashed before HISTORY was populated wrote a 0-byte file that
    # then crashed every subsequent turn with JSONDecodeError on load. If
    # the value isn't a valid non-empty JSON, leave the existing file alone
    # (better stale than corrupt).
    if [[ -z "${HISTORY:-}" || "$HISTORY" == "null" ]]; then
        echo "AMA: save_history refusing empty HISTORY for ${session_id}" >&2
        return 1
    fi
    local _tmp; _tmp=$(mktemp "${_hfile}.XXXXXX")
    printf '%s' "$HISTORY" > "$_tmp" && mv "$_tmp" "$_hfile" || { rm -f "$_tmp"; return 1; }
    # Mirror to SQLite session DB in background (hermes durability pattern)
    ( python3 tools/session_db.py sync "$session_id" "$_hfile" > /dev/null 2>&1 & )
}

load_history() {
    local session_id="$1"
    local _hfile="brain/state/history_${session_id}.json"
    # Handle the empty-file case: a 0-byte file is NOT valid JSON. Treat it
    # the same as a missing file → start fresh with []. Was crashing the
    # downstream payload builder (Vertex 400 "contents required") because
    # `cat "" | json.loads()` raises JSONDecodeError. Same handling if the
    # file has content but isn't parseable.
    if [[ -f "$_hfile" && ! -s "$_hfile" ]]; then
        echo "AMA: load_history found empty file at $_hfile — treating as []" >&2
        rm -f "$_hfile"  # clean up so save_history can write fresh later
    fi
    if [[ -f "$_hfile" ]]; then
        # Session idle auto-reset (hermes pattern): if file is older than SESSION_IDLE_HOURS,
        # treat session as expired and start fresh — avoids resuming week-old conversations
        local _idle_hours="${SESSION_IDLE_HOURS:-0}"  # 0 = disabled
        if [[ "$_idle_hours" -gt 0 ]]; then
            local _file_age_hours=$(( ( $(date +%s) - $(stat -c %Y "brain/state/history_${session_id}.json" 2>/dev/null || echo 0) ) / 3600 ))
            if [[ "$_file_age_hours" -ge "$_idle_hours" ]]; then
                echo "AMA: Session $session_id idle $_file_age_hours h (limit ${_idle_hours}h) — auto-reset." >&2
                local _archive_dir="brain/state/sessions"
                mkdir -p "$_archive_dir"
                mv "brain/state/history_${session_id}.json" "${_archive_dir}/history_${session_id}_$(date +%s).json" 2>/dev/null || \
                    rm -f "brain/state/history_${session_id}.json"
                HISTORY="[]"
                return
            fi
        fi

        HISTORY=$(cat "$_hfile")
        # Sanity check: if history ends with consecutive user messages (no assistant reply),
        # the conversation is in an invalid state — trim the orphaned user messages.
        # On any parse failure (corrupt JSON), fall back to [] instead of cascading.
        local _sanitized
        _sanitized=$(python3 -c "
import json, sys
try:
    h = json.loads(open(sys.argv[1]).read())
    if not isinstance(h, list):
        print('[]'); sys.exit(0)
    # 1. Trim trailing orphaned user messages (no assistant reply yet)
    while h and h[-1].get('role') == 'user':
        h.pop()
    # 2. Trim incomplete tool-call exchanges — Gemini 400s if N function_calls
    #    in a model turn don't have exactly N function_responses in the next turn.
    fixed = []
    i = 0
    while i < len(h):
        msg = h[i]
        if msg.get('role') == 'assistant' and msg.get('tool_calls'):
            n_calls = len(msg['tool_calls'])
            j = i + 1
            while j < len(h) and h[j].get('role') == 'tool':
                j += 1
            if (j - i - 1) < n_calls:
                break  # incomplete exchange — drop it and everything after
        fixed.append(msg)
        i += 1
    print(json.dumps(fixed, separators=(',', ':')))
except Exception as e:
    sys.stderr.write(f'AMA: load_history parse failed: {e} — resetting to []\n')
    print('[]')
" <(printf '%s' "$HISTORY") 2>/dev/null)
        # If the python script produced something usable, take it.
        # Otherwise fall back to [] (don't leave HISTORY as raw corrupt text).
        if [[ -n "$_sanitized" ]]; then
            HISTORY="$_sanitized"
        else
            echo "AMA: load_history could not parse $_hfile — resetting to []" >&2
            HISTORY="[]"
        fi
    else
        HISTORY="[]"
    fi
}

compact_history() {
    local session_id="$1"
    local chat_id="${2:-}"
    local thread_id="${3:-}"
    local msg_id="${4:-}"

    # Cheap pass first — collapse stale tool results + redact verbose write args
    # so they don't bloat token count before we even consider summarization.
    decay_history

    # Then smart compression if still over threshold
    compress_history "$session_id" "$chat_id" "$thread_id" "$msg_id"

    # Fallback to hard truncation if still over max limit
    local count; count=$(python3 -c "import json,sys; print(len(json.loads(open(sys.argv[1]).read())))" <(printf '%s' "$HISTORY") 2>/dev/null); count=${count:-0}
    if [ "$count" -gt "$MAX_HIST_MSGS" ]; then
        local remove_count=$((count - MAX_HIST_MSGS))
        local removed
        removed=$(python3 -c "import json,sys; h=json.loads(open(sys.argv[1]).read()); print(json.dumps(h[:${remove_count}],separators=(',',':')))" <(printf '%s' "$HISTORY"))

        local _hist_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        local _root_dir="$(cd "$_hist_dir/../.." && pwd)"
    local _loop_py
    _loop_py='
import json, sys, subprocess
removed = json.loads(open(sys.argv[1]).read())
root = sys.argv[2]
sid = sys.argv[3]
for msg in removed:
    role = msg.get("role", "")
    c = msg.get("content") or ""
    if isinstance(c, list):
        c = " ".join(p.get("text","") for p in c if isinstance(p, dict))
    c = str(c).strip()
    if c and c != "null":
        subprocess.run(
            ["python3", f"{root}/tools/memory_helper.py", "save",
             f"[{role}]: {c}",
             json.dumps({"session_id": sid, "type": "history"})],
            capture_output=True
        )
'
        python3 -c "$_loop_py" <(printf '%s' "$removed") "$_root_dir" "$session_id" 2>/dev/null

        HISTORY=$(python3 -c "import json,sys; h=json.loads(open(sys.argv[1]).read()); print(json.dumps(h[-${MAX_HIST_MSGS}:],separators=(',',':')))" <(printf '%s' "$HISTORY"))
    fi
}

_apply_provider_history_filter() {
  local hist="$1"
  if [ "$PROVIDER" != "default" ] && type "${PROVIDER}_filter_history" >/dev/null 2>&1; then
    hist=$(printf '%s' "$hist" | ${PROVIDER}_filter_history 2>/dev/null) || true
    [ -z "$hist" ] && hist="$1"
  fi
  printf '%s' "$hist"
}

# Progressive decay: tool results older than DECAY_KEEP turns get collapsed to a
# 1-line marker, and write_file/patch/edit_code arguments get their `content`/
# `code`/`patch_text`/`new_string` redacted. Cheap (no LLM call) and bounded —
# keeps mid-session history ~3-5× lighter without waiting for full compression.
# Only the freshest DECAY_KEEP tool exchanges keep their full content.
decay_history() {
    local _keep="${DECAY_KEEP:-4}"
    local _arg_cap="${DECAY_ARG_CAP:-2000}"
    local _deep_keep="${DEEP_DECAY_KEEP:-}"   # defaults to _keep*3 in python
    local _image_keep="${IMAGE_DECAY_KEEP:-}" # defaults to _keep*2 in python
    HISTORY=$(DECAY_KEEP="$_keep" DECAY_ARG_CAP="$_arg_cap" \
              DEEP_DECAY_KEEP="$_deep_keep" IMAGE_DECAY_KEEP="$_image_keep" \
              python3 -c '
import json, os, sys
h = json.loads(open(sys.argv[1]).read())
keep = int(os.environ.get("DECAY_KEEP", "4"))
arg_cap = int(os.environ.get("DECAY_ARG_CAP", "2000"))
# Two extra tiers (cc-oss microCompact inspired):
#   deep_keep — groups older than this get FULL clearing (no preserved line)
#   image_keep — image parts in user messages older than N user-turns get scrubbed
deep_keep = int(os.environ.get("DEEP_DECAY_KEEP") or (keep * 3))
image_keep = int(os.environ.get("IMAGE_DECAY_KEEP") or (keep * 2))

# Index of tool_call → tool_result groups, in order.
# A "group" = assistant(tool_calls) + its trailing tool messages.
groups = []
i = 0
while i < len(h):
    msg = h[i]
    if msg.get("role") == "assistant" and msg.get("tool_calls"):
        j = i + 1
        while j < len(h) and h[j].get("role") == "tool":
            j += 1
        groups.append((i, j))  # [start, end)
        i = j
    else:
        i += 1

# Decay tier-1: all groups except last `keep` get 1-line collapse + arg redaction
to_decay = groups[:-keep] if len(groups) > keep else []
# Decay tier-2: groups older than `deep_keep` get FULL clearing (no preserved line)
to_deep_decay = set(groups[:-deep_keep]) if len(groups) > deep_keep else set()
_VERBOSE_ARGS = ("content", "code", "patch_text", "new_string", "new_body", "text", "body")

for (start, end) in to_decay:
    deep = (start, end) in to_deep_decay

    # 1. Redact verbose argument fields in assistant tool_calls
    a = h[start]
    for tc in (a.get("tool_calls") or []):
        try:
            args = tc.get("function", {}).get("arguments", "{}")
            if isinstance(args, str):
                parsed = json.loads(args)
            else:
                parsed = dict(args)
            changed = False
            for k in _VERBOSE_ARGS:
                v = parsed.get(k)
                if isinstance(v, str) and len(v) > arg_cap:
                    parsed[k] = f"[elided {len(v)} chars]"
                    changed = True
            if changed:
                tc["function"]["arguments"] = json.dumps(parsed, separators=(",", ":"))
        except Exception:
            pass

    # 2. Collapse tool results — 1-line summary OR full clear if deep
    for k in range(start + 1, end):
        msg = h[k]
        if msg.get("role") != "tool":
            continue
        c = msg.get("content", "")
        if not isinstance(c, str):
            c = str(c)
        if deep and len(c) >= 200:
            msg["content"] = f"[old tool result cleared | {len(c)} chars]"
            continue
        if len(c) < 200:
            continue  # already small
        first = next((line.strip() for line in c.splitlines() if line.strip()), "").replace("\n", " ")
        if len(first) > 140:
            first = first[:140]
        msg["content"] = f"[decayed | {len(c)} chars] {first}"

# 3. Image-part scrubbing. Walk user messages (oldest → newest); for any user
#    message whose distance-from-end exceeds image_keep user-turns, replace any
#    image/image_url parts with a tiny placeholder. A single image base64 part
#    can be 5-50k tokens — far more than any tool result we already decay.
user_idxs = [k for k, m in enumerate(h) if m.get("role") == "user"]
if len(user_idxs) > image_keep:
    stale_user_idxs = set(user_idxs[:-image_keep])
    for k in stale_user_idxs:
        msg = h[k]
        c = msg.get("content")
        if not isinstance(c, list):
            continue
        new_parts = []
        scrubbed = 0
        for p in c:
            if not isinstance(p, dict):
                new_parts.append(p)
                continue
            ptype = p.get("type", "")
            if ptype in ("image_url", "image", "input_image"):
                scrubbed += 1
                continue  # drop entirely; replaced below
            new_parts.append(p)
        if scrubbed:
            new_parts.append({"type": "text", "text": f"[{scrubbed} image(s) elided — older than {image_keep} user turns]"})
            msg["content"] = new_parts

print(json.dumps(h, separators=(",", ":")))
' <(printf '%s' "$HISTORY") 2>/dev/null || printf '%s' "$HISTORY")
}
