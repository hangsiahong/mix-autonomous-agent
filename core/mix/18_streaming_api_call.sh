# Streaming API call with Telegram support
call_api_stream() {
    local chat_id="$1"
    local message_id="$2"
    local payload=$(_api_build_payload "true")
    
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

    # Use python to handle the stream and Telegram updates
    # We pass everything needed via environment
    TG_TOKEN="$TG_TOKEN" \
    BASE_URL="$BASE_URL" \
    API_KEY="$_api_key" \
    EXTRA_HEADERS="$_extra_headers" \
    CHAT_ID="$chat_id" \
    MESSAGE_ID="$message_id" \
    python3 -u -c '
import json, sys, time, os, requests

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

def update_tg(text):
    if not text: return
    # Scrub thinking blocks from Telegram output
    clean_text = re.sub(r"<(think|thinking|reasoning|thought)>.*?(</\1>|$)", "", text, flags=re.DOTALL | re.IGNORECASE)
    if not clean_text.strip(): return
    try:
        requests.post(tg_url, json={
            "chat_id": chat_id,
            "message_id": message_id,
            "text": clean_text.strip(),
            "parse_mode": "Markdown"
        }, timeout=5)
    except: pass

content = ""
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
            
            if "content" in delta and delta["content"]:
                content += delta["content"]
            
            if "tool_calls" in delta:
                for tc in delta["tool_calls"]:
                    idx = tc.get("index", 0)
                    if idx not in tool_calls:
                        tool_calls[idx] = {"name": "", "args": ""}
                    if "function" in tc:
                        f = tc["function"]
                        if "name" in f: tool_calls[idx]["name"] += f["name"]
                        if "arguments" in f: tool_calls[idx]["args"] += f["arguments"]
            
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
update_tg(clean_final if clean_final.strip() else "(done)")

# Output for bash parsing (TC: list of tool calls)
tc_list = [v for k, v in sorted(tool_calls.items())]
print(f"TC:{json.dumps(tc_list)}")
print(f"TEXT:{content}")
if usage:
    print(f"USAGE:{json.dumps(usage)}")
' <<EOF
$payload
EOF
}
