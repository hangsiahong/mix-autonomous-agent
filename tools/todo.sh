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
        TMP="$tmp" NEW_ID="$new_id" TEXT="$text" TODO_FILE="$TODO_FILE" python3 -c "
import json, os, datetime
f = os.environ['TODO_FILE']
try:
    with open(f, 'r') as jf: d = json.load(jf)
except: d = []
d.append({
    'id': os.environ['NEW_ID'],
    'text': os.environ['TEXT'],
    'done': False,
    'created': datetime.datetime.now(datetime.UTC).strftime('%Y-%m-%dT%H:%M:%SZ')
})
with open(os.environ['TMP'], 'w') as jf:
    json.dump(d, jf)
" && mv "$tmp" "$TODO_FILE"
        echo "Added [${new_id}]: $text"
        ;;
    list)
        if [[ ! -f "$TODO_FILE" ]]; then
            echo "No todos."
        else
            python3 -c "
import json, os
try:
    with open(os.environ['TODO_FILE'], 'r') as f:
        data = json.load(f)
    if not data:
        print('No todos.')
    else:
        for t in data:
            done = 'x' if t.get('done') else ' '
            print(f'[{done}] [{t.get(\"id\",\"\")}] {t.get(\"text\",\"\")}')
except Exception:
    print('No todos.')
" TODO_FILE="$TODO_FILE"
        fi
        ;;
    done)
        [[ -z "$id" ]] && { echo "Error: 'id' is required for 'done'."; exit 1; }
        tmp=$(mktemp)
        TMP="$tmp" TODO_ID="$id" TODO_FILE="$TODO_FILE" python3 -c "
import json, os
f = os.environ['TODO_FILE']
with open(f, 'r') as jf: d = json.load(jf)
for t in d:
    if str(t.get('id')) == os.environ['TODO_ID']:
        t['done'] = True
with open(os.environ['TMP'], 'w') as jf:
    json.dump(d, jf)
" && mv "$tmp" "$TODO_FILE"
        echo "Marked [$id] as done."
        ;;
    delete)
        [[ -z "$id" ]] && { echo "Error: 'id' is required for 'delete'."; exit 1; }
        tmp=$(mktemp)
        TODO_ID="$id" TODO_FILE="$TODO_FILE" python3 -c "
import json, os
f = os.environ['TODO_FILE']
d = json.load(open(f))
print(json.dumps([t for t in d if t.get('id') != os.environ['TODO_ID']]))
" > "$tmp" && mv "$tmp" "$TODO_FILE"
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
