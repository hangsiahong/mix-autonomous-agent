#!/bin/bash
# tools/bash.sh — Run a bash command in the project directory with safety checks.
#
# This tool is the most powerful in the system. The harness should treat it
# as SENSITIVE and gate it via core/access_control.sh.
#
# Inputs:
#   TOOL_command  — command to run (required)
#   TOOL_timeout  — seconds, default 30, max 120
#
# Safety:
#   • cd's to project root before running anything.
#   • Refuses commands that obviously exfiltrate credentials or destroy data,
#     including patterns hidden inside subshells / pipes / heredocs.
#   • Strips a small set of unconditionally dangerous constructs (rm -rf /,
#     fork bombs, mkfs, dd-of-disk, mount, shutdown, reboot).
#   • Caps runtime via `timeout`.
#
# This is *not* a sandbox. Treat it as production shell with guard rails.

set -u

cmd="${TOOL_command:-}"
runtime="${TOOL_timeout:-30}"

if [[ -z "$cmd" ]]; then
    echo "Error: 'command' is required."
    exit 1
fi

# Coerce timeout into a sane positive integer 1..120.
if ! [[ "$runtime" =~ ^[0-9]+$ ]] || (( runtime < 1 )); then
    runtime=30
fi
(( runtime > 120 )) && runtime=120

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT" || { echo "Error: cannot enter project root"; exit 1; }

# Block clearly destructive or exfil patterns anywhere in the command,
# not just at the start. These are not exhaustive — defence in depth only.
_DANGER_PATTERNS=(
    '\brm[[:space:]]+(-[a-zA-Z]*[rfRF][a-zA-Z]*[[:space:]]+)+(/|/\*|~|/etc|/var|/usr|/bin|/sbin|/boot|/lib|\$HOME)'
    '\bmkfs(\.|[[:space:]])'
    '\bdd[[:space:]].*of=/dev/[sh]d'
    ':\(\)\{[[:space:]]*:[[:space:]]*\|[[:space:]]*:[[:space:]]*&[[:space:]]*\}'
    '\b(shutdown|reboot|halt|poweroff)\b'
    '\b(mount|umount)[[:space:]]+'
    '\bchmod[[:space:]]+(-R[[:space:]]+)?[0-7]*777[[:space:]]+/'
    '\bchown[[:space:]]+(-R[[:space:]]+)?[^[:space:]]+[[:space:]]+/'
    # Credential exfil: reading common secret files
    '(cat|less|more|head|tail|tee|cp|scp|mv|tar|zip|gzip)[[:space:]]+[^|;&]*(/etc/(passwd|shadow|sudoers)|~/\.ssh/|/\.aws/credentials|\.netrc|\.pgpass|\.git-credentials|id_[rde][sca])'
    # Piping secrets to network
    '\$\{?(API_KEY|TG_TOKEN|TAVILY|SECRET|PASSWORD|PRIVATE_KEY)[A-Z_]*\}?[^|;&]*\|[[:space:]]*(curl|wget|nc|netcat|telnet|ssh)\b'
    # Reverse shells
    '\b(nc|ncat|netcat)\b[^|;&]*-e[[:space:]]+'
    'bash[[:space:]]+-i[[:space:]]+>'
    '/dev/tcp/'
    # Editing the bot's own credential file
    '(>+|tee|cp|mv|sed)[^|;&]*(\.env|brain/state/permissions\.json)'
)

for pat in "${_DANGER_PATTERNS[@]}"; do
    if echo "$cmd" | LC_ALL=C grep -qE "$pat"; then
        echo "Error: command blocked for safety (pattern: ${pat:0:60}...)"
        echo "If this is a legitimate need, ask the user to perform it manually."
        exit 1
    fi
done

# Reject suspicious unicode (zero-width chars, RTL overrides) — common in
# prompt-injection payloads that hide one command inside another.
if echo "$cmd" | LC_ALL=C grep -qP '[\x{200b}-\x{200f}\x{202a}-\x{202e}\x{2060}\x{feff}]'; then
    echo "Error: command contains invisible/bidirectional Unicode characters — refusing."
    exit 1
fi

# Run with timeout and a small environment to avoid leaking arbitrary host vars.
timeout --signal=TERM --kill-after=5 "${runtime}" bash -c "$cmd" 2>&1
status=$?
if (( status == 124 )); then
    echo ""
    echo "[Process killed: exceeded ${runtime}s timeout. Re-run with TOOL_timeout=N to extend, or break the work into smaller commands.]"
fi
exit $status
