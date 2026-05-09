# Streaming API call with Telegram support
call_api_stream() {
    local chat_id="$1"
    local message_id="$2"
    local skill="$3"
    local sys_prompt_override="$4"

    if [ "$PROVIDER" != "default" ] && type "${PROVIDER}_call_api_stream" >/dev/null 2>&1; then
      "${PROVIDER}_call_api_stream" "$chat_id" "$message_id" "$skill" "$sys_prompt_override"
      return $?
    fi

    local attempt=1
    local max_attempts=3

    while [ "$attempt" -le "$max_attempts" ]; do
        local payload=$(_api_build_payload "true" "$sys_prompt_override" "$skill")

        # Resolve API key and headers from Mix logic
        local _api_key="$API_KEY"
        if [ "$PROVIDER" != "default" ] && type "${PROVIDER}_get_api_key" >/dev/null 2>&1; then
          local _pkey; _pkey=$(${PROVIDER}_get_api_key 2>/dev/null) || true
          [ -n "$_pkey" ] && _api_key="$_pkey"
        fi

        local _extra_headers="{}"
        if [ "$PROVIDER" != "default" ] && type "${PROVIDER}_extra_headers_json" >/dev/null 2>&1; then
          local _ph; _ph=$(${PROVIDER}_extra_headers_json 2>/dev/null) || true
          [ -n "$_ph" ] && _extra_headers="$_ph"
        fi

        # We need to capture the output but also let it stream to TG
        local tmp_out=$(mktemp)
        local tmp_err=$(mktemp)

        # Use python to handle the stream and Telegram updates
        TG_TOKEN="$TG_TOKEN" \
        BASE_URL="$BASE_URL" \
        API_KEY="$_api_key" \
        EXTRA_HEADERS="$_extra_headers" \
        CHAT_ID="$chat_id" \
        MESSAGE_ID="$message_id" \
        python3 -u -c '
import json, sys, time, os, requests, re

tg_token = os.environ.get("TG_TOKEN")
chat_id = os.environ.get("CHAT_ID")
message_id = os.environ.get("MESSAGE_ID")
base_url = os.environ.get("BASE_URL")
api_key = os.environ.get("API_KEY")
extra_headers = json.loads(os.environ.get("EXTRA_HEADERS", "{}"))

url = f"{base_url}/chat/completions"
payload = json.load(sys.stdin)

headers = {
    "Authorization": f"Bearer {api_key}",
    "Content-Type": "application/json"
}
headers.update(extra_headers)

tg_url = f"https://api.telegram.org/bot{tg_token}/editMessageText"

def md_to_html(text):
    result = []
    parts = re.split(r'(```[\w]*\n?[\s\S]*?```|`[^`\n]+`)', text)
    for i, part in enumerate(parts):
        if i % 2 == 1:
            if part.startswith('```'):
                code = re.sub(r'^```\w*\n?', '', part)
                code = re.sub(r'\n?```$', '', code)
                code = code.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;')
                result.append(f'<pre><code>{code}</code></pre>')
            else:
                code = part[1:-1]
                code = code.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;')
                result.append(f'<code>{code}</code>')
        else:
            p = part.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;')
            p = re.sub(r'^#{1,6} +(.+)$', r'<b>\1</b>', p, flags=re.MULTILINE)
            p = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', p, flags=re.DOTALL)
            p = re.sub(r'__(.+?)__', r'<b>\1</b>', p, flags=re.DOTALL)
            p = re.sub(r'(?<!\*)\*(?!\*)(.+?)(?<!\s)\*(?!\*)', r'<i>\1</i>', p)
            p = re.sub(r'_([^_\n]+?)_', r'<i>\1</i>', p)
            p = re.sub(r'~~(.+?)~~', r'<s>\1</s>', p)
            p = re.sub(r'\[([^\]]+)\]\((https?://[^)]+)\)', r'<a href="\2">\1</a>', p)
            result.append(p)
    return ''.join(result)

def update_tg(text):
    if not text: return
    # Scrub thinking blocks from Telegram output
    clean_text = re.sub(r"<(think|thinking|reasoning|thought)>.*?(</\1>|$)", "", text, flags=re.DOTALL | re.IGNORECASE)
    if not clean_text.strip(): return
    html = md_to_html(clean_text.strip())
    try:
        requests.post(tg_url, json={
            "chat_id": chat_id,
            "message_id": message_id,
            "text": html,
            "parse_mode": "HTML"
        }, timeout=5)
    except: pass

content = ""
thought_active = False
tool_calls = {} # Use dict to accumulate by index
usage = None
last_update = time.time()

try:
    with requests.post(url, json=payload, headers=headers, stream=True, timeout=60) as r:
        for line in r.iter_lines():
            if not line: continue
            line = line.decode("utf-8")
            if not line.startswith("data: "): continue

            data_str = line[6:]
            if data_str == "[DONE]": break

            try:
                data = json.loads(data_str)
            except: continue

            # Check for usage info
            if "usage" in data:
                usage = data["usage"]

            delta = data.get("choices", [{}])[0].get("delta", {})

            if "thought" in delta and delta["thought"]:
                if not thought_active:
                    content += "<think>"
                    thought_active = True
                content += delta["thought"]

            if "content" in delta and delta["content"]:
                if thought_active:
                    content += "</think>"
                    thought_active = False
                content += delta["content"]

            if "tool_calls" in delta:
                if thought_active:
                    content += "</think>"
                    thought_active = False
                for tc in delta["tool_calls"]:
                    idx = tc.get("index", 0)
                    if idx not in tool_calls:
                        tool_calls[idx] = {"id": "", "type": "function", "function": {"name": "", "arguments": ""}}
                    
                    if "id" in tc:
                        tool_calls[idx]["id"] += tc["id"]
                    
                    if "function" in tc:
                        f = tc["function"]
                        if "name" in f: tool_calls[idx]["function"]["name"] += f["name"]
                        if "arguments" in f: tool_calls[idx]["function"]["arguments"] += f["arguments"]

            if time.time() - last_update > 2.0:
                display_text = content if content else "..."
                if tool_calls:
                    display_text += "\n\n(Thinking: tool calls pending...)"
                update_tg(display_text)
                last_update = time.time()
except Exception as e:
    sys.stderr.write(f"Error: {e}\n")

# Final update
clean_final = re.sub(r"<(think|thinking|reasoning|thought)>.*?(</\1>|$)", "", content, flags=re.DOTALL | re.IGNORECASE)
if tool_calls:
    clean_final += "\n\n(Running tools...)"
update_tg(clean_final if clean_final.strip() else "(done)")

# Output for bash parsing (TC: list of tool calls)
tc_list = []
for k, v in sorted(tool_calls.items()):
    if not v.get("id"):
        v["id"] = f"call_{int(time.time() * 1000)}"
    tc_list.append(v)

print(f"TC:{json.dumps(tc_list)}")
print(f"TEXT:{content}")
if usage:
    print(f"USAGE:{json.dumps(usage)}")
' <<EOF > "$tmp_out" 2> "$tmp_err"
$payload
EOF
        local status=$?
        local result=$(cat "$tmp_out")
        local err_out=$(cat "$tmp_err")
        rm -f "$tmp_out" "$tmp_err"

        # Check for errors in err_out or status
        if [[ $status -ne 0 || "$result" != *"TC:"* ]]; then
             echo "AMA: Stream Error (Status $status). Err: $err_out" >&2

             # Try to classify error from err_out if possible, or just retry
             if [[ "$attempt" -lt "$max_attempts" ]]; then
                 if [[ -n "$FALLBACK_MODEL" && "$MODEL" != "$FALLBACK_MODEL" ]]; then
                     echo "AMA: Switching to fallback model $FALLBACK_MODEL" >&2
                     MODEL="$FALLBACK_MODEL"
                 fi
                 local delay=$((2 ** attempt))
                 sleep "$delay"
                 attempt=$((attempt + 1))
                 continue
             fi
        fi

        echo "$result"
        return 0
    done
}
