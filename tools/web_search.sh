#!/bin/bash
# tools/web_search.sh - Multi-backend web search with auto-detection
# Backends (priority): Tavily → Exa → Brave → SearXNG → DuckDuckGo (DDGS)

query="${TOOL_query}"
limit="${TOOL_limit:-8}"

if [[ -z "$query" ]]; then
    echo "Error: query is required"
    exit 1
fi

TOOL_query="$query" TOOL_limit="$limit" python3 - <<'PYEOF'
import os, sys, json, re, ipaddress, socket
from urllib.parse import urlparse, quote_plus

query = os.environ.get("TOOL_query", "")
limit = int(os.environ.get("TOOL_limit", "8"))
limit = max(1, min(limit, 15))

# ── SSRF guard (hermes url_safety pattern) ─────────────────────────────────
_ALWAYS_BLOCK_HOSTS = {"metadata.google.internal", "metadata.goog"}
_ALWAYS_BLOCK_IPS = {
    ipaddress.ip_address("169.254.169.254"),
    ipaddress.ip_address("169.254.170.2"),
    ipaddress.ip_address("100.100.100.200"),
}
_ALWAYS_BLOCK_NETS = [ipaddress.ip_network("169.254.0.0/16")]
_PRIVATE_NETS = [
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("::1/128"),
    ipaddress.ip_network("fc00::/7"),
]

def is_safe_url(url: str) -> bool:
    try:
        p = urlparse(url)
        if p.scheme not in ("http", "https"):
            return False
        host = (p.hostname or "").lower().rstrip(".")
        if not host:
            return False
        if host in _ALWAYS_BLOCK_HOSTS:
            return False
        try:
            ip = ipaddress.ip_address(host)
        except ValueError:
            try:
                ip = ipaddress.ip_address(socket.gethostbyname(host))
            except Exception:
                return True  # Can't resolve, allow (fail-open for search results)
        if ip in _ALWAYS_BLOCK_IPS:
            return False
        for net in _ALWAYS_BLOCK_NETS + _PRIVATE_NETS:
            if ip in net:
                return False
        return True
    except Exception:
        return True  # Parse failure: allow (search URLs are generally safe)

def safe_results(results):
    return [r for r in results if is_safe_url(r.get("url", r.get("href", "")))]

# ── Backend: Tavily ────────────────────────────────────────────────────────
def search_tavily(query, limit):
    import requests
    key = os.environ.get("TAVILY_API_KEY", "").strip()
    r = requests.post("https://api.tavily.com/search",
        json={"api_key": key, "query": query, "max_results": limit, "search_depth": "basic"},
        timeout=15)
    r.raise_for_status()
    data = r.json()
    out = []
    for item in data.get("results", [])[:limit]:
        out.append({"title": item.get("title",""), "url": item.get("url",""), "snippet": item.get("content","")[:300]})
    return out

# ── Backend: Exa ───────────────────────────────────────────────────────────
def search_exa(query, limit):
    import requests
    key = os.environ.get("EXA_API_KEY", "").strip()
    r = requests.post("https://api.exa.ai/search",
        headers={"x-api-key": key, "Content-Type": "application/json"},
        json={"query": query, "numResults": limit, "useAutoprompt": True},
        timeout=15)
    r.raise_for_status()
    data = r.json()
    out = []
    for item in data.get("results", [])[:limit]:
        out.append({"title": item.get("title",""), "url": item.get("url",""), "snippet": item.get("highlight","")[:300]})
    return out

# ── Backend: Brave ─────────────────────────────────────────────────────────
def search_brave(query, limit):
    import requests
    key = os.environ.get("BRAVE_SEARCH_API_KEY", "").strip()
    r = requests.get("https://api.search.brave.com/res/v1/web/search",
        headers={"Accept": "application/json", "Accept-Encoding": "gzip", "X-Subscription-Token": key},
        params={"q": query, "count": min(limit, 20)},
        timeout=15)
    r.raise_for_status()
    data = r.json()
    out = []
    for item in data.get("web", {}).get("results", [])[:limit]:
        out.append({"title": item.get("title",""), "url": item.get("url",""), "snippet": item.get("description","")[:300]})
    return out

# ── Backend: SearXNG ───────────────────────────────────────────────────────
def search_searxng(query, limit):
    import requests
    base = os.environ.get("SEARXNG_URL", "").strip().rstrip("/")
    r = requests.get(f"{base}/search",
        params={"q": query, "format": "json", "engines": "google,bing,duckduckgo"},
        timeout=15)
    r.raise_for_status()
    data = r.json()
    out = []
    for item in data.get("results", [])[:limit]:
        out.append({"title": item.get("title",""), "url": item.get("url",""), "snippet": item.get("content","")[:300]})
    return out

# ── Backend: DuckDuckGo (ddgs package) ────────────────────────────────────
def search_ddgs(query, limit):
    from ddgs import DDGS
    out = []
    with DDGS() as ddgs:
        for r in ddgs.text(query, max_results=limit):
            out.append({"title": r.get("title",""), "url": r.get("href",""), "snippet": r.get("body","")[:300]})
    return out

# ── Backend: DDG HTML fallback (no deps) ──────────────────────────────────
def search_ddg_html(query, limit):
    import requests, html as html_mod
    UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/121.0.0.0 Safari/537.36"
    r = requests.get(f"https://html.duckduckgo.com/html/?q={quote_plus(query)}",
        headers={"User-Agent": UA}, timeout=15)
    items = re.findall(r'<a class="result__a" href="([^"]+)">(.*?)</a>', r.text)
    out = []
    for link, title in items[:limit]:
        if "uddg=" in link:
            m = re.search(r"uddg=([^&]+)", link)
            if m:
                from urllib.parse import unquote
                link = unquote(m.group(1))
        if link.startswith("//"):
            link = "https:" + link
        clean_title = html_mod.unescape(re.sub(r"<[^>]+>", "", title))
        out.append({"title": clean_title, "url": link, "snippet": ""})
    return out

# ── Auto-detect backend ────────────────────────────────────────────────────
def get_backend():
    if os.environ.get("TAVILY_API_KEY","").strip(): return "tavily"
    if os.environ.get("EXA_API_KEY","").strip(): return "exa"
    if os.environ.get("BRAVE_SEARCH_API_KEY","").strip(): return "brave"
    if os.environ.get("SEARXNG_URL","").strip(): return "searxng"
    try:
        from ddgs import DDGS  # noqa
        return "ddgs"
    except ImportError:
        return "ddg_html"

backend = os.environ.get("WEB_SEARCH_BACKEND", "").strip().lower() or get_backend()

BACKENDS = {
    "tavily": search_tavily,
    "exa": search_exa,
    "brave": search_brave,
    "searxng": search_searxng,
    "ddgs": search_ddgs,
    "ddg_html": search_ddg_html,
}

# ── Run search with fallback chain ─────────────────────────────────────────
results = []
tried = []
order = [backend] + [b for b in ["ddgs", "ddg_html", "tavily"] if b != backend]
for b in order:
    if b not in BACKENDS:
        continue
    tried.append(b)
    try:
        results = BACKENDS[b](query, limit)
        results = safe_results(results)
        if results:
            break
    except Exception as e:
        sys.stderr.write(f"[web_search] {b} failed: {e}\n")
        continue

# ── Format output ──────────────────────────────────────────────────────────
if not results:
    print(f"No results found for: {query}")
    sys.exit(0)

print(f"Web search: '{query}' — {len(results)} results (via {tried[-1] if results else 'none'})\n")
for i, r in enumerate(results, 1):
    title = r.get("title", "").strip()
    url = r.get("url", r.get("href", "")).strip()
    snippet = r.get("snippet", r.get("body", "")).strip()
    print(f"{i}. {title}")
    print(f"   {url}")
    if snippet:
        print(f"   {snippet[:250]}")
    print()
PYEOF
