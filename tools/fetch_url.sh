#!/bin/bash
# tools/fetch_url.sh - Extract content from a URL using Jina Reader (Minimalist)

url="${TOOL_url}"

if [[ -z "$url" ]]; then
    echo "Error: url is required"
    exit 1
fi

# We use r.jina.ai which is a free service that converts any URL to clean Markdown
# This is perfect for LLM research.

curl -s -L "https://r.jina.ai/${url}" | head -c 10000
echo -e "\n\n[Content truncated to 10k characters]"
