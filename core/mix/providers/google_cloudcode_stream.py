#!/usr/bin/env python3
"""
Google Code Assist streaming adapter for AMA.

Reads an OpenAI-format payload JSON from stdin, translates it to Gemini/Code
Assist format, streams from cloudcode-pa.googleapis.com, and outputs:
  TC:<json list of tool calls>
  TEXT:<response text>
  USAGE:<json usage dict>   (optional)

Env vars required:
  CODE_ASSIST_TOKEN   - OAuth Bearer token (from tools/google_oauth.py token)
  CODE_ASSIST_PROJECT - GCP project_id (can be empty for free tier auto-assign)
  TG_TOKEN / CHAT_ID / MESSAGE_ID - for live Telegram updates
"""
import json, os, re, sys, time, uuid

try:
    import requests
except ImportError:
    sys.stderr.write("requests not available\n")
    sys.exit(1)

CODE_ASSIST_ENDPOINT = "https://cloudcode-pa.googleapis.com"

access_token = os.environ.get("CODE_ASSIST_TOKEN", "")
project_id   = os.environ.get("CODE_ASSIST_PROJECT", "")
model_env    = os.environ.get("CODE_ASSIST_MODEL", "gemini-2.5-flash")
tg_token     = os.environ.get("TG_TOKEN", "")
chat_id      = os.environ.get("CHAT_ID", "")
message_id   = os.environ.get("MESSAGE_ID", "")

if not access_token:
    sys.stderr.write("CODE_ASSIST_TOKEN not set\n")
    sys.exit(1)

payload = json.loads(sys.stdin.read())
model = payload.get("model") or model_env


# ─── OpenAI → Gemini message translation ─────────────────────────────────────

def _coerce_text(content):
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(
            p.get("text", "") for p in content
            if isinstance(p, dict) and p.get("type") == "text"
        )
    return str(content)


def _translate_messages(messages):
    contents = []
    system_parts = []

    for msg in messages:
        role    = msg.get("role", "")
        content = msg.get("content")

        if role == "system":
            system_parts.append({"text": _coerce_text(content)})
            continue

        if role == "tool":
            name   = str(msg.get("name") or msg.get("tool_call_id") or "tool")
            raw    = _coerce_text(content)
            try:
                result = json.loads(raw) if raw else {}
                if not isinstance(result, dict):
                    result = {"output": str(result)}
            except Exception:
                result = {"output": raw}
            part = {"functionResponse": {"name": name, "response": result}}
            if contents and contents[-1].get("role") == "user":
                contents[-1]["parts"].append(part)
            else:
                contents.append({"role": "user", "parts": [part]})
            continue

        gemini_role = "model" if role == "assistant" else "user"
        parts = []

        text = _coerce_text(content)
        if text:
            parts.append({"text": text})

        for tc in (msg.get("tool_calls") or []):
            fn      = tc.get("function") or {}
            name    = fn.get("name", "")
            raw_arg = fn.get("arguments", "{}")
            try:
                args = json.loads(raw_arg) if isinstance(raw_arg, str) else raw_arg
                if not isinstance(args, dict):
                    args = {"_value": args}
            except Exception:
                args = {"_raw": str(raw_arg)}
            tsig = tc.get("thought_signature", "") or "skip_thought_signature_validator"
            parts.append({
                "functionCall":    {"name": name, "args": args},
                "thoughtSignature": tsig,
            })

        if parts:
            if contents and contents[-1].get("role") == gemini_role:
                contents[-1]["parts"].extend(parts)
            else:
                contents.append({"role": gemini_role, "parts": parts})

    system_instruction = {"parts": system_parts} if system_parts else None
    return contents, system_instruction


def _translate_tools(tools):
    if not tools:
        return []
    decls = []
    for t in (tools or []):
        if t.get("type") != "function":
            continue
        fn = t.get("function", {})
        d  = {"name": fn.get("name", ""), "description": fn.get("description", "")}
        p  = fn.get("parameters")
        if p:
            d["parameters"] = p
        decls.append(d)
    return [{"functionDeclarations": decls}] if decls else []


# ─── Build request ────────────────────────────────────────────────────────────

contents, system_instruction = _translate_messages(payload.get("messages", []))
gemini_tools = _translate_tools(payload.get("tools"))

inner: dict = {"contents": contents}
if system_instruction:
    inner["systemInstruction"] = system_instruction
if gemini_tools:
    inner["tools"] = gemini_tools

gen_cfg: dict = {}
temp = payload.get("temperature")
if temp is not None:
    gen_cfg["temperature"] = float(temp)
max_tok = payload.get("max_tokens") or payload.get("max_completion_tokens")
if max_tok:
    gen_cfg["maxOutputTokens"] = int(max_tok)
if gen_cfg:
    inner["generationConfig"] = gen_cfg

wrapped = {
    "project":        project_id,
    "model":          model,
    "user_prompt_id": str(uuid.uuid4()),
    "request":        inner,
}


# ─── Telegram live updates ───────────────────────────────────────────────────

_tg_url      = f"https://api.telegram.org/bot{tg_token}/editMessageText"
_last_update = [time.time()]
_last_sent   = [""]


def _scrub_think(text):
    return re.sub(r"<(think|thinking|thought)>.*?(</\1>|$)", "", text,
                  flags=re.DOTALL | re.IGNORECASE).strip()


def _md_to_html(text):
    result = []
    for i, part in enumerate(re.split(r"(```[\w]*\n?[\s\S]*?```|`[^`\n]+`)", text)):
        if i % 2 == 1:
            if part.startswith("```"):
                code = re.sub(r"^```\w*\n?", "", part)
                code = re.sub(r"\n?```$", "", code)
                code = code.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
                result.append(f"<pre><code>{code}</code></pre>")
            else:
                code = part[1:-1].replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
                result.append(f"<code>{code}</code>")
        else:
            p = part.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            p = re.sub(r"^#{1,6} +(.+)$", r"<b>\1</b>", p, flags=re.MULTILINE)
            p = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", p, flags=re.DOTALL)
            p = re.sub(r"(?<!\*)\*(?!\*)(.+?)(?<!\s)\*(?!\*)", r"<i>\1</i>", p)
            result.append(p)
    return "".join(result)


def update_tg(text: str, *, force: bool = False):
    if not (tg_token and chat_id and message_id):
        return
    now = time.time()
    if not force and now - _last_update[0] < 1.5:
        return
    clean = _scrub_think(text)
    if not clean or clean == _last_sent[0]:
        return
    _last_update[0] = now
    _last_sent[0] = clean
    try:
        requests.post(_tg_url, json={
            "chat_id":    chat_id,
            "message_id": message_id,
            "text":       _md_to_html(clean),
            "parse_mode": "HTML",
        }, timeout=5)
    except Exception:
        pass


# ─── Streaming call ──────────────────────────────────────────────────────────

headers = {
    "Content-Type":          "application/json",
    "Accept":                "text/event-stream",
    "Authorization":         f"Bearer {access_token}",
    "User-Agent":            "google-api-nodejs-client/9.15.1 (gzip)",
    "X-Goog-Api-Client":     "gl-node/24.0.0",
    "x-activity-request-id": str(uuid.uuid4()),
}

url          = f"{CODE_ASSIST_ENDPOINT}/v1internal:streamGenerateContent?alt=sse"
MAX_ATTEMPTS = 3

content       = ""
tool_calls: dict = {}
usage         = None
thought_active = False

for attempt in range(1, MAX_ATTEMPTS + 1):
    content        = ""
    tool_calls     = {}
    usage          = None
    thought_active = False
    tc_idx         = [0]

    try:
        with requests.post(url, json=wrapped, headers=headers, stream=True, timeout=600) as r:
            if r.status_code not in (200, 206):
                body = r.text[:2000]
                sys.stderr.write(f"API HTTP {r.status_code}: {body}\n")
                if r.status_code in (429, 503) and attempt < MAX_ATTEMPTS:
                    time.sleep(2 ** attempt)
                    continue
                sys.exit(1)

            for raw_line in r.iter_lines():
                if not raw_line:
                    continue
                line = raw_line.decode("utf-8") if isinstance(raw_line, bytes) else raw_line
                if not line.startswith("data: "):
                    continue
                data_str = line[6:]
                if data_str == "[DONE]":
                    break
                try:
                    event = json.loads(data_str)
                except Exception:
                    continue

                # Unwrap Code Assist envelope: {response: <gemini-response>}
                inner_r = event.get("response") if isinstance(event.get("response"), dict) else event

                # Usage
                um = inner_r.get("usageMetadata")
                if isinstance(um, dict):
                    usage = {
                        "prompt_tokens":     um.get("promptTokenCount", 0),
                        "completion_tokens": um.get("candidatesTokenCount", 0),
                        "total_tokens":      um.get("totalTokenCount", 0),
                    }

                for cand in (inner_r.get("candidates") or []):
                    parts = (cand.get("content") or {}).get("parts") or []
                    for part in parts:
                        if not isinstance(part, dict):
                            continue

                        # Thought (reasoning) part
                        if part.get("thought") is True:
                            piece = part.get("text", "")
                            if piece:
                                if not thought_active:
                                    content += "<think>"
                                    thought_active = True
                                content += piece
                            continue

                        # Text part
                        piece = part.get("text")
                        if piece:
                            if thought_active:
                                content += "</think>"
                                thought_active = False
                            content += piece
                            update_tg(content)
                            continue

                        # Function call part
                        fc = part.get("functionCall")
                        if isinstance(fc, dict) and fc.get("name"):
                            if thought_active:
                                content += "</think>"
                                thought_active = False
                            idx  = tc_idx[0]; tc_idx[0] += 1
                            name = fc["name"]
                            args = fc.get("args") or {}
                            try:
                                args_str = json.dumps(args, ensure_ascii=False)
                            except Exception:
                                args_str = "{}"
                            tool_calls[idx] = {
                                "id":   f"call_{name}_{idx}_{int(time.time()*1000)}",
                                "type": "function",
                                "function": {"name": name, "arguments": args_str},
                                "thought_signature": part.get("thoughtSignature", ""),
                            }

    except Exception as exc:
        sys.stderr.write(f"Stream attempt {attempt} error: {exc}\n")
        if attempt < MAX_ATTEMPTS:
            time.sleep(2 ** attempt)
            continue
        sys.exit(1)

    break  # success

if thought_active:
    content += "</think>"

update_tg(content or "(tool calls)", force=True)

# ─── Output ──────────────────────────────────────────────────────────────────

tc_list = []
for k, v in sorted(tool_calls.items()):
    tc: dict = {"id": v["id"], "type": "function", "function": v["function"]}
    if v.get("thought_signature"):
        tc["thought_signature"] = v["thought_signature"]
    tc_list.append(tc)

print(f"TC:{json.dumps(tc_list)}")
print(f"TEXT:{content}")
if usage:
    print(f"USAGE:{json.dumps(usage)}")
