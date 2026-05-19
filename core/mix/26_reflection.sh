#!/bin/bash
# core/mix/26_reflection.sh - Autonomous Self-Reflection + Session Recap

# Save a structured session recap. Triggered at session boundaries (e.g. /new):
# we summarise the just-archived history file and append one entry to
# brain/state/session_recaps.jsonl tagged with a unique session_id.
#
# Args:
#   $1  session_id   — tag for the recap entry (typically "<sid>_<unix_ts>")
#   $2  history_file — path to the JSON history to summarise (archived file)
save_session_recap() {
    local session_id="$1"
    local history_file="$2"

    [[ -z "$history_file" || ! -f "$history_file" ]] && return

    # Skip for short sessions (< 8 messages) — not enough substance to recap
    local count
    count=$(python3 -c "import json,sys; print(len(json.loads(open(sys.argv[1]).read())))" "$history_file" 2>/dev/null); count=${count:-0}
    [[ "$count" -lt 8 ]] && return

    # Skip for offline models — too slow for background recap
    [[ "$PROVIDER" == "ollama" ]] && return

    echo "AMA: Generating session recap for $session_id from $(basename "$history_file") ($count msgs)..." >&2

    # Build a compact transcript: keep first 4 + last 30 messages (so we
    # capture the opening intent and the final outcomes), truncate long
    # tool args / results so we don't blow the prompt budget.
    local _transcript
    _transcript=$(python3 - "$history_file" <<'PYEOF' 2>/dev/null
import json, sys
h = json.load(open(sys.argv[1]))

def fmt(m):
    role = m.get('role', '?')
    if role == 'user':
        c = m.get('content', '')
        if isinstance(c, list):
            c = ' '.join(p.get('text','') for p in c if isinstance(p, dict))
        return f'USER: {str(c)[:1200].strip()}'
    if role == 'assistant':
        out = []
        c = m.get('content') or ''
        if isinstance(c, list):
            c = ' '.join(p.get('text','') for p in c if isinstance(p, dict))
        c = str(c).strip()
        if c:
            out.append(f'ASSISTANT: {c[:1200]}')
        for tc in (m.get('tool_calls') or []):
            f = tc.get('function', {}) or {}
            n = f.get('name','?')
            a = f.get('arguments','{}')
            out.append(f'  -> {n}({str(a)[:240]})')
        return '\n'.join(out) if out else ''
    if role == 'tool':
        c = m.get('content', '') or ''
        n = m.get('name','?')
        return f'  <- {n}: {str(c)[:500].strip()}'
    return ''

# Sandwich: first 4 + last 30 (dedupe overlap), with a marker in between if we skipped.
head = h[:4]
tail = h[-30:] if len(h) > 34 else h[4:]
parts = []
for m in head:
    s = fmt(m)
    if s: parts.append(s)
if len(h) > 4 + len(tail):
    parts.append(f'  ... [omitted {len(h) - 4 - len(tail)} middle messages] ...')
for m in tail:
    s = fmt(m)
    if s: parts.append(s)
print('\n'.join(parts))
PYEOF
)

    if [[ -z "$_transcript" ]]; then
        echo "AMA: recap aborted — empty transcript from $history_file" >&2
        return
    fi

    # Compose the recap prompt: the actual session content + the format spec.
    local _prompt_tmp; _prompt_tmp=$(mktemp)
    {
        echo "Below is a session transcript. Generate a recap of THIS session — do not invent content."
        echo
        echo "=== TRANSCRIPT START ==="
        echo "$_transcript"
        echo "=== TRANSCRIPT END ==="
        echo
        echo "Output format (use these exact headers, no preamble):"
        echo
        echo "## Session Summary"
        echo "[1-2 sentences describing what was actually done in the transcript above]"
        echo
        echo "## Key Facts Learned"
        echo "[Bullet list: non-obvious user preferences, environment details, or decisions observed in the transcript. Skip the section's content with 'None.' if nothing qualifies.]"
        echo
        echo "## Unresolved Items"
        echo "[Bullet list: things explicitly left incomplete or errors not fixed. 'None.' if all resolved.]"
        echo
        echo "## Next Steps"
        echo "[1-3 bullets of likely next actions implied by the transcript. Skip with 'None.' if unclear.]"
        echo
        echo "Rules: Under 200 words total. Reference only facts present in the transcript. No conversational filler."
    } > "$_prompt_tmp"

    local saved_history="${HISTORY:-}"
    # Use AMA_TOOLS_OVERRIDE to pass [] without touching brain/tools.json.
    local _saved_override="${AMA_TOOLS_OVERRIDE:-}"
    export AMA_TOOLS_OVERRIDE="[]"
    # Prevent recap's 429s from poisoning the main agent's rate limit state.
    local _saved_no_rate_mark="${_AMA_NO_RATE_MARK:-0}"
    export _AMA_NO_RATE_MARK=1
    trap 'export AMA_TOOLS_OVERRIDE="$_saved_override"; export _AMA_NO_RATE_MARK="$_saved_no_rate_mark"; HISTORY="$saved_history"; rm -f "$_prompt_tmp"' EXIT INT TERM

    local _recap_hist
    _recap_hist=$(python3 - "$_prompt_tmp" <<'PYEOF' 2>/dev/null
import json, sys
sp = open(sys.argv[1]).read()
print(json.dumps([{"role": "user", "content": sp}]))
PYEOF
)
    rm -f "$_prompt_tmp"

    if [[ -z "$_recap_hist" ]]; then
        echo "AMA: recap aborted — failed to build prompt payload" >&2
        return
    fi

    HISTORY="$_recap_hist"
    local recap_response
    recap_response=$(call_api "You are a session summarizer. Be concise and factual.")

    [[ -z "$recap_response" || "$recap_response" == "FAIL:"* ]] && return

    local recap_text
    recap_text=$(python3 -c "
import sys, json
try:
    r = json.loads(open(sys.argv[1]).read())
    print(r.get('choices',[{}])[0].get('message',{}).get('content','').strip(), end='')
except: pass
" <(printf '%s' "$recap_response") 2>/dev/null)

    [[ -z "$recap_text" ]] && return

    # 1. Append to session_recaps.jsonl (local persistent log)
    local recaps_file="brain/state/session_recaps.jsonl"
    mkdir -p "brain/state"
    python3 -c "
import json, sys
entry = {
    'ts': __import__('datetime').datetime.utcnow().isoformat() + 'Z',
    'session_id': sys.argv[2],
    'recap': open(sys.argv[1]).read()
}
with open('$recaps_file', 'a') as f:
    f.write(json.dumps(entry) + '\n')
# Trim to last 100 recaps
lines = open('$recaps_file').readlines()
if len(lines) > 120:
    open('$recaps_file', 'w').writelines(lines[-100:])
" <(printf '%s' "$recap_text") "$session_id" 2>/dev/null

    # 2. Save full recap narrative to vector memory for broad semantic recall
    if [[ -f "tools/memory_helper.py" ]]; then
        python3 tools/memory_helper.py save \
            "[Session Recap $session_id] $recap_text" \
            "{\"session_id\": \"$session_id\", \"type\": \"session_recap\"}" 2>/dev/null || true
    fi

    # 3. Extract individual "Key Facts Learned" bullets → discrete LanceDB entries
    #    Each fact gets its own embedding so "does user prefer X?" finds it precisely
    if [[ -f "tools/memory_helper.py" ]]; then
        local _recap_tmp; _recap_tmp=$(mktemp)
        printf '%s' "$recap_text" > "$_recap_tmp"
        python3 - "$_recap_tmp" "$session_id" <<'PYEOF' 2>/dev/null || true
import re, json, subprocess, sys

recap = open(sys.argv[1]).read()
session_id = sys.argv[2]

m = re.search(r'##\s+Key Facts Learned\s*\n(.*?)(?=\n##|\Z)', recap, re.DOTALL | re.IGNORECASE)
if m:
    for line in m.group(1).splitlines():
        fact = re.sub(r'^[\s\-\*•]+', '', line).strip()
        if len(fact) < 15:
            continue
        meta = json.dumps({"session_id": session_id, "type": "fact", "source": "auto_extract"})
        subprocess.run(
            ["python3", "tools/memory_helper.py", "save", fact, meta],
            capture_output=True
        )
PYEOF
        rm -f "$_recap_tmp"
    fi

    echo "AMA: Session recap saved for $session_id."
}

reflect_turn() {
    local chat_id="$1"
    local thread_id="$2"
    local session_id="$3"

    # Only reflect if the user isn't just saying 'hi'
    local last_user_msg
    last_user_msg=$(python3 -c "
import json, sys
h = json.loads(open(sys.argv[1]).read())
user_msgs = [m for m in h if m.get('role') == 'user']
if user_msgs:
    print(user_msgs[-1].get('content', ''))
" <(printf '%s' "$HISTORY") 2>/dev/null)
    if [[ ${#last_user_msg} -lt 20 ]]; then
        return
    fi

    # Skip reflection for local/offline models — too slow for background calls
    if [[ "$PROVIDER" == "ollama" ]]; then
        return
    fi

    echo "AMA: Starting self-reflection for $session_id..."

    # Create a hidden reflection prompt
    local reflection_sys_prompt="You are the Reflection Core of AMA.
Review the conversation above and do the following (use tools, don't just describe):

1. ERRORS: Call read_error_log and check if any errors happened in this session.
   If the same error appeared 2+ times, call memory_remember to note the pattern.

2. MEMORY: Save any new durable facts about the user, their preferences, or environment
   using memory_remember. Only save high-signal facts worth recalling in future sessions.

3. INSIGHTS: If the user achieved something important or the session revealed a useful pattern,
   summarize it with memory_remember (type=insight).

Available tools: read_error_log, check_health, memory_remember, memory_recall, session_search,
sys_info, insights, search_files, web_search, fetch_url, clarify.

DO NOT use bash, edit_code, write_file, or any file-modifying tools here.
If you find a critical error pattern needing a code fix, use clarify to notify the user.

If there is nothing worth noting, respond with exactly: NO_ACTION
"

    # Save current history
    local temp_history="$HISTORY"

    # Override HISTORY to only include safe/read-only tools for reflection
    # Build safe tool subset from the real tools.json (before any override)
    local _real_tools; _real_tools=$(cat brain/tools.json 2>/dev/null || echo '[]')
    local _safe_tools
    _safe_tools=$(python3 -c "
import json, sys
try:
    tools = json.loads(sys.argv[1])
    allowed = {'memory_remember','memory_recall','session_search','memory',
               'read_error_log','check_health','sys_info','insights',
               'search_files','web_search','fetch_url','todo','clarify'}
    safe = [t for t in tools if t.get('name','') in allowed]
    print(json.dumps(safe, separators=(',',':')))
except:
    print('[]')
" "$_real_tools" 2>/dev/null)

    # Use AMA_TOOLS_OVERRIDE instead of touching brain/tools.json —
    # eliminates the race condition with concurrent save_session_recap
    local _saved_override="${AMA_TOOLS_OVERRIDE:-}"
    export AMA_TOOLS_OVERRIDE="$_safe_tools"
    # Prevent reflection's 429s from poisoning the main agent's rate limit state
    local _saved_no_rate="${_AMA_NO_RATE_MARK:-0}"
    export _AMA_NO_RATE_MARK=1
    trap 'export AMA_TOOLS_OVERRIDE="$_saved_override"; export _AMA_NO_RATE_MARK="$_saved_no_rate"; HISTORY="$temp_history"' EXIT INT TERM

    local turn=0
    while [ "$turn" -lt 5 ]; do
        turn=$((turn + 1))

        # Call API with system prompt override
        local response=$(call_api "$reflection_sys_prompt")

        # On API failure: retry 429/503 with backoff; stop on hard failures
        if [[ -z "$response" || "$response" == "FAIL:"* ]]; then
            local _err_code; _err_code=$(echo "$response" | grep -oP '(?<=FAIL:)\d+' | head -1)
            if [[ "$_err_code" == "429" || "$_err_code" == "503" ]] && [[ "$turn" -lt 5 ]]; then
                local _delay=$(( 15 * turn ))
                echo "Reflection: API rate-limited ($response), retrying in ${_delay}s ($turn/5)" >&2
                sleep "$_delay"
                continue
            fi
            echo "Reflection: API call failed ($response), stopping" >&2
            break
        fi

        local parsed=$(parse_resp "$response")

        local text=$(echo "$parsed" | grep "^TEXT:" | cut -c6-)
        local tool_calls=$(echo "$parsed" | grep "^TC:" | cut -c4-)

        if [[ "$text" == "NO_ACTION" || -z "$text" ]]; then
            break
        fi

        # Only send to user if there's real value AND it's not just a narrated plan.
        # Suppress messages that are pure intentions without tool results yet.
        local _has_tools=false
        [[ "$tool_calls" != "[]" && "$tool_calls" != "null" && -n "$tool_calls" ]] && _has_tools=true

        if [[ -n "$text" && "$text" != "null" && "$text" != "" && "$text" != "NO_ACTION" && "$_has_tools" == false ]]; then
            # Only send text-only proactive messages if they contain actual findings/fixes,
            # not just descriptions of what the agent "will" do next.
            if echo "$text" | grep -qiE "I('ll| will| would| am going to)|Let me |I'll check|I should|Next,|First,"; then
                : # suppress — it's narrating a plan, not reporting a result
            else
                tg_send "$chat_id" "[Proactive] $text" "$thread_id"
            fi
        fi

        if [[ "$tool_calls" != "[]" && "$tool_calls" != "null" && -n "$tool_calls" ]]; then
            local _tc_lines
            _tc_lines=$(echo "$tool_calls" | python3 -c "
import json, sys
for tc in json.loads(open(sys.argv[1]).read()):
    name = (tc.get('function') or {}).get('name','')
    args = (tc.get('function') or {}).get('arguments','{}')
    tc_json = json.dumps(tc, separators=(',',':'))
    print(name + '\x1f' + args + '\x1f' + tc_json)
" 2>/dev/null)
            while IFS= read -r _line; do
                local name args tc_json
                IFS=$'\x1f' read -r name args tc_json <<< "$_line"
                # Hard block: never allow mutating tools in reflection
                case "$name" in
                    bash|process|edit_code|write_file|patch|delete_file|custom_tool_manager|skill_manager|skill_install)
                        echo "Reflection: Blocked unsafe tool '$name'" >&2
                        continue
                        ;;
                esac
                echo "Reflection: Executing $name"
                log_tool_usage "$session_id" "$name"
                local output
                output=$(run_tool "$name" "$args")

                # Append to history so the next reflection turn knows what happened
                append_tool_call "[$tc_json]"
                append_tool_result "ref_$(date +%s)" "$name" "$output"
            done <<< "$_tc_lines"
            continue
        fi
        break
    done

    # Restore overrides and history (trap handles crash; we restore manually on clean exit)
    trap - EXIT INT TERM
    export AMA_TOOLS_OVERRIDE="$_saved_override"
    export _AMA_NO_RATE_MARK="$_saved_no_rate"
    HISTORY="$temp_history"
}

# ── Async Session Curator (hermes-style) ───────────────────────────────────
# After a tool-heavy turn, fork a sub-agent constrained to memory + skill-editing
# tools. It reads the just-completed trajectory, current MEMORY.md/USER.md, and
# the active skill prompt — then patches them with newly discovered, durable
# knowledge (API contracts, env quirks, user preferences) so the next run is
# faster. Runs in background; never blocks or notifies the user.
#
# Why this is separate from reflect_turn():
#   reflect_turn = read-only inspection (memory_remember to LanceDB, error_log).
#   curate_session = actual file edits to brain/state/*.md and brain/skills/*/prompt.md.
#   Keeping them apart lets us run reflection on every turn but curation only when
#   the trajectory likely revealed something worth baking in.
curate_session() {
    local session_id="$1"
    local active_skill="${2:-}"

    # Skip short or trivial sessions
    local count
    count=$(python3 -c "import json,sys; print(len(json.loads(open(sys.argv[1]).read())))" <(printf '%s' "$HISTORY") 2>/dev/null); count=${count:-0}
    [[ "$count" -lt 6 ]] && return

    # Skip offline / cheap models — they're not strong enough for curation judgement
    [[ "$PROVIDER" == "ollama" ]] && return

    # Opt-out flag
    [[ "${AMA_CURATOR:-1}" == "0" ]] && return

    echo "AMA: Curating session $session_id (active skill: ${active_skill:-none})..."

    # Snapshot current persistent state to show the curator what already exists.
    local _mem_now _usr_now _skill_path _skill_now
    _mem_now=$(cat brain/state/MEMORY.md 2>/dev/null || echo "(empty)")
    _usr_now=$(cat brain/state/USER.md 2>/dev/null || echo "(empty)")
    _skill_path=""
    _skill_now=""
    if [[ -n "$active_skill" ]]; then
        for _p in "brain/skills/${active_skill}/prompt.md" "core/skills/${active_skill}/prompt.md"; do
            if [[ -f "$_p" ]]; then
                _skill_path="$_p"
                _skill_now=$(cat "$_p")
                break
            fi
        done
    fi

    # Compact trajectory: last 14 messages, tool args truncated to 300 chars,
    # tool results to 600 chars. Curator just needs the shape, not full payloads.
    local _trajectory
    _trajectory=$(python3 -c "
import json, sys
h = json.loads(open(sys.argv[1]).read())
take = h[-14:]
lines = []
for m in take:
    role = m.get('role', '?')
    if role == 'user':
        c = m.get('content', '')
        if isinstance(c, list):
            c = ' '.join(p.get('text','') for p in c if isinstance(p, dict))
        lines.append(f'USER: {str(c)[:600].strip()}')
    elif role == 'assistant':
        c = m.get('content') or ''
        if c and str(c).strip(): lines.append(f'AGENT: {str(c)[:600].strip()}')
        for tc in (m.get('tool_calls') or []):
            n = tc.get('function',{}).get('name','?')
            a = tc.get('function',{}).get('arguments','{}')
            lines.append(f'  → tool {n}({str(a)[:300]})')
    elif role == 'tool':
        c = m.get('content', '')
        n = m.get('name','?')
        lines.append(f'  ← {n} result: {str(c)[:600].strip()}')
print('\n'.join(lines))
" <(printf '%s' "$HISTORY") 2>/dev/null)

    [[ -z "$_trajectory" ]] && return

    # Cross-session pattern signals: aggregate error_log + tool_usage so the
    # curator can spot recurring issues that no single session would expose
    # (same tool failing the same way across 3 different chats, etc.).
    local _patterns
    _patterns=$(python3 -c "
import json, sys, os, collections
err_path = 'brain/state/error_log.jsonl'
tool_path = 'brain/state/tool_usage.jsonl'

# Last 200 API errors — group by reason × model
err_counts = collections.Counter()
err_examples = {}
if os.path.exists(err_path):
    try:
        with open(err_path) as f:
            for line in f.readlines()[-200:]:
                try:
                    e = json.loads(line)
                    key = (e.get('reason','unknown'), e.get('model','?'))
                    err_counts[key] += 1
                    if key not in err_examples:
                        body = (e.get('body') or '')[:200].replace('\n',' ')
                        err_examples[key] = body
                except: pass
    except: pass

# Last 500 tool calls — frequency by tool name
tool_counts = collections.Counter()
if os.path.exists(tool_path):
    try:
        with open(tool_path) as f:
            for line in f.readlines()[-500:]:
                try:
                    e = json.loads(line)
                    tool_counts[e.get('tool','?')] += 1
                except: pass
    except: pass

lines = []
if err_counts:
    lines.append('### Recent API error patterns (last 200 errors)')
    for (reason, model), n in err_counts.most_common(8):
        if n < 3: break  # only patterns that repeat
        ex = err_examples.get((reason, model), '')[:120]
        lines.append(f'  • {n}× {reason} on {model}' + (f' — e.g. {ex!r}' if ex else ''))
if tool_counts:
    lines.append('')
    lines.append('### Recent tool usage frequency (last 500 calls)')
    for tool, n in tool_counts.most_common(10):
        lines.append(f'  • {n}× {tool}')

print(chr(10).join(lines) if lines else '(no recent patterns)')
" 2>/dev/null)

    # The curator prompt: tightly scoped, action-only, NO_CHANGES sentinel for nothing-to-do
    local _curator_sys="You are AMA's Session Curator. You run in the background after each session to bake newly-discovered durable knowledge into the agent's persistent state.

WHAT TO PERSIST (only if not already captured):
- API contracts the agent had to reverse-engineer (request shape, auth headers, field names, casing). Bake into the relevant skill prompt.
- Environment quirks (filesystem layout, service names, config locations). Save via memory(target=memory).
- User preferences inferred from this session (response style, terminology, defaults). Save via memory(target=user).
- Working command/curl templates the agent had to discover. Bake into the skill prompt as a copy-pasteable block.
- **Recurring cross-session issues**: if the patterns block below shows the same error/tool problem 3+ times, write a one-line note to MEMORY.md prefixed with '## Recurring issue:' so the agent sees it next session. Example: '## Recurring issue: bash tool returns Permission denied when writing to brain/state/ — verify ownership before write.'

WHAT TO IGNORE:
- Conversational chatter, greetings, single-task data (e.g. \"user spent \$200 today\" is task data, not knowledge).
- Anything already present in MEMORY.md, USER.md, or the active skill prompt.
- Anything trivially discoverable by a single fresh tool call.
- API contracts revealed by FAILED attempts in the trajectory — wait until they succeed.

WHAT YOU CAN AND CAN'T EDIT:
- ✓ MEMORY.md / USER.md via memory()
- ✓ brain/skills/*/prompt.md via edit_code()
- ✗ NEVER edit core/* or tools/* — those are harness code. If you see a likely harness bug in the patterns, write a '## Recurring issue:' note to MEMORY.md describing it; the user reviews and fixes.

HOW:
- memory(action=add|replace|remove, target=memory|user, content=\"...\")
- edit_code(path=\"brain/skills/<name>/prompt.md\", old_string=\"...\", new_string=\"...\")
- read_code if you need to inspect a file you don't already have.

LIMITS:
- AT MOST 3 changes per pass. Be surgical.
- Each fact: ONE LINE. No prose.
- If nothing worth persisting, respond with exactly: NO_CHANGES — then stop.
- NEVER call any tool not in this list. NEVER message the user. NEVER use bash."

    # Build the user-side payload — current state + trajectory + cross-session patterns
    local _curator_msg
    _curator_msg=$(python3 -c "
import sys, json
mem = open(sys.argv[1]).read()
usr = open(sys.argv[2]).read()
sk_path = sys.argv[3]
sk_body = open(sys.argv[4]).read() if sys.argv[4] else ''
traj = open(sys.argv[5]).read()
pat = open(sys.argv[6]).read() if len(sys.argv) > 6 else ''
parts = []
parts.append('## Current MEMORY.md')
parts.append(mem if mem.strip() else '(empty)')
parts.append('')
parts.append('## Current USER.md')
parts.append(usr if usr.strip() else '(empty)')
parts.append('')
if sk_path and sk_body:
    parts.append(f'## Active skill prompt — {sk_path}')
    parts.append(sk_body)
    parts.append('')
parts.append('## Trajectory of the session that just ended')
parts.append(traj)
parts.append('')
if pat and pat.strip() and pat.strip() != '(no recent patterns)':
    parts.append('## Cross-session patterns (recurring issues across sessions)')
    parts.append(pat)
print(json.dumps([{'role': 'user', 'content': chr(10).join(parts)}]))
" <(printf '%s' "$_mem_now") <(printf '%s' "$_usr_now") "$_skill_path" <(printf '%s' "$_skill_now") <(printf '%s' "$_trajectory") <(printf '%s' "$_patterns") 2>/dev/null)

    [[ -z "$_curator_msg" ]] && return

    # Tool override: only memory + edit_code + read_code (read_code is needed for verifying current state)
    local _saved_override="${AMA_TOOLS_OVERRIDE:-}"
    local _saved_no_rate="${_AMA_NO_RATE_MARK:-0}"
    local _saved_history="$HISTORY"
    export AMA_TOOLS_OVERRIDE=$(python3 -c "
import json, sys
try:
    tools = json.loads(open(sys.argv[1]).read())
    allowed = {'memory', 'edit_code', 'read_code'}
    safe = [t for t in tools if t.get('name') in allowed]
    print(json.dumps(safe, separators=(',', ':')))
except: print('[]')
" brain/tools.json 2>/dev/null)
    export _AMA_NO_RATE_MARK=1
    trap 'export AMA_TOOLS_OVERRIDE=\"$_saved_override\"; export _AMA_NO_RATE_MARK=\"$_saved_no_rate\"; HISTORY=\"$_saved_history\"' EXIT INT TERM

    HISTORY="$_curator_msg"

    local _changes=0
    local _max_turns=4
    local _turn=0
    while [ "$_turn" -lt "$_max_turns" ]; do
        _turn=$((_turn + 1))
        local _resp
        _resp=$(call_api "$_curator_sys")
        if [[ -z "$_resp" || "$_resp" == "FAIL:"* ]]; then
            echo "Curator: API call failed at turn $_turn — stopping" >&2
            break
        fi

        local _parsed; _parsed=$(parse_resp "$_resp")
        local _text; _text=$(echo "$_parsed" | grep "^TEXT:" | cut -c6-)
        local _tc; _tc=$(echo "$_parsed" | grep "^TC:" | cut -c4-)

        # Stop sentinel
        if [[ "$_text" == *"NO_CHANGES"* && ( "$_tc" == "[]" || -z "$_tc" || "$_tc" == "null" ) ]]; then
            echo "Curator: nothing to persist this session."
            break
        fi

        # No tool calls + no sentinel → assume done
        if [[ "$_tc" == "[]" || -z "$_tc" || "$_tc" == "null" ]]; then
            break
        fi

        # Execute each tool call sequentially. Hard-block anything not in the allowlist.
        local _tc_lines
        _tc_lines=$(echo "$_tc" | python3 -c "
import json, sys
for tc in json.loads(open(sys.argv[1]).read()):
    name = (tc.get('function') or {}).get('name','')
    args = (tc.get('function') or {}).get('arguments','{}')
    tc_json = json.dumps(tc, separators=(',',':'))
    print(name + chr(0x1f) + args + chr(0x1f) + tc_json)
" <(printf '%s' "$_tc") 2>/dev/null)

        while IFS= read -r _line; do
            [[ -z "$_line" ]] && continue
            local _name _args _tcjson
            IFS=$'\x1f' read -r _name _args _tcjson <<< "$_line"
            case "$_name" in
                memory|edit_code|read_code) ;;
                *)
                    echo "Curator: blocked unauthorized tool '$_name'" >&2
                    continue
                    ;;
            esac
            echo "Curator: $_name"
            local _out; _out=$(run_tool "$_name" "$_args")
            append_tool_call "[$_tcjson]"
            append_tool_result "cur_$(date +%s%N)" "$_name" "$_out"
            [[ "$_name" == "memory" || "$_name" == "edit_code" ]] && _changes=$((_changes + 1))
            # Hard cap on changes per pass
            if [[ "$_changes" -ge 3 ]]; then
                echo "Curator: hit 3-change cap, stopping"
                break 2
            fi
        done <<< "$_tc_lines"
    done

    trap - EXIT INT TERM
    export AMA_TOOLS_OVERRIDE="$_saved_override"
    export _AMA_NO_RATE_MARK="$_saved_no_rate"
    HISTORY="$_saved_history"

    if [[ "$_changes" -gt 0 ]]; then
        echo "AMA: Curator applied $_changes change(s) for $session_id."
    fi
}
