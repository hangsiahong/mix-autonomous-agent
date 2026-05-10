#!/bin/bash
# tools/read_code.sh — Paginated file read with line numbers.
#
# Inputs:
#   TOOL_path    — relative path within project root (required)
#   TOOL_offset  — starting line (1-based, default 1)
#   TOOL_limit   — max lines to return (default 500, max 2000)

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${TOOL_path:-}" ]]; then
    echo "Error: 'path' is required."
    exit 1
fi

cd "$ROOT" || { echo "Error: cannot enter project root"; exit 1; }

PATH_VAL="${TOOL_path}" \
OFFSET_VAL="${TOOL_offset:-1}" \
LIMIT_VAL="${TOOL_limit:-500}" \
python3 -c "
import json, os, sys
sys.stdout.write(json.dumps({
    'path': os.environ['PATH_VAL'],
    'offset': int(os.environ['OFFSET_VAL'] or 1),
    'limit': int(os.environ['LIMIT_VAL'] or 500),
}))" | python3 "$ROOT/tools/_lib/cli.py" read

# Append context discovery hints (subdirectory README/HINT files).
DISCOVERY_SH="$ROOT/tools/context_discovery.sh"
if [[ -f "$DISCOVERY_SH" ]]; then
    bash "$DISCOVERY_SH" "$TOOL_path" 2>/dev/null || true
fi
