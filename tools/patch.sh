#!/bin/bash
# tools/patch.sh — Apply a V4A multi-file/multi-hunk patch atomically.
#
# Inputs:
#   TOOL_patch — full patch in V4A format. Example:
#       *** Begin Patch
#       *** Update File: path/to/a.py
#       @@ optional context hint @@
#        unchanged context line (space prefix)
#       -removed line
#       +added line
#       *** Add File: path/new.txt
#       +brand new content
#       *** Delete File: path/old.txt
#       *** Move File: src.py -> dst.py
#       *** End Patch
#
# Behaviour (two-phase):
#   • Phase 1 validates EVERY operation in-memory. If anything fails,
#     no files are touched.
#   • Phase 2 applies all operations; aggregates a unified diff.
#   • Per-file syntax check (.sh/.py/.json) gates each write.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${TOOL_patch:-}" ]]; then
    echo "Error: 'patch' is required (V4A format)."
    exit 1
fi

cd "$ROOT" || { echo "Error: cannot enter project root"; exit 1; }

PATCH_VAL="${TOOL_patch}" python3 -c "
import json, os, sys
sys.stdout.write(json.dumps({'patch': os.environ['PATCH_VAL']}))
" | python3 "$ROOT/tools/_lib/cli.py" patch
