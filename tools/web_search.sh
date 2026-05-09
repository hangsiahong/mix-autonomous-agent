#!/bin/bash
# tools/web_search.sh - Search the web using DuckDuckGo (Minimalist)

query="${TOOL_query}"

if [[ -z "$query" ]]; then
    echo "Error: query is required"
    exit 1
fi

# Use DuckDuckGo HTML version
# We use a simple curl and grep/sed to extract results
# This is a bit brittle but minimalist. 
# For production, use Serper/Tavily/Google Search API.

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36"

html=$(curl -s -L -A "$UA" "https://html.duckduckgo.com/html/?q=$(printf '%s' "$query" | jq -sRr @uri)")

# Extract titles and links
# The HTML structure is roughly: <a class="result__a" href="...">Title</a>
echo "$html" | python3 -c '
import sys
import html
import re

content = sys.stdin.read()
results = re.findall(r"<a class=\"result__a\" href=\"(.*?)\">(.*?)</a>", content)

for i, (link, title) in enumerate(results[:10]):
    # Clean up the link (DDG uses proxy links sometimes)
    if link.startswith("//"): link = "https:" + link
    if "uddg=" in link:
        link = re.search(r"uddg=(.*?)($|&)", link).group(1)
        import urllib.parse
        link = urllib.parse.unquote(link)
    
    clean_title = re.sub(r"<.*?>", "", title)
    print(f"{i+1}. {html.unescape(clean_title)}")
    print(f"   URL: {link}")
    print("-" * 20)
'
