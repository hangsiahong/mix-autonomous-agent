#!/bin/bash
# core/mix/25_btw.sh — /btw ephemeral side-question command (openclaw pattern).
#
# Use case: user is mid-task with the agent (or just curious) and wants a quick
# answer that uses the current conversation as context, WITHOUT polluting the
# main session history or interrupting an active turn.
#
#   User: build me an awwwards landing page
#   Agent: [working, 4 tools deep...]
#   User: /btw what's the colour palette I told you about last week?
#   Agent: [pauses no main work; just answers] You said muted earth tones...
#
# Properties (all enforced):
#   • Tools disabled (AMA_TOOLS_OVERRIDE=[])
#   • Thinking disabled (THINKING_BUDGET=none) — fast + cheap
#   • History is READ for context but NEVER MUTATED
#   • Does not write to session_recaps.jsonl, MEMORY.md, USER.md, etc.
#   • Doesn't acquire the session lock — runs in parallel with active turn
#   • Synchronous from the user's POV: typing indicator → answer message
#
# The system prompt forbids the model from "continuing the main task" because
# the conversation context might contain in-flight tool calls / partial work
# the model would otherwise be tempted to complete. Borrowed from openclaw's
# <btw_side_question> + <in_flight_main_task> tagging trick.

btw_command() {
    local chat_id="$1"
    local thread_id="$2"
    local session_id="$3"
    local question="$4"
    local user_msg_id="${5:-0}"

    if [[ -z "$question" ]]; then
        tg_send "$chat_id" \
            "Usage: <code>/btw &lt;question&gt;</code>
A quick side question using the current session as background. Doesn't interrupt the agent, doesn't get saved to history." \
            "$thread_id" "HTML"
        return 0
    fi

    # Read history transiently (file may be missing on a fresh session — that's fine)
    local _hist_file="${DIR}/brain/state/history_${session_id}.json"
    local _hist_json="[]"
    if [[ -f "$_hist_file" ]]; then
        _hist_json=$(cat "$_hist_file")
    fi

    # Build the side-question payload. The <btw_side_question> tag signals
    # to the model: "answer THIS, not what's in the prior conversation".
    # If there's an in-flight last user message, label it explicitly so the
    # model knows not to continue it.
    local _btw_payload
    _btw_payload=$(BTW_Q="$question" HIST_JSON="$_hist_json" python3 -c "
import json, os, sys

q = os.environ['BTW_Q']
hist_raw = os.environ.get('HIST_JSON','[]')
try:
    h = json.loads(hist_raw)
except Exception:
    h = []

# Find the most recent user message (other than slash commands)
in_flight = ''
for m in reversed(h):
    if m.get('role') != 'user':
        continue
    c = m.get('content','')
    if isinstance(c, list):
        c = ' '.join(p.get('text','') for p in c if isinstance(p, dict))
    s = str(c).strip()
    if s.startswith('[SYSTEM:'):
        # Strip our injected context block
        parts = s.split('\\n\\n', 1)
        if len(parts) == 2:
            s = parts[1].strip()
    if s and not s.startswith('/'):
        in_flight = s[:600]
        break

content = f'<btw_side_question>\\n{q}\\n</btw_side_question>'
if in_flight:
    content += (
        '\\n\\n<in_flight_main_task>\\n'
        f'The user is currently in the middle of: {in_flight}\\n'
        'Do NOT continue, resume, or work on this. The /btw above is a separate question.\\n'
        '</in_flight_main_task>'
    )

# Build a transient history: existing context + the BTW question as final user msg.
# The model sees prior conversation for context, but the system prompt + tags
# stop it from continuing the main task.
btw_msg = {'role': 'user', 'content': content}
print(json.dumps(h + [btw_msg], separators=(',', ':')))
")

    if [[ -z "$_btw_payload" ]]; then
        tg_send "$chat_id" "⚠️ /btw failed to build payload." "$thread_id"
        return 1
    fi

    # Show typing while we wait
    tg_send_action "$chat_id" "typing" "$thread_id"

    # Override LLM state — fully transient, restored before we return
    local _saved_history="$HISTORY"
    local _saved_tools="${AMA_TOOLS_OVERRIDE:-}"
    local _saved_thinking="${THINKING_BUDGET:-medium}"
    local _saved_no_rate="${_AMA_NO_RATE_MARK:-0}"
    export AMA_TOOLS_OVERRIDE="[]"
    export THINKING_BUDGET=none
    # /btw shouldn't poison the main agent's rate-limit state — it's an ad-hoc
    # one-shot, failures here mustn't block the next user message.
    export _AMA_NO_RATE_MARK=1
    HISTORY="$_btw_payload"

    local _btw_sys="You are answering a /btw side question. The user is in the middle of another task with you — the prior conversation is BACKGROUND CONTEXT ONLY.

Rules:
- Answer ONLY the question wrapped in <btw_side_question> in the last user message.
- DO NOT continue, resume, or complete any task referenced in <in_flight_main_task>.
- DO NOT call tools, write files, run shell commands, or produce code unless the side question explicitly asks for code.
- DO NOT say things like 'I'll continue with the main task' or 'now back to your project'.
- Be brief — one paragraph or less when possible. The user just wants a quick answer.
- Telegram HTML output (the harness converts markdown to HTML). No tables."

    local _resp
    _resp=$(call_api "$_btw_sys")

    # Restore state immediately — even if API failed, don't poison the session
    HISTORY="$_saved_history"
    export AMA_TOOLS_OVERRIDE="$_saved_tools"
    export THINKING_BUDGET="$_saved_thinking"
    export _AMA_NO_RATE_MARK="$_saved_no_rate"

    # Handle failure
    if [[ -z "$_resp" || "$_resp" == "FAIL:"* ]]; then
        local _err="${_resp#FAIL:}"
        tg_send "$chat_id" "⚠️ /btw failed: <code>${_err:0:200}</code>" "$thread_id" "HTML"
        return 1
    fi

    # Extract answer text (call_api returns OpenAI-format JSON)
    local _text
    _text=$(printf '%s' "$_resp" | python3 -c "
import json, sys
try:
    r = json.loads(sys.stdin.read())
    msg = r.get('choices',[{}])[0].get('message',{})
    c = msg.get('content') or ''
    print(c.strip())
except Exception: pass
" 2>/dev/null)

    if [[ -z "$_text" ]]; then
        tg_send "$chat_id" "⚠️ /btw returned empty response." "$thread_id"
        return 1
    fi

    # Convert markdown → Telegram HTML
    local _html
    _html=$(printf '%s' "$_text" | python3 "${DIR}/tools/md_to_html.py")

    # Send with a 💡 prefix + footer marker so it's visually distinct from
    # regular agent replies. Reply-to the user's /btw message for threading.
    tg_send_r "$chat_id" "💡 ${_html}

<i>— /btw side answer (not saved to history)</i>" "$thread_id" "HTML" "$user_msg_id" > /dev/null
    return 0
}
