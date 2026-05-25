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
    local provider_file="${DIR}/brain/state/provider_${session_id}"
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

    # Export session_id so tool wrappers (tools/<name>.sh) can resolve per-
    # session state files without needing to reconstruct it from chat_id +
    # thread_id. Consumed by tool_search via TOOL_SESSION_ID.
    export AMA_SESSION_ID="$session_id"

    # Session Lock block
    (
        # Wait for the lock — write PID file INSIDE lock so it always points
        # to the RUNNING process, never a queued one that hasn't started yet
        flock -x 200
        # Store worker PID (this subshell) alongside agent PID so /stop can target it directly
        echo "$_agent_pid|${msg_id}|${chat_id}|${thread_id}|${user_id}|${BASHPID}" > "$pid_file"
        # Traps include save_history before pkilling children — defensive
        # backstop for the SIGKILL-mid-turn race where the per-batch save in
        # the tool-execution path didn't get to fire. save_history's
        # empty-HISTORY guard (11_history.sh:147) means an early-trap fire
        # before HISTORY is populated is a silent no-op, not corruption.
        # `|| true` keeps the trap body resilient to any save failure.
        #
        # CRITICAL: do NOT rm "$interrupt_input_file" here. That file is
        # owned by the QUEUED agent B (which writes it at line 58 before
        # blocking on the flock). When A dies via Interrupt, A's trap firing
        # would wipe B's pending text before B can read it — B then wakes,
        # sees stop_flag but no interrupt_input_file, and exits with
        # "Stopped" instead of taking over. The file's lifecycle belongs
        # to B's interrupt-detection path (cleared at line 104 after
        # successful takeover) or to the next agent's overwrite at line 58.
        trap 'save_history "$session_id" 2>/dev/null || true; pkill -TERM -P $BASHPID 2>/dev/null; rm -f "$stop_btn_file" "$pid_file"; exit 0' INT TERM
        trap 'save_history "$session_id" 2>/dev/null || true; pkill -TERM -P $BASHPID 2>/dev/null; rm -f "$stop_btn_file" "$pid_file"' EXIT

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

        # cc-oss-inspired token budget knob: either party can declare a budget
        # by including "+500k" / "use 50k tokens" / "spend 1.5m tokens" in their
        # message. Parsed on the user's input here; parsed on the assistant's
        # text inside the turn loop (further down). Sticky per-session until
        # /new or explicit clear. Drives both context display and hard-stop.
        local _user_budget
        _user_budget=$(printf '%s' "$input" | python3 tools/token_budget.py parse 2>/dev/null)
        if [[ -n "$_user_budget" ]]; then
            python3 tools/token_budget.py set "$session_id" "$_user_budget" user >/dev/null 2>&1
        fi
        # Inject the active-budget status (if any) into per-turn context so the
        # model can self-throttle. Empty string = no budget set = no line added.
        local _abudget_line
        _abudget_line=$(python3 tools/token_budget.py line "$session_id" 2>/dev/null)
        [[ -n "$_abudget_line" ]] && context_prompt+="${_abudget_line}\n"

        # Deferred tools: list names of tools the model COULD call but whose
        # schemas aren't loaded yet (saves ~1.5-2k tokens/turn baseline by
        # keeping their schemas out of the prompt until needed). Model uses
        # tool_search to fetch a schema when it actually wants to use one.
        local _deferred_list
        _deferred_list=$(python3 tools/tool_search.py list-deferred "$session_id" 2>/dev/null)
        if [[ -n "$_deferred_list" ]]; then
            context_prompt+="\n## Deferred Tools (call \`tool_search\` to load a schema)\n"
            context_prompt+="${_deferred_list}\n"
        fi

        # Active tasks (persistent, SQLite-backed via `task` tool). Shows up to
        # 5 pending+in_progress tasks for THIS session so the model sees its
        # own open work each turn. Empty when no tasks → no header rendered.
        local _tasks_context
        _tasks_context=$(python3 tools/task_manager.py context "$session_id" 2>/dev/null)
        if [[ -n "$_tasks_context" ]]; then
            context_prompt+="\n## Active Tasks (cross-session, see \`task\` tool to manage)\n"
            context_prompt+="${_tasks_context}\n"
        fi

        # Prior corrections: if the current input semantically matches a
        # past mistake by this user, surface the lesson. Uses the existing
        # Vertex text-embedding-004 path (tools/memory_helper.get_embedding).
        # Strict similarity threshold (0.82) so we only surface real matches.
        # Bounded timeout — never block a turn on this.
        if [[ -n "$input" && -n "${user_id:-}" ]]; then
            local _mistakes
            _mistakes=$(timeout 6 python3 tools/mistake_db.py recall \
                --user-id "${user_id}" \
                --query "${input}" \
                --top-k 2 \
                --min-sim 0.82 \
                2>/dev/null)
            if [[ -n "$_mistakes" && "$_mistakes" != "[]" ]]; then
                local _mistakes_block
                _mistakes_block=$(printf '%s' "$_mistakes" | python3 -c "
import json, sys
try:
    hits = json.load(sys.stdin)
    if not hits: sys.exit(0)
    lines = ['Past corrections for similar phrasings — apply the lesson, do not repeat the misread:']
    for h in hits[:2]:
        lesson = str(h.get('lesson','')).strip()
        want = str(h.get('actual_want','')).strip()
        sim = h.get('similarity', 0)
        if not lesson and not want: continue
        bits = []
        if lesson: bits.append(f'lesson: {lesson}')
        if want:   bits.append(f'wanted: {want}')
        lines.append(f'- ({sim:.2f}) ' + ' | '.join(bits))
    if len(lines) > 1:
        print('\\n'.join(lines))
except Exception:
    pass
" 2>/dev/null)
                if [[ -n "$_mistakes_block" ]]; then
                    context_prompt+="\n## Prior Corrections (semantic match on this input)\n${_mistakes_block}\n"
                fi
            fi
        fi

        # Citation warnings: hallucination flags raised by tools/citation_check.py
        # against the previous turn's reply. Render the most recent batch only
        # — keeps the context block bounded. Persisted file holds last 3 turns.
        local _cw_file="${DIR}/brain/state/citation_warnings_${session_id}.json"
        if [[ -f "$_cw_file" ]]; then
            local _cw_block
            _cw_block=$(python3 -c "
import json, sys
try:
    arr = json.load(open(sys.argv[1]))
    if isinstance(arr, list) and arr:
        last = arr[-1]
        viols = last.get('violations') or []
        if viols:
            lines = ['Your previous turn flagged these unsourced specific claims — do NOT repeat the pattern:']
            for v in viols[:5]:
                claim = str(v.get('claim',''))[:140]
                reason = str(v.get('reason',''))[:140]
                lines.append(f'- \"{claim}\" — {reason}')
            print('\\n'.join(lines))
except Exception:
    pass
" "$_cw_file" 2>/dev/null)
            if [[ -n "$_cw_block" ]]; then
                context_prompt+="\n## Citation Warnings (from previous turn)\n${_cw_block}\n"
            fi
        fi

        # Voice drift hint from previous turn (only when USER.md has voice prefs).
        local _vw_file="${DIR}/brain/state/voice_warnings_${session_id}.json"
        if [[ -f "$_vw_file" ]]; then
            local _vw_block
            _vw_block=$(python3 -c "
import json, sys
try:
    arr = json.load(open(sys.argv[1]))
    if isinstance(arr, list) and arr:
        e = arr[-1]
        reason = str(e.get('reason','')).strip()
        sugg   = str(e.get('suggestion','')).strip()
        if reason:
            line = f'Previous reply drifted from established voice: {reason}'
            if sugg: line += f' Suggestion: {sugg}'
            print(line)
except Exception:
    pass
" "$_vw_file" 2>/dev/null)
            if [[ -n "$_vw_block" ]]; then
                context_prompt+="\n## Voice Reminder\n${_vw_block}\n"
            fi
        fi

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
        local _status_query=0 _survey_query=0
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

        # Survey-query circuit breaker. Questions like "what can X do?",
        # "tell me about Y", "how does Z work" are answerable from
        # already-loaded context (system prompt, active skill body, MEMORY.md,
        # USER.md, recaps) without exploring the codebase. The koompi-biz-skill
        # incident (174s / 12 tool calls for "what can we do with it") showed
        # the agent treats capability questions as research projects by
        # default. Same enforcement as status-query: prompt nudge + clamp.
        # Status takes precedence — survey only fires when status didn't.
        if [[ "$_status_query" -eq 0 ]]; then
            if [[ "$input" =~ ^[Ww]hat\ (can|does)\ .+\ do ]] || \
               [[ "$input" =~ ^[Tt]ell\ me\ (about|what) ]] || \
               [[ "$input" =~ ^[Ww]hat\ (are|is)\ (the\ |your\ )?(capabilit|feature|tool|skill|abilit) ]] || \
               [[ "$input" =~ ^[Hh]ow\ does\ .+\ work ]] || \
               [[ "$input" =~ ^[Ww]hat.{0,3}s\ this\ (skill|tool|repo|project|file|script|module) ]] || \
               [[ "$input" =~ ^[Ww]hat\ (can|could)\ (you|we|i)\ do\ (with|using)\  ]]; then
                _survey_query=1
                MAX_TURNS=2
                context_prompt+="- **SURVEY QUERY** (detected): the answer lives in your already-loaded context — system prompt, active skill body, ## My Notes, ## About the User, recent recaps. Answer in **0 tool calls** when possible (1 if you need a single authoritative lookup). Do NOT list_files, search_files, grep, or read_code to 'enumerate capabilities' — that content is already in front of you. Only investigate the codebase if the user explicitly says 'go read', 'check the code', 'investigate', etc. MAX_TURNS clamped to 2.\n"
            fi
        fi

        # Heavy-query router: questions that need real reasoning depth (opinion,
        # evaluation, architectural choice, "is X a mistake", "what do you
        # think", rating) get routed to a pro model for this turn only. Cheap
        # models reflexively agree with leading premises and serve up generic
        # industry wisdom; pro models actually push back. Cost: ~5× flash for
        # a small fraction of turns. Override resolution:
        #   1. $HEAVY_MODEL env var if set (e.g. gemini-3-pro-preview)
        #   2. else, swap "flash" → "pro" in current MODEL if pattern matches
        #   3. else, no-op (user stays on whatever they configured)
        # Status-query and heavy-query are mutually exclusive in practice; if
        # both somehow fire, status takes precedence (already set above).
        if [[ "$_status_query" -eq 0 && "$_survey_query" -eq 0 && "${AMA_HEAVY_ROUTER_DISABLED:-0}" != "1" ]]; then
            local _heavy_query=0
            if [[ "$input" =~ [Ww]hat\ (do|would)\ you\ think ]] || \
               [[ "$input" =~ [Yy]our\ (thoughts?|opinion|take|view|verdict|assessment) ]] || \
               [[ "$input" =~ [Hh]ow\ would\ you\ rate ]] || \
               [[ "$input" =~ [Rr]ate\ (this|it|yourself|your|the) ]] || \
               [[ "$input" =~ [Ss]hould\ (we|I)\ (rewrite|migrate|switch|adopt|drop|move|refactor|redesign) ]] || \
               [[ "$input" =~ [Ii]s\ .+\ (a\ mistake|the\ right\ call|the\ best|worth\ it) ]] || \
               [[ "$input" =~ ([Ee]valuate|[Aa]ssess|[Cc]ritique|[Cc]ritic)\  ]] || \
               [[ "$input" =~ [Aa]ny\ way\ (we|I)\ can\ (improve|do\ better) ]] || \
               [[ "$input" =~ [Dd]o\ you\ (think|believe)\  ]] || \
               [[ "$input" =~ [Aa]rchitect(ure|ural)\ (decision|choice|review) ]]; then
                _heavy_query=1
                # Resolve heavy model: (1) $HEAVY_MODEL env override > (2) explicit
                # map in brain/tier_routing.json. NEVER fall back to mechanical
                # "flash→pro" substitution — produces non-existent model names
                # (e.g. gemini-3-flash-preview's real pro counterpart is
                # gemini-3.1-pro-preview, NOT gemini-3-pro-preview which 404s).
                local _heavy_model="${HEAVY_MODEL:-}"
                if [[ -z "$_heavy_model" ]]; then
                    _heavy_model=$(MODEL_LOOKUP="$MODEL" python3 -c "
import json, os
try:
    d = json.load(open('brain/tier_routing.json'))
    print(d.get('heavy_upgrade_map', {}).get(os.environ['MODEL_LOOKUP'], ''))
except Exception:
    pass
" 2>/dev/null)
                fi
                if [[ -n "$_heavy_model" && "$_heavy_model" != "$MODEL" ]]; then
                    echo "AMA: Heavy query — MODEL=$MODEL → $_heavy_model for this turn" >&2
                    MODEL="$_heavy_model"
                    context_prompt+="- **HEAVY QUERY** (detected): pro model active for this turn (escalated from flash). The user wants real reasoning depth — audit premises before answering, push back on bad framings, cite specifics, do not reflexively agree. Apply the **Critical Reasoning Discipline** section of the system prompt.\n"
                elif [[ -z "$_heavy_model" ]]; then
                    echo "AMA: Heavy query detected but no upgrade mapping for MODEL=$MODEL (set HEAVY_MODEL in .env or add to heavy_upgrade_map in tier_routing.json). Staying on $MODEL." >&2
                fi
            fi
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

        # Apply per-session provider override BEFORE model — switching providers
        # also switches BASE_URL/API_KEY via ${provider}_activate, and the
        # model_file value should win over any default the activator might set.
        # Written by tools/switch_provider.sh or /provider; cleared by writing
        # the literal string "default".
        if [[ -f "$provider_file" ]]; then
            local _session_provider; _session_provider=$(cat "$provider_file" 2>/dev/null)
            if [[ -n "$_session_provider" && "$_session_provider" != "$PROVIDER" ]]; then
                PROVIDER="$_session_provider"
                if type "${PROVIDER}_activate" >/dev/null 2>&1; then
                    "${PROVIDER}_activate" >/dev/null 2>&1 || true
                fi
                # google_activate sets _GOOGLE_VERTEX_MODEL_PREFIX="google/" — leaks
                # into non-google requests if we don't clear it. Same fix the
                # scheduler override path uses.
                [[ "$PROVIDER" != "google" ]] && unset _GOOGLE_VERTEX_MODEL_PREFIX
            fi
        fi

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
        # Per-run tally of how many TURNS each read-only tool appeared in.
        # A parallel batch of 8 reads in one turn = 1 (good — batching).
        # Sequential 8-turn cascade = 8 (bad — what we're nudging against).
        # Used by the idempotent-tool overuse guard below the fingerprint
        # circuit breaker. Killswitch: AMA_IDEMPOTENT_GUARD_DISABLED=1.
        local -A _ro_turn_counts=()
        # Persistent step log for the whole agent turn (Claude-Code-style cumulative pane).
        # Lines separated by \x1e (RS); each line = "<emoji>|<name>|<key_arg>|<duration_s>"
        local _steps_log=""
        # Persistent narration log — each entry is the assistant's "I'm doing X" sentence
        # for one tool batch, separated by \x1e. Renders as 📝 blockquote in the between-turn
        # pane and in the final message so the user can follow the agent's reasoning trail.
        local _narration_log=""
        local _RS=$'\x1e'
        # Tracks whether the user explicitly stopped this turn (/stop, Stop
        # button, or Interrupt). Set inside the loop when stop_flag is observed;
        # consumed by the render branches below to emit a "🛑 Stopped" message
        # instead of treating the abort as a max-turns failure.
        local _user_stopped=false
        # Tracks whether the active token budget was exhausted this turn. Set
        # inside the token-accounting block when spent ≥ budget. Drives a
        # dedicated render branch (similar to _user_stopped) so the user sees
        # "💸 Budget reached" instead of "Max turns reached".
        local _budget_exhausted=false
        while [ "$turn" -lt "$MAX_TURNS" ]; do
            # Cooperative stop check (top of every turn). The hard-kill path
            # (kill_tree_hard in router.sh) is the primary mechanism — this
            # polling exists so that a stop also lands cleanly when SIGTERM is
            # wedged behind a syscall (e.g. requests.post on a slow socket).
            # Whichever fires first wins; the other becomes a no-op.
            if [[ -f "$stop_flag" ]]; then
                _user_stopped=true
                break
            fi
            turn=$((turn + 1))
            [[ "$turn" -gt 1 ]] && tg_send_action "$chat_id" "typing" "$thread_id"
            export _AMA_REASONING_HTML="${_AMA_REASONING_HTML:-}"

            local result
            result=$(call_api_stream "$chat_id" "$msg_id" "$skill")

            # If kill_tree_hard fired during the stream, call_api_stream's
            # python child was killed and `result` is empty/partial. Check
            # stop_flag now so we render "Stopped" instead of "Failed".
            if [[ -f "$stop_flag" ]]; then
                _user_stopped=true
                break
            fi


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

                # Budget knob: assistant text can also set/replace the budget,
                # then we accumulate spend and check 90%/100% thresholds.
                if [[ -n "$text" && "$text" != "null" ]]; then
                    local _asst_budget
                    _asst_budget=$(printf '%s' "$text" | python3 tools/token_budget.py parse 2>/dev/null)
                    if [[ -n "$_asst_budget" ]]; then
                        python3 tools/token_budget.py set "$session_id" "$_asst_budget" assistant >/dev/null 2>&1
                    fi
                fi
                local _bdelta=$((${_it:-0} + ${_ot:-0}))
                if [[ "$_bdelta" -gt 0 ]]; then
                    local _bstatus
                    _bstatus=$(python3 tools/token_budget.py add "$session_id" "$_bdelta" 2>/dev/null)
                    if [[ -n "$_bstatus" ]]; then
                        local _bspent _bpct _bcrossed _bexh
                        IFS='|' read -r _bspent _bpct _bcrossed _bexh <<< "$_bstatus"
                        # 90% crossing — inject a one-shot system reminder into
                        # history. The model sees it on the next call and can
                        # gracefully wrap up. (Mirrors cc-oss continuation msg.)
                        if [[ "$_bcrossed" == "1" ]]; then
                            append_text "user" "[SYSTEM: Token budget warning — you've used ${_bspent} tokens (${_bpct}% of declared budget). Wrap up: finish the current task efficiently or summarize what you've done. Do not abandon — you have ~10% remaining.]"
                        fi
                        # 100% — hard-stop the turn loop. Render branch below
                        # will show a "💸 Budget reached" message with the
                        # narration trail so the user can see what got done.
                        if [[ "$_bexh" == "1" ]]; then
                            _budget_exhausted=true
                            break
                        fi
                    fi
                fi
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
                    # Accumulate narration for the cumulative pane + final render.
                    # Single-line, capped at 240 chars; the pane keeps only the last N entries.
                    local _narr_line
                    _narr_line=$(printf '%s' "$text" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
                    if [[ ${#_narr_line} -gt 240 ]]; then
                        _narr_line="${_narr_line:0:240}…"
                    fi
                    [[ -n "$_narr_line" ]] && _narration_log+="${_narration_log:+$_RS}${_narr_line}"
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
                # Post-batch file-mutation verifier (hermes v0.14.0 pattern).
                # Stats every file targeted by write tools in THIS batch; if any
                # exist + sizes look off, append the footer to the last tool
                # result so the model can spot silent write failures before its
                # next text reply (or before the next tool batch).
                local _fm_footer
                _fm_footer=$(printf '%s' "$tool_calls" | python3 tools/file_mutation_check.py 2>/dev/null)
                if [[ -n "$_fm_footer" ]]; then
                    HISTORY=$(python3 -c "
import json, sys
h = json.loads(open(sys.argv[1]).read())
footer = open(sys.argv[2]).read()
for i in range(len(h)-1, -1, -1):
    if h[i].get('role') == 'tool':
        c = h[i].get('content', '')
        h[i]['content'] = str(c) + '\n' + footer
        break
print(json.dumps(h, separators=(',',':')))
" <(printf '%s' "$HISTORY") <(printf '%s' "$_fm_footer") 2>/dev/null || printf '%s' "$HISTORY")
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

                # Circuit breaker: identical tool-call batch repeats.
                # Two-stage: nudge at 3rd identical call (give the model one
                # turn to recover), hard-stop at 4th. Previously hard-stopped
                # at 3rd, which killed transient stuck patterns the model
                # would have recovered from on its own with a hint.
                local _tc_fp; _tc_fp=$(printf '%s' "$tool_calls" | md5sum 2>/dev/null | cut -c1-8)
                if [[ "$_tc_fp" == "$_last_tc_fingerprint" && -n "$_tc_fp" ]]; then
                    _tc_repeat_count=$((_tc_repeat_count + 1))
                    if [[ $_tc_repeat_count -eq 2 ]]; then
                        # 3rd identical call — nudge into the last tool result.
                        # The next API call sees it and (usually) changes course.
                        local _fp_nudge=$'\n[SYSTEM: You just made the EXACT same tool call as the previous turn (same tool, same args). The result has not changed. STOP retrying with identical args. Either (a) try a DIFFERENT approach — different tool, different args, different angle, (b) answer from what you already have, or (c) call `clarify` to ask the user. One more identical call will hard-stop this turn.]'
                        HISTORY=$(NUDGE_TEXT="$_fp_nudge" python3 -c "
import json, os, sys
h = json.loads(open(sys.argv[1]).read())
nudge = os.environ['NUDGE_TEXT']
for i in range(len(h)-1, -1, -1):
    if h[i].get('role') == 'tool':
        h[i]['content'] = str(h[i].get('content','')) + nudge
        break
print(json.dumps(h, separators=(',',':')))
" <(printf '%s' "$HISTORY") 2>/dev/null || printf '%s' "$HISTORY")
                    elif [[ $_tc_repeat_count -ge 3 ]]; then
                        # 4th identical call — ignored the nudge. Hard-stop.
                        tg_edit "$chat_id" "$msg_id" \
                            "⚠️ <i>Stuck loop detected — same tool call repeated 4× in a row, including after a recovery nudge. Stopping early to save tokens. Use /retry if needed.</i>" \
                            "HTML" > /dev/null 2>&1 || true
                        loop_completed=false
                        break
                    fi
                else
                    _tc_repeat_count=0
                    _last_tc_fingerprint="$_tc_fp"
                fi

                # Idempotent-tool overuse guard (hermes-style, AMA-adapted).
                # The fingerprint check above only catches identical-batch
                # repeats. This catches DIFFERENT-arg cascades of the same
                # read-only tool (read_code A, then B, then C across N turns)
                # — the koompi-biz-skill 174s / 12-call exploration pattern.
                # Metric: turns each tool appeared in. Parallel batch in one
                # turn counts as 1; sequential cascade counts as N. Soft nudge
                # at 3, strong nudge at 5. No hard-stop — agent keeps agency.
                if [[ "${AMA_IDEMPOTENT_GUARD_DISABLED:-0}" != "1" ]]; then
                    local _ro_seen_this_turn=","
                    while IFS= read -r _ro_name; do
                        [[ -z "$_ro_name" ]] && continue
                        case "$_ro_name" in
                            read_code|list_files|search_files|repo_map|fetch_url|web_search|session_search|memory_recall) ;;
                            *) continue ;;
                        esac
                        # Count each tool at most once per turn — parallel batches don't get punished.
                        [[ "$_ro_seen_this_turn" == *",$_ro_name,"* ]] && continue
                        _ro_seen_this_turn+="$_ro_name,"
                        _ro_turn_counts[$_ro_name]=$((${_ro_turn_counts[$_ro_name]:-0} + 1))
                        local _ron=${_ro_turn_counts[$_ro_name]}
                        local _ro_nudge=""
                        if [[ $_ron -eq 3 ]]; then
                            _ro_nudge=$'\n[SYSTEM: You\'ve now called `'"$_ro_name"$'` across 3 separate turns this run. If you have more queued, BATCH them in one response (the harness runs them in parallel). If you have enough context, ANSWER NOW. Sequential per-turn calls cost ~10s of round-trip each — batching is ~10s total.]'
                        elif [[ $_ron -ge 5 ]]; then
                            _ro_nudge=$'\n[SYSTEM: '"$_ron"$' turns of sequential `'"$_ro_name"$'` calls — this is the cascade pattern. STOP exploring. Either (a) answer from what you already have, (b) call `clarify` to ask the user what they actually want, or (c) batch any remaining reads in ONE final response. Do NOT make another isolated `'"$_ro_name"$'` call.]'
                        fi
                        if [[ -n "$_ro_nudge" ]]; then
                            HISTORY=$(NUDGE_TEXT="$_ro_nudge" python3 -c "
import json, os, sys
h = json.loads(open(sys.argv[1]).read())
nudge = os.environ['NUDGE_TEXT']
for i in range(len(h)-1, -1, -1):
    if h[i].get('role') == 'tool':
        h[i]['content'] = str(h[i].get('content','')) + nudge
        break
print(json.dumps(h, separators=(',',':')))
" <(printf '%s' "$HISTORY") 2>/dev/null || printf '%s' "$HISTORY")
                        fi
                    done < <(python3 -c "
import json, sys
try:
    for tc in json.loads(open(sys.argv[1]).read()):
        n = tc.get('function',{}).get('name','') or tc.get('name','')
        if n: print(n)
except Exception: pass
" <(printf '%s' "$tool_calls") 2>/dev/null)
                fi

                # /stop resilience: persist HISTORY after every completed tool
                # batch so an interrupt or kill mid-turn never costs the user
                # the work that already finished. Without this, save_history
                # only fires at line ~1299 (end of turn) — a /stop mid-loop
                # loses every tool result accumulated this turn. Pair with
                # the EXIT-trap save (defensive) and the load_history
                # placeholder synth (which heals the orphaned tool_call from
                # the in-flight tool that didn't get to land).
                save_history "$session_id"

                # Cumulative step-log pane (Claude-Code-style) — replaces the prior
                # "last 4 tool names" block. Shows every completed step in this turn
                # with status emoji, key arg, and elapsed duration.
                local _between_msg
                _between_msg=$(STEPS_LOG="$_steps_log" \
                               NARRATION_LOG="$_narration_log" \
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
def md_light(t):
    t = esc(t)
    t = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', t)
    t = re.sub(r'\`([^\`]+)\`', r'<code>\1</code>', t)
    t = re.sub(r'(?<![A-Za-z0-9])_([^_]+)_(?![A-Za-z0-9])', r'<i>\1</i>', t)
    return t

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

# Cumulative narration — last 6 'I'm doing X' sentences from the model, one per tool batch.
# Renders as a single blockquote at the top so the user sees the agent's reasoning trail.
narr_raw = os.environ.get('NARRATION_LOG','')
narr_lines = []
if narr_raw:
    for entry in narr_raw.split(chr(0x1e))[-6:]:
        entry = entry.strip()
        if entry:
            narr_lines.append(f'📝 {md_light(entry)}')

snippet = os.environ.get('REASONING_SNIPPET','').strip()
word = os.environ.get('STATUS_WORD','Thinking')

out = []
if narr_lines:
    out.append('<blockquote>' + '\n'.join(narr_lines) + '</blockquote>')
if snippet:
    out.append(f'<blockquote>💭 {md_light(snippet)}</blockquote>')
if lines:
    out.append('\n'.join(lines))
out.append(f'<i>{word}…</i>')
print('\n'.join(out))
" 2>/dev/null || echo "⏳ <i>Thinking…</i>")
                tg_edit "$chat_id" "$msg_id" "$_between_msg" "HTML" > /dev/null 2>&1
                export _AMA_REASONING_HTML=""
                # Final stop_flag check before going back for another model call —
                # catches a Stop click that landed while tools were executing. Without
                # this, we'd issue one more (potentially slow) API call before noticing.
                if [[ -f "$stop_flag" ]]; then
                    _user_stopped=true
                    break
                fi
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

        if [[ "$_user_stopped" == true ]]; then
            # User clicked Stop/Interrupt or sent /stop. Show the narration trail +
            # step list so they can see where the agent was when they stopped it.
            local _stopped_pane
            _stopped_pane=$(STEPS_LOG="$_steps_log" NARRATION_LOG="$_narration_log" python3 -c "
import os, re
EMOJI = {'bash':'🛠️','web_search':'🔍','fetch_url':'🌐','read_file':'📖','write_file':'✍️',
         'edit_code':'📝','search_files':'🔎','todo':'📋','memory':'🧠','memory_remember':'🧠',
         'memory_recall':'🧠','process':'⚙️','browser':'🌍','image_generate':'🎨','patch':'🩹',
         'repo_map':'🗺️','clarify':'❓','session_search':'🗂️','sys_info':'📊','recap':'📝',
         'custom_tool_manager':'🔧','skill_manager':'🎯','skill_install':'📦','insights':'📈',
         'delegate':'🤖','ast_edit':'🔬','last_session':'🗓️','send_file':'📤'}
def esc(s): return s.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;')
def md_light(t):
    t = esc(t)
    t = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', t)
    t = re.sub(r'\`([^\`]+)\`', r'<code>\1</code>', t)
    t = re.sub(r'(?<![A-Za-z0-9])_([^_]+)_(?![A-Za-z0-9])', r'<i>\1</i>', t)
    return t
out = []
narr_raw = os.environ.get('NARRATION_LOG','')
if narr_raw:
    narr_out = [f'📝 {md_light(e.strip())}' for e in narr_raw.split(chr(0x1e))[-6:] if e.strip()]
    if narr_out:
        out.append('<blockquote>' + '\n'.join(narr_out) + '</blockquote>')
raw = os.environ.get('STEPS_LOG','')
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
            local _stop_full="🛑 <i>Stopped by user.</i>"
            [[ -n "$_stopped_pane" ]] && _stop_full="${_stopped_pane}"$'\n\n'"${_stop_full}"
            tg_edit_safe "$chat_id" "$msg_id" "$_stop_full" "HTML" "$thread_id" || true
            [[ -n "$user_msg_id" && "$user_msg_id" != "0" ]] && tg_react "$chat_id" "$user_msg_id" "👎" || true
        elif [[ "$_budget_exhausted" == true ]]; then
            # Token budget reached. Show narration + steps + the budget status
            # line so the user can see how far the agent got and decide whether
            # to /retry with a larger budget or accept the partial result.
            local _budget_status_line
            _budget_status_line=$(python3 tools/token_budget.py line "$session_id" 2>/dev/null | sed 's/^- \*\*Active budget\*\*[^:]*:/💸/;s/⚠ approaching limit/exhausted/')
            local _bx_pane
            _bx_pane=$(STEPS_LOG="$_steps_log" NARRATION_LOG="$_narration_log" python3 -c "
import os, re
EMOJI = {'bash':'🛠️','web_search':'🔍','fetch_url':'🌐','read_file':'📖','write_file':'✍️',
         'edit_code':'📝','search_files':'🔎','todo':'📋','memory':'🧠','memory_remember':'🧠',
         'memory_recall':'🧠','process':'⚙️','browser':'🌍','image_generate':'🎨','patch':'🩹',
         'repo_map':'🗺️','clarify':'❓','session_search':'🗂️','sys_info':'📊','recap':'📝',
         'custom_tool_manager':'🔧','skill_manager':'🎯','skill_install':'📦','insights':'📈',
         'delegate':'🤖','ast_edit':'🔬','last_session':'🗓️','send_file':'📤'}
def esc(s): return s.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;')
def md_light(t):
    t = esc(t)
    t = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', t)
    t = re.sub(r'\`([^\`]+)\`', r'<code>\1</code>', t)
    t = re.sub(r'(?<![A-Za-z0-9])_([^_]+)_(?![A-Za-z0-9])', r'<i>\1</i>', t)
    return t
out = []
narr_raw = os.environ.get('NARRATION_LOG','')
if narr_raw:
    narr_out = [f'📝 {md_light(e.strip())}' for e in narr_raw.split(chr(0x1e))[-6:] if e.strip()]
    if narr_out:
        out.append('<blockquote>' + '\n'.join(narr_out) + '</blockquote>')
raw = os.environ.get('STEPS_LOG','')
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
            local _bx_full="💸 <i>Token budget reached.</i> ${_budget_status_line:-}\n<i>Use /budget clear or send a new budget to continue, or /retry to resume.</i>"
            [[ -n "$_bx_pane" ]] && _bx_full="${_bx_pane}"$'\n\n'"${_bx_full}"
            tg_edit_safe "$chat_id" "$msg_id" "$_bx_full" "HTML" "$thread_id" || true
            [[ -n "$user_msg_id" && "$user_msg_id" != "0" ]] && tg_react "$chat_id" "$user_msg_id" "👎" || true
        elif [[ "$loop_completed" == true ]]; then
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
                _step_pane=$(STEPS_LOG="$_steps_log" NARRATION_LOG="$_narration_log" python3 -c "
import os, re
EMOJI = {'bash':'🛠️','web_search':'🔍','fetch_url':'🌐','read_file':'📖','write_file':'✍️',
         'edit_code':'📝','search_files':'🔎','todo':'📋','memory':'🧠','memory_remember':'🧠',
         'memory_recall':'🧠','process':'⚙️','browser':'🌍','image_generate':'🎨','patch':'🩹',
         'repo_map':'🗺️','clarify':'❓','session_search':'🗂️','sys_info':'📊','recap':'📝',
         'custom_tool_manager':'🔧','skill_manager':'🎯','skill_install':'📦','insights':'📈',
         'delegate':'🤖','ast_edit':'🔬','last_session':'🗓️','send_file':'📤'}
def esc(s): return s.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;')
def md_light(t):
    t = esc(t)
    t = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', t)
    t = re.sub(r'\`([^\`]+)\`', r'<code>\1</code>', t)
    t = re.sub(r'(?<![A-Za-z0-9])_([^_]+)_(?![A-Za-z0-9])', r'<i>\1</i>', t)
    return t

out = []
# Narration trail (📝 lines) — the post-mortem of what the agent was thinking
# at each tool batch. Rendered above the tool list, below the final answer body.
narr_raw = os.environ.get('NARRATION_LOG','')
if narr_raw:
    narr_out = []
    for e in narr_raw.split(chr(0x1e))[-6:]:
        e = e.strip()
        if e:
            narr_out.append(f'📝 {md_light(e)}')
    if narr_out:
        out.append('<blockquote>' + '\n'.join(narr_out) + '</blockquote>')

raw = os.environ.get('STEPS_LOG','')
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
                # Final-render order: ANSWER → collapsed trail spoiler → footer.
                # The narration + step list is preserved (drill-down for the
                # curious) but tucked behind <tg-spoiler> so the answer reads
                # clean by default. During the run the trail is still visible
                # in the between-turn pane; only the final edit collapses it.
                # Strip the <blockquote> wrapper around narration before
                # spoiler-wrapping — block-inside-inline nesting is fragile in
                # Telegram's HTML parser, and the spoiler collapse already
                # provides the visual containment blockquote was giving.
                local _full_html="$_rendered_text"
                if [[ -n "$_step_pane" ]]; then
                    local _step_pane_flat="${_step_pane//<blockquote>/}"
                    _step_pane_flat="${_step_pane_flat//<\/blockquote>/}"
                    _full_html="${_full_html}"$'\n\n'"<tg-spoiler>${_step_pane_flat}</tg-spoiler>"
                fi
                _full_html="${_full_html}"$'\n\n'"${_footer}"
                [[ -n "$_ctx_warn" ]] && _full_html+=$'\n'"${_ctx_warn}"
                tg_edit_safe "$chat_id" "$msg_id" "$_full_html" "HTML" "$thread_id"
                # Log the final-answer message_id for reaction-capture lookup later.
                # Fully detached so it never blocks the user-visible response.
                ( python3 "${DIR}/tools/learning_capture.py" log \
                    --chat-id "$chat_id" --message-id "$msg_id" \
                    --session-id "$session_id" --user-id "${user_id:-}" \
                    --user-text "${input:0:2000}" \
                    --assistant-text "${text:0:4000}" \
                    --model "${MODEL:-}" >/dev/null 2>&1 ) &
            elif [[ -n "$text" && "$text" != "null" && $total_tool_calls -eq 0 ]]; then
                local _final_html; _final_html="$(md_to_tg_html "$text")"
                [[ -n "$_ctx_warn" ]] && _final_html+=$'\n'"${_ctx_warn}"
                # No-tool footer: tokens (always when >0) + elapsed (≥10s).
                # _tok_str is " | 1.2k tok"; _elapsed_str is " ⏱ 25s". Strip
                # the leading separator and stitch with " · " between parts.
                local _meta=""
                [[ -n "$_tok_str" ]] && _meta="${_tok_str# | }"
                if [[ -n "$_elapsed_str" ]]; then
                    [[ -n "$_meta" ]] && _meta+=" · "
                    _meta+="${_elapsed_str# }"
                fi
                [[ -n "$_meta" ]] && _final_html+=$'\n'"<i>╴ ${_meta}</i>"
                tg_edit_safe "$chat_id" "$msg_id" "$_final_html" "HTML" "$thread_id"
                # Log the final-answer message_id for reaction-capture lookup later.
                ( python3 "${DIR}/tools/learning_capture.py" log \
                    --chat-id "$chat_id" --message-id "$msg_id" \
                    --session-id "$session_id" --user-id "${user_id:-}" \
                    --user-text "${input:0:2000}" \
                    --assistant-text "${text:0:4000}" \
                    --model "${MODEL:-}" >/dev/null 2>&1 ) &
            else
                # Empty response — Gemini thinking-only output or scrubbed content.
                # The ⏳ placeholder is still showing. Replace it with a retry prompt.
                tg_edit "$chat_id" "$msg_id" "🤔 <i>No response generated (model may have only produced internal reasoning). Use /retry to try again.</i>" "HTML" > /dev/null 2>&1 || true
                [[ -n "$user_msg_id" && "$user_msg_id" != "0" ]] && tg_react "$chat_id" "$user_msg_id" "👎" || true
            fi
            # React ✅ on the user's original message (hermes: done signal)
            [[ -z "$text" ]] || { [[ -n "$user_msg_id" && "$user_msg_id" != "0" ]] && tg_react "$chat_id" "$user_msg_id" "✅"; }
        else
            # Loop hit max turns without clean exit — show the narration trail + steps
            # so the user can see where the agent got stuck (most useful failure mode for debugging).
            local _stuck_pane
            _stuck_pane=$(STEPS_LOG="$_steps_log" NARRATION_LOG="$_narration_log" python3 -c "
import os, re
EMOJI = {'bash':'🛠️','web_search':'🔍','fetch_url':'🌐','read_file':'📖','write_file':'✍️',
         'edit_code':'📝','search_files':'🔎','todo':'📋','memory':'🧠','memory_remember':'🧠',
         'memory_recall':'🧠','process':'⚙️','browser':'🌍','image_generate':'🎨','patch':'🩹',
         'repo_map':'🗺️','clarify':'❓','session_search':'🗂️','sys_info':'📊','recap':'📝',
         'custom_tool_manager':'🔧','skill_manager':'🎯','skill_install':'📦','insights':'📈',
         'delegate':'🤖','ast_edit':'🔬','last_session':'🗓️','send_file':'📤'}
def esc(s): return s.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;')
def md_light(t):
    t = esc(t)
    t = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', t)
    t = re.sub(r'\`([^\`]+)\`', r'<code>\1</code>', t)
    t = re.sub(r'(?<![A-Za-z0-9])_([^_]+)_(?![A-Za-z0-9])', r'<i>\1</i>', t)
    return t
out = []
narr_raw = os.environ.get('NARRATION_LOG','')
if narr_raw:
    narr_out = [f'📝 {md_light(e.strip())}' for e in narr_raw.split(chr(0x1e))[-6:] if e.strip()]
    if narr_out:
        out.append('<blockquote>' + '\n'.join(narr_out) + '</blockquote>')
raw = os.environ.get('STEPS_LOG','')
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
            local _stuck_body; _stuck_body="$(md_to_tg_html "${text:-}")"
            local _stuck_full="${_stuck_body}"
            [[ -n "$_stuck_pane" ]] && _stuck_full="${_stuck_pane}"$'\n\n'"${_stuck_full}"
            _stuck_full="${_stuck_full}"$'\n\n'"⚠️ <i>Max turns reached. Use /retry to continue or /new for fresh session.</i>"
            tg_edit_safe "$chat_id" "$msg_id" "$_stuck_full" "HTML" "$thread_id" || true
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
        # Skip post-turn background work entirely on user-initiated stop or
        # budget exhaustion — the turn was aborted, reflection would be partial
        # or misleading, and the curator would burn tokens analysing an
        # incomplete trajectory (defeating the budget the user just imposed).
        if [[ $total_tool_calls -gt 0 && "$_user_stopped" != true && "$_budget_exhausted" != true ]]; then
            (
                (
                    # Reflection (read-only inspection, saves to LanceDB).
                    # NOTE: session-level recap is intentionally NOT done here —
                    # it fires from the /new (router.sh) handler against the
                    # just-archived history file, so each recap covers a full
                    # session instead of a single turn.
                    reflect_turn "$chat_id" "$thread_id" "$session_id"

                    # Citation check: event-driven hallucination scan on the
                    # final assistant reply. Cheap pre-filter skips most turns;
                    # only fires the LLM call when specific-fact patterns appear.
                    # Writes warnings to brain/state/citation_warnings_<sid>.json
                    # for next turn's context block. Always fail-silent.
                    timeout 30 python3 tools/citation_check.py \
                        --session-id "$session_id" \
                        --history "${DIR}/brain/state/history_${session_id}.json" \
                        > /dev/null 2>&1 || true

                    # Mistake detection: regex pre-filter on the user's latest
                    # message; if it looks like a correction, run extraction
                    # via cheap model and record to brain/state/mistakes.db.
                    # Recalled on future turns when similar phrasings appear.
                    timeout 30 python3 tools/mistake_detect.py \
                        --session-id "$session_id" \
                        --user-id "${user_id:-}" \
                        --history "${DIR}/brain/state/history_${session_id}.json" \
                        > /dev/null 2>&1 || true

                    # Voice drift check: skips immediately if USER.md has no
                    # voice/style entries, so most users pay zero cost. When
                    # voice prefs exist, scans the last reply for drift and
                    # persists a single warning for next turn.
                    timeout 30 python3 tools/voice_check.py \
                        --session-id "$session_id" \
                        --history "${DIR}/brain/state/history_${session_id}.json" \
                        > /dev/null 2>&1 || true

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
