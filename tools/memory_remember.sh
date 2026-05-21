#!/bin/bash
# Tool: memory_remember
# Args: text (string), metadata_json (string)

text="${TOOL_text}"
meta="${TOOL_metadata_json:-"{}"}"

# ── Critic gate — quality-check the proposed observation before it lands in
# LanceDB. Fail-open on any error (better to save a possibly-bad memory than
# to silently lose a possibly-good one). Killswitch: AMA_MEM_CRITIC_DISABLED=1.
_critic_out=$(printf '%s' "{\"text\": $(python3 -c "import json,sys;print(json.dumps(sys.argv[1]))" "$text")}" | \
    timeout 25 python3 "$(dirname "$0")/memory_critic.py" --mode vector 2>/dev/null)
if [[ -n "$_critic_out" ]]; then
    _accept=$(python3 -c "import json,sys;d=json.loads(sys.stdin.read() or '{}');print('1' if d.get('accept',True) else '0')" <<< "$_critic_out" 2>/dev/null)
    if [[ "$_accept" == "0" ]]; then
        _reason=$(python3 -c "import json,sys;d=json.loads(sys.stdin.read() or '{}');print(d.get('reason',''))" <<< "$_critic_out" 2>/dev/null)
        printf 'Critic rejected memory write: %s\n' "$_reason"
        exit 0
    fi
    # Use revised text if critic improved it
    _revised=$(python3 -c "import json,sys;d=json.loads(sys.stdin.read() or '{}');print(d.get('revised') or '')" <<< "$_critic_out" 2>/dev/null)
    if [[ -n "$_revised" ]]; then
        text="$_revised"
    fi
fi

# Inject saved_at timestamp into metadata
meta=$(echo "$meta" | python3 -c "
import json, sys, time
try:
    m = json.load(sys.stdin)
except Exception:
    m = {}
m.setdefault('saved_at', int(time.time()))
print(json.dumps(m))
" 2>/dev/null || echo "$meta")

python3 "$(dirname "$0")/memory_helper.py" save "$text" "$meta"
