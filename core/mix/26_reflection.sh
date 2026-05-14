#!/bin/bash
# core/mix/26_reflection.sh - Autonomous Self-Reflection + Session Recap

# Save a structured end-of-session recap (hermes pattern: persist key session facts across sessions)
save_session_recap() {
    local session_id="$1"
    local chat_id="$2"
    local thread_id="$3"

    # Skip for short sessions (< 8 messages) — not enough substance to recap
    local count
    count=$(python3 -c "import json,sys; print(len(json.loads(open(sys.argv[1]).read())))" <(printf '%s' "$HISTORY") 2>/dev/null); count=${count:-0}
    [[ "$count" -lt 8 ]] && return

    # Skip for offline models — too slow for background recap
    [[ "$PROVIDER" == "ollama" ]] && return

    echo "AMA: Generating session recap for $session_id..."

    local recap_prompt="Generate a short session recap in structured format.

## Session Summary
[1-2 sentences: what was accomplished overall]

## Key Facts Learned
[Bullet list: user preferences, environment details, decisions made. Only non-obvious facts worth remembering across sessions.]

## Unresolved Items
[Bullet list: things left incomplete, errors not fixed, questions not answered. Empty list if all resolved.]

## Next Steps
[What the user likely wants to do next, based on context. 1-3 bullets max. Skip if unclear.]

Rules: Be concise. Total under 200 words. No preamble. Respond ONLY with the structured document."

    local saved_history="$HISTORY"
    # Use AMA_TOOLS_OVERRIDE to pass [] without touching brain/tools.json.
    # Avoids the race condition where concurrent reflect_turn reads [] as its backup.
    local _saved_override="${AMA_TOOLS_OVERRIDE:-}"
    export AMA_TOOLS_OVERRIDE="[]"
    trap 'export AMA_TOOLS_OVERRIDE="$_saved_override"; HISTORY="$saved_history"' EXIT INT TERM

    local _sp_tmp; _sp_tmp=$(mktemp)
    printf '%s' "$recap_prompt" > "$_sp_tmp"
    local _recap_hist
    _recap_hist=$(python3 - "$_sp_tmp" <<'PYEOF' 2>/dev/null
import json, sys
sp = open(sys.argv[1]).read()
print(json.dumps([{"role": "user", "content": sp}]))
PYEOF
)
    rm -f "$_sp_tmp"

    HISTORY="${_recap_hist:-$saved_history}"
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
    trap 'export AMA_TOOLS_OVERRIDE="$_saved_override"; HISTORY="$temp_history"' EXIT INT TERM

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

    # Restore full tools.json and history (trap handles crash case too)
    trap - EXIT INT TERM
    mv "$_tools_bak" brain/tools.json 2>/dev/null || true
    HISTORY="$temp_history"
}
