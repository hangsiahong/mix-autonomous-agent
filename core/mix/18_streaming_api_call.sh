# Streaming API call with Telegram support
call_api_stream() {
    local chat_id="$1"
    local message_id="$2"
    local skill="$3"
    local sys_prompt_override="$4"

    local attempt=1
    local max_attempts=5

    while [ "$attempt" -le "$max_attempts" ]; do
        # Pool: pick best available provider/key for this attempt
        pool_apply "$attempt"

        # Provider-specific streaming override (e.g. google_call_api_stream for Vertex SSE)
        if [ "$PROVIDER" != "default" ] && type "${PROVIDER}_call_api_stream" >/dev/null 2>&1; then
            "${PROVIDER}_call_api_stream" "$chat_id" "$message_id" "$skill" "$sys_prompt_override"
            local _ret=$?
            if [[ $_ret -eq 0 ]]; then return 0; fi
            # Stream failed — if pool has another entry, rotate and retry
            if [[ "$(pool_is_enabled)" == "true" && "$attempt" -lt "$max_attempts" ]]; then
                # Only mark rate-limited for actual rate limits, not model errors
                # (pool_mark_limited for model 404s just wastes 60s)
                local _delay
                _delay=$(python3 -c "import random,time; a=$attempt; d=min(5.0*(2**(a-1)),60.0); print(f'{d+random.uniform(0,0.5*d):.1f}')" 2>/dev/null || echo $((5 * attempt)))
                echo "AMA: Stream failed for pool entry ${_POOL_IDX:-}, retrying in ${_delay}s..." >&2
                sleep "$_delay"
                attempt=$((attempt + 1))
                continue
            fi
            return $_ret
        fi

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
        PREV_REASONING="${_thought_snippet:-}" \
        python3 -u -c '
import json, sys, time, os, requests, re

tg_token = os.environ.get("TG_TOKEN")
chat_id = os.environ.get("CHAT_ID")
message_id = os.environ.get("MESSAGE_ID")
base_url = os.environ.get("BASE_URL")
api_key = os.environ.get("API_KEY")
extra_headers = json.loads(os.environ.get("EXTRA_HEADERS", "{}"))
prev_reasoning = os.environ.get("PREV_REASONING", "").strip()

# Reasoning lane — separate Telegram message for thinking (OpenClaw pattern)
_think_msg_id = None
_think_text = ""
_think_last_update = 0.0
def _send_or_update_think(text):
    global _think_msg_id, _think_last_update
    snippet = " ".join(text.split())[-200:]
    escaped = snippet.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;")
    now = time.time()
    if _think_msg_id is None:
        try:
            r = requests.post(f"https://api.telegram.org/bot{tg_token}/sendMessage",
                json={"chat_id": chat_id, "text": f"💭 <i>{escaped}…</i>", "parse_mode": "HTML"}, timeout=5)
            if r.ok: _think_msg_id = r.json().get("result", {}).get("message_id")
            _think_last_update = now
        except Exception: pass
    elif now - _think_last_update > 1.5:
        try:
            requests.post(f"https://api.telegram.org/bot{tg_token}/editMessageText",
                json={"chat_id": chat_id, "message_id": _think_msg_id,
                      "text": f"💭 <i>{escaped}…</i>", "parse_mode": "HTML"}, timeout=5)
            _think_last_update = now
        except Exception: pass

url = f"{base_url}/chat/completions"
payload = json.loads(sys.stdin.read())

headers = {
    "Authorization": f"Bearer {api_key}",
    "Content-Type": "application/json"
}
headers.update(extra_headers)

tg_url = f"https://api.telegram.org/bot{tg_token}/editMessageText"
tg_action_url = f"https://api.telegram.org/bot{tg_token}/sendChatAction"

import threading

_typing_stop = threading.Event()

def _typing_loop():
    while not _typing_stop.wait(4):
        try:
            requests.post(tg_action_url, json={"chat_id": chat_id, "action": "typing"}, timeout=3)
        except Exception:
            pass

_typing_thread = threading.Thread(target=_typing_loop, daemon=True)
_typing_thread.start()

def md_to_html(text):
    result = []
    FENCE_RE = re.compile(r"(```[\w]*\n?[\s\S]*?```|`[^`\n]+`)")
    parts = FENCE_RE.split(text)
    for i, part in enumerate(parts):
        if i % 2 == 1:
            if part.startswith("```"):
                code = re.sub(r"^```\w*\n?", "", part)
                code = re.sub(r"\n?```$", "", code)
                code = code.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;")
                result.append("<pre><code>" + code + "</code></pre>")
            else:
                code = part[1:-1]
                code = code.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;")
                result.append("<code>" + code + "</code>")
        else:
            p = part.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;")
            p = re.sub(r"^#{1,6} +(.+)$", r"<b>\1</b>", p, flags=re.MULTILINE)
            p = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", p, flags=re.DOTALL)
            p = re.sub(r"__(.+?)__", r"<b>\1</b>", p, flags=re.DOTALL)
            p = re.sub(r"(?<!\*)\*(?!\*)(.+?)(?<!\s)\*(?!\*)", r"<i>\1</i>", p)
            p = re.sub(r"_([^_\n]+?)_", r"<i>\1</i>", p)
            p = re.sub(r"~~(.+?)~~", r"<s>\1</s>", p)
            href_repl = "<a href=\"" + "\\2" + "\">" + "\\1" + "</a>"
            p = re.sub(r"\[([^\]]+)\]\((https?://[^)]+)\)", href_repl, p)
            result.append(p)
            
    html = "".join(result)
    
    def format_think(match):
        content = match.group(2)
        if len(content) > 1000:
            content = content[:500] + "\n\n<i>... [thinking truncated] ...</i>\n\n" + content[-500:]
        return "<blockquote><b>🧠 Thinking</b>\n<i>" + content.strip() + "</i></blockquote>\n"
        
    html = re.sub(r"&lt;(think|thinking|reasoning|thought)&gt;(.*?)(&lt;/\1&gt;|$)", format_think, html, flags=re.DOTALL|re.IGNORECASE)
    return html

def update_tg(text):
    if not text and not prev_reasoning: return
    # Convert markdown first, then combine — avoids double-escaping HTML tags
    html = md_to_html(text.strip()) if text.strip() else ""
    if prev_reasoning:
        reason_html = md_to_html(prev_reasoning.strip())
        html = f"<blockquote>💭 {reason_html}</blockquote>" + ("\n\n" + html if html else "")
    if not html.strip(): return

    if len(html) > 4000:
        html = html[:3900] + "\n\n<i>... [message truncated due to Telegram 4096 limit]</i>"
    try:
        resp = requests.post(tg_url, json={
            "chat_id": chat_id,
            "message_id": message_id,
            "text": html,
            "parse_mode": "HTML"
        }, timeout=5)
        if not resp.ok:
            sys.stderr.write(f"TG edit failed {resp.status_code}: {resp.text[:300]}\n")
    except Exception as e:
        sys.stderr.write(f"TG edit error: {e}\n")

content = ""
thought_active = False
tool_calls = {} # Use dict to accumulate by index
usage = None
last_update = time.time()

# ── Tool progress (openclaw-style) ──
_TOOL_EMOJI = {
    "bash":"🛠️","web_search":"🔍","fetch_url":"🌐","read_file":"📖",
    "write_file":"✍️","edit_code":"📝","search_files":"🔎","todo":"📋",
    "memory":"🧠","memory_remember":"🧠","memory_recall":"🧠",
    "process":"⚙️","browser":"🌍","image_generate":"🎨","patch":"🩹",
    "repo_map":"🗺️","clarify":"💬","session_search":"🗂️","sys_info":"📊",
    "custom_tool_manager":"🔧","skill_manager":"🎯","skill_install":"📦",
    "insights":"📈","recap":"📝","kanban_show":"📌","kanban_create":"📌",
    "kanban_complete":"✅","kanban_block":"🚧",
}

def _tool_progress_block(tc_dict, max_lines=4):
    lines = []
    for idx in sorted(tc_dict.keys()):
        tc = tc_dict[idx]
        name = (tc.get("function", {}).get("name") or "").strip()
        if not name: continue
        emoji = _TOOL_EMOJI.get(name, "🧩")
        label = name.replace("_", " ")
        try:
            args = json.loads(tc.get("function", {}).get("arguments") or "{}")
            detail = next((str(v)[:60].replace(chr(96), chr(39)).strip() for v in args.values() if isinstance(v,str) and str(v).strip()), None)
        except Exception:
            detail = None
        raw = f"{emoji} {label}" + (f": {detail}" if detail else "")
        lines.append(f"`{raw}`")
    return "_Working…_\n" + "\n".join(lines[-max_lines:]) if lines else "_Working…_"

def _build_display(text, tc_dict):
    clean = re.sub(r"<(think|thinking|reasoning|thought|memory-context)>.*?(</\1>|$)", "", text, flags=re.DOTALL|re.IGNORECASE).strip()
    block = _tool_progress_block(tc_dict)
    return (clean + "\n\n" + block) if clean else block

MAX_STREAM_ATTEMPTS = 2
_stream_attempt = 0
_stream_success = False

while _stream_attempt < MAX_STREAM_ATTEMPTS:
    _stream_attempt += 1
    if _stream_attempt > 1:
        time.sleep(2)
        update_tg("⏳ _Reconnecting…_")
        # Reset accumulated state for clean retry
        content = ""
        thought_active = False
        tool_calls = {}
        usage = None
        last_update = time.time()

    try:
      with requests.post(url, json=payload, headers=headers, stream=True, timeout=60) as r:
        if r.status_code not in (200, 206):
            body = r.text[:2000]
            sys.stderr.write(f"API HTTP {r.status_code}: {body}\n")
            if r.status_code in (429, 503):
                continue  # retryable
            sys.exit(1)
        for line in r.iter_lines():
            if not line: continue
            line = line.decode("utf-8")
            if not line.startswith("data: "): continue

            data_str = line[6:]
            if data_str == "[DONE]": break

            try:
                data = json.loads(data_str)
            except Exception:
                continue

            # Check for usage info
            if "usage" in data:
                usage = data["usage"]

            delta = data.get("choices", [{}])[0].get("delta", {})

            if "thought" in delta and delta["thought"]:
                if not thought_active:
                    content += "<think>"
                    thought_active = True
                content += delta["thought"]
                _think_text += delta["thought"]
                _send_or_update_think(_think_text)

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
                        tool_calls[idx] = {"id": "", "type": "function", "function": {"name": "", "arguments": ""}, "thought_signature": ""}

                    if "id" in tc:
                        tool_calls[idx]["id"] += tc["id"]

                    # Capture thought_signature for Google thinking models (Vertex OpenAI-compat)
                    _ts = tc.get("thought_signature") or ""
                    if not _ts:
                        _ts = (tc.get("extra_content") or {}).get("google", {}).get("thought_signature", "")
                    if _ts:
                        tool_calls[idx]["thought_signature"] += _ts

                    if "function" in tc:
                        f = tc["function"]
                        if "name" in f: tool_calls[idx]["function"]["name"] += f["name"]
                        if "arguments" in f: tool_calls[idx]["function"]["arguments"] += f["arguments"]

            if time.time() - last_update > 2.0:
                if tool_calls:
                    display_text = _build_display(content, tool_calls)
                else:
                    display_text = content if content else "⏳"
                update_tg(display_text)
                last_update = time.time()
      _stream_success = True
      break  # stream completed — exit retry loop
    except Exception as e:
        sys.stderr.write(f"Stream attempt {_stream_attempt} error: {e}\n")
        if _stream_attempt >= MAX_STREAM_ATTEMPTS:
            try:
                partial = re.sub(r"<(think|thinking|reasoning|thought|memory-context)>.*?(</\1>|$)", "", content, flags=re.DOTALL|re.IGNORECASE).strip()
                if partial:
                    update_tg(partial + "\n\n⚠️ _Connection dropped. Partial response above._")
                else:
                    update_tg("⚠️ _Connection dropped after 2 attempts. Please /retry._")
            except Exception:
                pass

_typing_stop.set()

# Final update
clean_final = re.sub(r"<(think|thinking|reasoning|thought|memory-context)>.*?(</\1>|$)", "", content, flags=re.DOTALL | re.IGNORECASE)
sys.stderr.write(f"DBG18: content_len={len(content)} clean_final_len={len(clean_final.strip())} msg_id={message_id} chat_id={chat_id}\n")
if tool_calls:
    update_tg(_build_display(clean_final, tool_calls))
elif clean_final.strip():
    update_tg(clean_final)

# Output for bash parsing (TC: list of tool calls)
tc_list = []
for k, v in sorted(tool_calls.items()):
    if not v.get("id"):
        v["id"] = f"call_{int(time.time() * 1000)}"
    tc = {"id": v["id"], "type": v.get("type", "function"), "function": v["function"]}
    if v.get("thought_signature"):
        tc["thought_signature"] = v["thought_signature"]
    tc_list.append(tc)

if _think_msg_id:
    print(f"THINKMSG:{_think_msg_id}")
if _think_text.strip():
    _ts = " ".join(_think_text.split())[:300]
    print("THINK:" + _ts)
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
        [[ -n "$err_out" ]] && echo "DBG_ERR: $err_out"

        # Check for errors in err_out or status
        if [[ $status -ne 0 || "$result" != *"TC:"* ]]; then
             echo "AMA: Stream Error (Status $status). Err: $err_out" >&2

             if [[ "$attempt" -lt "$max_attempts" ]]; then
                 local _is_rate_limit=false
                 if [[ "$err_out" == *"API HTTP 429"* || "$err_out" == *"API HTTP 503"* || "$err_out" == *"RESOURCE_EXHAUSTED"* ]]; then
                     _is_rate_limit=true
                     pool_mark_limited "${_POOL_IDX:-}" 60
                     [[ "${_AMA_NO_RATE_MARK:-0}" != "1" ]] && mark_rate_limited "$PROVIDER" "$MODEL" 60
                 fi
                 if [[ "$(pool_is_enabled)" != "true" && -n "$FALLBACK_MODEL" && "$MODEL" != "$FALLBACK_MODEL" ]]; then
                     echo "AMA: Switching to fallback model $FALLBACK_MODEL" >&2
                     MODEL="$FALLBACK_MODEL"
                 fi
                 local delay
                 if [[ "$_is_rate_limit" == "true" && "$(pool_is_enabled)" != "true" ]]; then
                     # Wait until actual rate limit expires — rapid retries just re-extend it
                     delay=$(python3 -c "
import json, time
try:
    d = json.load(open('brain/state/rate_limits.json'))
    until = float(d.get('${PROVIDER}_${MODEL}', 0))
    print(max(15, int(until - time.time()) + 5))
except: print(60)
" 2>/dev/null || echo 60)
                     echo "AMA: Rate-limited, waiting ${delay}s for quota reset (attempt $attempt/$max_attempts)..." >&2
                 else
                     delay=$(python3 -c "import random; a=$attempt; d=min(5.0*(2**(a-1)),60.0); print(f'{d+random.uniform(0,0.5*d):.1f}')" 2>/dev/null || echo $((5 * attempt)))
                     echo "AMA: Stream error, retrying in ${delay}s (attempt $attempt/$max_attempts)..." >&2
                 fi
                 sleep "$delay"
                 attempt=$((attempt + 1))
                 continue
             fi
        fi

        echo "$result"
        return 0
    done
}
