#!/bin/bash
# core/mix/29_goal_loop.sh — Autonomous goal-directed loop (hermes /goal pattern).
#
# /goal <text>       — set a standing goal; run_agent runs once on it immediately,
#                      then after each turn a tiny judge call decides done/continue.
#                      If "continue", the goal text is re-queued via the existing
#                      brain/state/queue_<sid> mechanism — no new plumbing needed.
# /goal status       — show active goal, turns used, last judge verdict
# /goal stop / done  — mark done, stop looping
# /goal pause        — pause; resume with /goal resume
# /goal resume       — un-pause and re-queue immediately
# /goal max <n>      — change max turns (default 20)
#
# State: brain/state/goal_<sid>.json
#   { "text": "...", "max_turns": 20, "turns_used": 0,
#     "status": "active|paused|done|exhausted|failed",
#     "started_at": <epoch>, "last_verdict": "...", "last_reason": "..." }
#
# Disable entirely with AMA_GOAL_LOOP=0.

_goal_file() {
    local sid="$1"
    echo "${DIR}/brain/state/goal_${sid}.json"
}

# Read goal state. Returns "" if no goal file, else the JSON.
goal_read() {
    local sid="$1"
    local f; f=$(_goal_file "$sid")
    [[ -f "$f" ]] || return 1
    cat "$f" 2>/dev/null
}

# Write goal state atomically.
goal_write() {
    local sid="$1"
    local json="$2"
    local f; f=$(_goal_file "$sid")
    mkdir -p "$(dirname "$f")"
    local tmp; tmp=$(mktemp "${f}.XXXXXX")
    printf '%s' "$json" > "$tmp" && mv "$tmp" "$f"
}

# Get a JSON field from the goal state, defaulting to $3.
goal_field() {
    local sid="$1"
    local key="$2"
    local default="${3:-}"
    local f; f=$(_goal_file "$sid")
    [[ -f "$f" ]] || { printf '%s' "$default"; return; }
    python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get(sys.argv[2], sys.argv[3]))
except: print(sys.argv[3])
" "$f" "$key" "$default" 2>/dev/null
}

# Update one or more fields in the goal state, preserving the rest.
# Usage: goal_set <sid> key1=val1 key2=val2 ...
goal_set() {
    local sid="$1"; shift
    local f; f=$(_goal_file "$sid")
    [[ -f "$f" ]] || return 1
    local updates=""
    for kv in "$@"; do
        local k="${kv%%=*}"
        local v="${kv#*=}"
        updates+="${k}=${v}"$'\n'
    done
    local new_json
    new_json=$(UPDATES="$updates" python3 -c "
import json, os, sys
d = json.load(open(sys.argv[1]))
for line in os.environ['UPDATES'].splitlines():
    if '=' not in line: continue
    k, v = line.split('=', 1)
    # Coerce known numeric fields
    if k in ('max_turns','turns_used','started_at'):
        try: v = int(v)
        except: pass
    d[k] = v
print(json.dumps(d, separators=(',',':')))
" "$f" 2>/dev/null)
    [[ -n "$new_json" ]] && goal_write "$sid" "$new_json"
}

# Initialise a new goal. Wipes any prior goal for this session.
goal_create() {
    local sid="$1"
    local text="$2"
    local max_turns="${3:-${AMA_GOAL_MAX_TURNS:-20}}"
    local now; now=$(date +%s)
    local json
    json=$(TEXT="$text" MAX="$max_turns" NOW="$now" python3 -c "
import json, os
print(json.dumps({
  'text': os.environ['TEXT'],
  'max_turns': int(os.environ['MAX']),
  'turns_used': 0,
  'status': 'active',
  'started_at': int(os.environ['NOW']),
  'last_verdict': '',
  'last_reason': ''
}, separators=(',',':')))")
    goal_write "$sid" "$json"
}

# Cheap judge: given goal text + last assistant response (+ trailing trajectory),
# decide DONE | CONTINUE: <reason> | FAIL: <reason>. Plain LLM call, no tools.
# Returns the raw verdict line on stdout.
goal_judge() {
    local sid="$1"
    local goal_text="$2"
    local last_response="$3"

    # Build a tiny payload: goal + recent trajectory (≤6 messages, compact)
    local _traj
    _traj=$(python3 -c "
import json, sys
try:
    h = json.loads(open(sys.argv[1]).read())
except:
    h = []
take = h[-6:]
lines = []
for m in take:
    role = m.get('role','?')
    if role == 'user':
        c = m.get('content','')
        if isinstance(c, list):
            c = ' '.join(p.get('text','') for p in c if isinstance(p, dict))
        s = str(c).strip()[:400]
        # Strip the [SYSTEM: Context Updated] preamble for clarity
        if '[SYSTEM: Context Updated]' in s:
            s = s.split('\n\n', 1)[-1]
        lines.append(f'USER: {s}')
    elif role == 'assistant':
        c = (m.get('content') or '').strip()[:400]
        tcn = [tc.get('function',{}).get('name','?') for tc in (m.get('tool_calls') or [])]
        if c: lines.append(f'AGENT: {c}')
        if tcn: lines.append(f'AGENT used: {\", \".join(tcn)}')
    elif role == 'tool':
        n = m.get('name','?')
        c = str(m.get('content',''))[:200].replace(chr(10),' ')
        lines.append(f'  ← {n}: {c}')
print(chr(10).join(lines))
" <(printf '%s' "$HISTORY") 2>/dev/null)

    local judge_sys="You are a goal-completion judge. The user set a standing GOAL. An agent is working on it, one turn at a time. After each turn, you decide whether the goal is fully accomplished and the loop should stop.

Output EXACTLY ONE LINE in one of these forms:
  DONE
  CONTINUE: <one-sentence reason what's still needed>
  FAIL: <one-sentence reason why this goal cannot be achieved>

Rules:
- DONE only when the goal is FULLY satisfied — no remaining sub-tasks, no obvious next step, no error to fix.
- If the agent's last message asked the user a clarifying question, output: FAIL: agent needs user input
- If the agent hit a permission/auth/network wall it cannot resolve, output: FAIL: <reason>
- Otherwise, if there is ANY useful next step the agent could autonomously take, output: CONTINUE: <next-step hint>
- No preamble, no markdown, no extra lines."

    local judge_msg
    judge_msg=$(GOAL="$goal_text" RESP="$last_response" TRAJ="$_traj" python3 -c "
import json, os
goal = os.environ['GOAL']
resp = os.environ['RESP'][:1500]
traj = os.environ['TRAJ'][:2000]
content = f'GOAL: {goal}\n\nLAST AGENT RESPONSE:\n{resp}\n\nRECENT TRAJECTORY:\n{traj}'
print(json.dumps([{'role':'user','content':content}], separators=(',',':')))" 2>/dev/null)

    # Constrain: no tools, no thinking, single-turn call
    local _saved_override="${AMA_TOOLS_OVERRIDE:-}"
    local _saved_no_rate="${_AMA_NO_RATE_MARK:-0}"
    local _saved_history="$HISTORY"
    local _saved_thinking="${THINKING_BUDGET:-medium}"
    export AMA_TOOLS_OVERRIDE="[]"
    export _AMA_NO_RATE_MARK=1
    export THINKING_BUDGET=none
    trap 'export AMA_TOOLS_OVERRIDE="$_saved_override"; export _AMA_NO_RATE_MARK="$_saved_no_rate"; export THINKING_BUDGET="$_saved_thinking"; HISTORY="$_saved_history"' EXIT INT TERM
    HISTORY="$judge_msg"

    local resp
    resp=$(call_api "$judge_sys")

    trap - EXIT INT TERM
    export AMA_TOOLS_OVERRIDE="$_saved_override"
    export _AMA_NO_RATE_MARK="$_saved_no_rate"
    export THINKING_BUDGET="$_saved_thinking"
    HISTORY="$_saved_history"

    if [[ -z "$resp" || "$resp" == "FAIL:"* ]]; then
        echo "FAIL: judge_api_error"
        return
    fi
    # Extract first non-empty line of the response text
    local verdict
    verdict=$(printf '%s' "$resp" | python3 -c "
import sys, json
try:
    r = json.loads(sys.stdin.read())
    t = (r.get('choices',[{}])[0].get('message',{}).get('content') or '').strip()
    # First non-blank line
    for line in t.splitlines():
        line = line.strip()
        if line:
            print(line); break
except: pass" 2>/dev/null)

    # Sanity check: must start with DONE / CONTINUE / FAIL
    case "$verdict" in
        DONE*|CONTINUE*|FAIL*) printf '%s' "$verdict" ;;
        *) printf 'FAIL: unparseable judge response: %s' "${verdict:0:120}" ;;
    esac
}

# Called from run_agent end-of-turn (after lock release). Runs the judge and,
# if CONTINUE, appends the goal text to the queue file so run_agent re-fires.
#
# Args: session_id, last_assistant_response, queue_file_path
goal_maybe_continue() {
    local sid="$1"
    local last_response="$2"
    local queue_file="$3"

    [[ "${AMA_GOAL_LOOP:-1}" == "0" ]] && return
    local goal_json; goal_json=$(goal_read "$sid") || return
    [[ -z "$goal_json" ]] && return

    local status; status=$(goal_field "$sid" status "")
    [[ "$status" != "active" ]] && return  # only auto-continue when active

    local goal_text; goal_text=$(goal_field "$sid" text "")
    [[ -z "$goal_text" ]] && return

    local turns_used; turns_used=$(goal_field "$sid" turns_used 0)
    local max_turns;  max_turns=$(goal_field "$sid" max_turns 20)
    turns_used=$((turns_used + 1))

    if [[ "$turns_used" -ge "$max_turns" ]]; then
        goal_set "$sid" status=exhausted turns_used="$turns_used" last_reason="max_turns_reached"
        # Don't bother judging — we're out of budget
        return 2
    fi

    # Run judge (blocking, ~1-3s)
    local verdict
    verdict=$(goal_judge "$sid" "$goal_text" "$last_response")

    # Persist verdict for observability
    local _reason="${verdict#*: }"
    [[ "$_reason" == "$verdict" ]] && _reason=""
    goal_set "$sid" turns_used="$turns_used" last_verdict="${verdict%%:*}" last_reason="${_reason}"

    case "$verdict" in
        DONE*)
            goal_set "$sid" status=done
            return 1
            ;;
        FAIL*)
            goal_set "$sid" status=failed
            return 3
            ;;
        CONTINUE*)
            # Append the goal text to the queue file so run_agent picks it up.
            # Wrap with a marker so the agent knows this came from the goal loop
            # (not a real user message) — useful for UX cues.
            local _next="[GOAL CONTINUATION turn $turns_used/$max_turns] ${goal_text}"
            # Include the judge's next-step hint if present
            if [[ -n "$_reason" ]]; then
                _next="${_next}"$'\n\n'"Next step hint: ${_reason}"
            fi
            mkdir -p "$(dirname "$queue_file")"
            printf '%s\n' "$_next" >> "$queue_file"
            return 0
            ;;
        *)
            goal_set "$sid" status=failed last_reason="unparseable_verdict"
            return 3
            ;;
    esac
}

# Render a short status block for /goal status — HTML for Telegram.
goal_status_html() {
    local sid="$1"
    local goal_json; goal_json=$(goal_read "$sid") || { echo "<i>No active goal. Use /goal &lt;text&gt; to set one.</i>"; return; }
    [[ -z "$goal_json" ]] && { echo "<i>No active goal.</i>"; return; }
    printf '%s' "$goal_json" | python3 -c "
import json, sys, time, html
d = json.load(sys.stdin)
def esc(s): return html.escape(str(s))
emoji = {'active':'🎯','paused':'⏸','done':'✅','exhausted':'⏱','failed':'⚠️'}.get(d.get('status','?'),'•')
mins = (int(time.time()) - int(d.get('started_at',0))) // 60 if d.get('started_at') else 0
print(f'{emoji} <b>Goal</b> — <i>{esc(d.get(\"status\",\"?\"))}</i>')
print(f'<code>{esc(d.get(\"text\",\"\"))}</code>')
print(f'Turns: {d.get(\"turns_used\",0)}/{d.get(\"max_turns\",0)} · age: {mins}m')
v = d.get('last_verdict','')
r = d.get('last_reason','')
if v:
    line = f'Last verdict: <i>{esc(v)}</i>'
    if r: line += f' — {esc(r)[:200]}'
    print(line)
" 2>/dev/null
}
