#!/bin/bash
# core/mix/14_tool_distill.sh — semantic distillation of long tool outputs.
#
# Wraps long, information-dense tool outputs (web pages, search results,
# memory recalls) through a cheap kconsole model to extract only the slice
# relevant to the user's current question. The model in the main turn then
# sees the distilled version; the full raw output is preserved on disk for
# audit and can be re-read if needed.
#
# Action-oriented tools (write_file, bash, edit_code) are NOT distilled —
# the agent needs their exact output to verify behavior.
#
# Killswitch: export AMA_DISTILL_DISABLED=1 to short-circuit to passthrough.

# Tools whose output is informational and benefits from a relevance pass.
_DISTILL_WHITELIST=(web_search fetch_url memory_recall session_search browser)

# Char threshold below which folding is sufficient and distillation is skipped.
_DISTILL_MIN_CHARS=1500

# Hard ceiling on distill latency (seconds). If kconsole is slow, fall back
# to the original output so the main turn isn't blocked.
_DISTILL_TIMEOUT=20

# ── Per-tool result wrapper ───────────────────────────────────────────────────
# distill_tool_output <tool_name> <output> <session_id> <tool_call_id>
#   stdout: distilled (or original) output
#
# Reads HISTORY from the caller's scope to extract the last user message,
# which is used as the relevance anchor for distillation.
distill_tool_output() {
    local tool_name="$1"
    local output="$2"
    local sid="$3"
    local tc_id="$4"

    # Killswitch — disable entire pass without code change.
    if [[ "${AMA_DISTILL_DISABLED:-0}" == "1" ]]; then
        printf '%s' "$output"
        return 0
    fi

    # Whitelist gate — non-informational tools pass through untouched.
    local in_list=0
    for _t in "${_DISTILL_WHITELIST[@]}"; do
        if [[ "$_t" == "$tool_name" ]]; then in_list=1; break; fi
    done
    if [[ "$in_list" -eq 0 ]]; then
        printf '%s' "$output"
        return 0
    fi

    # Size gate — short outputs don't need it; existing fold logic handles them.
    local _len=${#output}
    if (( _len < _DISTILL_MIN_CHARS )); then
        printf '%s' "$output"
        return 0
    fi

    # Skip if the output is clearly an error/failure — keep verbatim for debugging.
    case "$output" in
        Error:*|"["*"error"*|*"Permission denied"*|*"Traceback"*)
            printf '%s' "$output"
            return 0
            ;;
    esac

    # Extract last user message from HISTORY for relevance anchor.
    local last_user
    last_user=$(printf '%s' "${HISTORY:-[]}" | python3 -c "
import json, sys
try:
    h = json.loads(sys.stdin.read())
    for m in reversed(h):
        if m.get('role') == 'user':
            c = m.get('content') or ''
            if isinstance(c, list):
                c = ' '.join(p.get('text','') for p in c if isinstance(p,dict))
            print(str(c)[:2000])
            break
except Exception:
    pass
" 2>/dev/null)

    # No anchor → distillation can't be relevance-targeted; pass through.
    if [[ -z "$last_user" ]]; then
        printf '%s' "$output"
        return 0
    fi

    # Audit: save the raw output so it can be referenced or recovered.
    local audit_dir="${DIR:-.}/brain/state/distill_audit"
    mkdir -p "$audit_dir"
    local _stamp; _stamp=$(date +%s)
    local audit_file="${audit_dir}/${sid}_${_stamp}_${tc_id}.txt"
    # Best-effort write; do not block on failure.
    printf '%s' "$output" > "$audit_file" 2>/dev/null || true

    # Build the distillation prompt. The prompt itself stays small; the bulk
    # is the raw output piped on stdin.
    local sys_prompt
    sys_prompt=$(cat <<PROMPT
You are extracting the relevant slice of a long tool result for an autonomous agent.

User's current question / task:
"""
${last_user}
"""

The agent called tool \`${tool_name}\` and got the output below.

Extract ONLY the parts of the output that are relevant to the user's question.
- Preserve facts, URLs, names, numbers, code snippets, and quotes verbatim.
- Drop boilerplate (cookie banners, navigation menus, ads, footers).
- Drop unrelated tangents and obvious repetition.
- Keep the result under ~800 tokens.
- If the entire output is relevant and concise, return it as-is.
- If the output contains no relevant content, return exactly: [No relevant content in tool output]

Output the distilled text only. No preface, no explanation, no surrounding quotes.
PROMPT
)

    # Call the distill tier via mix_call.py with a hard timeout.
    local distilled
    distilled=$(printf '%s' "$output" | timeout "$_DISTILL_TIMEOUT" \
        python3 "${DIR:-.}/tools/mix_call.py" \
            --tier distill \
            --system "$sys_prompt" \
            --max-tokens 1200 \
            --temperature 0.1 \
            --timeout "$_DISTILL_TIMEOUT" \
        2>/dev/null)

    # Failure → original output. Never return empty.
    if [[ -z "$distilled" ]]; then
        printf '%s' "$output"
        return 0
    fi

    # Tag the distilled result so the agent (and any reader) knows it was
    # processed, and point to the audit file in case the full text is needed.
    local _orig_chars=$_len
    local _new_chars=${#distilled}
    local _audit_rel="${audit_file#${DIR:-.}/}"
    printf '%s\n\n[Distilled by AMA: %d → %d chars. Full output: %s]' \
        "$distilled" "$_orig_chars" "$_new_chars" "$_audit_rel"
}
