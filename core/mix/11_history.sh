# History Management

append_text() {
    local role="$1"
    local content="$2"
    local media_json="$3" # Optional JSON array for multi-modal [{type: "image_url", ...}]
    
    if [[ -n "$media_json" && "$media_json" != "null" && "$media_json" != "[]" ]]; then
        # Multi-modal: use Python + tempfiles to avoid ARG_MAX with large base64 data.
        # jq --argjson passes content as a command-line arg, hitting the kernel 2MB limit.
        local _h_file _m_file
        _h_file=$(mktemp)
        _m_file=$(mktemp)
        printf '%s' "$HISTORY" > "$_h_file"
        printf '%s' "$media_json" > "$_m_file"
        HISTORY=$(ROLE="$role" TEXT="$content" H_FILE="$_h_file" M_FILE="$_m_file" python3 -c '
import json, os
h = json.load(open(os.environ["H_FILE"]))
media = json.load(open(os.environ["M_FILE"]))
text = os.environ["TEXT"]
role = os.environ["ROLE"]
parts = [{"type": "text", "text": text}] + media
h.append({"role": role, "content": parts})
print(json.dumps(h, separators=(",", ":")))
')
        rm -f "$_h_file" "$_m_file"
    else
        HISTORY=$(ROLE="$role" CONTENT="$content" python3 -c "
import json, os, sys
h = json.load(sys.stdin)
h.append({'role': os.environ['ROLE'], 'content': os.environ['CONTENT']})
print(json.dumps(h, separators=(',', ':')))
" <<< "$HISTORY")
    fi
}

append_tool_call() {
    local tool_calls="$1"
    HISTORY=$(TC="$tool_calls" python3 -c "
import json, os, sys
h = json.load(sys.stdin)
tc = json.loads(os.environ['TC'])
h.append({'role': 'assistant', 'content': None, 'tool_calls': tc})
print(json.dumps(h, separators=(',', ':')))
" <<< "$HISTORY")
}

append_tool_result() {
    local id="$1"
    local name="$2"
    local output="$3"
    HISTORY=$(TID="$id" TNAME="$name" TOUT="$output" python3 -c "
import json, os, sys
h = json.load(sys.stdin)
h.append({'role': 'tool', 'tool_call_id': os.environ['TID'], 'name': os.environ['TNAME'], 'content': os.environ['TOUT']})
print(json.dumps(h, separators=(',', ':')))
" <<< "$HISTORY")
}

save_history() {
    local session_id="$1"
    echo "$HISTORY" > "brain/state/history_${session_id}.json"
}

load_history() {
    local session_id="$1"
    if [[ -f "brain/state/history_${session_id}.json" ]]; then
        HISTORY=$(cat "brain/state/history_${session_id}.json")
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
    local count; count=$(echo "$HISTORY" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null); count=${count:-0}
    if [ "$count" -gt "$MAX_HIST_MSGS" ]; then
        local remove_count=$((count - MAX_HIST_MSGS))
        local removed
        removed=$(python3 -c "import json,sys; h=json.load(sys.stdin); print(json.dumps(h[:${remove_count}],separators=(',',':')))" <<< "$HISTORY")

        local _hist_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        local _root_dir="$(cd "$_hist_dir/../.." && pwd)"
        local _loop_py
        _loop_py='
import json, os, subprocess
removed = json.loads(os.environ["REMOVED"])
root = os.environ["ROOT"]
sid = os.environ["SID"]
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
        REMOVED="$removed" ROOT="$_root_dir" SID="$session_id" python3 -c "$_loop_py" 2>/dev/null

        HISTORY=$(python3 -c "import json,sys; h=json.load(sys.stdin); print(json.dumps(h[-${MAX_HIST_MSGS}:],separators=(',',':')))" <<< "$HISTORY")
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
