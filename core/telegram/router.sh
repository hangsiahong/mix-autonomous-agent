#!/bin/bash
# core/telegram/router.sh - Command routing

tg_handle_update() {
    local update="$1"

    # Parse all update fields in one Python call (avoids 7+ jq invocations).
    # shlex.quote is used so eval is safe regardless of message content.
    local _vars
    _vars=$(UPDATE="$update" python3 -c "
import json, os, shlex
try:
    u = json.loads(os.environ['UPDATE'])
except Exception:
    u = {}
msg = u.get('message') or {}
cbq = u.get('callback_query') or {}
src_msg = msg if msg else (cbq.get('message') or {})
src_from = (msg.get('from') or cbq.get('from')) or {}
chat = src_msg.get('chat') or {}
bot_username = os.environ.get('BOT_USERNAME', '')

# Reply-to: capture the original message's ID and text for threading
reply_to_msg = msg.get('reply_to_message') or {}
reply_to_id = str(reply_to_msg.get('message_id', '') or '')

# For group @mention gate: check if bot is @mentioned in text or caption
raw_text = str(msg.get('text', '') or msg.get('caption', '') or cbq.get('data', '') or '')
is_mention = False
if bot_username and ('@' + bot_username).lower() in raw_text.lower():
    is_mention = True
# Also check if it's a reply to a bot message
is_reply_to_bot = bool(reply_to_msg.get('from', {}).get('is_bot'))

# media_group_id for album batching
media_group_id = str(msg.get('media_group_id', '') or '')

vals = {
    'chat_id':       str(chat.get('id', '') or ''),
    'thread_id':     str(src_msg.get('message_thread_id', '') or ''),
    'chat_type':     str(chat.get('type', 'private') or 'private'),
    'chat_title':    str(chat.get('title', '') or ''),
    'text':          raw_text,
    'user_id':       str(src_from.get('id', '') or ''),
    'username':      str(src_from.get('username', '') or ''),
    'message_id':    str(src_msg.get('message_id', '') or ''),
    'reply_to_id':   reply_to_id,
    'is_mention':    '1' if is_mention else '0',
    'is_reply_to_bot': '1' if is_reply_to_bot else '0',
    'media_group_id': media_group_id,
}
for k, v in vals.items():
    print(f'{k}={shlex.quote(v)}')
" 2>/dev/null) || true
    eval "$_vars"
    
    # Build Session ID
    local session_id="tg_${chat_id}"
    if [[ -n "$thread_id" ]]; then
        session_id="tg_${chat_id}_${thread_id}"
    fi

    # Extract Media
    local media_out=$(tg_extract_media "$update")
    local media_json=$(echo "$media_out" | grep -v "MEDIA_FILE:" || echo "[]")
    local media_file=$(echo "$media_out" | grep "MEDIA_FILE:" | cut -d: -f2- || true)

    if [[ -n "$media_file" ]]; then
        text="$text [Attached File: $media_file]"
    fi

    # Ignore empty messages unless there is media
    [[ "$text" == "null" || -z "$text" ]] && [[ "$media_json" == "[]" ]] && return

    # Whitelist Check
    if ! is_whitelisted "$chat_id" && ! is_whitelisted "$user_id"; then
        if [[ "$user_id" == "${TG_ADMIN}" && "$text" == "/whitelist"* ]]; then
             : # Allow admin whitelist bootstrap
        else
            echo "Access denied for chat_id $chat_id / user_id $user_id."
            return
        fi
    fi

    # Group @mention gate (hermes-style): in groups only respond when @mentioned or replied-to
    # Controlled by env REQUIRE_MENTION=1 or for all groups when not DM
    if [[ "$chat_type" != "private" && "$text" != /* ]]; then
        local _require_mention="${REQUIRE_MENTION:-0}"
        # If REQUIRE_MENTION is set, skip unless @mentioned or reply to bot
        if [[ "$_require_mention" == "1" || "$_require_mention" == "true" ]]; then
            if [[ "$is_mention" != "1" && "$is_reply_to_bot" != "1" ]]; then
                return  # Silent drop — bot not addressed
            fi
        fi
    fi

    # Photo album batching (hermes-style): coalesce media_group albums into one agent call
    # If this photo belongs to a media group, defer it to a pending batch file for 1 second
    if [[ -n "$media_group_id" && "$media_group_id" != "null" ]]; then
        local _batch_dir="${DIR}/brain/state/albums"
        mkdir -p "$_batch_dir"
        local _batch_file="${_batch_dir}/${session_id}_${media_group_id}"
        # Append this update's media to the batch file
        local _cur_media="$media_json"
        if [[ -f "$_batch_file" ]]; then
            # Merge: combine existing + new media arrays
            _cur_media=$(python3 -c "
import json, sys
existing = json.loads(open(sys.argv[1]).read())
new = json.loads(sys.argv[2])
combined = existing + new
print(json.dumps(combined))
" "$_batch_file" "$media_json" 2>/dev/null || echo "$media_json")
        fi
        printf '%s' "$_cur_media" > "$_batch_file"
        # Schedule flush after 1 second (background — kills any pending flush for same album)
        local _lock_file="${_batch_dir}/${session_id}_${media_group_id}.lock"
        # Background flush: wait 1s then dispatch if this is the last writer
        (
            sleep 1
            [[ -f "$_batch_file" ]] || exit 0
            local _batched_media; _batched_media=$(cat "$_batch_file")
            rm -f "$_batch_file"
            local _caption="$text"
            [[ -z "$_caption" ]] && _caption="[Photo album]"
            ( set -m; run_agent "$chat_id" "$_caption" "$user_id" "$_batched_media" "$thread_id" "$session_id" "$chat_title" "$username" "$skill" "$message_id" ) &
        ) &
        return  # Don't process immediately; let the batch flush handle it
    fi

    # Auto-load AMA skill if mentioning AMA or autonomous-agent
    local topic_cfg=$(get_topic_config "$chat_id" "$thread_id")
    local skill=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('skill','') or '')" "$topic_cfg" 2>/dev/null)
    if [[ -z "$skill" ]] && [[ "$text" =~ ([[:space:]]|^)[Aa][Mm][Aa]([[:space:]]|$) || "$text" =~ "autonomous-agent" ]]; then
        skill="ama"
    fi

    # Handle Slash Commands
    if [[ "$text" == /* ]]; then
        local cmd=$(echo "$text" | awk '{print $1}')
        local args=$(echo "$text" | sed "s|^$cmd||" | sed 's|^[[:space:]]*||')
        
        case "$cmd" in
            /start)
                tg_send "$chat_id" "AMA (Autonomous Mix Agent) ready. Use /help for commands." "$thread_id"
                ;;
            /help)
                tg_send "$chat_id" "<b>Commands</b>
<b>Session</b>
/stop — stop running task • /stop all — kill everything
/new or /reset — fresh session (history archived)
/retry — re-run last message
/undo — remove last exchange from history
/steer &lt;note&gt; — inject guidance mid-run (after next tool call)
/queue &lt;text&gt; — queue a message for after current run

<b>Config</b>
/model &lt;name&gt; — switch model this session
/skill &lt;name&gt; — activate a skill • /skill off to clear
/skills — list available skills

<b>Info</b>
/status — model, session, system info
/usage — token usage this session
/insights — token + tool frequency stats

<b>Admin</b>
/whitelist &lt;id&gt; — add user/chat
/restart — restart bot
/shutdown — shut down bot" "$thread_id" "HTML"
                ;;
            /whitelist)
                local target_id=$(echo "$args" | awk '{print $1}')
                if [[ "$user_id" == "${TG_ADMIN}" && -n "$target_id" ]]; then
                    add_to_whitelist "$target_id"
                    tg_send "$chat_id" "User/Chat $target_id added to whitelist." "$thread_id"
                else
                    tg_send "$chat_id" "Usage: /whitelist <id> (Admin only)" "$thread_id"
                fi
                ;;
            /reset|/new)
                local _hist_file="${DIR}/brain/state/history_${session_id}.json"
                if [[ -f "$_hist_file" ]]; then
                    local _archive_dir="${DIR}/brain/state/sessions"
                    mkdir -p "$_archive_dir"
                    local _ts; _ts=$(date +%s)
                    cp "$_hist_file" "${_archive_dir}/history_${session_id}_${_ts}.json"
                    rm -f "$_hist_file"
                fi
                # End session in SQLite DB (hermes: end_reason="reset")
                ( python3 tools/session_db.py end "$session_id" "reset" > /dev/null 2>&1 & )
                # Clear session-level overrides on reset
                rm -f "${DIR}/brain/state/model_${session_id}" \
                      "${DIR}/brain/state/steer_${session_id}" \
                      "${DIR}/brain/state/queue_${session_id}" 2>/dev/null || true
                tg_send "$chat_id" "🆕 New session started. Past conversations are archived and searchable with \`session_search\`." "$thread_id"
                ;;

            /sessions)
                # List recent sessions with lineage (hermes /sessions command)
                local _limit_arg=$(echo "$args" | awk '{print $1}')
                local _limit="${_limit_arg:-10}"
                local _sessions_out
                _sessions_out=$(python3 -c "
import sys, json
sys.path.insert(0, '${DIR}/tools')
from session_db import list_sessions, session_lineage
import datetime

rows = list_sessions($_limit)
if not rows:
    print('No sessions found.')
    sys.exit(0)

lines = ['<b>Recent Sessions</b>']
for r in rows:
    sid = r['id']
    title = (r.get('title') or sid)[:30]
    model = (r.get('model') or '?')[:20]
    msgs = r.get('message_count', 0)
    tokens = (r.get('input_tokens',0) or 0) + (r.get('output_tokens',0) or 0)
    status = r.get('end_reason') or ('active' if not r.get('ended_at') else 'ended')
    parent = r.get('parent_session_id')
    lineage = ' ← (compressed)' if parent else ''
    ts = r.get('updated_at') or r.get('started_at') or 0
    if ts:
        dt = datetime.datetime.fromtimestamp(float(ts)).strftime('%m-%d %H:%M')
    else:
        dt = '?'
    lines.append(f'<code>{sid[:28]}</code> <i>{dt}</i>')
    lines.append(f'  {title} | {model} | {msgs} msgs | {tokens:,}t | {status}{lineage}')
print('\n'.join(lines))
" 2>/dev/null || echo "Session DB unavailable. Try /status for current session info.")
                tg_send "$chat_id" "$_sessions_out" "$thread_id" "HTML"
                ;;

            /retry)
                # Re-run the last user message (hermes pattern: trim last exchange, re-queue)
                local _hist_file="${DIR}/brain/state/history_${session_id}.json"
                local _last_user_text=""
                if [[ -f "$_hist_file" ]]; then
                    _last_user_text=$(python3 -c "
import json, sys
h = json.load(open(sys.argv[1]))
# Find last user message going backwards, extract text
for msg in reversed(h):
    if msg.get('role') == 'user':
        c = msg.get('content', '')
        if isinstance(c, list):
            c = ' '.join(p.get('text','') for p in c if isinstance(p,dict) and p.get('type')=='text')
        print(str(c).strip())
        break
" "$_hist_file" 2>/dev/null)
                fi
                if [[ -z "$_last_user_text" ]]; then
                    tg_send "$chat_id" "Nothing to retry — history is empty." "$thread_id"
                else
                    # Trim history to before the last user turn
                    python3 -c "
import json, sys
h = json.load(open(sys.argv[1]))
# Find index of last user message
idx = None
for i in range(len(h)-1, -1, -1):
    if h[i].get('role') == 'user':
        idx = i; break
if idx is not None:
    open(sys.argv[1], 'w').write(json.dumps(h[:idx], separators=(',',':')))
" "$_hist_file" 2>/dev/null
                    tg_send "$chat_id" "🔁 Retrying last message…" "$thread_id"
                    ( set -m; run_agent "$chat_id" "$_last_user_text" "$user_id" "[]" "$thread_id" "$session_id" "$chat_title" "$username" "$skill" "$message_id" ) &
                fi
                ;;

            /undo)
                # Remove the last exchange (last user message + everything after) from history
                local _hist_file="${DIR}/brain/state/history_${session_id}.json"
                if [[ ! -f "$_hist_file" ]]; then
                    tg_send "$chat_id" "Nothing to undo — history is empty." "$thread_id"
                else
                    local _undo_result
                    _undo_result=$(python3 -c "
import json, sys
h = json.load(open(sys.argv[1]))
idx = None
for i in range(len(h)-1, -1, -1):
    if h[i].get('role') == 'user':
        idx = i; break
if idx is None:
    print('empty')
else:
    removed = len(h) - idx
    preview = h[idx].get('content','')
    if isinstance(preview, list):
        preview = ' '.join(p.get('text','') for p in preview if isinstance(p,dict))
    open(sys.argv[1], 'w').write(json.dumps(h[:idx], separators=(',',':')))
    print(f'removed:{removed}:{str(preview)[:80]}')
" "$_hist_file" 2>/dev/null)
                    if [[ "$_undo_result" == "empty" ]]; then
                        tg_send "$chat_id" "Nothing to undo." "$thread_id"
                    else
                        local _removed_count; _removed_count=$(echo "$_undo_result" | cut -d: -f2)
                        local _preview; _preview=$(echo "$_undo_result" | cut -d: -f3-)
                        tg_send "$chat_id" "↩️ Removed $_removed_count message(s). Last prompt was: <i>${_preview}</i>" "$thread_id" "HTML"
                    fi
                fi
                ;;

            /model)
                # Per-session model override (hermes pattern: stored per session_id)
                local _model_arg=$(echo "$args" | awk '{print $1}')
                if [[ -z "$_model_arg" ]]; then
                    local _cur_model="${MODEL:-unknown}"
                    local _override_model=""
                    [[ -f "${DIR}/brain/state/model_${session_id}" ]] && _override_model=$(cat "${DIR}/brain/state/model_${session_id}" 2>/dev/null)
                    if [[ -n "$_override_model" ]]; then
                        tg_send "$chat_id" "Current model: <code>${_override_model}</code> (session override)\nDefault: <code>${_cur_model}</code>\n\nUse <code>/model &lt;name&gt;</code> to switch. <code>/model default</code> to reset." "$thread_id" "HTML"
                    else
                        tg_send "$chat_id" "Current model: <code>${_cur_model}</code>\n\nUse <code>/model &lt;name&gt;</code> to switch." "$thread_id" "HTML"
                    fi
                elif [[ "$_model_arg" == "default" || "$_model_arg" == "reset" ]]; then
                    rm -f "${DIR}/brain/state/model_${session_id}"
                    tg_send "$chat_id" "✅ Model reset to default: <code>${MODEL:-unknown}</code>" "$thread_id" "HTML"
                else
                    mkdir -p "${DIR}/brain/state"
                    printf '%s' "$_model_arg" > "${DIR}/brain/state/model_${session_id}"
                    tg_send "$chat_id" "✅ Model set to <code>${_model_arg}</code> for this session." "$thread_id" "HTML"
                fi
                ;;

            /usage)
                # Show token usage for this session (hermes pattern)
                local _usage_report
                _usage_report=$(python3 -c "
import json, sys, os
usage_file = '${DIR}/brain/state/usage_log.jsonl'
session_id = '${session_id}'
if not os.path.exists(usage_file):
    print('No usage data recorded yet.')
    sys.exit(0)
lines = open(usage_file).readlines()
total_in = total_out = total_calls = 0
for line in lines:
    try:
        e = json.loads(line)
        if e.get('chat_id') == session_id or e.get('chat_id') == session_id.replace('tg_',''):
            u = e.get('usage', {})
            total_in += int(u.get('prompt_tokens', 0) or 0)
            total_out += int(u.get('completion_tokens', 0) or 0)
            total_calls += 1
    except: pass
if total_calls == 0:
    # Fall back to totals file
    try:
        t = json.load(open('${DIR}/brain/state/usage_totals.json'))
        total_in = t.get('prompt_tokens',0)
        total_out = t.get('completion_tokens',0)
        print(f'All-time: {total_in:,} in + {total_out:,} out = {total_in+total_out:,} tokens')
        sys.exit(0)
    except: pass
    print('No usage data for this session.')
    sys.exit(0)
total = total_in + total_out
print(f'Session: {total_calls} API calls\n{total_in:,} input + {total_out:,} output = {total:,} total tokens')
" 2>/dev/null || echo "Usage data unavailable.")
                tg_send "$chat_id" "📊 <b>Token Usage</b>\n${_usage_report}" "$thread_id" "HTML"
                ;;

            /steer)
                # Inject guidance mid-run (hermes pattern: appended to next tool result)
                if [[ -z "$args" ]]; then
                    tg_send "$chat_id" "Usage: <code>/steer &lt;guidance text&gt;</code>\nThe note will be injected after the agent's next tool call." "$thread_id" "HTML"
                else
                    mkdir -p "${DIR}/brain/state"
                    local _steer_file="${DIR}/brain/state/steer_${session_id}"
                    printf '%s\n' "$args" >> "$_steer_file"
                    tg_send "$chat_id" "💬 Steer queued. It will be injected after the next tool call." "$thread_id"
                fi
                ;;

            /queue)
                # Queue a message to run after current turn completes (hermes pattern)
                if [[ -z "$args" ]]; then
                    tg_send "$chat_id" "Usage: <code>/queue &lt;message&gt;</code>\nThe message will be processed after the current task finishes." "$thread_id" "HTML"
                else
                    mkdir -p "${DIR}/brain/state"
                    local _queue_file="${DIR}/brain/state/queue_${session_id}"
                    printf '%s\n' "$args" >> "$_queue_file"
                    local _qdepth; _qdepth=$(wc -l < "$_queue_file" 2>/dev/null || echo 1)
                    tg_send "$chat_id" "📥 Queued (position $_qdepth)." "$thread_id"
                fi
                ;;
            /status)
                local _title="Untitled"
                [[ -f "brain/state/titles.json" ]] && _title=$(SID="$session_id" python3 -c "
import json,os; d=json.load(open('brain/state/titles.json')); print(d.get(os.environ['SID'],'Untitled') or 'Untitled')" 2>/dev/null)
                # Session age from history file mtime
                local _sess_age="new"
                if [[ -f "${DIR}/brain/state/history_${session_id}.json" ]]; then
                    local _age_s=$(( $(date +%s) - $(stat -c %Y "${DIR}/brain/state/history_${session_id}.json" 2>/dev/null || echo $(date +%s)) ))
                    if [[ $_age_s -lt 3600 ]]; then _sess_age="${_age_s}s"
                    elif [[ $_age_s -lt 86400 ]]; then _sess_age="$((_age_s/3600))h"
                    else _sess_age="$((_age_s/86400))d"; fi
                fi
                # Message count
                local _msg_count=$(python3 -c "import json; print(len(json.load(open('${DIR}/brain/state/history_${session_id}.json'))))" 2>/dev/null || echo 0)
                # Active agents & queue depth
                local _active_agents=$(ls "${DIR}/brain/state"/run_*.pid 2>/dev/null | wc -l)
                local _queue_depth=0
                [[ -f "${DIR}/brain/state/queue_${session_id}" ]] && _queue_depth=$(wc -l < "${DIR}/brain/state/queue_${session_id}" 2>/dev/null || echo 0)
                # Model override
                local _cur_model="${MODEL:-unknown}"
                [[ -f "${DIR}/brain/state/model_${session_id}" ]] && _cur_model="$(cat "${DIR}/brain/state/model_${session_id}")* (override)"
                local _sysinfo=$(bash tools/sys_info.sh 2>/dev/null || true)
                tg_send "$chat_id" "<b>Status</b>
<b>Session:</b> <code>$session_id</code> (${_sess_age}, ${_msg_count} msgs)
<b>Title:</b> ${_title}
<b>Provider:</b> ${PROVIDER:-default}  <b>Model:</b> <code>${_cur_model}</code>
<b>Skill:</b> ${skill:-none}  <b>Type:</b> $chat_type
<b>Active agents:</b> ${_active_agents}  <b>Queued:</b> ${_queue_depth}
<b>User:</b> ${username:-$user_id}

${_sysinfo}" "$thread_id" "HTML"
                ;;
            /skills|/skill)
                local sname=$(echo "$args" | awk '{print $1}')
                if [[ -z "$sname" ]]; then
                    # List all available skills from core + brain
                    local _skill_list
                    _skill_list=$(python3 -c "
import os, json
roots = [('core/skills', 'core'), ('brain/skills', 'user')]
lines = []
for root, label in roots:
    if not os.path.isdir(root): continue
    for name in sorted(os.listdir(root)):
        if os.path.isdir(os.path.join(root, name)):
            lines.append(f'• <b>{name}</b> ({label})')
print('\n'.join(lines) if lines else '  (none)')
" 2>/dev/null)
                    local msg="<b>Available Skills</b>
${_skill_list}

Active: <code>${skill:-none}</code>

Use <code>/skill &lt;name&gt;</code> to activate.
Use <code>/skill off</code> to clear."
                    tg_send "$chat_id" "$msg" "$thread_id" "HTML"
                elif [[ "$sname" == "off" || "$sname" == "none" ]]; then
                    set_topic_config "$chat_id" "$thread_id" "skill" ""
                    tg_send "$chat_id" "Skill cleared. Running in default mode." "$thread_id" "HTML"
                else
                    # Validate skill exists
                    if [[ -d "core/skills/$sname" || -d "brain/skills/$sname" ]]; then
                        set_topic_config "$chat_id" "$thread_id" "skill" "$sname"
                        tg_send "$chat_id" "Skill set to: <code>$sname</code>" "$thread_id" "HTML"
                    else
                        tg_send "$chat_id" "Skill '<code>$sname</code>' not found. Use /skills to list available skills." "$thread_id" "HTML"
                    fi
                fi
                ;;
            /insights)
                local report=$(bash tools/insights.sh)
                tg_send "$chat_id" "$report" "$thread_id"
                ;;

            /history)
                # Show last N conversation turns (hermes /history pattern)
                local _hist_file="${DIR}/brain/state/history_${session_id}.json"
                local _n_arg=$(echo "$args" | awk '{print $1}')
                local _n="${_n_arg:-20}"
                if [[ ! -f "$_hist_file" ]]; then
                    tg_send "$chat_id" "No history for this session." "$thread_id"
                else
                    local _hist_out
                    _hist_out=$(N="$_n" python3 -c "
import json, os, sys
h = json.load(open('$_hist_file'))
n = int(os.environ.get('N','20'))
lines = []
for msg in h[-n:]:
    role = msg.get('role','?')
    c = msg.get('content','')
    if role == 'tool':
        lines.append('🔧 <code>' + (msg.get('name','tool'))[:20] + ': ' + str(c)[:80].replace('<','&lt;').replace('>','&gt;') + '</code>')
    elif role == 'assistant':
        if msg.get('tool_calls'):
            names = ', '.join(t.get('function',{}).get('name','?') for t in msg['tool_calls'])
            lines.append('<b>assistant:</b> [→ ' + names[:80] + ']')
        elif c:
            text = str(c)[:150].replace('<','&lt;').replace('>','&gt;')
            lines.append('<b>assistant:</b> ' + text + ('…' if len(str(c))>150 else ''))
    elif role == 'user':
        if isinstance(c, list): c = ' '.join(p.get('text','') for p in c if isinstance(p,dict))
        c = str(c)
        if '[SYSTEM:' not in c and len(c.strip()) > 0:
            lines.append('<b>you:</b> ' + c[:150].replace('<','&lt;').replace('>','&gt;') + ('…' if len(c)>150 else ''))
total = len(h)
print(f'<b>History</b> (last {min(n,len(lines))} of {total} messages)\n\n' + '\n'.join(lines[-10:]) if lines else 'Session has no visible turns yet.')
" 2>/dev/null || echo "Could not read history.")
                    tg_send "$chat_id" "$_hist_out" "$thread_id" "HTML"
                fi
                ;;

            /topic)
                # Name this thread/topic and optionally bind a skill to it (hermes topic binding)
                local _tname=$(echo "$args" | sed 's/^[[:space:]]*//' | cut -d' ' -f1-)
                if [[ -z "$_tname" ]]; then
                    local _cur_topic
                    _cur_topic=$(get_topic_config "$chat_id" "$thread_id")
                    local _tname_cur; _tname_cur=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('name',''))" "$_cur_topic" 2>/dev/null)
                    local _tskill_cur; _tskill_cur=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('skill',''))" "$_cur_topic" 2>/dev/null)
                    tg_send "$chat_id" "Topic: <b>${_tname_cur:-unnamed}</b>  Skill: <code>${_tskill_cur:-none}</code>

Use <code>/topic &lt;name&gt;</code> to name this thread.
Use <code>/skill &lt;name&gt;</code> to bind a skill." "$thread_id" "HTML"
                else
                    set_topic_config "$chat_id" "$thread_id" "name" "$_tname"
                    tg_send "$chat_id" "📌 Topic named: <b>${_tname}</b>" "$thread_id" "HTML"
                fi
                ;;
            /stop)
                kill_tree() {
                    local _pid=$1
                    local _pids="$_pid"
                    get_children() {
                        local _parent=$1
                        for _child in $(pgrep -P "$_parent" 2>/dev/null); do
                            _pids="$_pids $_child"
                            get_children "$_child"
                        done
                    }
                    get_children "$_pid"
                    kill -TERM $_pids 2>/dev/null || true
                }
                local _stop_args=$(echo "$args" | awk '{print $1}')
                if [[ "$_stop_args" == "all" ]]; then
                    # /stop all — kill every running session + flag all queued ones
                    local _stopped=0
                    for _pf in "${DIR}/brain/state"/run_*.pid; do
                        [[ -f "$_pf" ]] || continue
                        # Derive session_id from filename: run_<session_id>.pid
                        local _sf="${_pf%.pid}"
                        _sf="${_sf##*/run_}"
                        # Set stop flag so any queued process for this session exits too
                        touch "${DIR}/brain/state/stop_${_sf}" 2>/dev/null || true
                        rm -f "${DIR}/brain/state/queue_${_sf}" 2>/dev/null || true
                        local _pf_data; _pf_data=$(cat "$_pf" 2>/dev/null) || continue
                        local _ppid _pmsg _pchat _pthread
                        IFS='|' read -r _ppid _pmsg _pchat _pthread <<< "$_pf_data"
                        if kill -0 "$_ppid" 2>/dev/null; then
                            kill_tree "$_ppid"
                            if [[ -n "$_pmsg" && "$_pmsg" != "pending" && -n "$_pchat" ]]; then
                                tg_edit "$_pchat" "$_pmsg" "🛑 <i>Stopped.</i>" "HTML" > /dev/null 2>&1 || true
                            fi
                            _stopped=$((_stopped + 1))
                        fi
                        rm -f "$_pf"
                    done
                    # Also clear any orphaned queues
                    rm -f "${DIR}/brain/state"/queue_* 2>/dev/null || true
                    if [[ "$_stopped" -gt 0 ]]; then
                        tg_send "$chat_id" "🛑 Stopped $_stopped running task(s)." "$thread_id"
                    else
                        tg_send "$chat_id" "No active tasks to stop." "$thread_id"
                    fi
                else
                    # /stop — kill this session only
                    local pid_file="${DIR}/brain/state/run_${session_id}.pid"
                    local stop_flag="${DIR}/brain/state/stop_${session_id}"
                    # Always set stop flag first — catches queued processes that get the
                    # lock AFTER we kill the running one (they check the flag and exit)
                    touch "$stop_flag"
                    rm -f "${DIR}/brain/state/queue_${session_id}" 2>/dev/null || true
                    if [[ -f "$pid_file" ]]; then
                        local _pid_data; _pid_data=$(cat "$pid_file" 2>/dev/null)
                        local run_pid _msg_id _orig_chat _orig_thread
                        IFS='|' read -r run_pid _msg_id _orig_chat _orig_thread <<< "$_pid_data"
                        echo "AMA: Stopping session $session_id (PID $run_pid)"
                        # Kill the agent process tree (NOT its process group, which would kill bot.sh)
                        kill_tree "$run_pid"
                        rm -f "$pid_file"
                        # Edit the dangling "Thinking…" or "Working…" bot message
                        if [[ -n "$_msg_id" && "$_msg_id" != "pending" ]]; then
                            tg_edit "${_orig_chat:-$chat_id}" "$_msg_id" "🛑 <i>Stopped.</i>" "HTML" > /dev/null 2>&1 || true
                        fi
                        tg_send "$chat_id" "🛑 Task stopped." "$thread_id"
                    else
                        # No running process — but we set the stop flag above, which will
                        # catch any queued process when it tries to acquire the lock
                        tg_send "$chat_id" "🛑 Stopped (was queued)." "$thread_id"
                    fi
                fi
                ;;
            /shutdown)
                if [[ "$user_id" == "${TG_ADMIN}" ]]; then
                    tg_send "$chat_id" "Shutting down bot. Goodbye." "$thread_id"
                    local _bot_pid
                    _bot_pid=$(cat "${DIR}/brain/state/bot.pid" 2>/dev/null)
                    rm -f "${DIR}/brain/state/bot.pid"
                    [[ -n "$_bot_pid" ]] && kill -TERM "$_bot_pid" 2>/dev/null
                    kill -TERM "$$" 2>/dev/null
                    exit 0
                else
                    tg_send "$chat_id" "Admin only." "$thread_id"
                fi
                ;;
            /restart)
                if [[ "$user_id" == "${TG_ADMIN}" ]]; then
                    tg_send "$chat_id" "Restarting via pm2... be right back." "$thread_id"
                    # If running under pm2, let it handle the restart
                    if pm2 restart ama-bot >> "${DIR}/logs/bot.log" 2>&1; then
                        exit 0
                    fi
                    # Fallback: not under pm2 — manual restart
                    nohup bash "${DIR}/bot.sh" >> "${DIR}/logs/bot.log" 2>&1 &
                    local _bot_pid
                    _bot_pid=$(cat "${DIR}/brain/state/bot.pid" 2>/dev/null)
                    sleep 1
                    rm -f "${DIR}/brain/state/bot.pid"
                    if [[ -n "$_bot_pid" ]]; then
                        kill -TERM "-$_bot_pid" 2>/dev/null || kill -TERM "$_bot_pid" 2>/dev/null
                    fi
                    kill -TERM "$$" 2>/dev/null
                    exit 0
                else
                    tg_send "$chat_id" "Admin only." "$thread_id"
                fi
                ;;
            /login)
                if [[ "${PROVIDER}" == "copilot" ]]; then
                    copilot_login "$chat_id" # Copilot login usually happens in DM anyway
                else
                    tg_send "$chat_id" "Provider is not set to copilot." "$thread_id"
                fi
                ;;
            *)
                # Pass unknown commands to agent
                ( set -m; run_agent "$chat_id" "$text" "$user_id" "$media_json" "$thread_id" "$session_id" "$chat_title" "$username" "$skill" "$message_id" ) &
                ;;
        esac
    else
        # Normal text -> Run Agent (pass message_id for reply-to threading)
        ( set -m; run_agent "$chat_id" "$text" "$user_id" "$media_json" "$thread_id" "$session_id" "$chat_title" "$username" "$skill" "$message_id" ) &
    fi
}
