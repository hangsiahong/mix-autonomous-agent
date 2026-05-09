# History Management

append_text() {
    local role="$1"
    local content="$2"
    local media_json="$3" # Optional JSON array for multi-modal [{type: "image_url", ...}]
    
    if [[ -n "$media_json" && "$media_json" != "null" ]]; then
        # Multi-modal content
        local combined_content=$(jq -n --arg text "$content" --argjson media "$media_json" \
            '[{"type": "text", "text": $text}] + $media')
        HISTORY=$(echo "$HISTORY" | jq -c --arg role "$role" --argjson content "$combined_content" '. + [{role: $role, content: $content}]')
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
    local count=$(echo "$HISTORY" | jq 'length')
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
