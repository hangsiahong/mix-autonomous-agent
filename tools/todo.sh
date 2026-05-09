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
        NEW_ID="$new_id" TEXT="$text" TODO_FILE="$TODO_FILE" python3 -c "
import json, os, datetime
f = os.environ['TODO_FILE']
try: d = json.load(open(f))
except: d = []
d.append({'id': os.environ['NEW_ID'], 'text': os.environ['TEXT'], 'done': False, 'created': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')})
open(os.environ.get('TMP',''), 'w').write(json.dumps(d))
" TMP="$tmp" && mv "$tmp" "$TODO_FILE"
        echo "Added [${new_id}]: $text"
        ;;
    list)
        count=$(python3 -c "import json; print(len(json.load(open('$TODO_FILE'))))" 2>/dev/null || echo 0)
        if [[ "$count" -eq 0 ]]; then
            echo "No todos."
        else
            python3 -c "
import json
for t in json.load(open('$TODO_FILE')):
    done = 'x' if t.get('done') else ' '
    print(f'[{done}] [{t.get(\"id\",\"\")}] {t.get(\"text\",\"\")}')
" 2>/dev/null
        fi
        ;;
    done)
        [[ -z "$id" ]] && { echo "Error: 'id' is required for 'done'."; exit 1; }
        tmp=$(mktemp)
        TODO_ID="$id" TODO_FILE="$TODO_FILE" python3 -c "
import json, os
f = os.environ['TODO_FILE']
d = json.load(open(f))
for t in d:
    if t.get('id') == os.environ['TODO_ID']:
        t['done'] = True
open(os.environ.get('TMP',''), 'w').write(json.dumps(d))
" TMP="$tmp" && mv "$tmp" "$TODO_FILE"
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
