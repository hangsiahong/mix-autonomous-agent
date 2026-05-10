#!/bin/bash
# tools/write_file.sh — Create or overwrite a file with safety checks.
#
# Inputs:
#   TOOL_path     — relative path within project root (required)
#   TOOL_content  — content to write (default empty)
#   TOOL_append   — "true" to append instead of overwrite (default false)
#
# For .sh / .py / .json files, the new content is syntax-checked before
# the file is touched. Sensitive system paths and credential directories
# are refused.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${TOOL_path:-}" ]]; then
    echo "Error: 'path' is required."
    exit 1
fi

cd "$ROOT" || { echo "Error: cannot enter project root"; exit 1; }

PATH_VAL="${TOOL_path}" \
CONTENT_VAL="${TOOL_content:-}" \
APPEND_VAL="${TOOL_append:-false}" \
python3 -c "
import json, os, sys
ap = os.environ['APPEND_VAL'].lower() in ('true','1','yes')
sys.stdout.write(json.dumps({
    'path': os.environ['PATH_VAL'],
    'content': os.environ['CONTENT_VAL'],
    'append': ap,
}))" | python3 "$ROOT/tools/_lib/cli.py" write
