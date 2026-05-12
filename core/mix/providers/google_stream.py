import json, sys, time, os, requests, re, threading

def md_to_html(text):
    if not text: return ""
    result = []
    # Simplified markdown to HTML for Telegram
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
            # Python regex for italic *text* (non-greedy, no nested stars)
            p = re.sub(r"(?<!\*)\*(?!\*)(.+?)(?<!\s)\*(?!\*)", r"<i>\1</i>", p)
            p = re.sub(r"_([^_\n]+?)_", r"<i>\1</i>", p)
            p = re.sub(r"~~(.+?)~~", r"<s>\1</s>", p)
            href_repl = "<a href=\"" + "\\2" + "\">" + "\\1" + "</a>"
            p = re.sub(r"\[([^\]]+)\]\((https?://[^)]+)\)", href_repl, p)
            result.append(p)
    return "".join(result)

def update_tg(tg_url, chat_id, message_id, text):
    if not text: return
    # Scrub thinking blocks from Telegram output
    clean_text = re.sub(r"<(think|thinking|reasoning|thought|memory-context)>.*?(</\1>|$)", "", text, flags=re.DOTALL | re.IGNORECASE)
    if not clean_text.strip(): return
    html = md_to_html(clean_text.strip())
    try:
        resp = requests.post(tg_url, json={
            "chat_id": chat_id,
            "message_id": int(message_id) if message_id else message_id,
            "text": html,
            "parse_mode": "HTML"
        }, timeout=5)
        if not resp.ok:
            sys.stderr.write(f"TG edit failed {resp.status_code}: {resp.text[:200]}\n")
    except Exception as e:
        sys.stderr.write(f"TG edit error: {e}\n")

def main():
    tg_token = os.environ.get("TG_TOKEN")
    chat_id = os.environ.get("CHAT_ID")
    message_id = os.environ.get("MESSAGE_ID")
    url = os.environ.get("GOOGLE_STREAM_URL")
    api_key = os.environ.get("API_KEY")
    mode = os.environ.get("GOOGLE_MODE", "studio")

    # Native Gemini Streaming URL modification
    if ":generateContent" in url:
        url = url.replace(":generateContent", ":streamGenerateContent")
    
    if mode == "studio" and "alt=sse" not in url:
        url += "&alt=sse"

    try:
        payload_data = sys.stdin.read()
        payload = json.loads(payload_data)
    except Exception as e:
        sys.stderr.write(f"Payload error: {e}\n")
        sys.exit(1)

    headers = {"Content-Type": "application/json"}
    if mode == "vertex":
        headers["Authorization"] = f"Bearer {api_key}"

    tg_url = f"https://api.telegram.org/bot{tg_token}/editMessageText"
    tg_action_url = f"https://api.telegram.org/bot{tg_token}/sendChatAction"

    _typing_stop = threading.Event()
    def _typing_loop():
        while not _typing_stop.wait(4):
            try: requests.post(tg_action_url, json={"chat_id": chat_id, "action": "typing"}, timeout=3)
            except: pass
    
    threading.Thread(target=_typing_loop, daemon=True).start()

    full_text = ""
    tool_calls = []
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

    def _tool_progress_block(tc_list, max_lines=4):
        lines = []
        for tc in tc_list:
            name = (tc.get("function", {}).get("name") or "").strip()
            if not name: continue
            emoji = _TOOL_EMOJI.get(name, "🧩")
            label = name.replace("_", " ")
            try:
                args = json.loads(tc.get("function", {}).get("arguments") or "{}")
                detail = next((str(v)[:60].replace("`","'").strip() for v in args.values() if isinstance(v,str) and str(v).strip()), None)
            except Exception:
                detail = None
            raw = f"{emoji} {label}" + (f": {detail}" if detail else "")
            lines.append(f"`{raw}`")
        return "_Working…_\n" + "\n".join(lines[-max_lines:]) if lines else "_Working…_"

    def _build_display(text, tc_list):
        block = _tool_progress_block(tc_list)
        return (text.strip() + "\n\n" + block) if text.strip() else block

    MAX_STREAM_ATTEMPTS = 2
    for _attempt in range(1, MAX_STREAM_ATTEMPTS + 1):
        if _attempt > 1:
            time.sleep(2)
            update_tg(tg_url, chat_id, message_id, "⏳ _Reconnecting…_")
            full_text = ""
            tool_calls = []
            usage = None
            last_update = time.time()
        try:
            with requests.post(url, json=payload, headers=headers, stream=True, timeout=60) as r:
                if r.status_code != 200:
                    sys.stderr.write(f"API Error {r.status_code}: {r.text[:500]}\n")
                    if r.status_code in (429, 503) and _attempt < MAX_STREAM_ATTEMPTS:
                        continue
                    sys.exit(1)

                for line in r.iter_lines():
                    if not line: continue
                    line = line.decode("utf-8")
                    if not line.startswith("data: "): continue

                    try:
                        chunk = json.loads(line[6:])
                    except: continue

                    candidate = (chunk.get("candidates") or [{}])[0]
                    content = candidate.get("content", {})
                    parts = content.get("parts", [])

                    for p in parts:
                        if "text" in p and not p.get("thought"):
                            full_text += p["text"]
                        if "functionCall" in p:
                            fc = p["functionCall"]
                            sig = p.get("thoughtSignature", "")
                            tc_entry = {
                                "id": f"call_{int(time.time()*1000)}_{len(tool_calls)}",
                                "type": "function",
                                "function": {
                                    "name": fc.get("name"),
                                    "arguments": json.dumps(fc.get("args", {}))
                                }
                            }
                            if sig:
                                tc_entry["thought_signature"] = sig
                            tool_calls.append(tc_entry)

                    if "usageMetadata" in chunk:
                        usage = chunk["usageMetadata"]

                    if time.time() - last_update > 2.0:
                        display = _build_display(full_text, tool_calls) if tool_calls else (full_text or "⏳")
                        update_tg(tg_url, chat_id, message_id, display)
                        last_update = time.time()
            break  # stream succeeded
        except Exception as e:
            sys.stderr.write(f"Stream attempt {_attempt} error: {e}\n")
            if _attempt >= MAX_STREAM_ATTEMPTS:
                try:
                    if full_text.strip():
                        update_tg(tg_url, chat_id, message_id,
                                  full_text + "\n\n⚠️ _Connection dropped. Partial response above._")
                    else:
                        update_tg(tg_url, chat_id, message_id,
                                  "⚠️ _Connection dropped after 2 attempts. Please /retry._")
                except Exception:
                    pass

    _typing_stop.set()

    # Final Telegram update
    sys.stderr.write(f"DBG: full_text_len={len(full_text)} msg_id={message_id} chat_id={chat_id}\n")
    if tool_calls:
        update_tg(tg_url, chat_id, message_id, _build_display(full_text, tool_calls))
    elif full_text:
        update_tg(tg_url, chat_id, message_id, full_text)

    # Final logic
    print(f"TC:{json.dumps(tool_calls)}")
    print(f"TEXT:{full_text}")
    if usage:
        u = {
            "prompt_tokens": usage.get("promptTokenCount", 0),
            "completion_tokens": usage.get("candidatesTokenCount", 0),
            "total_tokens": usage.get("totalTokenCount", 0)
        }
        print(f"USAGE:{json.dumps(u)}")

if __name__ == "__main__":
    main()
