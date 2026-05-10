#!/bin/bash
# tools/edit_code.sh — Find-and-replace editor with multi-strategy fuzzy matching.
#
# Inputs:
#   TOOL_path         — relative path within project root (required)
#   TOOL_old_string   — text to find (multi-line OK; required)
#   TOOL_new_string   — replacement text (multi-line OK)
#   TOOL_replace_all  — "true" to replace every occurrence; default false
#
# Behaviour:
#   • Validates path is inside the project root and not a sensitive system file.
#   • Tries 9 matching strategies in order (exact → unicode → fuzzy block).
#   • If only fuzzy strategies match, the strategy name is reported in output
#     so the agent can verify the diff.
#   • For .sh / .py / .json files, re-validates syntax after the replacement
#     and aborts the write if syntax breaks.
#   • Prints a unified diff on success.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${TOOL_path:-}" ]]; then
    echo "Error: 'path' is required."
    exit 1
fi
if [[ -z "${TOOL_old_string:-}" ]]; then
    echo "Error: 'old_string' is required. Use write_file to create new files."
    exit 1
fi

cd "$ROOT" || { echo "Error: cannot enter project root"; exit 1; }

PATH_VAL="${TOOL_path}" \
OLD_VAL="${TOOL_old_string}" \
NEW_VAL="${TOOL_new_string:-}" \
RA_VAL="${TOOL_replace_all:-false}" \
python3 -c "
import json, os, sys
ra = os.environ['RA_VAL'].lower() in ('true','1','yes')
sys.stdout.write(json.dumps({
    'path': os.environ['PATH_VAL'],
    'old_string': os.environ['OLD_VAL'],
    'new_string': os.environ['NEW_VAL'],
    'replace_all': ra,
}))" | python3 "$ROOT/tools/_lib/cli.py" edit
