# Parse LLM response (supports OpenAI and Gemini Native)
parse_resp() {
    local resp="$1"

    if [[ "$resp" != "{"* ]]; then
        printf 'RAW:%s\nTC:null\nTEXT:\n' "$resp"
        return
    fi

    local _parsed
    _parsed=$(RESP="$resp" python3 -c "
import json, os, time
resp_str = os.environ['RESP']
try:
    r = json.loads(resp_str)
except Exception:
    print('PARSE_ERROR')
    raise SystemExit(0)

text = ''
tool_calls = None

if 'candidates' in r:
    # Gemini Native
    parts = (r.get('candidates') or [{}])[0].get('content', {}).get('parts', [])
    text = ' '.join(p.get('text', '') for p in parts if 'text' in p).rstrip()
    g_tc = [p['functionCall'] for p in parts if 'functionCall' in p]
    if g_tc:
        tool_calls = [
            {
                'id': 'call_' + str(int(time.time() * 1000) % 10**9 + i),
                'type': 'function',
                'function': {
                    'name': fc.get('name', ''),
                    'arguments': json.dumps(fc.get('args', {}))
                }
            }
            for i, fc in enumerate(g_tc)
        ]
elif 'choices' in r:
    # OpenAI Format
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
text = text.replace('\\n', ' ').strip()

print('TEXT:' + (text or ''))
print('TC:' + (json.dumps(tool_calls, separators=(',',':')) if tool_calls is not None else 'null'))
" 2>/dev/null)

    if [[ "$_parsed" == "PARSE_ERROR" || -z "$_parsed" ]]; then
        printf 'RAW:%s\nTC:null\nTEXT:\n' "$resp"
        return
    fi

    local text tool_calls
    text=$(echo "$_parsed" | grep "^TEXT:" | cut -c6-)
    tool_calls=$(echo "$_parsed" | grep "^TC:" | cut -c4-)
    [ -z "$tool_calls" ] && tool_calls="null"

    printf 'RAW:%s\nTC:%s\nTEXT:%s\n' "$resp" "$tool_calls" "$text"
}
