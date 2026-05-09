# History Management

append_text() {
    local role="$1"
    local content="$2"
    HISTORY=$(echo "$HISTORY" | jq -c --arg role "$role" --arg content "$content" '. + [{role: $role, content: $content}]')
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
    local chat_id="$1"
    echo "$HISTORY" > "brain/state/history_${chat_id}.json"
}

load_history() {
    local chat_id="$1"
    if [[ -f "brain/state/history_${chat_id}.json" ]]; then
        HISTORY=$(cat "brain/state/history_${chat_id}.json")
    else
        HISTORY="[]"
    fi
}

compact_history() {
    local chat_id="$1" # Need chat_id for metadata
    local count=$(echo "$HISTORY" | jq 'length')
    if [ "$count" -gt "$MAX_HIST_MSGS" ]; then
        # Extract messages that will be removed
        local remove_count=$((count - MAX_HIST_MSGS))
        local removed=$(echo "$HISTORY" | jq -c "limit($remove_count; .)")
        
        # Save to long-term memory
        echo "$removed" | jq -c '.[]' | while read -r msg; do
            local role=$(echo "$msg" | jq -r '.role')
            local content=$(echo "$msg" | jq -r '.content // ""')
            if [[ -n "$content" && "$content" != "null" ]]; then
                python3 "tools/memory_helper.py" save "[$role]: $content" "{\"chat_id\": \"$chat_id\", \"type\": \"history\"}" >/dev/null 2>&1
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
