#!/bin/bash
# tools/_lib/err_trap.sh — sourceable ERR-trap pre-mortem for tool scripts.
#
# Usage (at the top of any tool script, after `set -u`):
#   source "$(dirname "${BASH_SOURCE[0]}")/_lib/err_trap.sh"
#
# What it does:
#   • set -E -o errtrace so the ERR trap propagates into functions/subshells
#   • on any failing command, writes ONE JSON line to
#       brain/state/tool_premortem.jsonl
#     with: ts, tool, exit, line, cmd, source, tc_id (if AMA_TOOL_TC_ID is set)
#   • fail-open: errors emitting the pre-mortem must NEVER block the tool.
#
# Why this exists:
#   Tools that quietly return empty/garbage output are hard to diagnose after
#   the fact. A pre-mortem ERR trap captures the failing command and line
#   number at the moment of failure, so a later debugger can `tail` the
#   pre-mortem log and see exactly what went wrong without re-running.
#
#   Does NOT replace explicit `if cmd; then ... else echo "Error: ..."; fi`
#   handling — it's a safety net for the unhandled paths.

# Skip silently if already installed (idempotent for nested sources).
if [[ -z "${_AMA_ERR_TRAP_INSTALLED:-}" ]]; then
    _AMA_ERR_TRAP_INSTALLED=1

    _AMA_PREMORTEM_LOG="${AMA_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)}/brain/state/tool_premortem.jsonl"

    _ama_emit_err() {
        local _exit="$1" _line="$2" _cmd="$3" _src="$4"
        # Only emit for non-zero exits; ERR also fires for `false` chains etc.
        [[ "$_exit" == "0" ]] && return 0
        # Trim cmd to keep log tidy — full BASH_COMMAND can be huge for pipes.
        local _cmd_short="${_cmd:0:400}"
        # JSON-escape via python (jq isn't guaranteed and printf %q is wrong shape).
        python3 - "$_exit" "$_line" "$_cmd_short" "$_src" "${0:-?}" "${AMA_TOOL_TC_ID:-}" <<'PYEOF' 2>/dev/null >> "$_AMA_PREMORTEM_LOG" || true
import sys, json, datetime
exit_code, line, cmd, src, tool, tc_id = sys.argv[1:7]
row = {
    "ts": datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "tool": tool.rsplit("/", 1)[-1].replace(".sh", ""),
    "exit": int(exit_code) if exit_code.lstrip("-").isdigit() else exit_code,
    "line": int(line) if line.isdigit() else line,
    "cmd": cmd,
    "source": src,
}
if tc_id:
    row["tc_id"] = tc_id
print(json.dumps(row, ensure_ascii=False))
PYEOF
        return 0  # never propagate trap failure
    }

    set -E -o errtrace 2>/dev/null || true
    trap '_ama_emit_err "$?" "$LINENO" "$BASH_COMMAND" "${BASH_SOURCE[0]:-?}"' ERR
fi
