#!/bin/bash
# tools/skill_manager.sh - Bind skills to topics

_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT_DIR="$(cd "$_TOOLS_DIR/.." && pwd)"

source "${_ROOT_DIR}/core/config.sh"

action="${TOOL_action}" # bind, list, unbind, create
# Auto-fill chat/thread from the per-call execution context that
# 13_tool_execution.sh already exports. Agents do NOT need to pass these
# manually — empty thread_id is the DM-root for 1-to-1 chats and is now
# valid (was previously rejected, which made bind impossible in DMs).
chat_id="${TOOL_chat_id:-${TOOL_CHAT_ID:-}}"
thread_id="${TOOL_thread_id:-${TOOL_THREAD_ID:-}}"
session_id="${TOOL_session_id:-${TOOL_SESSION_ID:-}}"
skill="${TOOL_skill}"
name="${TOOL_name:-$skill}"

if [[ "$action" == "bind" ]]; then
    if [[ -z "$skill" ]]; then
        echo "Error: 'skill' is required. (chat_id/thread_id are auto-filled from the session — you only need to pass the skill name.)"
        exit 1
    fi
    if [[ -z "$chat_id" ]]; then
        echo "Error: chat_id missing — tool was invoked outside an agent turn."
        exit 1
    fi

    # Validate skill exists — refuse to bind on typo (was: silently mkdir orphan dir).
    if [[ ! -f "${_ROOT_DIR}/brain/skills/${skill}/prompt.md" && \
          ! -f "${_ROOT_DIR}/core/skills/${skill}/prompt.md" ]]; then
        echo "Error: skill '${skill}' does not exist (no prompt.md in brain/skills/ or core/skills/). Use skill_manager(action=list) to see what's available, or skill_manager(action=create, ...) to create it first."
        exit 1
    fi

    # Long-term: topic config (brain/config.json group_topics) so the binding
    # survives /restart and applies to future sessions in this chat/thread.
    # set_topic_config takes (chat_id, thread_id, key, value) per-call — the
    # old code passed a JSON blob as the 3rd arg, which the function rejected
    # silently as "invalid key". Now writes the fields individually.
    set_topic_config "$chat_id" "$thread_id" "skill" "$skill" 2>/dev/null
    if [[ "$name" != "$skill" ]]; then
        set_topic_config "$chat_id" "$thread_id" "name" "$name" 2>/dev/null
    fi

    # Per-session sticky sidecar so the binding takes effect on the NEXT turn
    # in the current session. Without this, router.sh's active_skill_<sid>
    # shadow check (router.sh:516) keeps reading the previously-active skill
    # until the session ends — making bind feel like a no-op mid-conversation.
    if [[ -n "$session_id" ]]; then
        _active_skill_file="${_ROOT_DIR}/brain/state/active_skill_${session_id}"
        mkdir -p "$(dirname "$_active_skill_file")"
        printf '%s' "$skill" > "$_active_skill_file" 2>/dev/null || true
    fi

    if [[ -z "$thread_id" ]]; then
        echo "Skill '$skill' bound to chat $chat_id (DM root). Active next turn."
    else
        echo "Skill '$skill' bound to topic '$name' (thread $thread_id) in chat $chat_id. Active next turn."
    fi

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
n = len(rows)
if n == 0:
    print('0 skills installed.')
else:
    print(f'{n} skill{\"s\" if n!=1 else \"\"} installed:')
    print('\n'.join(rows))
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
