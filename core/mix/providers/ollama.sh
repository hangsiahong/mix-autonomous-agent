# ─── Provider: Ollama (local LLM) ────────────────────────────────────────────
# Runs any Ollama model locally via its OpenAI-compatible API.
#
# Requirements:
#   - Ollama running: ollama serve  (or systemctl start ollama)
#   - Model pulled:  ollama pull <model>
#
# Config:
#   PROVIDER=ollama
#   MODEL=gemma4:e4b-it-q4_K_M   (or any model you've pulled)
#   OLLAMA_URL=http://localhost:11434  (optional override)
#
# No API key required. Auth header is sent with a dummy value that Ollama ignores.

_OLLAMA_DEFAULT_URL="http://localhost:11434"

ollama_activate() {
  local base="${OLLAMA_URL:-$_OLLAMA_DEFAULT_URL}"
  # Store raw base URL for native API calls (without /v1)
  _OLLAMA_BASE_URL="${base}"
  # Also set /v1 for framework compatibility (auth, etc.)
  BASE_URL="${base}/v1"
  # Ollama ignores the Authorization header but the framework requires a value
  API_KEY="${OLLAMA_API_KEY:-ollama}"
}

# No extra headers needed
ollama_extra_headers_json() {
  echo '{}'
}

# No extra payload mods needed — disable thinking for speed
ollama_extra_payload_json() {
  echo '{"think": false}'
}

# Non-streaming call used by summary/title/reflection — strip tools for speed.
# Uses native /api/chat endpoint which properly honours think:false.
ollama_call_api() {
  local sys_prompt_override="$1"

  local payload
  payload=$(_api_build_payload "false" "$sys_prompt_override") || { echo "FAIL:payload"; return 1; }

  # Strip tools and tool_choice — non-interactive calls don't need them and they slow Ollama down
  # Use native /api/chat format with think:false and stream:false
  payload=$(python3 -c "
import sys, json
b = json.loads(open(sys.argv[1]).read())
b.pop('tools', None)
b.pop('tool_choice', None)
b['think'] = False
b['stream'] = False
print(json.dumps(b))
" <(printf '%s' "$payload") 2>/dev/null) || true

  local tmp; tmp=$(mktemp)
  local http_code
  http_code=$(curl -s -w "%{http_code}" \
    -H "Content-Type: application/json" \
    --max-time 120 \
    -o "$tmp" \
    -d "$payload" \
    "${_OLLAMA_BASE_URL:-http://localhost:11434}/api/chat" 2>/dev/null) || true
  local body; body=$(cat "$tmp" 2>/dev/null || true); rm -f "$tmp"

  if [[ "$http_code" != "200" ]] || [[ -z "$body" ]]; then
    echo "FAIL:ollama_call_api_http_$http_code"
    return 1
  fi

  # Convert native Ollama response to OpenAI-compat format so callers don't need to change
  body=$(python3 -c "
import sys, json
d = json.loads(open(sys.argv[1]).read())
msg = d.get('message', {})
content = msg.get('content') or ''
p = d.get('prompt_eval_count', 0)
c = d.get('eval_count', 0)
out = {
    'choices': [{'message': msg}],
    'usage': {'prompt_tokens': p, 'completion_tokens': c, 'total_tokens': p+c}
}
print(json.dumps(out))
" <(printf '%s' "$body") 2>/dev/null)
  printf '%s' "$body"
}

# Flatten array content to plain strings — Ollama models don't support multipart content format.
# Also removes tool/tool_call messages which most local models can't handle properly.
ollama_filter_history() {
  python3 -c '
import sys, json

history = json.loads(open(sys.argv[1]).read())
out = []
for msg in history:
    role = msg.get("role", "")
    # Skip tool result and tool_call assistant messages
    if role == "tool":
        continue
    if role == "assistant" and msg.get("tool_calls"):
        continue
    content = msg.get("content")
    # Flatten array content to plain string
    if isinstance(content, list):
        parts = []
        for p in content:
            if isinstance(p, dict):
                t = p.get("text") or p.get("content") or ""
                if t:
                    parts.append(t)
            elif isinstance(p, str):
                parts.append(p)
        content = "\n".join(parts)
    out.append({"role": role, "content": content or ""})
print(json.dumps(out))
'
}

# Override streaming with a simple non-streaming call + single Telegram update.
# Ollama is local/fast so streaming is unnecessary; this avoids SSE parsing issues.
ollama_call_api_stream() {
  local chat_id="$1"
  local message_id="$2"
  local skill="$3"
  local sys_prompt_override="$4"

  local payload
  payload=$(_api_build_payload "false" "$sys_prompt_override" "$skill") || {
    echo "FAIL:payload"; return 1
  }

  # Strip tools if the last user message is short (simple chat — saves ~800 prompt tokens)
  local _last_msg
  _last_msg=$(python3 -c "
import sys,json
b=json.loads(open(sys.argv[1]).read())
msgs=[m for m in b.get('messages',[]) if m.get('role')=='user']
if msgs:
    c=msgs[-1].get('content','')
    if isinstance(c,list): c=' '.join(p.get('text','') for p in c if isinstance(p,dict))
    print(str(len(c)))
else:
    print('0')
" <(printf '%s' "$payload") 2>/dev/null) || _last_msg=999
  # Build native /api/chat payload: think:false, stream:false, strip tools if short message
  payload=$(python3 -c "
import sys,json
b=json.loads(open(sys.argv[1]).read())
b['think'] = False
b['stream'] = False
import sys as _sys
msg_len = int(_sys.argv[1]) if len(_sys.argv) > 1 else 999
if msg_len < 200:
    b.pop('tools',None)
    b.pop('tool_choice',None)
print(json.dumps(b))
" <(printf '%s' "$payload") "${_last_msg:-999}" 2>/dev/null) || true

  local attempt=1
  local max_attempts=3
  while [ "$attempt" -le "$max_attempts" ]; do
    local tmp; tmp=$(mktemp)
    local http_code
    http_code=$(curl -s -w "%{http_code}" \
      -H "Content-Type: application/json" \
      --max-time 300 \
      -o "$tmp" \
      -d "$payload" \
      "${_OLLAMA_BASE_URL:-http://localhost:11434}/api/chat" 2>/dev/null) || true
    local body; body=$(cat "$tmp" 2>/dev/null || true); rm -f "$tmp"

    if [[ "$http_code" != "200" ]] || [[ -z "$body" ]]; then
      attempt=$((attempt + 1))
      sleep $((2 ** attempt))
      continue
    fi

    # Parse with Python to be robust — handles Ollama native /api/chat format
    local parsed
    parsed=$(python3 - "$body" <<'PYEOF'
import sys, json, re

raw = sys.argv[1]
try:
    data = json.loads(raw)
except Exception as e:
    print(f"FAIL:json_parse:{e}")
    sys.exit(1)

text = ""
tool_calls = []
usage = None

# Ollama native /api/chat format: {"message": {...}, "prompt_eval_count": ..., "eval_count": ...}
msg = data.get("message", {})
text = msg.get("content") or ""
tcs = msg.get("tool_calls") or []
for tc in tcs:
    if not tc.get("id"):
        tc["id"] = "call_" + (tc.get("function", {}).get("name") or "tool")
    tool_calls.append(tc)

p = data.get("prompt_eval_count", 0)
c = data.get("eval_count", 0)
if p or c:
    usage = {"prompt_tokens": p, "completion_tokens": c, "total_tokens": p + c}

print(f"TC:{json.dumps(tool_calls)}")
print(f"TEXT:{text}")
if usage:
    print(f"USAGE:{json.dumps(usage)}")
PYEOF
)

    if [[ "$parsed" == FAIL:* ]]; then
      attempt=$((attempt + 1))
      sleep $((2 ** attempt))
      continue
    fi

    # Update Telegram with the full response text (use Python to handle multiline)
    local reply_text
    reply_text=$(printf '%s' "$parsed" | python3 -c "
import sys, re
c = sys.stdin.read()
m = re.search(r'(?m)^TEXT:(.*?)(?=\nUSAGE:|\Z)', c, re.DOTALL)
if m: print(m.group(1), end='')
" 2>/dev/null)
    local tcs
    tcs=$(echo "$parsed" | grep "^TC:" | cut -c4-)

    local tg_text="${reply_text:-...}"
    if [[ "$tcs" != "[]" && -n "$tcs" && "$tcs" != "null" ]]; then
      tg_text="${tg_text}\n\n(Running tools...)"
    fi
    # Scrub think blocks before sending to Telegram
    local clean
    clean=$(python3 -c "
import sys, re
t = sys.stdin.read()
t = re.sub(r'<(think|thinking|reasoning|thought)>.*?(</\1>|\$)', '', t, flags=re.DOTALL|re.IGNORECASE)
print(t.strip())
" <<< "$tg_text" 2>/dev/null) || clean="$tg_text"

    if [[ -n "$clean" && "$clean" != "..." ]]; then
      curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/editMessageText" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\":\"${chat_id}\",\"message_id\":\"${message_id}\",\"text\":$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$clean"),\"parse_mode\":\"Markdown\"}" \
        >/dev/null 2>&1 || true
    fi

    echo "$parsed"
    return 0
  done

  echo "FAIL:ollama_max_retries"
  return 1
}
