#!/bin/bash
# tools/skill_manager.sh - Bind skills to topics

_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT_DIR="$(cd "$_TOOLS_DIR/.." && pwd)"

source "${_ROOT_DIR}/core/config.sh"

action="${TOOL_action}" # bind, list, unbind
chat_id="${TOOL_chat_id}"
thread_id="${TOOL_thread_id}"
skill="${TOOL_skill}"
name="${TOOL_name:-$skill}"

if [[ "$action" == "bind" ]]; then
    if [[ -z "$chat_id" || -z "$thread_id" || -z "$skill" ]]; then
        echo "Error: chat_id, thread_id and skill are required."
        exit 1
    fi

    # Validate skill exists — refuse to bind on typo (was: silently mkdir orphan dir).
    if [[ ! -f "${_ROOT_DIR}/brain/skills/${skill}/prompt.md" && \
          ! -f "${_ROOT_DIR}/core/skills/${skill}/prompt.md" ]]; then
        echo "Error: skill '${skill}' does not exist (no prompt.md in brain/skills/ or core/skills/). Use skill_manager(action=list) to see what's available, or skill_manager(action=create, ...) to create it first."
        exit 1
    fi

    topic_data=$(TID="$thread_id" SKILL="$skill" NAME="$name" python3 -c "
import json, os
print(json.dumps({'thread_id': os.environ['TID'], 'skill': os.environ['SKILL'], 'name': os.environ['NAME']}))
")
    
    set_topic_config "$chat_id" "$thread_id" "$topic_data"
    echo "Skill '$skill' bound to topic '$name' ($thread_id) in chat $chat_id."

elif [[ "$action" == "unbind" ]]; then
     # Use a special value or filter out
     # For simplicity, just set skill to empty
     topic_data=$(get_topic_config "$chat_id" "$thread_id")
     if [[ -n "$topic_config" && "$topic_config" != "null" ]]; then
         topic_data=$(echo "$topic_data" | python3 -c "import json,sys; d=json.load(sys.stdin); d.pop('skill',None); print(json.dumps(d))")
         set_topic_config "$chat_id" "$thread_id" "$topic_data"
         echo "Skill unbound from topic $thread_id."
     else
         echo "Topic not found."
     fi

elif [[ "$action" == "list" ]]; then
    python3 -c "
import os, json
roots = [('core/skills', 'core'), ('brain/skills', 'user')]
seen = set()
rows = []
for root, src in roots:
    if not os.path.isdir(root): continue
    for name in sorted(os.listdir(root)):
        path = os.path.join(root, name)
        if os.path.isdir(path) and name not in seen:
            seen.add(name)
            has_prompt = os.path.exists(os.path.join(path, 'prompt.txt'))
            has_tools  = os.path.exists(os.path.join(path, 'tools.json'))
            rows.append(f'  {name} [{src}]' + (' +tools' if has_tools and open(os.path.join(path,'tools.json')).read().strip() not in ('[]','') else ''))
print('\n'.join(rows) if rows else '  (no skills found)')
"

elif [[ "$action" == "create" ]]; then
    if [[ -z "$skill" || -z "${TOOL_prompt:-}" ]]; then
        echo "Error: 'skill' (name) and 'prompt' are required for create."
        exit 1
    fi
    skill_dir="${_ROOT_DIR}/brain/skills/${skill}"
    mkdir -p "$skill_dir"
    echo "${TOOL_prompt}" > "$skill_dir/prompt.md"
    # Write tools.json if extra toolsets requested
    if [[ -n "${TOOL_toolsets:-}" ]]; then
        TS="${TOOL_toolsets}" python3 -c "
import json, os
ts = os.environ['TS'].split()
print(json.dumps([{'_enabled_toolsets': ts}], indent=2))
" > "$skill_dir/tools.json"
    else
        echo "[]" > "$skill_dir/tools.json"
    fi
    echo "Skill '${skill}' created at brain/skills/${skill}/. Activate with /skill ${skill} in Telegram."
fi
