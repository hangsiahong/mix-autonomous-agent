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
if ! python3 - "$cmd" <<'PYEOF'
import sys, re
cmd = sys.argv[1]
patterns = [
    r'\brm\s+(-[a-zA-Z]*[rfRF][a-zA-Z]*\s+)+(/|/\*|~|/etc|/var|/usr|/bin|/sbin|/boot|/lib|\$HOME)',
    r'\bmkfs(\.|\s)',
    r'\bdd\s+.*of=/dev/[sh]d',
    r':\(\)\{\s*:\s*\|\s*:\s*&\s*\}',
    r'\b(shutdown|reboot|halt|poweroff)\b',
    r'\b(mount|umount)\s+',
    r'\bchmod\s+(-R\s+)?0?[0-7]*777\s+/',
    r'\bchown\s+(-R\s+)?[^[:space:]]+\s+/',
    r'(cat|less|more|head|tail|tee|cp|scp|mv|tar|zip|gzip)\s+[^|;&]*(/etc/(passwd|shadow|sudoers)|~/\.ssh/|/\.aws/credentials|\.netrc|\.pgpass|\.git-credentials|id_[rde][sca])',
    r'\$\{?(API_KEY|TG_TOKEN|TAVILY|SECRET|PASSWORD|PRIVATE_KEY)[A-Z_]*\}?[^|;&]*\|[[:space:]]*(curl|wget|nc|netcat|telnet|ssh)\b',
    r'\b(nc|ncat|netcat)\b[^|;&]*-e\s+',
    r'bash\s+-i\s+>',
    r'/dev/tcp/',
    r'(>+|tee|cp|mv|sed)[^|;&]*(\.env|brain/state/permissions\.json)'
]
for pat in patterns:
    try:
        if re.search(pat, cmd, re.IGNORECASE):
            print(f"Error: command blocked for safety (pattern: {pat[:60]}...)")
            sys.exit(1)
    except Exception:
        continue
sys.exit(0)
PYEOF
then
    exit 1
fi

# Reject suspicious unicode (zero-width chars, RTL overrides) — common in
# prompt-injection payloads that hide one command inside another.
if python3 -c "
import sys, re
cmd = sys.stdin.read()
# Zero-width, RTL overrides, BOM, word joiners
if re.search(r'[\u200b-\u200f\u202a-\u202e\u2060\ufeff]', cmd):
    sys.exit(1)
sys.exit(0)
" <<< "$cmd"; then
    : # clean
else
    echo "Error: command contains invisible/bidirectional Unicode characters — refusing."
    exit 1
fi

# Run with timeout and a small environment to avoid leaking arbitrary host vars.
output=$(timeout --signal=TERM --kill-after=5 "${runtime}" bash -c "$cmd" 2>&1)
status=$?

echo "$output"

if (( status == 124 )); then
    echo ""
    echo "[Process killed: exceeded ${runtime}s timeout. Re-run with TOOL_timeout=N to extend, or break the work into smaller commands.]"
fi

# Better sensory feedback: analyze failures and surface actionable hints
# so the LLM doesn't have to guess what went wrong.
if (( status != 0 )); then
    hint=""
    # Missing Python module
    mod=$(echo "$output" | grep -oP "(?<=No module named ')[^']+" | head -1)
    [[ -n "$mod" ]] && hint="💡 Missing module: pip install ${mod}"

    # Command not found
    if [[ -z "$hint" ]]; then
        missing_cmd=$(echo "$output" | grep -oP "(?<=command not found: )\S+" | head -1)
        [[ -n "$missing_cmd" ]] && hint="💡 '${missing_cmd}' not found. Install it or check PATH."
    fi

    # Permission denied
    if [[ -z "$hint" ]]; then
        perm_file=$(echo "$output" | grep -oP "(?<=Permission denied: )['\"]?[^\s'\"]+['\"]?" | head -1)
        if [[ -z "$perm_file" ]]; then
            echo "$output" | grep -q "Permission denied" && perm_file="<file>"
        fi
        [[ -n "$perm_file" ]] && hint="💡 Permission denied on ${perm_file}. Try: chmod +x ${perm_file} or check ownership."
    fi

    # Port already in use
    if [[ -z "$hint" ]]; then
        echo "$output" | grep -qiE "address already in use|port.*in use|EADDRINUSE" && \
            hint="💡 Port already in use. Find the process: lsof -ti :<port> | xargs kill"
    fi

    # Syntax error in a script we ran
    if [[ -z "$hint" ]]; then
        syn_file=$(echo "$output" | grep -oP "(?<=syntax error in )([^\s:]+)" | head -1)
        [[ -n "$syn_file" ]] && hint="💡 Syntax error in ${syn_file}. Run: bash -n ${syn_file}"
    fi

    # File/directory not found
    if [[ -z "$hint" ]]; then
        echo "$output" | grep -qE "No such file or directory|not found|does not exist" && \
            hint="💡 Path not found. Verify with: ls -la <path>"
    fi

    if [[ -n "$hint" ]]; then
        printf '\n%s\n' "$hint"
    fi
    echo "[Exit code: ${status}]"
fi

exit $status
