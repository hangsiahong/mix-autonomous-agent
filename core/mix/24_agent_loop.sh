#!/bin/bash
# core/mix/24_agent_loop.sh — main turn loop for AMA.
#
# `run_agent` is the entry point for every Telegram message (and every
# scheduled / queued / goal-loop fire). It acquires a per-session flock,
# loads history, builds the per-turn `context_prompt`, calls the streaming
# API in a loop (up to MAX_TURNS), dispatches tool calls (parallel-safe
# batches go through 23_parallel_tools.sh; single calls through 22_process_
# one_tool_call.sh), and renders the result to Telegram via the
# tg_edit/tg_send helpers in core/telegram/api.sh.
#
# Post-turn background work (reflection → recap → curator) is fired via the
# `( ( cmd ) & )` detach idiom so it survives the EXIT trap that cleans up
# the run_agent subshell. See [[feedback-bash-detach-idiom]] for why.
#
# Queued messages (from /queue, /goal continuation, or scheduler fires) are
# picked up at the END of run_agent and re-enter via another run_agent call.

run_agent() {
    local chat_id="$1"
    local input="$2"
    local user_id="$3"
    local media_json="$4"
    local thread_id="$5"
    local session_id="$6"
    local chat_title="$7"
    local username="$8"
    local skill="${9}"
    local user_msg_id="${10:-}"  # Telegram message_id of the user's message (for reply-to + reactions)

    local pid_file="${DIR}/brain/state/run_${session_id}.pid"
    local stop_flag="${DIR}/brain/state/stop_${session_id}"
    local steer_file="${DIR}/brain/state/steer_${session_id}"
    local queue_file="${DIR}/brain/state/queue_${session_id}"
    local model_file="${DIR}/brain/state/model_${session_id}"
    local stop_btn_file="${DIR}/brain/state/stopbtn_${session_id}"
    local interrupt_input_file="${DIR}/brain/state/interrupt_input_${session_id}"

    # 1. Immediate Feedback: Decide status based on lock availability
    mkdir -p "${DIR}/brain/state/locks"
    local lock_file="${DIR}/brain/state/locks/${session_id}.lock"
    local initial_status="Thinking"
    local msg_id
    local _turn_start; _turn_start=$(date +%s)

    # React 👀 on the user's message to signal we received it (hermes pattern)
    [[ -n "$user_msg_id" && "$user_msg_id" != "0" ]] && tg_react "$chat_id" "$user_msg_id" "👀"

    # Dynamic status verb — rotates through words to avoid stale "Thinking…" feel
    local _status_words=("Thinking" "Analyzing" "Synthesizing" "Cooking" "Architecting" "Reasoning" "Processing")
    local _status_pick="${_status_words[$(( RANDOM % ${#_status_words[@]} ))]}"

    # Try non-blocking lock to check if busy
    if ! flock -n "${lock_file}" true 2>/dev/null; then
        initial_status="Queued"
        # Store input for potential Interrupt button use
        printf '%s' "$input" > "$interrupt_input_file"
        msg_id=$(tg_send_buttons "$chat_id" \
            "🕒 <i>Queued</i>" \
            "[[{\"text\":\"⚡ Interrupt\",\"callback_data\":\"interrupt:${session_id}\"}]]" \
            "$thread_id" "HTML" "$user_msg_id")
    else
        # Working message — Stop button is attached directly so we don't need a
        # separate ephemeral message that has to be cleaned up at the end.
        msg_id=$(tg_send_buttons "$chat_id" \
            "⏳ <i>${_status_pick}…</i>" \
            "[[{\"text\":\"⏹ Stop\",\"callback_data\":\"stop:${session_id}\"}]]" \
            "$thread_id" "HTML" "$user_msg_id")
    fi

    # Capture our own PID before entering subshell ($$  in subshell returns
    # the invoking shell's PID, not ours; $BASHPID is the actual process PID)
    local _agent_pid=$BASHPID

    # Session Lock block
    (
        # Wait for the lock — write PID file INSIDE lock so it always points
        # to the RUNNING process, never a queued one that hasn't started yet
        flock -x 200
        # Store worker PID (this subshell) alongside agent PID so /stop can target it directly
        echo "$_agent_pid|${msg_id}|${chat_id}|${thread_id}|${user_id}|${BASHPID}" > "$pid_file"
        trap 'pkill -TERM -P $BASHPID 2>/dev/null; rm -f "$stop_btn_file" "$interrupt_input_file" "$pid_file"; exit 0' INT TERM
        trap 'pkill -TERM -P $BASHPID 2>/dev/null; rm -f "$stop_btn_file" "$interrupt_input_file" "$pid_file"' EXIT

        # Stop flag handling (before sending Stop button — avoids flash on immediate exit):
        # - Queued + stop_flag + interrupt_input: Interrupt clicked — B takes over directly
        # - Queued + stop_flag only: genuine /stop — exit
        # - Otherwise: clear any stale stop_flag and continue
        if [[ "$initial_status" == "Queued" && -f "$stop_flag" ]]; then
            if [[ -f "$interrupt_input_file" ]]; then
                # Interrupt: B becomes the runner — cancel the C fallback marker
                rm -f "$stop_flag" "$interrupt_input_file" \
                    "${DIR}/brain/state/interrupt_run_${session_id}" 2>/dev/null || true
                initial_status="Interrupt"
                tg_edit "$chat_id" "$msg_id" "⏳ <i>${_status_pick}…</i>" "HTML" > /dev/null 2>&1
            else
                ( tg_edit "$chat_id" "$msg_id" "🛑 <i>Stopped.</i>" "HTML" > /dev/null 2>&1 & )
                exit 0
            fi
        else
            rm -f "$stop_flag" 2>/dev/null || true
        fi

        # Stop button is already attached to msg_id by tg_send_buttons above.
        # If we were Queued, swap text from "🕒 Queued" to "⏳ Thinking…" and replace
        # the Interrupt button with Stop.
        if [[ "$initial_status" == "Queued" ]]; then
            tg_edit "$chat_id" "$msg_id" "⏳ <i>${_status_pick}…</i>" "HTML" \
                "[[{\"text\":\"⏹ Stop\",\"callback_data\":\"stop:${session_id}\"}]]" \
                > /dev/null 2>&1
        fi

        tg_send_action "$chat_id" "typing" "$thread_id"
        load_history "$session_id"
        
        # Context Injection — per-turn volatile state goes here, NOT into the
        # cached system prompt. Keeping date/cwd here lets the Vertex prefix
        # cache stay warm across turns. See 16_api.sh comment.
        local _now _cwd
        _now=$(date '+%A, %B %-d, %Y at %H:%M %Z')
        _cwd=$(pwd)
        local context_prompt="## Current Session Context\n"
        context_prompt+="- **Date/Time**: ${_now}\n"
        context_prompt+="- **Working Directory**: ${_cwd}\n"
        context_prompt+="- **Platform**: Telegram\n"
        [[ -n "$chat_title" ]] && context_prompt+="- **Chat**: $chat_title (ID: $chat_id)\n"
        [[ -n "$thread_id" ]] && context_prompt+="- **Topic/Thread ID**: $thread_id\n"
        context_prompt+="- **User**: ${username:-$user_id}\n"
        context_prompt+="- **Session Key**: $session_id\n"
        # Telegram reply context: when the user replies to a specific message
        # (their own or the bot's), tell the LLM what they're pointing at.
        # Without this, replies look identical to normal continuations and
        # the model misattributes context. reply_to_text/reply_to_author are
        # set by tg_handle_update's parser and inherited via the subshell fork.
        if [[ -n "${reply_to_text:-}" ]]; then
            local _author="${reply_to_author:-User}"
            # Single-line the replied-to text for the bullet
            local _replied; _replied=$(printf '%s' "$reply_to_text" | tr '\n' ' ' | sed 's/  */ /g')
            context_prompt+="- **Replying to** (msg #${reply_to_id:-?}, by ${_author}): \"${_replied}\"\n"
        fi

        # Token-budget self-awareness: show the model how much it's spending
        # in the CURRENT session (since last /new), the per-turn average, and
        # the recent context size. Goal: model self-throttles when burning
        # tokens unusually fast.
        # Session boundary anchor = history file's mtime — /new archives + rm,
        # so the file's ctime/mtime resets at session start. Usage log entries
        # before that timestamp belong to a prior session.
        local _budget_line _hist_mtime=0
        [[ -f "${DIR}/brain/state/history_${session_id}.json" ]] && \
            _hist_mtime=$(stat -c '%Y' "${DIR}/brain/state/history_${session_id}.json" 2>/dev/null || echo 0)
        _budget_line=$(SID="$session_id" MDL="${MODEL:-}" SINCE="${_hist_mtime}" python3 -c "
import json, os, sys
sid = os.environ.get('SID','')
model = (os.environ.get('MDL','') or '').lower()
since = int(os.environ.get('SINCE','0') or 0)
# Model context window (matches 32_usage.sh context_warning)
if 'gemini-3' in model or 'gemini-2.5' in model or 'flash' in model:
    ctx = 1_000_000
elif 'gemini-2' in model:
    ctx = 1_048_576
elif 'claude' in model:
    ctx = 200_000
else:
    ctx = 128_000

log_path = 'brain/state/usage_log.jsonl'
session_calls = []   # current session only (ts >= since)
recent_calls = []    # last 20 calls regardless of session, for lifetime baseline
try:
    with open(log_path) as f:
        lines = f.readlines()
    for line in lines[-500:]:  # cap scan
        try:
            e = json.loads(line)
            ts = int(e.get('ts', 0) or 0)
            u = e.get('usage', {}) or {}
            pt = int(u.get('prompt_tokens', 0) or 0)
            ct = int(u.get('completion_tokens', 0) or 0)
            recent_calls.append((pt, ct))
            if e.get('chat_id') == sid and (since == 0 or ts >= since - 60):
                # 60s grace window in case usage was logged slightly before
                # history file got its first mtime stamp.
                session_calls.append((pt, ct))
        except Exception: continue
except FileNotFoundError:
    pass

def fmt(n):
    return f'{n/1000:.1f}k' if n >= 1000 else str(n)

# Lifetime baseline = last 20 calls across all sessions (rolling, not historical)
recent_n = recent_calls[-20:] if recent_calls else []
recent_avg = (sum(p+c for p,c in recent_n) // len(recent_n)) if recent_n else 0

if not session_calls:
    print(f'- **Token budget**: fresh session · ctx window {ctx:,} · recent baseline avg/turn {fmt(recent_avg)}')
    sys.exit(0)

s_in = sum(c[0] for c in session_calls)
s_out = sum(c[1] for c in session_calls)
s_total = s_in + s_out
s_turns = len(session_calls)
s_avg = s_total // s_turns if s_turns else 0
last_pt, last_ct = session_calls[-1]
last_total = last_pt + last_ct
# Context %: use the LAST prompt size (current state), not session sum
ctx_pct = round(last_pt / ctx * 100, 1)

# Pacing hint — flag when this session is burning unusually fast
hint = ''
if recent_avg and s_avg > recent_avg * 1.5:
    hint = f' · ⚠ above baseline ({fmt(recent_avg)}/turn) — consider compressing replies'

line = (
    f'- **Token budget**: session {fmt(s_total)} ({s_turns} turn'
    + ('s' if s_turns != 1 else '')
    + f', {fmt(s_avg)} avg) · last turn {fmt(last_total)} · ctx {ctx_pct}% used{hint}'
)
print(line)
" 2>/dev/null)
        [[ -n "$_budget_line" ]] && context_prompt+="${_budget_line}\n"

        # Status-query circuit breaker. When the user asks a count/list/status
        # question, the right answer is "one authoritative tool call, then
        # reply" — not an investigation. Today's 96-second scheduler-list
        # incident showed the agent will rationalise a 5-tool deep dive even
        # with the prompt rule. Two-layer enforcement:
        #   1. Inject a hard "MAX 2 tool calls" bullet at the most recent
        #      (highest-attention) position in context.
        #   2. Locally clamp MAX_TURNS=2 so the loop forces a final answer
        #      after at most 2 tool batches even if the model keeps trying.
        # The patterns are intentionally simple — false positives just mean
        # the agent has to answer in 2 turns instead of MAX_TURNS, which is
        # fine for genuinely simple queries that happen to use these words.
        local _status_query=0
        if [[ "$input" =~ ^[Hh]ow\ (many|much)\  ]] || \
           [[ "$input" =~ ^[Ll]ist\  ]] || \
           [[ "$input" =~ ^[Ss]how\ (me\ )? ]] || \
           [[ "$input" =~ ^[Ww]hat.{0,3}s\ (my|your|the|our|on)\  ]] || \
           [[ "$input" =~ ^[Dd]o\ I\ have\  ]] || \
           [[ "$input" =~ ^[Ii]s\ .+\ (running|active|enabled|on|set)[\.\?\!\ ]*$ ]] || \
           [[ "$input" =~ ^[Cc]ount\  ]]; then
            _status_query=1
            MAX_TURNS=2
            context_prompt+="- **STATUS QUERY** (detected from input pattern): answer in **1 tool call** and reply. Do NOT verify with bash/ls/cat after the authoritative tool returns. Trust the result. MAX_TURNS clamped to 2 — second turn must produce final answer.\n"
        fi
        
        if [[ -z "$skill" ]]; then
            local topic_config=$(get_topic_config "$chat_id" "$thread_id")
            if [[ -n "$topic_config" && "$topic_config" != "null" ]]; then
                skill=$(python3 -c "import json,sys; print(json.loads(open(sys.argv[1]).read()).get('skill',''))" <(printf '%s' "$topic_config") 2>/dev/null)
                local topic_name=$(python3 -c "import json,sys; print(json.loads(open(sys.argv[1]).read()).get('name',''))" <(printf '%s' "$topic_config") 2>/dev/null)
                [[ -n "$topic_name" ]] && context_prompt+="- **Topic Name**: $topic_name\n"
            fi
            # Fall back to DEFAULT_SKILL when no per-session or topic skill is set
            [[ -z "$skill" && -n "${DEFAULT_SKILL:-}" ]] && skill="$DEFAULT_SKILL"
        fi
        [[ -n "$skill" ]] && context_prompt+="- **Active Skill**: $skill\n"

        # Per-turn capability hint: tells the agent whether the CURRENT
        # provider+model actually supports vision, so it doesn't probe to
        # verify (which is what cost 64s in the 2026-05-19 13:17 incident).
        local _vision_state
        _vision_state=$(PROV="${PROVIDER:-}" MDL="${MODEL:-}" python3 -c "
import os
prov = os.environ.get('PROV','').lower()
mdl = os.environ.get('MDL','').lower()
# Provider paths that route image_url → inline_data / image parts:
#   google.sh (vertex/studio) — explicit conversion in payload builder
#   google_cloudcode          — same path (Gemini API)
#   anthropic                 — passes image_url through (Claude 3+ native)
#   default/openai-compat     — image_url is OpenAI's native shape; depends on model
# Models that DON'T see images (text-only):
#   ollama with non-multimodal model (gemma, mistral text variants, llama text)
text_only_model_patterns = ('gemma:', 'gemma-', 'gemma2', 'mistral:', 'llama2:', 'llama3:', 'qwen2:', 'qwen3:', 'deepseek-r1:', 'deepseek-coder:')
multimodal_model_patterns = ('gemini', 'claude', 'gpt-4', 'llava', 'bakllava', 'pixtral', 'qwen-vl', 'qwen2-vl')

has_vision = False
if prov == 'ollama':
    has_vision = any(p in mdl for p in multimodal_model_patterns)
elif prov in ('google', 'google_cloudcode', 'anthropic'):
    has_vision = True
elif any(p in mdl for p in multimodal_model_patterns):
    has_vision = True
elif any(p in mdl for p in text_only_model_patterns):
    has_vision = False
else:
    # Unknown provider/model — be optimistic; Telegram images will fail if not supported
    has_vision = True
print('enabled' if has_vision else 'disabled (model is text-only)')
" 2>/dev/null)
        context_prompt+="- **Vision**: ${_vision_state:-enabled}\n"

        # Apply per-session model override (/model command — hermes pattern)
        if [[ -f "$model_file" ]]; then
            local _session_model; _session_model=$(cat "$model_file" 2>/dev/null)
            [[ -n "$_session_model" ]] && MODEL="$_session_model"
        fi

        # Per-task override for scheduled jobs: when input starts with
        # "[SCHEDULED #N]" (set by extensions/cron/run.sh), look for the
        # sidecar at brain/state/sched_override_<sid>_<N>.json and apply
        # model/provider/skill for THIS turn only. Sidecar is deleted after
        # read so subsequent turns return to normal behaviour.
        #
        # Logging to logs/scheduler_debug.log because stderr goes to the
        # terminal where the bot was started — invisible if launched by pm2
        # or detached. This file is the single source of truth for
        # "did the override fire and with what values".
        local _sched_log="${DIR}/logs/scheduler_debug.log"
        mkdir -p "$(dirname "$_sched_log")"
        if [[ "$input" =~ ^\[SCHEDULED\ \#([0-9]+)\] ]]; then
            local _sched_id="${BASH_REMATCH[1]}"
            local _override_file="${DIR}/brain/state/sched_override_${session_id}_${_sched_id}.json"
            echo "[$(date '+%H:%M:%S')] sched-detect #${_sched_id} sid=${session_id} override=${_override_file}" >> "$_sched_log"
            if [[ -f "$_override_file" ]]; then
                local _ov_model _ov_provider _ov_skill
                { read _ov_model; read _ov_provider; read _ov_skill; } < <(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('model',''))
    print(d.get('provider',''))
    print(d.get('skill',''))
except: print(); print(); print()" "$_override_file" 2>/dev/null)
                echo "[$(date '+%H:%M:%S')] sched-override #${_sched_id} model=${_ov_model} provider=${_ov_provider} skill=${_ov_skill}  (was MODEL=${MODEL} PROVIDER=${PROVIDER})" >> "$_sched_log"
                [[ -n "$_ov_model" ]] && { MODEL="$_ov_model"; }
                if [[ -n "$_ov_provider" && "$_ov_provider" != "$PROVIDER" ]]; then
                    PROVIDER="$_ov_provider"
                    if type "${PROVIDER}_activate" >/dev/null 2>&1; then
                        "${PROVIDER}_activate" >/dev/null 2>&1 \
                            && echo "[$(date '+%H:%M:%S')] sched-activate #${_sched_id} ${PROVIDER}_activate OK  BASE_URL=${BASE_URL}" >> "$_sched_log" \
                            || echo "[$(date '+%H:%M:%S')] sched-activate #${_sched_id} ${PROVIDER}_activate FAILED" >> "$_sched_log"
                    else
                        echo "[$(date '+%H:%M:%S')] sched-activate #${_sched_id} no ${PROVIDER}_activate function exists" >> "$_sched_log"
                    fi
                fi
                # Clear stale provider-specific env that might mangle the new request.
                # _GOOGLE_VERTEX_MODEL_PREFIX gets set by google_activate to "google/"
                # and prefixes the model name in the payload — bad when we just switched
                # to kconsole (would send model="google/koompi-free" to KConsole).
                if [[ "$PROVIDER" != "google" ]]; then
                    unset _GOOGLE_VERTEX_MODEL_PREFIX
                fi
                [[ -n "$_ov_skill" ]] && skill="$_ov_skill"
                echo "[$(date '+%H:%M:%S')] sched-applied #${_sched_id} → MODEL=${MODEL} PROVIDER=${PROVIDER} BASE_URL=${BASE_URL:-?}" >> "$_sched_log"
                # DO NOT delete the sidecar — the override is the same every
                # fire (per task definition). Deleting it meant the 2nd, 3rd,
                # … fires of the same task lost their override and silently
                # fell back to the default model. Scheduler `remove` cleans
                # up the sidecar when the task itself is removed.
            else
                echo "[$(date '+%H:%M:%S')] sched-detect #${_sched_id} NO sidecar file — override skipped" >> "$_sched_log"
            fi
        fi

        # Ensure session exists in SQLite DB (hermes: create_session is idempotent)
        ( python3 tools/session_db.py create "$session_id" "${user_id:-}" "${MODEL:-}" \
            > /dev/null 2>&1 & )

        # Self-heal check: if a heal_request exists from cron/error detection, run it now
        self_heal_if_needed "$session_id" "$chat_id" "$thread_id"

        append_text "user" "[SYSTEM: Context Updated]\n$context_prompt\n\n$input" "$media_json"
        ( generate_title "$session_id" & )

        compact_history "$session_id" "$chat_id" "$thread_id" "$msg_id"

        # Emergency Safety Truncation
        local char_count=${#HISTORY}
        if [[ "$char_count" -gt 200000 ]]; then
            HISTORY=$(python3 -c "import json,sys; h=json.loads(open(sys.argv[1]).read()); print(json.dumps(h[:5] + [{'role':'system','content':'[Safety: Mid-history purged due to size]'}]+ h[-10:],separators=(',',':')))" <(printf '%s' "$HISTORY"))
            save_history "$session_id"
        fi

        local turn=0
        local total_tool_calls=0
        local all_tool_names=""
        local loop_completed=false
        local total_input_tokens=0
        local total_output_tokens=0
        local _thought_snippet=""  # persists across turns — shows last known reasoning
        local _last_tc_fingerprint=""
        local _tc_repeat_count=0
        # Persistent step log for the whole agent turn (Claude-Code-style cumulative pane).
        # Lines separated by \x1e (RS); each line = "<emoji>|<name>|<key_arg>|<duration_s>"
        local _steps_log=""
        local _RS=$'\x1e'
        while [ "$turn" -lt "$MAX_TURNS" ]; do
            turn=$((turn + 1))
            [[ "$turn" -gt 1 ]] && tg_send_action "$chat_id" "typing" "$thread_id"
            export _AMA_REASONING_HTML="${_AMA_REASONING_HTML:-}"

            local result
            result=$(call_api_stream "$chat_id" "$msg_id" "$skill")
            
            if [[ -z "$result" || "$result" == "FAIL:"* ]]; then
                local err_info="${result#FAIL:}"
                tg_edit "$chat_id" "$msg_id" "Error: Failed to get response from AI. ${err_info:-'Please try again later.'}" > /dev/null 2>&1
                break
            fi

            local tool_calls=$(echo "$result" | grep "^TC:" | cut -c4-)
            local usage=$(echo "$result" | grep "^USAGE:" | cut -c7-)
            local _think_line=$(echo "$result" | grep "^THINK:" | head -1 | cut -c7-)
            local text
            text=$(printf '%s' "$result" | python3 -c "import sys, re; c = sys.stdin.read(); m = re.search(r'(?m)^TEXT:(.*?)(?=\nUSAGE:|\Z)', c, re.DOTALL); print(m.group(1) if m else '', end='')" 2>/dev/null)
            
            [[ -n "$usage" ]] && log_usage "$session_id" "$usage" "$MODEL"
            local _ctx_warn=""
            [[ -n "$usage" ]] && _ctx_warn=$(context_warning "$usage" "$MODEL")

            # Accumulate token counts across all turns for footer display
            if [[ -n "$usage" ]]; then
                local _it=0 _ot=0
                { read _it; read _ot; } < <(printf '%s' "$usage" | python3 -c "
import json,sys; u=json.load(sys.stdin)
print(u.get('prompt_tokens',u.get('input_tokens',0)))
print(u.get('completion_tokens',u.get('output_tokens',0)))" 2>/dev/null)
                total_input_tokens=$((total_input_tokens + ${_it:-0}))
                total_output_tokens=$((total_output_tokens + ${_ot:-0}))
            fi

            # Update thinking snippet only when new reasoning arrives — persists across turns
            # so between-tool messages always show the last known reasoning, not just status word.
            if [[ -n "$_think_line" ]]; then
                _thought_snippet=$(printf '%s' "$_think_line" | python3 -c "
import sys
s = sys.stdin.read().strip()
s = s[:200] + ('…' if len(s) > 200 else '')
print(s.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;'))
" 2>/dev/null || true)
            elif [[ "$text" == *"<think>"* ]]; then
                _thought_snippet=$(printf '%s' "$text" | python3 -c "
import sys, re
t = sys.stdin.read()
m = re.search(r'<think[^>]*>(.*?)</think>', t, re.DOTALL | re.IGNORECASE)
if m:
    s = ' '.join(m.group(1).split())
    s = s[:200] + ('…' if len(s) > 200 else '')
    print(s.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;'))
" 2>/dev/null || true)
            fi

            [[ -n "$text" && "$text" != "null" ]] && append_text "assistant" "$text"

            if [[ -n "$tool_calls" && "$tool_calls" != "[]" && "$tool_calls" != "null" ]]; then
                if [[ -n "$text" && "$text" != "null" ]]; then
                    local _esc_reason=$(printf '%s' "$text" | head -c 500 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
                    [[ ${#text} -gt 480 ]] && _esc_reason="${_esc_reason}..."
                    export _AMA_REASONING_HTML="$_esc_reason"
                    tg_edit "$chat_id" "$msg_id" "$_esc_reason" "HTML" > /dev/null 2>&1
                fi
                append_tool_call "$tool_calls"

                local batch_names="" batch_count=0
                { read batch_count; read batch_names; } < <(python3 -c "
import json,sys
calls=json.loads(open(sys.argv[1]).read())
print(len(calls))
print(', '.join(c.get('function',{}).get('name','?') for c in calls))" \
<(printf '%s' "$tool_calls") 2>/dev/null)
                total_tool_calls=$((total_tool_calls + batch_count))
                [[ -n "$batch_names" ]] && all_tool_names+="${all_tool_names:+, }$batch_names"

                if [[ $batch_count -gt 1 ]] && is_batch_parallel_safe "$tool_calls"; then
                    local _batch_start=$(date +%s)
                    execute_parallel_batch "$chat_id" "$msg_id" "$thread_id" "$tool_calls" "$session_id"
                    local _batch_elapsed=$(( $(date +%s) - _batch_start ))
                    # Append one step per parallel tool (same duration since they ran concurrently)
                    while IFS='|' read -r _pn _pkey; do
                        [[ -z "$_pn" ]] && continue
                        _steps_log+="${_steps_log:+$_RS}✓|${_pn}|${_pkey}|${_batch_elapsed}"
                    done < <(python3 -c "
import json,sys
for tc in json.loads(open(sys.argv[1]).read()):
    name = (tc.get('function',{}).get('name') or tc.get('name','') or '').strip()
    args = tc.get('function',{}).get('arguments') or '{}'
    key = ''
    try:
        a = json.loads(args) if isinstance(args,str) else args
        for k in ('query','path','command','url','file_path','name','target','action'):
            if k in a:
                key = str(a[k]).replace('\n',' ').strip()[:60]
                break
    except: pass
    print(f'{name}|{key}')" <(printf '%s' "$tool_calls") 2>/dev/null)
                else
                    while IFS='|' read -r name tc_id; do
                        [[ -z "$name" ]] && continue
                        [[ -z "$tc_id" ]] && tc_id="tc_$(date +%s%N)"
                        local single_tc=$(python3 -c "import json, sys, os; calls = json.loads(open(sys.argv[1]).read()); target_id = os.environ.get('TC_ID',''); match = next((t for t in calls if t.get('id') == target_id), None); print(json.dumps(match or calls[0], separators=(',',':')) if calls else '')" <(printf '%s' "$tool_calls") TC_ID="$tc_id" 2>/dev/null)
                        local _tool_start=$(date +%s)
                        local output=$(process_tc "$chat_id" "$msg_id" "$single_tc" "$thread_id")
                        local _tool_elapsed=$(( $(date +%s) - _tool_start ))
                        # Extract key arg for the step log
                        local _key
                        _key=$(printf '%s' "$single_tc" | python3 -c "
import sys, json
try:
    tc = json.loads(sys.stdin.read())
    args = tc.get('function',{}).get('arguments','{}')
    a = json.loads(args) if isinstance(args,str) else args
    for k in ('query','path','command','url','file_path','name','target','action'):
        if k in a:
            print(str(a[k]).replace(chr(10),' ').strip()[:60]); break
except: pass" 2>/dev/null)
                        _steps_log+="${_steps_log:+$_RS}✓|${name}|${_key}|${_tool_elapsed}"
                        append_tool_result "$tc_id" "$name" "$output"
                    done < <(python3 -c "
import sys, json
for tc in json.loads(open(sys.argv[1]).read()):
    name = tc.get('function', {}).get('name') or tc.get('name', '') or 'unknown_tool'
    print(f'{name.strip()}|{tc.get(\"id\", \"\").strip()}')
" <(printf '%s' "$tool_calls"))
                fi
                # Drain pending /steer into last tool result (hermes pattern)
                if [[ -f "$steer_file" ]]; then
                    local _steer_text; _steer_text=$(cat "$steer_file" 2>/dev/null)
                    rm -f "$steer_file"
                    if [[ -n "$_steer_text" ]]; then
                        # Append steer as "User guidance" to the last tool result in history
                        HISTORY=$(python3 -c "
import json, sys
h = json.loads(open(sys.argv[1]).read())
steer = open(sys.argv[2]).read().strip()
# Find last tool message and append guidance
for i in range(len(h)-1, -1, -1):
    if h[i].get('role') == 'tool':
        c = h[i].get('content', '')
        h[i]['content'] = str(c) + '\n\nUser guidance: ' + steer
        break
print(json.dumps(h, separators=(',',':')))
" <(printf '%s' "$HISTORY") <(printf '%s' "$_steer_text") 2>/dev/null || printf '%s' "$HISTORY")
                    fi
                fi

                # Circuit breaker: if the exact same tool-call batch repeats 3× in a row,
                # the LLM is stuck — stop early instead of burning the rest of MAX_TURNS.
                local _tc_fp; _tc_fp=$(printf '%s' "$tool_calls" | md5sum 2>/dev/null | cut -c1-8)
                if [[ "$_tc_fp" == "$_last_tc_fingerprint" && -n "$_tc_fp" ]]; then
                    _tc_repeat_count=$((_tc_repeat_count + 1))
                    if [[ $_tc_repeat_count -ge 2 ]]; then
                        tg_edit "$chat_id" "$msg_id" \
                            "⚠️ <i>Stuck loop detected — same tool call repeated 3× in a row. Stopping early to save tokens. Use /retry if needed.</i>" \
                            "HTML" > /dev/null 2>&1 || true
                        loop_completed=false
                        break
                    fi
                else
                    _tc_repeat_count=0
                    _last_tc_fingerprint="$_tc_fp"
                fi

                # Cumulative step-log pane (Claude-Code-style) — replaces the prior
                # "last 4 tool names" block. Shows every completed step in this turn
                # with status emoji, key arg, and elapsed duration.
                local _between_msg
                _between_msg=$(STEPS_LOG="$_steps_log" \
                               STATUS_WORD="$_status_pick" \
                               REASONING_SNIPPET="$_thought_snippet" \
                               python3 -c "
import os, re
EMOJI = {'bash':'🛠️','web_search':'🔍','fetch_url':'🌐','read_file':'📖','write_file':'✍️',
         'edit_code':'📝','search_files':'🔎','todo':'📋','memory':'🧠','memory_remember':'🧠',
         'memory_recall':'🧠','process':'⚙️','browser':'🌍','image_generate':'🎨','patch':'🩹',
         'repo_map':'🗺️','clarify':'💬','session_search':'🗂️','sys_info':'📊','recap':'📝',
         'custom_tool_manager':'🔧','skill_manager':'🎯','skill_install':'📦','insights':'📈',
         'kanban_show':'📌','kanban_create':'📌','kanban_complete':'✅','kanban_block':'🚧',
         'delegate':'🤖','ast_edit':'🔬','last_session':'🗓️','send_file':'📤','clarify':'❓'}
def esc(s):
    return s.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;')
raw = os.environ.get('STEPS_LOG','')
lines = []
if raw:
    entries = raw.split(chr(0x1e))
    # Keep the last 8 entries to avoid overflowing Telegram (4096 cap on msg)
    for e in entries[-8:]:
        parts = e.split('|')
        if len(parts) < 4: continue
        st, name, key, dur = parts[0], parts[1], parts[2], parts[3]
        em = EMOJI.get(name, '🧩')
        # Bullet (•) = light dim; ✓ = done; ▸ = running
        sym = '✓' if st == '✓' else '▸' if st == '▸' else '•'
        # Pretty name + dim duration
        try:
            d = int(dur)
            dur_s = f' <i>{d}s</i>' if d >= 1 else ''
        except: dur_s = ''
        key_s = f' <i>{esc(key)[:60]}</i>' if key else ''
        lines.append(f'{sym} <code>{em} {name}</code>{key_s}{dur_s}')

snippet = os.environ.get('REASONING_SNIPPET','').strip()
word = os.environ.get('STATUS_WORD','Thinking')

def md_light(t):
    t = esc(t)
    t = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', t)
    t = re.sub(r'_([^_]+)_', r'<i>\1</i>', t)
    return t

out = []
if snippet:
    out.append(f'<blockquote>💭 {md_light(snippet)}</blockquote>')
if lines:
    out.append('\n'.join(lines))
out.append(f'<i>{word}…</i>')
print('\n'.join(out))
" 2>/dev/null || echo "⏳ <i>Thinking…</i>")
                tg_edit "$chat_id" "$msg_id" "$_between_msg" "HTML" > /dev/null 2>&1
                export _AMA_REASONING_HTML=""
                continue
            fi
            # Steer arrived but no tools were called this turn — inject into next turn
            # instead of losing it silently (hermes: steer waits for next tool batch)
            if [[ -f "$steer_file" ]]; then
                local _steer_leftover; _steer_leftover=$(cat "$steer_file" 2>/dev/null)
                rm -f "$steer_file"
                if [[ -n "$_steer_leftover" ]]; then
                    # Add as a user guidance message so next turn picks it up
                    append_text "user" "[User guidance for next response: $_steer_leftover]"
                    tg_edit "$chat_id" "$msg_id" "⏳ <i>Applying guidance…</i>" "HTML" > /dev/null 2>&1
                    continue  # Run another turn with the steer applied
                fi
            fi
            loop_completed=true
            break
        done

        # Remove the Stop button from the main message — agent is done
        tg_remove_buttons "$chat_id" "$msg_id" > /dev/null 2>&1 || true
        rm -f "$stop_btn_file"  # legacy: clean up any leftover marker from old code path

        if [[ "$loop_completed" == true ]]; then
            local _elapsed_total=$(( $(date +%s) - _turn_start ))
            local _elapsed_str=""
            [[ $_elapsed_total -ge 10 ]] && _elapsed_str=" ⏱ ${_elapsed_total}s"
            # Token count across all turns (input + output)
            local _tok_str=""
            local _ttok=$((total_input_tokens + total_output_tokens))
            if [[ $_ttok -gt 0 ]]; then
                _tok_str=$(python3 -c "t=$_ttok; print(f' | {t/1000:.1f}k tok' if t>=1000 else f' | {t} tok')" 2>/dev/null || echo "")
            fi
            if [[ $total_tool_calls -gt 0 && -n "$text" ]]; then
                # Per-tool counts (e.g. "bash×2, edit_code") for the dim footer line
                local footer_parts=$(echo "$all_tool_names" | tr ',' '\n' | sed 's/^ *//' | grep -v '^$' | sort | uniq -c | sort -rn | awk '{cnt=$1; name=$2; for(i=3;i<=NF;i++) name=name" "$i; if(cnt>1) print name"×"cnt; else print name}' | paste -sd ', ')
                local _rendered_text; _rendered_text=$(md_to_tg_html "$text")
                # Build the step pane (separate from rendered markdown to avoid HTML escaping the icons)
                local _step_pane
                _step_pane=$(STEPS_LOG="$_steps_log" python3 -c "
import os
EMOJI = {'bash':'🛠️','web_search':'🔍','fetch_url':'🌐','read_file':'📖','write_file':'✍️',
         'edit_code':'📝','search_files':'🔎','todo':'📋','memory':'🧠','memory_remember':'🧠',
         'memory_recall':'🧠','process':'⚙️','browser':'🌍','image_generate':'🎨','patch':'🩹',
         'repo_map':'🗺️','clarify':'❓','session_search':'🗂️','sys_info':'📊','recap':'📝',
         'custom_tool_manager':'🔧','skill_manager':'🎯','skill_install':'📦','insights':'📈',
         'delegate':'🤖','ast_edit':'🔬','last_session':'🗓️','send_file':'📤'}
def esc(s): return s.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;')
raw = os.environ.get('STEPS_LOG','')
out = []
if raw:
    for e in raw.split(chr(0x1e))[-8:]:
        p = e.split('|')
        if len(p) < 4: continue
        st, name, key, dur = p[0], p[1], p[2], p[3]
        em = EMOJI.get(name, '🧩')
        try: dur_s = f' <i>{int(dur)}s</i>' if int(dur) >= 1 else ''
        except: dur_s = ''
        key_s = f' <i>{esc(key)[:60]}</i>' if key else ''
        out.append(f'✓ <code>{em} {name}</code>{key_s}{dur_s}')
print('\n'.join(out))
" 2>/dev/null)
                local _footer="<i>╴ ${total_tool_calls} tool$([[ $total_tool_calls -ne 1 ]] && echo 's') · ${footer_parts}${_tok_str}${_elapsed_str}</i>"
                local _full_html="$_rendered_text"
                [[ -n "$_step_pane" ]] && _full_html="${_step_pane}"$'\n\n'"${_full_html}"
                _full_html="${_full_html}"$'\n\n'"${_footer}"
                [[ -n "$_ctx_warn" ]] && _full_html+=$'\n'"${_ctx_warn}"
                tg_edit_safe "$chat_id" "$msg_id" "$_full_html" "HTML" "$thread_id"
            elif [[ -n "$text" && "$text" != "null" && $total_tool_calls -eq 0 ]]; then
                local _final_html; _final_html="$(md_to_tg_html "$text")"
                [[ -n "$_ctx_warn" ]] && _final_html+=$'\n'"${_ctx_warn}"
                [[ -n "$_elapsed_str" ]] && _final_html+=$'\n'"<i>${_elapsed_str:1}</i>"
                tg_edit_safe "$chat_id" "$msg_id" "$_final_html" "HTML" "$thread_id"
            else
                # Empty response — Gemini thinking-only output or scrubbed content.
                # The ⏳ placeholder is still showing. Replace it with a retry prompt.
                tg_edit "$chat_id" "$msg_id" "🤔 <i>No response generated (model may have only produced internal reasoning). Use /retry to try again.</i>" "HTML" > /dev/null 2>&1 || true
                [[ -n "$user_msg_id" && "$user_msg_id" != "0" ]] && tg_react "$chat_id" "$user_msg_id" "👎" || true
            fi
            # React ✅ on the user's original message (hermes: done signal)
            [[ -z "$text" ]] || { [[ -n "$user_msg_id" && "$user_msg_id" != "0" ]] && tg_react "$chat_id" "$user_msg_id" "✅"; }
        else
            # Loop hit max turns without clean exit
            tg_edit_safe "$chat_id" "$msg_id" "$(md_to_tg_html "${text:-}")\n\n⚠️ _Max turns reached. Use /retry to continue or /new for fresh session._" "HTML" "$thread_id" || true
            [[ -n "$user_msg_id" && "$user_msg_id" != "0" ]] && tg_react "$chat_id" "$user_msg_id" "👎"
        fi

        # Release the session lock early — post-turn bookkeeping doesn't need it.
        # The next queued message can start acquiring the lock immediately.
        exec 200>&-

        save_history "$session_id"
        log_trajectory "$session_id" "completed"
        # Background post-turn work: reflection → recap → curator — chained so they
        # don't race for the API rate-limit window. Must use the `( cmd & )` detach
        # idiom (outer subshell exits → inner subshell orphaned → reparented to
        # init → survives the run_agent EXIT trap's `pkill -TERM -P $BASHPID`).
        # A plain `( ... ) &` would keep the chain as a child of run_agent and
        # get TERMed the moment the turn finishes.
        if [[ $total_tool_calls -gt 0 ]]; then
            (
                (
                    # Reflection (read-only inspection, saves to LanceDB).
                    # NOTE: session-level recap is intentionally NOT done here —
                    # it fires from the /new (router.sh) handler against the
                    # just-archived history file, so each recap covers a full
                    # session instead of a single turn.
                    reflect_turn "$chat_id" "$thread_id" "$session_id"

                    # Curator: edits MEMORY.md / USER.md / skill prompts. Only on
                    # tool-heavy turns where learning is likely.
                    if [[ "$loop_completed" == true && $total_tool_calls -ge 3 ]]; then
                        sleep 3
                        curate_session "$session_id" "$skill" 2>&1 | sed 's/^/[curator] /' >> logs/curator.log
                    fi
                ) &
            )
        fi
        # Pre-warm memory for next turn — local embedding call, doesn't compete
        # with the LLM rate limit, runs in parallel without staggering.
        if [[ "${MEMORY_PREFETCH:-1}" != "0" && -n "$text" && $total_tool_calls -gt 0 ]]; then
            local _prefetch_cache="${DIR}/brain/state/prefetch_${session_id}"
            local _next_query
            _next_query=$(printf '%s' "$text" | head -c 300)
            ( timeout 8 python3 tools/memory_helper.py search "$_next_query" 3 \
                > "$_prefetch_cache" 2>/dev/null || rm -f "$_prefetch_cache" ) &
        fi
    ) 200>"$lock_file"

    # Goal-loop continuation: if a /goal is active, ask the judge whether the
    # last turn finished it. If not, the judge appends the goal text to
    # queue_file and the existing queue handler below re-runs run_agent.
    # Skipped on /stop or when the user has explicitly paused/cleared the goal.
    if [[ ! -f "$stop_flag" ]] && type goal_maybe_continue >/dev/null 2>&1; then
        # Read the last assistant message from history for the judge prompt
        local _last_resp
        _last_resp=$(python3 -c "
import json
try:
    h = json.load(open('brain/state/history_${session_id}.json'))
    for m in reversed(h):
        if m.get('role') == 'assistant':
            c = m.get('content') or ''
            if isinstance(c, str) and c.strip():
                print(c[:2000]); break
except: pass" 2>/dev/null)
        # Capture verdict for user-visible feedback after the next message
        local _goal_status_before; _goal_status_before=$(goal_field "$session_id" status "")
        if [[ "$_goal_status_before" == "active" ]]; then
            goal_maybe_continue "$session_id" "$_last_resp" "$queue_file"
            local _gret=$?
            # Brief Telegram notice on terminal states so the user knows the loop ended
            case "$_gret" in
                1)  # DONE
                    tg_send "$chat_id" "✅ <i>Goal complete.</i>" "$thread_id" "HTML"
                    ;;
                2)  # exhausted
                    tg_send "$chat_id" "⏱ <i>Goal stopped — max turns reached. Use /goal max &lt;n&gt; or /goal resume to extend.</i>" "$thread_id" "HTML"
                    ;;
                3)  # failed
                    local _why; _why=$(goal_field "$session_id" last_reason "")
                    tg_send "$chat_id" "⚠️ <i>Goal stopped: ${_why:-judge halted}</i>" "$thread_id" "HTML"
                    ;;
            esac
        fi
    fi

    # Process queued message after lock is released (hermes /queue pattern)
    # Check stop flag again just in case a /stop hit right as the lock released
    if [[ -f "$queue_file" && ! -f "$stop_flag" ]]; then
        local _queued_text
        _queued_text=$(head -1 "$queue_file" 2>/dev/null)
        # Pop the first line
        python3 -c "
import sys
lines = open(sys.argv[1]).readlines()
if len(lines) > 1:
    open(sys.argv[1],'w').writelines(lines[1:])
else:
    import os; os.unlink(sys.argv[1])
" "$queue_file" 2>/dev/null || rm -f "$queue_file"
        if [[ -n "$_queued_text" ]]; then
            ( set -m; run_agent "$chat_id" "$_queued_text" "$user_id" "[]" "$thread_id" "$session_id" "$chat_title" "$username" "$skill" ) &
        fi
    fi
}
