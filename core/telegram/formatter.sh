#!/bin/bash
# core/telegram/formatter.sh - Text processing

# Escape for MarkdownV2
tg_escape() {
    echo "$1" | sed 's/\([_*[]()~`>#+\-=|{}.!]\)/\\\1/g'
}

# Convert Markdown to Telegram HTML (openclaw-style)
# Handles: **bold**, _italic_, `code`, ```blocks```, ~~strike~~, [links](url), # headings
md_to_tg_html() {
    printf '%s' "$1" | python3 -c '
import sys, re

def md_to_html(text):
    result = []
    # Split on fenced/inline code to avoid formatting inside code
    parts = re.split(r"(```[\w]*\n?[\s\S]*?```|`[^`\n]+`)", text)
    for i, part in enumerate(parts):
        if i % 2 == 1:
            if part.startswith("```"):
                code = re.sub(r"^```\w*\n?", "", part)
                code = re.sub(r"\n?```$", "", code)
                code = code.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;")
                result.append(f"<pre><code>{code}</code></pre>")
            else:
                code = part[1:-1]
                code = code.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;")
                result.append(f"<code>{code}</code>")
        else:
            p = part.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;")
            p = re.sub(r"^#{1,6} +(.+)$", r"<b>\1</b>", p, flags=re.MULTILINE)
            p = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", p, flags=re.DOTALL)
            p = re.sub(r"__(.+?)__", r"<b>\1</b>", p, flags=re.DOTALL)
            p = re.sub(r"(?<!\*)\*(?!\*)(.+?)(?<!\s)\*(?!\*)", r"<i>\1</i>", p)
            p = re.sub(r"_([^_\n]+?)_", r"<i>\1</i>", p)
            p = re.sub(r"~~(.+?)~~", r"<s>\1</s>", p)
            p = re.sub(r"\[([^\]]+)\]\((https?://[^)]+)\)", r"<a href=\"\2\">\1</a>", p)
            result.append(p)
    
    html = "".join(result)
    
    def format_think(match):
        content = match.group(2)
        if len(content) > 1000:
            content = content[:500] + "\n\n<i>... [thinking truncated] ...</i>\n\n" + content[-500:]
        return f"<blockquote><b>🧠 Thinking</b>\n<i>{content.strip()}</i></blockquote>\n"
        
    html = re.sub(r"&lt;(think|thinking|reasoning|thought)&gt;(.*?)(&lt;/\1&gt;|$)", format_think, html, flags=re.DOTALL|re.IGNORECASE)
    return html

print(md_to_html(sys.stdin.read()), end="")
'
}
