#!/bin/bash
# tools/fetch_url.sh - Fetch and extract web page content with SSRF protection
# Backends: Jina Reader (default) → direct httpx fallback
# Learned from hermes-agent: SSRF guard + LLM summarization to reduce context bloat

url="${TOOL_url}"
extract_query="${TOOL_query:-}"      # Optional: what to extract/focus on
max_chars="${TOOL_max_chars:-8000}"  # Max chars before LLM compression kicks in

if [[ -z "$url" ]]; then
    echo "Error: url is required"
    exit 1
fi

TOOL_url="$url" TOOL_query="$extract_query" TOOL_max_chars="$max_chars" python3 - <<'PYEOF'
import os, sys, re, ipaddress, socket, subprocess
from urllib.parse import urlparse
import requests

url = os.environ.get("TOOL_url", "").strip()
extract_query = os.environ.get("TOOL_query", "").strip()
max_chars = int(os.environ.get("TOOL_max_chars", "8000"))
script_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ── SSRF guard (hermes url_safety pattern) ─────────────────────────────────
_ALWAYS_BLOCK_HOSTS = {"metadata.google.internal", "metadata.goog"}
_ALWAYS_BLOCK_IPS = {
    ipaddress.ip_address("169.254.169.254"),
    ipaddress.ip_address("169.254.170.2"),
    ipaddress.ip_address("100.100.100.200"),
}
_BLOCK_NETS = [
    ipaddress.ip_network("169.254.0.0/16"),
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("127.0.0.0/8"),
]

def is_safe_url(url: str) -> tuple[bool, str]:
    try:
        p = urlparse(url)
        if p.scheme not in ("http", "https"):
            return False, f"scheme '{p.scheme}' not allowed"
        host = (p.hostname or "").lower().rstrip(".")
        if not host:
            return False, "empty hostname"
        if host in _ALWAYS_BLOCK_HOSTS:
            return False, f"blocked hostname: {host}"
        try:
            ip = ipaddress.ip_address(host)
        except ValueError:
            try:
                ip = ipaddress.ip_address(socket.gethostbyname(host))
            except Exception:
                return True, ""  # can't resolve — allow
        if ip in _ALWAYS_BLOCK_IPS:
            return False, f"blocked cloud metadata IP: {ip}"
        for net in _BLOCK_NETS:
            if ip in net:
                return False, f"private/internal IP blocked (SSRF): {ip}"
        return True, ""
    except Exception as e:
        return False, str(e)

safe, reason = is_safe_url(url)
if not safe:
    print(f"Error: URL blocked for security reasons — {reason}")
    sys.exit(1)

# ── Fetch via Jina Reader (primary — returns clean markdown) ───────────────
content = None
try:
    r = requests.get(f"https://r.jina.ai/{url}",
        headers={"Accept": "text/plain", "User-Agent": "AMA-Agent/1.0"},
        timeout=25)
    if r.status_code == 200 and len(r.text.strip()) > 100:
        content = r.text
except Exception as e:
    sys.stderr.write(f"[fetch_url] Jina failed: {e}\n")

# ── Fallback: direct fetch + basic HTML strip ──────────────────────────────
if not content:
    try:
        r = requests.get(url,
            headers={"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/121.0.0.0 Safari/537.36"},
            timeout=20, allow_redirects=True)
        raw = r.text
        # Strip scripts, styles, tags
        raw = re.sub(r"<(script|style)[^>]*>.*?</\1>", "", raw, flags=re.DOTALL | re.IGNORECASE)
        raw = re.sub(r"<[^>]+>", " ", raw)
        raw = re.sub(r"[ \t]{2,}", " ", raw)
        raw = re.sub(r"\n{3,}", "\n\n", raw)
        content = raw.strip()
    except Exception as e:
        print(f"Error fetching URL: {e}")
        sys.exit(1)

if not content or len(content.strip()) < 50:
    print("Error: No useful content found at the URL.")
    sys.exit(1)

# ── Truncate or LLM-compress (hermes strategy) ─────────────────────────────
total_len = len(content)

if total_len <= max_chars:
    # Short enough — output directly
    print(f"[Fetched {url} — {total_len} chars]\n")
    print(content)
    sys.exit(0)

# Smart truncation: center around query term matches (hermes pattern)
if extract_query:
    terms = [t.lower() for t in extract_query.split() if t.strip()]
    text_lower = content.lower()
    positions = []
    for t in terms:
        for m in re.finditer(re.escape(t), text_lower):
            positions.append(m.start())

    if positions:
        positions.sort()
        best_start, best_count = 0, 0
        for pos in positions:
            ws = max(0, pos - max_chars // 3)
            we = ws + max_chars
            if we > len(content):
                ws = max(0, len(content) - max_chars)
            count = sum(1 for p in positions if ws <= p < ws + max_chars)
            if count > best_count:
                best_count, best_start = count, ws
        start = best_start
        end = min(len(content), start + max_chars)
        prefix = "...[earlier content truncated]...\n\n" if start > 0 else ""
        suffix = "\n\n...[remaining content truncated]..." if end < len(content) else ""
        truncated = prefix + content[start:end] + suffix
    else:
        truncated = content[:max_chars] + f"\n\n...[{total_len - max_chars} chars truncated]..."
else:
    truncated = content[:max_chars] + f"\n\n...[{total_len - max_chars} chars truncated]..."

# ── Optionally summarize with LLM if query is provided ────────────────────
if extract_query and len(truncated) > 2000:
    try:
        summary_prompt = f"""Extract the information relevant to the following query from this web page content.
Query: {extract_query}
URL: {url}

Return ONLY the relevant excerpts and a brief summary. Preserve URLs, code snippets, and specific technical details.
If the content does not contain relevant information for the query, say so briefly.

WEB CONTENT:
{truncated}"""

        result = subprocess.run(
            ["bash", "-c", f"""
cd '{script_dir}'
source core/mix/init.sh 2>/dev/null
HISTORY=$(python3 -c "import json,sys; print(json.dumps([{{\"role\":\"user\",\"content\":sys.argv[1]}}]))" "$@" 2>/dev/null)
export HISTORY
call_api "You are a web content extractor. Return only relevant excerpts and a brief summary. Be concise." 2>/dev/null | python3 -c "
import sys,json
try:
    r=json.load(sys.stdin)
    t=r.get('choices',[{{}}])[0].get('message',{{}}).get('content','')
    if not t:
        t=r.get('candidates',[{{}}])[0].get('content',{{}}).get('parts',[{{}}])[0].get('text','')
    print(t.strip(),end='')
except: pass
"
"""],
            input=summary_prompt,
            capture_output=True, text=True, timeout=30, stdin=subprocess.PIPE,
            env=dict(os.environ)
        )
        summary = result.stdout.strip()
        if summary:
            print(f"[Fetched {url} — {total_len} chars, LLM-extracted for: '{extract_query}']\n")
            print(summary)
            sys.exit(0)
    except Exception:
        pass  # Fall through to plain truncated output

print(f"[Fetched {url} — {total_len} chars, truncated to {max_chars}]\n")
print(truncated)
PYEOF
