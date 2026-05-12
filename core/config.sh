#!/bin/bash
# core/config.sh - Configuration management

_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT_DIR="$(cd "$_CONFIG_DIR/.." && pwd)"
CONFIG_FILE="${_ROOT_DIR}/brain/config.json"

# Default config if not exists
if [ ! -f "$CONFIG_FILE" ]; then
    mkdir -p "$(dirname "$CONFIG_FILE")"
    echo '{"whitelist": [], "home_chat": null}' > "$CONFIG_FILE"
fi

load_config() {
    cat "$CONFIG_FILE"
}

save_config() {
    # Atomic write: prevents corruption when concurrent sessions call save_config
    local _tmp; _tmp=$(mktemp "${CONFIG_FILE}.XXXXXX")
    printf '%s' "$1" > "$_tmp" && mv "$_tmp" "$CONFIG_FILE" || { rm -f "$_tmp"; return 1; }
}

is_whitelisted() {
    local id="$1"
    # Always whitelist the user who started the bot or defined in TG_ADMIN
    if [[ -n "${TG_ADMIN}" && "$id" == "${TG_ADMIN}" ]]; then
        return 0
    fi

    ID="$id" CF="$CONFIG_FILE" python3 -c "
import json, os
try:
    d = json.load(open(os.environ['CF']))
    exit(0 if os.environ['ID'] in d.get('whitelist', []) else 1)
except:
    exit(1)
"
}

add_to_whitelist() {
    local id="$1"
    local config=$(load_config)
    local new_config
    new_config=$(ID="$id" python3 -c "
import json, os, sys
d = json.load(sys.stdin)
wl = d.get('whitelist', [])
d['whitelist'] = list(dict.fromkeys(wl + [os.environ['ID']]))
print(json.dumps(d))
" <<< "$config")
    save_config "$new_config"
}

set_home_chat() {
    local id="$1"
    local config=$(load_config)
    local new_config
    new_config=$(ID="$id" python3 -c "
import json, os, sys
d = json.load(sys.stdin)
d['home_chat'] = os.environ['ID']
print(json.dumps(d))
" <<< "$config")
    save_config "$new_config"
    # Also ensure home chat is whitelisted
    add_to_whitelist "$id"
}

get_topic_config() {
    local chat_id="$1"
    local thread_id="$2"
    local config=$(load_config)

    # Try to find topic in group_topics
    CID="$chat_id" TID="$thread_id" python3 -c "
import json, os, sys
d = json.load(sys.stdin)
cid = os.environ['CID']
tid = os.environ['TID']
for g in d.get('group_topics', []):
    if g.get('chat_id') == cid:
        for t in g.get('topics', []):
            if t.get('thread_id') == tid:
                print(json.dumps(t, separators=(',',':')))
" <<< "$config"
}

set_topic_config() {
    local chat_id="$1"
    local thread_id="$2"
    local key="$3"
    local val="$4"

    local config=$(load_config)

    local updated_config
    updated_config=$(CID="$chat_id" TID="$thread_id" KEY="$key" VAL="$val" python3 -c "
import json, os, sys
d = json.load(sys.stdin)
cid = os.environ['CID']
tid = os.environ['TID']
key = os.environ['KEY']
val = os.environ['VAL']
if 'group_topics' not in d:
    d['group_topics'] = []
group = next((g for g in d['group_topics'] if g.get('chat_id') == cid), None)
if group is None:
    group = {'chat_id': cid, 'topics': []}
    d['group_topics'].append(group)
topics = group.get('topics', [])
topic = next((t for t in topics if t.get('thread_id') == tid), None)
if topic is None:
    topics.append({'thread_id': tid, key: val})
else:
    topic[key] = val
group['topics'] = topics
print(json.dumps(d))
" <<< "$config")

    save_config "$updated_config"
}
