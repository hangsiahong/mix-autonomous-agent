# History Management

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
    # Cap tool output size: keep first 4000 + last 1000 chars to prevent history bloat
    # (hermes pattern: enforce per-turn budget on tool results)
    local _MAX_TOOL_CHARS=6000
    HISTORY=$(python3 -c "
import json, sys
h = json.loads(open(sys.argv[1]).read())
out = open(sys.argv[2]).read()
max_chars = int(sys.argv[5])
if len(out) > max_chars:
    head = out[:4000]
    tail = out[-1000:]
    removed = len(out) - 5000
    out = head + f'\n\n[...{removed} chars truncated...]\n\n' + tail
h.append({'role': 'tool', 'tool_call_id': sys.argv[3], 'name': sys.argv[4], 'content': out})
print(json.dumps(h, separators=(',', ':')))
" <(printf '%s' "$HISTORY") <(printf '%s' "$output") "$id" "$name" "$_MAX_TOOL_CHARS")
}

save_history() {
    local session_id="$1"
    local _hfile="brain/state/history_${session_id}.json"
    local _tmp; _tmp=$(mktemp "${_hfile}.XXXXXX")
    printf '%s' "$HISTORY" > "$_tmp" && mv "$_tmp" "$_hfile" || { rm -f "$_tmp"; return 1; }
}

load_history() {
    local session_id="$1"
    if [[ -f "brain/state/history_${session_id}.json" ]]; then
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

        HISTORY=$(cat "brain/state/history_${session_id}.json")
        # Sanity check: if history ends with consecutive user messages (no assistant reply),
        # the conversation is in an invalid state — trim the orphaned user messages.
        HISTORY=$(python3 -c "
import json, sys
try:
    h = json.loads(open(sys.argv[1]).read())
    while h and h[-1].get('role') == 'user':
        h.pop()
    print(json.dumps(h, separators=(',', ':')))
except:
    pass
" <(printf '%s' "$HISTORY") 2>/dev/null || echo "$HISTORY")
    else
        HISTORY="[]"
    fi
}

compact_history() {
    local session_id="$1"
    local chat_id="${2:-}"
    local thread_id="${3:-}"
    local msg_id="${4:-}"

    # First, try smart compression if history is long
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
