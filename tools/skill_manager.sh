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
    
    # Check if skill exists (optional, but good for validation)
    # For now, just create the directory if it doesn't exist to allow "proto-skills"
    mkdir -p "${_ROOT_DIR}/brain/skills/${skill}"
    
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
    if [[ -d "${_ROOT_DIR}/brain/skills" ]]; then
        ls "${_ROOT_DIR}/brain/skills"
    else
        echo "No skills found."
    fi
fi
