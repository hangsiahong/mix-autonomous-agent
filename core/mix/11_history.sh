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
        HISTORY=$(echo "$HISTORY" | jq -c --arg role "$role" --arg content "$content" '. + [{role: $role, content: $content}]')
    fi
}

append_tool_call() {
    local tool_calls="$1"
    HISTORY=$(echo "$HISTORY" | jq -c --argjson tc "$tool_calls" '. + [{role: "assistant", content: null, tool_calls: $tc}]')
}

append_tool_result() {
    local id="$1"
    local name="$2"
    local output="$3"
    HISTORY=$(echo "$HISTORY" | jq -c --arg id "$id" --arg name "$name" --arg output "$output" '. + [{role: "tool", tool_call_id: $id, name: $name, content: $output}]')
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
    
    # First, try smart compression if history is long
    compress_history "$session_id"
    
    # Fallback to hard truncation if still over max limit
    local count; count=$(echo "$HISTORY" | jq 'length' 2>/dev/null); count=${count:-0}
    if [ "$count" -gt "$MAX_HIST_MSGS" ]; then
        local remove_count=$((count - MAX_HIST_MSGS))
        local removed=$(echo "$HISTORY" | jq -c "limit($remove_count; .)")
        
        local _hist_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        local _root_dir="$(cd "$_hist_dir/../.." && pwd)"
        echo "$removed" | jq -c '.[]' | while read -r msg; do
            local role=$(echo "$msg" | jq -r '.role')
            # Extract content text (handle both string and array)
            local content=$(echo "$msg" | jq -r 'if .content | type == "array" then .content | map(.text // "") | join(" ") else .content // "" end')
            
            if [[ -n "$content" && "$content" != "null" ]]; then
                python3 "${_root_dir}/tools/memory_helper.py" save "[$role]: $content" "{\"session_id\": \"$session_id\", \"type\": \"history\"}" >/dev/null 2>&1
            fi
        done

        HISTORY=$(echo "$HISTORY" | jq -c "last($MAX_HIST_MSGS)")
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
