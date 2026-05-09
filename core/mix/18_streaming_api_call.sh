# Streaming API call with Telegram support
call_api_stream() {
    local chat_id="$1"
    local message_id="$2" # Existing message to edit
    local payload=$(_api_build_payload "true")
    local url="https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:streamGenerateContent?alt=sse&key=${API_KEY}"

    # We use a python script to handle SSE and Telegram updates
    python3 -u -c '
import json, sys, time, requests

chat_id = sys.argv[1]
message_id = sys.argv[2]
tg_token = sys.argv[3]
url = sys.argv[4]
payload = json.load(sys.stdin)

tg_url = f"https://api.telegram.org/bot{tg_token}/editMessageText"

def update_tg(text):
    if not text: return
    try:
        requests.post(tg_url, json={
            "chat_id": chat_id,
            "message_id": message_id,
            "text": text,
            "parse_mode": "Markdown"
        }, timeout=5)
    except: pass

content = ""
tool_calls = []
last_update = time.time()

try:
    with requests.post(url, json=payload, stream=True, timeout=60) as r:
        for line in r.iter_lines():
            if not line: continue
            line = line.decode("utf-8")
            if line.startswith("data: "):
                data = json.loads(line[6:])
                
                # Gemini SSE format
                parts = data.get("candidates", [{}])[0].get("content", {}).get("parts", [])
                for p in parts:
                    if "text" in p:
                        content += p["text"]
                    if "functionCall" in p:
                        tool_calls.append(p["functionCall"])
                
                # Update Telegram every 1.5 seconds
                if time.time() - last_update > 1.5:
                    display_text = content if content else "..."
                    if tool_calls:
                        display_text += "\n\n(Thinking: tool calls pending...)"
                    update_tg(display_text)
                    last_update = time.time()
except Exception as e:
    sys.stderr.write(f"Error: {e}\n")

# Final update
update_tg(content if content else "(done)")

# Output for bash parsing
print(f"TC:{json.dumps(tool_calls)}")
print(f"TEXT:{content}")
' "$chat_id" "$message_id" "$TG_TOKEN" "$url" <<EOF
$payload
EOF
}
