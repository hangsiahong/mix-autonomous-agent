import json
import sys
import os
import requests
import time
import re

def update_tg(tg_token, chat_id, message_id, text):
    if not text: return
    clean_text = re.sub(r"<(think|thinking|reasoning|thought)>.*?(</\1>|$)", "", text, flags=re.DOTALL | re.IGNORECASE)
    if not clean_text.strip(): return
    url = f"https://api.telegram.org/bot{tg_token}/editMessageText"
    try:
        requests.post(url, json={
            "chat_id": chat_id,
            "message_id": message_id,
            "text": clean_text.strip(),
            "parse_mode": "Markdown"
        }, timeout=5)
    except: pass

def main():
    tg_token = os.environ.get("TG_TOKEN")
    chat_id = os.environ.get("CHAT_ID")
    message_id = os.environ.get("MESSAGE_ID")
    url = os.environ.get("GOOGLE_STREAM_URL")
    api_key = os.environ.get("API_KEY") # Might be OAuth token
    is_vertex = os.environ.get("GOOGLE_MODE") == "vertex"
    
    payload = json.load(sys.stdin)
    
    headers = {"Content-Type": "application/json"}
    if is_vertex:
        headers["Authorization"] = f"Bearer {api_key}"
    
    # Gemini stream endpoint is :streamGenerateContent
    # But if we use the generateContent URL, we can just use stream=True in some cases? 
    # No, Gemini native uses a different URL for streaming.
    
    stream_url = url.replace(":generateContent", ":streamGenerateContent")
    if not is_vertex:
        stream_url += "&alt=sse"
    else:
        stream_url += "?alt=sse"

    content = ""
    tool_calls = {}
    usage = None
    last_update = time.time()
    
    try:
        with requests.post(stream_url, json=payload, headers=headers, stream=True, timeout=60) as r:
            for line in r.iter_lines():
                if not line: continue
                line = line.decode("utf-8")
                if not line.startswith("data: "): continue
                
                data_str = line[6:]
                try:
                    data = json.loads(data_str)
                except: continue
                
                # Gemini Stream format
                # data is a candidate or a list of candidates
                candidate = data.get("candidates", [{}])[0]
                parts = candidate.get("content", {}).get("parts", [])
                
                for part in parts:
                    if "text" in part:
                        content += part["text"]
                    if "functionCall" in part:
                        fc = part["functionCall"]
                        name = fc.get("name")
                        # Gemini doesn't always index them in stream? 
                        # Actually it usually sends one full function call or parts of it.
                        # For now assume one function call per turn or accumulate by name.
                        if name not in tool_calls:
                            tool_calls[name] = {"name": name, "arguments": ""}
                        if "args" in fc:
                            # In Gemini, args is already a dict
                            tool_calls[name]["arguments"] = json.dumps(fc["args"])

                if time.time() - last_update > 2.0:
                    update_tg(tg_token, chat_id, message_id, content if content else "...")
                    last_update = time.time()
                    
            if "usageMetadata" in data:
                usage = data["usageMetadata"]
    except Exception as e:
        sys.stderr.write(f"Error: {e}\n")

    update_tg(tg_token, chat_id, message_id, content if content else "(done)")
    
    tc_list = [{"id": f"call_{int(time.time())}_{i}", "type": "function", "function": v} for i, v in enumerate(tool_calls.values())]
    print(f"TC:{json.dumps(tc_list)}")
    print(f"TEXT:{content}")
    if usage:
        print(f"USAGE:{json.dumps(usage)}")

if __name__ == "__main__":
    main()
