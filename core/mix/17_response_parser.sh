# Parse LLM response (OpenAI format — all providers normalize to this)
parse_resp() {
    local resp="$1"

    if [[ "$resp" != "{"* ]]; then
        printf 'TC:null\nTEXT:\n'
        return
    fi

    local _parsed
    _parsed=$(python3 -c "
import json, sys
try:
    r = json.loads(open(sys.argv[1]).read())
except Exception:
    print('PARSE_ERROR')
    raise SystemExit(0)

text = ''
tool_calls = None

msg = (r.get('choices') or [{}])[0].get('message', {})
text = msg.get('content', '') or ''
tc = msg.get('tool_calls')
if isinstance(tc, list):
    tool_calls = []
    for t in tc:
        if not t.get('id'):
            t = dict(t)
            fname = (t.get('function') or {}).get('name', 'tool')
            t['id'] = 'call_' + fname
        tool_calls.append(t)

# Collapse newlines to spaces for single-line output
text = text.replace('\\n', ' ').strip() if text else ''

print('TEXT:' + (text or ''))
print('TC:' + (json.dumps(tool_calls, separators=(',',':')) if tool_calls is not None else 'null'))
" 2>/dev/null)

    if [[ "$_parsed" == "PARSE_ERROR" || -z "$_parsed" ]]; then
        printf 'TC:null\nTEXT:\n'
        return
    fi

    local text tool_calls
    text=$(echo "$_parsed" | grep "^TEXT:" | cut -c6-)
    tool_calls=$(echo "$_parsed" | grep "^TC:" | cut -c4-)
    [ -z "$tool_calls" ] && tool_calls="null"

    printf 'TC:%s\nTEXT:%s\n' "$tool_calls" "$text"
}
