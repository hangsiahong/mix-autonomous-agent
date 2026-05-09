#!/bin/bash
# Tool: todo
# Manage a per-session task list. Actions: add, list, done, delete, clear.

action="${TOOL_action}"
session="${TOOL_session:-default}"
text="${TOOL_text:-}"
id="${TOOL_id:-}"

TODO_FILE="brain/state/todo_${session}.json"

# Ensure file exists
[[ -f "$TODO_FILE" ]] || echo "[]" > "$TODO_FILE"

case "$action" in
    add)
        [[ -z "$text" ]] && { echo "Error: 'text' is required for 'add'."; exit 1; }
        new_id=$(date +%s | tail -c 5)
        tmp=$(mktemp)
        jq --arg id "$new_id" --arg text "$text" \
            '. + [{id: $id, text: $text, done: false, created: (now | todate)}]' \
            "$TODO_FILE" > "$tmp" && mv "$tmp" "$TODO_FILE"
        echo "Added [${new_id}]: $text"
        ;;
    list)
        count=$(jq 'length' "$TODO_FILE")
        if [[ "$count" -eq 0 ]]; then
            echo "No todos."
        else
            jq -r '.[] | "[\(if .done then "x" else " " end)] [\(.id)] \(.text)"' "$TODO_FILE"
        fi
        ;;
    done)
        [[ -z "$id" ]] && { echo "Error: 'id' is required for 'done'."; exit 1; }
        tmp=$(mktemp)
        jq --arg id "$id" 'map(if .id == $id then .done = true else . end)' \
            "$TODO_FILE" > "$tmp" && mv "$tmp" "$TODO_FILE"
        echo "Marked [$id] as done."
        ;;
    delete)
        [[ -z "$id" ]] && { echo "Error: 'id' is required for 'delete'."; exit 1; }
        tmp=$(mktemp)
        jq --arg id "$id" '[.[] | select(.id != $id)]' \
            "$TODO_FILE" > "$tmp" && mv "$tmp" "$TODO_FILE"
        echo "Deleted [$id]."
        ;;
    clear)
        echo "[]" > "$TODO_FILE"
        echo "All todos cleared."
        ;;
    *)
        echo "Unknown action: '$action'. Valid actions: add, list, done, delete, clear"
        exit 1
        ;;
esac
