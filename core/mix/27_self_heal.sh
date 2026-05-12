#!/bin/bash
# core/mix/27_self_heal.sh — Self-healing loop
#
# Two entry points:
#   self_heal_if_needed  <session_id> <chat_id> <thread_id>
#     Called at start of each agent turn. Checks for a pending heal_request.json.
#     If found, runs a diagnostic + fix session and notifies admin.
#
#   self_heal_check_errors <session_id>
#     Called from cron or after repeated API errors. Analyzes error_log.jsonl
#     for recurring patterns (3+ hits in 24h) and creates a heal request if needed.
#
# Safety model (hermes dangerous-command approval pattern):
#   - Changes to tools/ → auto-applied after syntax check
#   - Changes to core/ or brain/ → sent to TG_ADMIN for review, not applied
#   - All actions logged to brain/state/self_heal_log.jsonl

HEAL_REQUEST_FILE="${DIR}/brain/state/heal_request.json"
SELF_HEAL_COOLDOWN_FILE="${DIR}/brain/state/.self_heal_last_run"
SELF_HEAL_COOLDOWN_HOURS=4  # Don't run more than once per N hours

# ── Entry: check at turn start ────────────────────────────────────────────────

self_heal_if_needed() {
    local session_id="$1"
    local chat_id="$2"
    local thread_id="$3"

    [[ -f "$HEAL_REQUEST_FILE" ]] || return 0
    [[ "$PROVIDER" == "ollama" ]] && return 0  # too slow for local models

    # Cooldown check
    local _now; _now=$(date +%s)
    local _last=0
    [[ -f "$SELF_HEAL_COOLDOWN_FILE" ]] && _last=$(cat "$SELF_HEAL_COOLDOWN_FILE" 2>/dev/null || echo 0)
    local _hours_since=$(( (_now - _last) / 3600 ))
    if [[ "$_hours_since" -lt "$SELF_HEAL_COOLDOWN_HOURS" ]]; then
        return 0
    fi
    echo "$_now" > "$SELF_HEAL_COOLDOWN_FILE"

    local heal_context
    heal_context=$(python3 -c "import json; d=json.load(open('$HEAL_REQUEST_FILE')); print(json.dumps(d, indent=2))" 2>/dev/null)
    rm -f "$HEAL_REQUEST_FILE"

    [[ -z "$heal_context" ]] && return 0

    echo "AMA: Self-heal triggered for session $session_id"
    tg_send "$chat_id" "🔧 <i>Running self-diagnostic…</i>" "$thread_id" "HTML" > /dev/null 2>&1

    _run_self_heal_session "$session_id" "$chat_id" "$thread_id" "$heal_context"
}

# ── Entry: triggered by cron or repeated errors ───────────────────────────────

self_heal_check_errors() {
    local session_id="${1:-system}"

    # Cooldown
    local _now; _now=$(date +%s)
    local _last=0
    [[ -f "$SELF_HEAL_COOLDOWN_FILE" ]] && _last=$(cat "$SELF_HEAL_COOLDOWN_FILE" 2>/dev/null || echo 0)
    if [[ $(( (_now - _last) / 3600 )) -lt 1 ]]; then
        return 0  # checked within last hour
    fi

    if python3 tools/error_analyzer.py patterns --hours 24 2>/dev/null | grep -q "^[3-9][0-9]*x\|^[1-9][0-9][0-9]*x"; then
        echo "AMA: Recurring error patterns detected — creating heal request"
        python3 tools/error_analyzer.py create_request 24 2>/dev/null || true
    fi
}

# ── Internal: run the actual self-heal session ────────────────────────────────

_run_self_heal_session() {
    local session_id="$1"
    local chat_id="$2"
    local thread_id="$3"
    local heal_context="$4"

    local saved_history="$HISTORY"
    local _tools_bak; _tools_bak=$(mktemp "brain/tools.json.bak.XXXXXX")
    cp brain/tools.json "$_tools_bak" 2>/dev/null || true

    # Self-heal gets WRITE access to tools/ but is blocked from core/ changes
    # (it can DESCRIBE core/ fixes but not apply them — admin approval required)
    local _heal_tools
    _heal_tools=$(python3 -c "
import json, sys
tools = json.load(open('brain/tools.json'))
# Allow: bash (limited), read_code, edit_code, write_file, check_health,
#        read_error_log, search_files, memory_remember
allowed = {'bash','read_code','edit_code','write_file','search_files',
           'check_health','read_error_log','memory_remember','memory_recall',
           'session_search','sys_info','repo_map','clarify'}
safe = [t for t in tools if t.get('name','') in allowed]
print(json.dumps(safe, separators=(',',':')))
" 2>/dev/null)
    trap 'mv "$_tools_bak" brain/tools.json 2>/dev/null; HISTORY="$saved_history"' EXIT INT TERM
    printf '%s' "$_heal_tools" > brain/tools.json

    # Build heal prompt — inject context about what errors were found
    local heal_sys_prompt="You are AMA's Self-Healing Core. Recurring errors have been detected.

## Detected Issues
$heal_context

## Your Mission
1. Use check_health to assess the current system state
2. Use read_error_log to review the actual errors
3. Use bash (read-only: grep, cat, ls) to investigate root causes
4. For issues in tools/ scripts: fix them directly with edit_code or write_file
5. For issues in core/ harness files: describe the fix precisely — DO NOT edit core/ files directly
   (Core changes require admin review — you'll send the proposal via clarify)
6. Log what you found and fixed using memory_remember with type='self_heal'

## Safety Rules
- You MAY edit files in: tools/, brain/skills/, brain/state/
- You MUST NOT edit files in: core/, bot.sh, brain/system_prompt.md, brain/tools.json
- After any tool/ edit, run: bash -n <file> to verify syntax
- If you detect a fix for core/ files, use clarify to send the proposal to the user

Start with check_health, then read_error_log."

    # Run a short diagnostic loop (max 8 turns)
    HISTORY=$(python3 -c "
import json, sys
print(json.dumps([{'role':'user','content':'Run self-diagnostic and fix what you can.'}]))")

    local turn=0
    local _heal_result=""
    while [[ "$turn" -lt 8 ]]; do
        turn=$((turn + 1))
        local response; response=$(call_api "$heal_sys_prompt")

        if [[ -z "$response" || "$response" == "FAIL:"* ]]; then
            break
        fi

        local parsed; parsed=$(parse_resp "$response")
        local text; text=$(echo "$parsed" | grep "^TEXT:" | cut -c6-)
        local tool_calls; tool_calls=$(echo "$parsed" | grep "^TC:" | cut -c4-)

        [[ -n "$text" && "$text" != "null" ]] && append_text "assistant" "$text"

        if [[ -n "$tool_calls" && "$tool_calls" != "[]" && "$tool_calls" != "null" ]]; then
            append_tool_call "$tool_calls"
            while IFS='|' read -r name tc_id; do
                [[ -z "$name" ]] && continue
                local single_tc; single_tc=$(python3 -c "
import json, sys, os
calls = json.loads(open(sys.argv[1]).read())
tc_id = os.environ.get('TC_ID','')
match = next((t for t in calls if t.get('id') == tc_id), calls[0] if calls else None)
print(json.dumps(match or {}, separators=(',',':')))
" <(printf '%s' "$tool_calls") TC_ID="$tc_id" 2>/dev/null)

                # Safety intercept: block edits to core/ files
                local _tool_args; _tool_args=$(python3 -c "
import json, sys
tc = json.loads(open(sys.argv[1]).read())
print(tc.get('function',{}).get('arguments','{}'))
" <(printf '%s' "$single_tc") 2>/dev/null)
                local _file_path; _file_path=$(python3 -c "
import json, sys
args = json.loads(sys.argv[1])
print(args.get('path', args.get('file_path', args.get('target', ''))))
" "$_tool_args" 2>/dev/null)

                if [[ "$name" =~ ^(edit_code|write_file|patch)$ ]] && [[ "$_file_path" =~ ^(core/|bot\.sh) ]]; then
                    append_tool_result "$tc_id" "$name" \
                        "BLOCKED: Cannot auto-edit core/ files. Describe the fix and send via clarify for admin review."
                    continue
                fi

                local output; output=$(process_tc "$chat_id" "" "$single_tc" "$thread_id" 2>/dev/null)
                append_tool_result "$tc_id" "$name" "$output"
            done < <(python3 -c "
import sys, json
for tc in json.loads(open(sys.argv[1]).read()):
    name = tc.get('function',{}).get('name','')
    print(f'{name}|{tc.get(\"id\",\"\")}')
" <(printf '%s' "$tool_calls"))
            continue
        fi

        # No tool calls — model gave its final summary
        _heal_result="$text"
        break
    done

    # Restore everything
    trap - EXIT INT TERM
    mv "$_tools_bak" brain/tools.json 2>/dev/null || true
    HISTORY="$saved_history"

    # Log the heal session and notify admin
    if [[ -n "$_heal_result" ]]; then
        local _heal_ts; _heal_ts=$(date -u +%s)
        python3 tools/error_analyzer.py log "self_heal_session" "${_heal_result:0:200}" 2>/dev/null || true

        # Archive errors that pre-date this heal run — they triggered the heal,
        # they're now addressed (or at least acknowledged), stop re-alerting on them
        python3 tools/error_analyzer.py archive_before "$(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null || true

        # Notify admin
        local _admin_chat; _admin_chat="${TG_ADMIN:-$chat_id}"
        local _msg="🔧 <b>Self-Heal Complete</b>
$(echo "$_heal_result" | head -c 800)

<i>Old error entries archived.</i>"
        tg_send "$_admin_chat" "$_msg" "" "HTML" > /dev/null 2>&1 || true
    fi

    echo "AMA: Self-heal session completed for $session_id"
}
