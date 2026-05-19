#!/bin/bash
# core/telegram/router.sh - Command routing

_ama_handle_callback() {
    local cbq_id="$1"
    local data="$2"
    local chat_id="$3"
    local session_id="$4"
    local thread_id="$5"
    local user_id="$6"
    local username="$7"
    local btn_msg_id="$8"   # message_id of the message that had the button

    tg_answer_callback "$cbq_id"

    case "$data" in
        stop:*)
            local _sid="${data#stop:}"
            local _pid_file="${DIR}/brain/state/run_${_sid}.pid"
            local _stop_flag="${DIR}/brain/state/stop_${_sid}"
            local _stop_btn_file="${DIR}/brain/state/stopbtn_${_sid}"  # legacy

            touch "$_stop_flag"
            rm -f "${DIR}/brain/state/queue_${_sid}" \
                  "${DIR}/brain/state/interrupt_input_${_sid}" 2>/dev/null || true

            if [[ -f "$_pid_file" ]]; then
                local _pid_data; _pid_data=$(cat "$_pid_file" 2>/dev/null)
                local _run_pid _agent_msg_id _orig_chat _orig_thread _uid _worker_pid
                IFS='|' read -r _run_pid _agent_msg_id _orig_chat _orig_thread _uid _worker_pid <<< "$_pid_data"
                kill -TERM "$_run_pid" 2>/dev/null || true
                [[ -n "$_worker_pid" ]] && kill -TERM "$_worker_pid" 2>/dev/null || true
                sleep 0.3
                pkill -TERM -P "$_run_pid" 2>/dev/null || true
                [[ -n "$_worker_pid" ]] && pkill -TERM -P "$_worker_pid" 2>/dev/null || true
                rm -f "$_pid_file"
                [[ -n "$_agent_msg_id" && -n "$_orig_chat" ]] && \
                    tg_edit "$_orig_chat" "$_agent_msg_id" "🛑 <i>Stopped.</i>" "HTML" > /dev/null 2>&1 || true
            fi
            # Stop button now lives on the agent's main message → just strip buttons,
            # don't delete the message (the "Stopped" edit above is the visible state).
            [[ -n "$btn_msg_id" ]] && tg_remove_buttons "$chat_id" "$btn_msg_id" > /dev/null 2>&1 || true
            rm -f "$_stop_btn_file"
            ;;

        interrupt:*)
            local _sid="${data#interrupt:}"
            local _pending_file="${DIR}/brain/state/interrupt_input_${_sid}"
            local _run_marker="${DIR}/brain/state/interrupt_run_${_sid}"

            # Read but do NOT delete pending file yet — the queued agent (B) needs it
            # to detect this is an interrupt (not a genuine /stop) and take over directly.
            local _pending_text; _pending_text=$(cat "$_pending_file" 2>/dev/null)
            [[ -z "$_pending_text" ]] && return  # stale button, already answered

            # Remove Interrupt button from the queued message
            [[ -n "$btn_msg_id" ]] && tg_remove_buttons "$chat_id" "$btn_msg_id" 2>/dev/null || true

            # Stop the running agent A
            local _pid_file="${DIR}/brain/state/run_${_sid}.pid"
            local _stop_flag="${DIR}/brain/state/stop_${_sid}"
            local _stop_btn_file="${DIR}/brain/state/stopbtn_${_sid}"

            touch "$_stop_flag"
            if [[ -f "$_pid_file" ]]; then
                local _pid_data; _pid_data=$(cat "$_pid_file" 2>/dev/null)
                local _run_pid _agent_msg_id _orig_chat _orig_thread
                IFS='|' read -r _run_pid _agent_msg_id _orig_chat _orig_thread <<< "$_pid_data"
                kill -TERM "$_run_pid" 2>/dev/null || true
                sleep 0.3
                pkill -TERM -P "$_run_pid" 2>/dev/null || true
                rm -f "$_pid_file"
                [[ -n "$_agent_msg_id" && -n "$_orig_chat" ]] && \
                    tg_edit "$_orig_chat" "$_agent_msg_id" "🛑 <i>Stopped.</i>" "HTML" > /dev/null 2>&1 || true
            fi
            _sbid=$(cat "$_stop_btn_file" 2>/dev/null)
            [[ -n "$_sbid" ]] && tg_delete "$chat_id" "$_sbid" > /dev/null 2>&1 || true
            rm -f "$_stop_btn_file"

            # Mark that a C fallback is planned.
            # If queued agent B exists: B detects interrupt_input_file, deletes this marker,
            # and runs the message directly without needing C.
            # If no B exists: C starts after lock clears as the sole runner.
            touch "$_run_marker"
            (
                sleep 2
                rm -f "$_stop_flag"
                if [[ -f "$_run_marker" ]]; then
                    rm -f "$_run_marker" "$_pending_file"
                    ( set -m; run_agent "$chat_id" "$_pending_text" "$user_id" "[]" \
                        "$thread_id" "$_sid" "" "${username:-}" "" "$btn_msg_id" ) &
                fi
            ) &
            ;;
    esac
}

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

# Reply-to: capture the original message's ID, author, and text so the LLM
# can see what specific message the user is responding to. Without this, a
# reply to an older message looks identical to a normal continuation turn
# and the LLM misattributes context.
reply_to_msg = msg.get('reply_to_message') or {}
reply_to_id = str(reply_to_msg.get('message_id', '') or '')
reply_to_text = ''
reply_to_author = ''
if reply_to_msg:
    reply_to_text = str(reply_to_msg.get('text', '') or reply_to_msg.get('caption', '') or '')
    # Truncate to keep context_prompt small. If it was a long bot message,
    # the full text is already in history anyway.
    if len(reply_to_text) > 400:
        reply_to_text = reply_to_text[:400] + ' …'
    _rf = reply_to_msg.get('from') or {}
    if _rf.get('is_bot'):
        reply_to_author = 'Bot'
    else:
        reply_to_author = _rf.get('first_name') or _rf.get('username') or 'User'

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
    'reply_to_text': reply_to_text,
    'reply_to_author': reply_to_author,
    'is_mention':    '1' if is_mention else '0',
    'is_reply_to_bot': '1' if is_reply_to_bot else '0',
    'media_group_id': media_group_id,
    'callback_query_id': str(cbq.get('id', '') or ''),
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
        # Strip the [type] suffix for cleaner context, keep full path
        local _mf_path; _mf_path=$(echo "$media_file" | sed 's/ \[.*\]$//')
        local _mf_type; _mf_type=$(echo "$media_file" | grep -oP '\[\K[^\]]+' || true)
        text="$text

[User attached file: ${_mf_path}]
Read it with bash: cat \"${_mf_path}\" | head -200
For PDFs: pdftotext \"${_mf_path}\" - | head -200
For code/text: cat \"${_mf_path}\""
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

    # Callback query (inline button click) — route before group-mode gate
    if [[ -n "$callback_query_id" ]]; then
        _ama_handle_callback "$callback_query_id" "$text" "$chat_id" "$session_id" \
            "$thread_id" "$user_id" "$username" "$message_id"
        return
    fi

    # Per-group mode gate
    # Mode resolved: per-group setting > REQUIRE_MENTION env fallback > active
    # Modes: active (reply all) | mention_only (reply only @mention/reply) | silent (never reply)
    local _group_mode="active"
    if [[ "$chat_type" != "private" ]]; then
        _group_mode=$(get_group_mode "$chat_id")
        # If no per-group setting, fall back to global REQUIRE_MENTION env var
        if [[ "$_group_mode" == "active" && "${REQUIRE_MENTION:-0}" == "1" ]]; then
            _group_mode="mention_only"
        fi
    fi

    # Determine whether to respond — slash commands always pass through
    local _should_respond=true
    if [[ "$chat_type" != "private" && "$text" != /* ]]; then
        case "$_group_mode" in
            mention_only)
                if [[ "$is_mention" != "1" && "$is_reply_to_bot" != "1" ]]; then
                    _should_respond=false
                fi
                ;;
            silent)
                _should_respond=false
                ;;
        esac
    fi

    # Passive context: when not responding, save message to a rolling buffer
    # so the agent has context when it IS eventually mentioned/called
    if [[ "$_should_respond" == "false" ]]; then
        local _passive_file="${DIR}/brain/state/passive_${session_id}.jsonl"
        python3 -c "
import json, sys, time
entry = {'ts': time.time(), 'user': sys.argv[1], 'text': sys.argv[2]}
path = sys.argv[3]
with open(path, 'a') as f:
    f.write(json.dumps(entry, ensure_ascii=False) + '\n')
lines = open(path).readlines()
if len(lines) > 40:
    open(path, 'w').writelines(lines[-40:])
" "${username:-$user_id}" "$text" "$_passive_file" 2>/dev/null || true
        return
    fi

    # When responding in mention_only mode: inject recent passive context so agent
    # knows what was discussed before it was called
    if [[ "$chat_type" != "private" && "$_group_mode" == "mention_only" ]]; then
        local _passive_file="${DIR}/brain/state/passive_${session_id}.jsonl"
        if [[ -f "$_passive_file" && -s "$_passive_file" ]]; then
            local _pctx
            _pctx=$(python3 -c "
import json, sys
lines = open(sys.argv[1]).readlines()[-20:]
entries = []
for l in lines:
    try:
        e = json.loads(l)
        entries.append(f\"{e.get('user','?')}: {e.get('text','').strip()}\")
    except: pass
print('\n'.join(entries))
" "$_passive_file" 2>/dev/null)
            if [[ -n "$_pctx" ]]; then
                text="[Recent group messages before you were mentioned — for context only, do NOT re-answer these]
${_pctx}
[End context]

${text}"
            fi
            rm -f "$_passive_file"
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
    local _topic_skill=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('skill','') or '')" "$topic_cfg" 2>/dev/null)
    local skill="$_topic_skill"
    if [[ -z "$skill" ]] && [[ "$text" =~ ([[:space:]]|^)[Aa][Mm][Aa]([[:space:]]|$) || "$text" =~ "autonomous-agent" ]]; then
        skill="ama"
    fi

    # Active-skill persistence: if a previous turn in this session routed to a
    # different skill, prefer continuing with it. The topic skill is just the
    # *default* — a session can drift to a different skill mid-conversation, and
    # short follow-ups ("did you do it?", "thanks", "more details") shouldn't
    # snap back to the default and lose context.
    local _active_skill_file="${DIR}/brain/state/active_skill_${session_id}"
    local _active_skill=""
    [[ -f "$_active_skill_file" ]] && _active_skill=$(cat "$_active_skill_file" 2>/dev/null)
    if [[ -n "$_active_skill" ]]; then
        skill="$_active_skill"
    fi

    # Keyword-based skill auto-router (skip for slash commands).
    # Only overrides when the new message strongly matches a DIFFERENT skill.
    if [[ "$text" != /* ]] && [[ -n "$text" ]]; then
        local _routed
        _routed=$(printf '%s' "$text" | python3 "${DIR}/tools/skill_router.py" route "$skill" 2>/dev/null)
        if [[ -n "$_routed" ]]; then
            skill="$_routed"
        fi
    fi

    # Persist the chosen skill for the next turn (only if non-empty and not a slash command)
    if [[ "$text" != /* ]] && [[ -n "$skill" ]]; then
        mkdir -p "$(dirname "$_active_skill_file")"
        printf '%s' "$skill" > "$_active_skill_file" 2>/dev/null || true
    fi

    # Goal auto-pause: if a goal loop is active and the user sends a non-/goal
    # message, pause the loop so the user's message takes precedence.
    # User can resume with /goal resume.
    if [[ "$text" != /goal* ]] && [[ "$text" != /* ]] && [[ -n "$text" ]]; then
        local _gfile="${DIR}/brain/state/goal_${session_id}.json"
        if [[ -f "$_gfile" ]]; then
            local _gstatus; _gstatus=$(python3 -c "
import json,sys
try: print(json.load(open(sys.argv[1])).get('status',''))
except: pass" "$_gfile" 2>/dev/null)
            if [[ "$_gstatus" == "active" ]]; then
                python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
d['status']='paused'
open(sys.argv[1],'w').write(json.dumps(d, separators=(',',':')))" "$_gfile" 2>/dev/null || true
                tg_send "$chat_id" "⏸ <i>Goal auto-paused — your message takes priority. <code>/goal resume</code> to continue.</i>" "$thread_id" "HTML"
            fi
        fi
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
/btw &lt;question&gt; — ephemeral side question, doesn't interrupt or persist
/goal &lt;prose&gt; — autonomous goal loop (judge decides done each turn); /goal status|stop|pause|resume|max
/schedule add every=12h "..." [model=X] — recurring task; /schedule list|remove|pause|resume

<b>Config</b>
/model &lt;name&gt; — switch model this session
/skill &lt;name&gt; — activate a skill • /skill off to clear
/skills — list available skills
/providers — show all providers (main + pool) with status
/models — list available models • /models &lt;name&gt; to switch
/group mode [active|mention_only|silent] — per-group reply behaviour (admin, groups only)
/google_login — connect Google account (OAuth, free tier)
/google_login_callback &lt;url&gt; — complete Google login

<b>Info</b>
/status — model, session, system info
/usage — token usage this session
/insights — token + tool frequency stats

<b>Admin</b>
/whitelist &lt;id&gt; — add user/chat
/reload — hot-reload core files (no restart, in-place)
/restart — full restart via pm2
/shutdown — shut down bot" "$thread_id" "HTML"
                ;;
            /whitelist)
                local target_id=$(echo "$args" | awk '{print $1}')
                if [[ "$user_id" == "${TG_ADMIN}" && -n "$target_id" ]]; then
                    add_to_whitelist "$target_id"
                    # Mirror to the audit log so /access_log + access_control(action=log)
                    # see admin additions too, not just agent-tool calls.
                    printf '%s|whitelist|%s|by:admin:%s\n' \
                        "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$target_id" "$user_id" \
                        >> "${DIR}/brain/state/access_control.log"
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
                      "${DIR}/brain/state/queue_${session_id}" \
                      "${DIR}/brain/state/active_skill_${session_id}" \
                      "${DIR}/brain/state/prefetch_${session_id}" \
                      "${DIR}/brain/state/goal_${session_id}.json" 2>/dev/null || true
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

            /providers)
                local _pool_status
                _pool_status=$(pool_status_html 2>/dev/null)
                if [[ -z "$_pool_status" ]]; then
                    tg_send "$chat_id" "No providers configured.

Copy <code>brain/provider_pool.json.example</code> to <code>brain/provider_pool.json</code> and fill in your keys." "$thread_id" "HTML"
                else
                    tg_send "$chat_id" "$_pool_status" "$thread_id" "HTML"
                fi
                ;;

            /models)
                # List available models for each provider, or switch model
                local _models_arg="$args"
                if [[ -n "$_models_arg" ]]; then
                    # Switch model — store as session override
                    mkdir -p "${DIR}/brain/state"
                    printf '%s' "$_models_arg" > "${DIR}/brain/state/model_${session_id}"
                    tg_send "$chat_id" "✅ Model switched to <code>${_models_arg}</code> for this session.
Use <code>/model default</code> to reset." "$thread_id" "HTML"
                else
                    # List available models per provider
                    local _cur_model="${MODEL:-?}"
                    [[ -f "${DIR}/brain/state/model_${session_id}" ]] && _cur_model=$(cat "${DIR}/brain/state/model_${session_id}" 2>/dev/null)
                    local _cur_provider="${PROVIDER:-default}"
                    local _cloudcode_models=""
                    if [[ -f "${DIR}/tools/google_oauth.py" ]]; then
                        _cloudcode_models=$(python3 "${DIR}/tools/google_oauth.py" quota 2>/dev/null | grep -oP '^\s+\K\S+(?=\s+█)' | head -10 | tr '\n' ' ')
                    fi
                    tg_send "$chat_id" "<b>Current:</b> <code>${_cur_provider}/${_cur_model}</code>

<b>Switch:</b> <code>/models &lt;model-name&gt;</code>

<b>Google (Vertex / main):</b>
• <code>gemini-3-flash-preview</code>
• <code>gemini-2.5-pro</code>
• <code>gemini-2.0-flash-exp</code>

<b>Google OAuth (Code Assist):</b>
${_cloudcode_models:+$(echo "$_cloudcode_models" | tr ' ' '\n' | sed 's/^/• <code>/;s/$/<\/code>/' | head -7 | tr '\n' '\n')}

<b>DeepSeek:</b>  <code>deepseek-chat</code>  <code>deepseek-reasoner</code>
<b>Groq:</b>      <code>llama-3.3-70b-versatile</code>  <code>gemma2-9b-it</code>
<b>Mistral:</b>   <code>mistral-large-latest</code>  <code>codestral-latest</code>
<b>ZAI:</b>       <code>glm-4-plus</code>  <code>glm-4-flash</code>
<b>MiniMax:</b>   <code>MiniMax-M1</code>
<b>OpenRouter:</b> <code>/models openrouter/MODEL_SLUG</code>

<i>Provider pool entries are managed via /providers</i>" "$thread_id" "HTML"
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

            /btw)
                # Ephemeral side-question — uses current session as background,
                # doesn't write to history, no tools, no thinking. Runs in a
                # detached subshell so it doesn't block other commands.
                ( ( btw_command "$chat_id" "$thread_id" "$session_id" "$args" "${message_id:-0}" ) & )
                ;;

            /schedule|/sched)
                # Thin wrapper around tools/scheduler.sh — same path as the
                # `scheduler` tool the agent uses, so chat-driven and
                # slash-driven scheduling stay in sync.
                #
                # Forms:
                #   /schedule list
                #   /schedule remove <id>
                #   /schedule pause <id>   /schedule resume <id>
                #   /schedule add every=12h "<prompt>" [model=X] [provider=Y] [skill=Z]
                #   /schedule every 12h "<prompt>" [model=X]  (shorthand: defaults to add)
                local _sub="${args%% *}"
                local _rest="${args#* }"; [[ "$_rest" == "$args" ]] && _rest=""
                case "$_sub" in
                    "" )
                        tg_send "$chat_id" "Usage:
<code>/schedule list</code>
<code>/schedule add every=12h \"prompt\" [model=X] [provider=Y]</code>
<code>/schedule remove &lt;id&gt;</code>
<code>/schedule pause &lt;id&gt;</code> / <code>/schedule resume &lt;id&gt;</code>

You can also just chat: \"<i>ama, every 12h summarize my transactions with koompi-free</i>\"" "$thread_id" "HTML"
                        ;;
                    list)
                        local _out
                        _out=$(TOOL_action=list TOOL_chat_id="$chat_id" bash "${DIR}/tools/scheduler.sh" 2>&1)
                        tg_send "$chat_id" "<pre>${_out}</pre>" "$thread_id" "HTML"
                        ;;
                    remove|delete|pause|resume)
                        local _id="${_rest%% *}"
                        local _out
                        _out=$(TOOL_action="$_sub" TOOL_id="$_id" bash "${DIR}/tools/scheduler.sh" 2>&1)
                        tg_send "$chat_id" "$_out" "$thread_id"
                        ;;
                    add|*)
                        # Parse key=val pairs + the quoted prompt.
                        # Skip leading "add" if present.
                        local _arg_str="$args"
                        [[ "$_sub" == "add" ]] && _arg_str="$_rest"
                        local _every="" _prompt="" _model="" _provider="" _skill=""
                        # Extract key=val tokens (no quotes)
                        for _kv in $(echo "$_arg_str" | grep -oE '[a-z_]+=[^ "]+'); do
                            local _k="${_kv%%=*}" _v="${_kv#*=}"
                            case "$_k" in
                                every)    _every="$_v" ;;
                                model)    _model="$_v" ;;
                                provider) _provider="$_v" ;;
                                skill)    _skill="$_v" ;;
                            esac
                        done
                        # Extract quoted prompt — first "..." in the arg string
                        _prompt=$(echo "$_arg_str" | python3 -c "
import sys, re
s = sys.stdin.read()
m = re.search(r'\"([^\"]+)\"', s)
print(m.group(1) if m else '')")
                        # Fallback: if no quoted prompt, use everything after the kvs
                        if [[ -z "$_prompt" ]]; then
                            _prompt=$(echo "$_arg_str" | sed -E 's/[a-z_]+=[^ ]+//g' | xargs)
                        fi
                        if [[ -z "$_every" || -z "$_prompt" ]]; then
                            tg_send "$chat_id" "Need both <code>every=&lt;duration&gt;</code> and a quoted prompt. Example:\n<code>/schedule add every=12h \"summarize today's transactions\" model=koompi-free</code>" "$thread_id" "HTML"
                        else
                            local _out
                            _out=$(TOOL_action=add TOOL_every="$_every" TOOL_prompt="$_prompt" \
                                   TOOL_model="$_model" TOOL_provider="$_provider" TOOL_skill="$_skill" \
                                   TOOL_chat_id="$chat_id" TOOL_thread_id="$thread_id" \
                                   bash "${DIR}/tools/scheduler.sh" 2>&1)
                            tg_send "$chat_id" "<pre>${_out}</pre>" "$thread_id" "HTML"
                        fi
                        ;;
                esac
                ;;

            /goal)
                # Autonomous goal-loop: agent runs the goal turn-by-turn, judge
                # decides done/continue after each turn (hermes /goal pattern).
                local _goal_sub="${args%% *}"
                local _goal_rest="${args#* }"; [[ "$_goal_rest" == "$args" ]] && _goal_rest=""
                local _goal_file_path="${DIR}/brain/state/goal_${session_id}.json"
                case "$_goal_sub" in
                    "" )
                        tg_send "$chat_id" "Usage:
<code>/goal &lt;prose&gt;</code> — set + run an autonomous goal
<code>/goal status</code> — show current goal
<code>/goal stop</code> — clear goal, stop looping
<code>/goal pause</code> / <code>/goal resume</code> — toggle the loop
<code>/goal max &lt;n&gt;</code> — change max turns (default 20)" "$thread_id" "HTML"
                        ;;
                    status)
                        local _status_html
                        _status_html=$(goal_status_html "$session_id" 2>/dev/null)
                        tg_send "$chat_id" "${_status_html:-<i>No goal set.</i>}" "$thread_id" "HTML"
                        ;;
                    stop|done|clear|reset)
                        if [[ -f "$_goal_file_path" ]]; then
                            rm -f "$_goal_file_path"
                            tg_send "$chat_id" "🛑 Goal cleared." "$thread_id"
                        else
                            tg_send "$chat_id" "<i>No active goal.</i>" "$thread_id" "HTML"
                        fi
                        ;;
                    pause)
                        if [[ -f "$_goal_file_path" ]]; then
                            goal_set "$session_id" status=paused
                            tg_send "$chat_id" "⏸ Goal paused. Use <code>/goal resume</code> to continue." "$thread_id" "HTML"
                        else
                            tg_send "$chat_id" "<i>No active goal.</i>" "$thread_id" "HTML"
                        fi
                        ;;
                    resume)
                        if [[ -f "$_goal_file_path" ]]; then
                            goal_set "$session_id" status=active
                            # Kick the loop by queueing the goal text now
                            local _gtext; _gtext=$(goal_field "$session_id" text "")
                            if [[ -n "$_gtext" ]]; then
                                printf '%s\n' "[GOAL RESUME] ${_gtext}" >> "${DIR}/brain/state/queue_${session_id}"
                                tg_send "$chat_id" "▶ Goal resumed." "$thread_id"
                                # Trigger run_agent so the queue gets consumed even when idle
                                ( set -m; run_agent "$chat_id" "[GOAL RESUME] ${_gtext}" "$user_id" "[]" "$thread_id" "$session_id" "$chat_title" "$username" "$skill" "0" ) &
                                # Pop the line we just added since we're handling it directly
                                sed -i '$d' "${DIR}/brain/state/queue_${session_id}" 2>/dev/null || true
                            else
                                tg_send "$chat_id" "⚠️ Goal has no text. Set a new one with <code>/goal &lt;prose&gt;</code>." "$thread_id" "HTML"
                            fi
                        else
                            tg_send "$chat_id" "<i>No paused goal to resume.</i>" "$thread_id" "HTML"
                        fi
                        ;;
                    max)
                        local _n="${_goal_rest%% *}"
                        if [[ -f "$_goal_file_path" && "$_n" =~ ^[0-9]+$ ]]; then
                            goal_set "$session_id" max_turns="$_n"
                            tg_send "$chat_id" "🎯 Max turns set to $_n." "$thread_id"
                        else
                            tg_send "$chat_id" "Usage: <code>/goal max &lt;n&gt;</code> while a goal is active." "$thread_id" "HTML"
                        fi
                        ;;
                    *)
                        # Treat as the goal text itself.
                        local _gtext="$args"
                        goal_create "$session_id" "$_gtext"
                        tg_send "$chat_id" "🎯 Goal set: <code>${_gtext}</code>\nMax turns: $(goal_field "$session_id" max_turns 20). Working on it…" "$thread_id" "HTML"
                        # Fire run_agent immediately on the goal text
                        ( set -m; run_agent "$chat_id" "$_gtext" "$user_id" "[]" "$thread_id" "$session_id" "$chat_title" "$username" "$skill" "${message_id:-0}" ) &
                        ;;
                esac
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
                local _active_agents=0
                for _pf in "${DIR}/brain/state"/run_*.pid; do
                    [[ -f "$_pf" ]] || continue
                    _ppid=$(cut -d'|' -f1 "$_pf" 2>/dev/null)
                    kill -0 "$_ppid" 2>/dev/null && _active_agents=$((_active_agents+1))
                done
                local _queue_depth=0
                [[ -f "${DIR}/brain/state/queue_${session_id}" ]] && _queue_depth=$(wc -l < "${DIR}/brain/state/queue_${session_id}" 2>/dev/null || echo 0)
                # Delegate tmux sessions
                local _delegate_info=""
                _delegate_info=$(python3 -c "
import os, json, time
from pathlib import Path
state = Path('${DIR}/brain/state')
lines = []
for meta_f in sorted(state.glob('delegate_ama_*.meta')):
    session = meta_f.stem.replace('delegate_', '')
    try:
        m = json.loads(meta_f.read_text())
        elapsed = round(time.time() - m.get('started_at', time.time()))
        goal = m.get('goal','?')[:40]
        done_f = state / f'delegate_{session}.done'
        if done_f.exists():
            status = '✅' if done_f.read_text().strip() == '0' else '❌'
        else:
            import subprocess
            alive = subprocess.run(['tmux','has-session','-t',session],
                                   capture_output=True).returncode == 0
            status = '⏳' if alive else '💥'
        lines.append(f'  {status} <code>{session}</code> ({elapsed}s) — {goal}')
    except Exception:
        pass
print('\n'.join(lines) if lines else '')
" 2>/dev/null)
                # Model override
                local _cur_model="${MODEL:-unknown}"
                [[ -f "${DIR}/brain/state/model_${session_id}" ]] && _cur_model="$(cat "${DIR}/brain/state/model_${session_id}")* (override)"
                local _sysinfo=$(bash tools/sys_info.sh 2>/dev/null || true)
                local _delegate_block=""
                [[ -n "$_delegate_info" ]] && _delegate_block="
<b>Delegate tasks:</b>
${_delegate_info}"
                tg_send "$chat_id" "<b>Status</b>
<b>Session:</b> <code>$session_id</code> (${_sess_age}, ${_msg_count} msgs)
<b>Title:</b> ${_title}
<b>Provider:</b> ${PROVIDER:-default}  <b>Model:</b> <code>${_cur_model}</code>
<b>Skill:</b> ${skill:-none}  <b>Type:</b> $chat_type
<b>Active agents:</b> ${_active_agents}  <b>Queued:</b> ${_queue_depth}
<b>User:</b> ${username:-$user_id}${_delegate_block}

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

            /group)
                if [[ "$chat_type" == "private" ]]; then
                    tg_send "$chat_id" "This command only works in groups." "$thread_id"
                elif [[ "$user_id" != "${TG_ADMIN}" ]]; then
                    tg_send "$chat_id" "Admin only." "$thread_id"
                else
                    local _gcmd; _gcmd=$(echo "$args" | awk '{print $1}')
                    local _gval; _gval=$(echo "$args" | awk '{print $2}')
                    case "$_gcmd" in
                        mode)
                            case "$_gval" in
                                active|mention_only|silent)
                                    set_group_mode "$chat_id" "$_gval"
                                    local _desc=""
                                    case "$_gval" in
                                        active)       _desc="replies to all messages" ;;
                                        mention_only) _desc="replies only when @mentioned or replied-to; reads everything silently" ;;
                                        silent)       _desc="never replies; reads and learns silently" ;;
                                    esac
                                    tg_send "$chat_id" "✅ Group mode: <b>${_gval}</b>
<i>${_desc}</i>" "$thread_id" "HTML"
                                    ;;
                                *)
                                    tg_send "$chat_id" "Valid modes: <code>active</code> | <code>mention_only</code> | <code>silent</code>
Example: <code>/group mode mention_only</code>" "$thread_id" "HTML"
                                    ;;
                            esac
                            ;;
                        status)
                            local _cur; _cur=$(get_group_mode "$chat_id")
                            tg_send "$chat_id" "Group mode: <b>${_cur}</b>
Change with <code>/group mode [active|mention_only|silent]</code>" "$thread_id" "HTML"
                            ;;
                        *)
                            tg_send "$chat_id" "<b>/group</b> — per-group behaviour

<code>/group mode active</code> — reply to all messages
<code>/group mode mention_only</code> — reply only when @mentioned; reads everything silently for context
<code>/group mode silent</code> — never reply; reads and learns silently
<code>/group status</code> — show current mode" "$thread_id" "HTML"
                            ;;
                    esac
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
                        local run_pid _msg_id _orig_chat _orig_thread _uid2 _worker_pid2
                        IFS='|' read -r run_pid _msg_id _orig_chat _orig_thread _uid2 _worker_pid2 <<< "$_pid_data"
                        echo "AMA: Stopping session $session_id (PID $run_pid worker ${_worker_pid2:-?})"
                        # Kill worker subshell directly (holds streaming child), then full tree
                        [[ -n "$_worker_pid2" ]] && kill -TERM "$_worker_pid2" 2>/dev/null || true
                        [[ -n "$_worker_pid2" ]] && pkill -TERM -P "$_worker_pid2" 2>/dev/null || true
                        kill_tree "$run_pid"
                        rm -f "$pid_file"
                        # Edit the dangling "Thinking…" or "Working…" bot message
                        if [[ -n "$_msg_id" && "$_msg_id" != "pending" ]]; then
                            tg_edit "${_orig_chat:-$chat_id}" "$_msg_id" "🛑 <i>Stopped.</i>" "HTML" > /dev/null 2>&1 || true
                        fi
                        tg_send "$chat_id" "🛑 Task stopped." "$thread_id"
                        # Remove Stop button if still visible
                        local _stopbtn_id; _stopbtn_id=$(cat "${DIR}/brain/state/stopbtn_${session_id}" 2>/dev/null)
                        [[ -n "$_stopbtn_id" ]] && tg_delete "$chat_id" "$_stopbtn_id" > /dev/null 2>&1 || true
                        rm -f "${DIR}/brain/state/stopbtn_${session_id}"
                    else
                        # No running process — but we set the stop flag above, which will
                        # catch any queued process when it tries to acquire the lock
                        tg_send "$chat_id" "🛑 Stopped (was queued)." "$thread_id"
                        rm -f "${DIR}/brain/state/interrupt_input_${session_id}"
                    fi
                fi
                ;;
            /google_login)
                # Step 1: generate PKCE auth URL and send to user
                local _oauth_tool="${DIR}/tools/google_oauth.py"
                if [[ ! -f "$_oauth_tool" ]]; then
                    tg_send "$chat_id" "google_oauth.py not found. Update your installation." "$thread_id"
                elif [[ "$(python3 "$_oauth_tool" status 2>/dev/null)" == logged_in* && "$args" != "force" ]]; then
                    local _gl_status _gl_email
                    _gl_status=$(python3 "$_oauth_tool" status 2>/dev/null)
                    _gl_email=$(echo "$_gl_status" | grep -oP 'email=\K\S+')
                    tg_send "$chat_id" "✅ <b>Already logged in</b>
Account: <code>${_gl_email}</code>

Next step — tell me: <i>add this Google account to my provider pool</i> and I'll configure it automatically.

Or to re-login with a different account: /google_login force" "$thread_id" "HTML"
                else
                    local _auth_url
                    _auth_url=$(python3 "$_oauth_tool" init 2>/dev/null)
                    if [[ -z "$_auth_url" ]]; then
                        tg_send "$chat_id" "Failed to generate auth URL." "$thread_id"
                    else
                        tg_send "$chat_id" "🔐 <b>Google Login (Code Assist free tier)</b>

1. Open this URL in any browser:
<code>${_auth_url}</code>

2. Sign in with your Google account and tap Allow.

3. Your browser will show a <b>\"This site can't be reached\"</b> error on localhost:8085 — <b>that's normal and expected</b>. Don't close it.

4. Copy the <b>full URL</b> from the address bar (starts with <code>http://127.0.0.1:8085/oauth2callback?state=...</code>).

5. Paste it back here:
<code>/google_login_callback &lt;paste the full URL&gt;</code>" "$thread_id" "HTML"
                    fi
                fi
                ;;

            /google_rediscover)
                local _oauth_tool="${DIR}/tools/google_oauth.py"
                tg_send "$chat_id" "⏳ Re-discovering tier and model (no re-login needed)…" "$thread_id"
                local _rd_out _rd_tmp
                _rd_tmp=$(mktemp)
                python3 "$_oauth_tool" rediscover >"$_rd_tmp" 2>/dev/null
                _rd_out=$(cat "$_rd_tmp"); rm -f "$_rd_tmp"
                if [[ "$_rd_out" == OK* ]]; then
                    local _rd_tier _rd_model
                    _rd_tier=$(echo "$_rd_out" | grep -oP 'tier=\K\S+')
                    _rd_model=$(echo "$_rd_out" | grep -oP 'model=\K\S+')
                    tg_send "$chat_id" "✅ Rediscovered!
Tier: <code>${_rd_tier:-?}</code>
Model: <code>${_rd_model:-?}</code>

Pool entry uses model automatically — restart bot to apply: pm2 restart ama-bot" "$thread_id" "HTML"
                else
                    tg_send "$chat_id" "❌ Rediscovery failed: <code>${_rd_out}</code>" "$thread_id" "HTML"
                fi
                ;;

            /google_quota)
                local _oauth_tool="${DIR}/tools/google_oauth.py"
                if [[ ! -f "$_oauth_tool" ]]; then
                    tg_send "$chat_id" "google_oauth.py not found." "$thread_id"
                elif [[ "$(python3 "$_oauth_tool" status 2>/dev/null)" != logged_in* ]]; then
                    tg_send "$chat_id" "Not logged in. Use /google_login first." "$thread_id"
                else
                    local _quota_out
                    _quota_out=$(python3 "$_oauth_tool" quota 2>/dev/null)
                    tg_send "$chat_id" "<pre>${_quota_out}</pre>" "$thread_id" "HTML"
                fi
                ;;

            /google_login_callback)
                # Step 2: exchange code for tokens, save, offer pool config
                local _callback_val="$args"
                local _oauth_tool="${DIR}/tools/google_oauth.py"
                if [[ -z "$_callback_val" ]]; then
                    tg_send "$chat_id" "Usage: /google_login_callback &lt;redirect URL or code&gt;" "$thread_id" "HTML"
                else
                    tg_send "$chat_id" "⏳ Exchanging authorization code…" "$thread_id"
                    local _finish_out _finish_tmp
                    _finish_tmp=$(mktemp)
                    python3 "$_oauth_tool" finish "$_callback_val" >"$_finish_tmp" 2>/dev/null
                    _finish_out=$(cat "$_finish_tmp"); rm -f "$_finish_tmp"
                    if [[ "$_finish_out" == OK* ]]; then
                        local _fc_email _fc_tier _fc_model
                        _fc_email=$(echo "$_finish_out" | grep -oP 'email=\K\S+')
                        _fc_tier=$(echo "$_finish_out" | grep -oP 'tier=\K\S+')
                        _fc_model=$(echo "$_finish_out" | grep -oP 'model=\K\S+')
                        tg_send "$chat_id" "✅ <b>Logged in!</b>
Account: <code>${_fc_email}</code>
Tier: <code>${_fc_tier:-?}</code>
Model: <code>${_fc_model:-gemini-2.5-flash}</code>

Now tell me: <i>add this Google account to my provider pool</i> and I'll configure it automatically." "$thread_id" "HTML"
                    else
                        tg_send "$chat_id" "❌ Login failed.

<code>${_finish_out}</code>

Try /google_login again." "$thread_id" "HTML"
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
            /reload)
                if [[ "$user_id" == "${TG_ADMIN}" ]]; then
                    local _bot_pid; _bot_pid=$(cat "${DIR}/brain/state/bot.pid" 2>/dev/null)
                    if [[ -n "$_bot_pid" ]] && kill -0 "$_bot_pid" 2>/dev/null; then
                        tg_send "$chat_id" "🔄 <b>Hot-reload triggered</b>
Sending SIGHUP to bot (PID <code>${_bot_pid}</code>).
Core files will be re-sourced between the current long-poll iteration.
<i>Changes to core/mix/, core/telegram/, providers/ take effect immediately — no restart needed.</i>
<i>Use /restart only if env vars (.env) changed.</i>" "$thread_id" "HTML"
                        kill -HUP "$_bot_pid" 2>/dev/null
                    else
                        tg_send "$chat_id" "⚠️ Bot PID not found — try /restart instead." "$thread_id" "HTML"
                    fi
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
