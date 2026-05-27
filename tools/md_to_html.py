#!/usr/bin/env python3
"""md_to_html.py — single source of truth for Markdown→Telegram-HTML rendering.

Used by:
- core/telegram/formatter.sh (md_to_tg_html shell wrapper)
- core/mix/18_streaming_api_call.sh (inline streaming display)
- core/mix/providers/google_stream.py (Vertex native streaming display)

Why a shared module: bugs (parse errors, escaping, blockquote semantics) had to be
fixed in three places. Now there is exactly one.

Telegram HTML reference: https://core.telegram.org/bots/api#html-style
Supported tags: <b> <i> <u> <s> <a> <code> <pre> <pre><code class="language-X">
                <blockquote> <tg-spoiler>

CLI:
  echo "**bold** text" | python3 tools/md_to_html.py
  python3 tools/md_to_html.py --max-chars 4096

Library:
  from md_to_html import md_to_html
  html = md_to_html(text, max_chars=4096)
"""
from __future__ import annotations

import re
import sys

# Telegram message hard limit is 4096 chars. Default cap leaves room for footers.
DEFAULT_MAX_CHARS = 4000

FENCE_RE = re.compile(r"(```[\w-]*\n?[\s\S]*?```|`[^`\n]+`)")

# Lines that look like a markdown table row: optional whitespace, leading pipe,
# at least one more pipe somewhere on the line. Tight enough to avoid matching
# prose with inline `|` (which doesn't start with pipe).
_TABLE_LINE = re.compile(r"^\s*\|.*\|")


def _auto_wrap_tables(text: str) -> str:
    """
    Wrap runs of ≥2 consecutive markdown-table-looking lines (outside existing
    code fences) in a ``` block, so they render as monospace `<pre>` in
    Telegram instead of broken raw pipes. Idempotent: lines already inside a
    fence are left alone.
    """
    if "|" not in text:
        return text
    parts = FENCE_RE.split(text)
    for i, part in enumerate(parts):
        if i % 2 == 1:
            continue  # already fenced — leave alone
        lines = part.split("\n")
        new_lines: list[str] = []
        run: list[str] = []

        def flush():
            if len(run) >= 2:
                new_lines.append("```")
                new_lines.extend(run)
                new_lines.append("```")
            elif run:
                new_lines.extend(run)
            run.clear()

        for ln in lines:
            if _TABLE_LINE.match(ln):
                run.append(ln)
            else:
                flush()
                new_lines.append(ln)
        flush()
        parts[i] = "\n".join(new_lines)
    return "".join(parts)
_HEADING_RE = re.compile(r"^#{1,6} +(.+)$", re.MULTILINE)
_BOLD_RE = re.compile(r"\*\*(.+?)\*\*", re.DOTALL)
_BOLD_UND_RE = re.compile(r"__(.+?)__", re.DOTALL)
# Italic *…* — careful not to match **bold** or list bullets
_ITAL_STAR_RE = re.compile(r"(?<!\*)\*(?!\*)(.+?)(?<!\s)\*(?!\*)")
# Italic _…_ — within a single line, no internal underscores
_ITAL_UND_RE = re.compile(r"_([^_\n]+?)_")
_STRIKE_RE = re.compile(r"~~(.+?)~~")
_LINK_RE = re.compile(r"\[([^\]]+)\]\((https?://[^)]+)\)")
_THINK_RE = re.compile(
    r"&lt;(think|thinking|reasoning|thought)&gt;(.*?)(&lt;/\1&gt;|$)",
    re.DOTALL | re.IGNORECASE,
)
# Pre-pass version that matches the RAW <think>...</think> in markdown
# before escaping. We truncate at this stage so the cut cannot land in
# the middle of a markdown construct that later becomes a paired HTML
# tag — otherwise `**bold spanning the cut**` would render as <b>...
# without a matching </b> and Telegram would reject the message.
_RAW_THINK_RE = re.compile(
    r"<(think|thinking|reasoning|thought)>(.*?)</\1>",
    re.DOTALL | re.IGNORECASE,
)


def _esc(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _truncate_raw_think_blocks(text: str) -> str:
    """Truncate <think> content over 1000 chars to first 500 + marker + last 500.

    Operates on raw markdown before escaping/markdown→HTML conversion so
    that markdown pairs (**bold**, *italic*, etc.) are never cut mid-pair.
    """
    def repl(m: "re.Match[str]") -> str:
        tag = m.group(1)
        content = m.group(2)
        if len(content) <= 1000:
            return m.group(0)
        truncated = content[:500] + "\n\n... [thinking truncated] ...\n\n" + content[-500:]
        return f"<{tag}>{truncated}</{tag}>"
    return _RAW_THINK_RE.sub(repl, text)


def _format_think(match: "re.Match[str]") -> str:
    content = match.group(2)
    # Truncation already done by _truncate_raw_think_blocks before HTML
    # conversion. Don't wrap in <i> — content may contain <code>/<pre>
    # from the code-block pass, and Telegram rejects those nested in <i>.
    return f"<blockquote><b>🧠 Thinking</b>\n{content.strip()}</blockquote>\n"


def md_to_html(text: str, max_chars: int = DEFAULT_MAX_CHARS) -> str:
    """Render Markdown → Telegram-compatible HTML, with safe escaping."""
    if not text:
        return ""
    # Pre-pass 1: truncate long <think> blocks in raw markdown so the cut
    # can never land in the middle of a **bold** / *italic* / [link] pair
    # that the markdown→HTML pass would have rendered to a paired HTML tag.
    text = _truncate_raw_think_blocks(text)
    # Pre-pass 2: auto-wrap raw markdown tables (lines starting with `|`) in
    # ``` fences so they render as monospace <pre> instead of broken pipes.
    # Idempotent — lines already inside a fence are untouched.
    text = _auto_wrap_tables(text)
    result: list[str] = []
    parts = FENCE_RE.split(text)
    for i, part in enumerate(parts):
        if i % 2 == 1:
            # Code block / inline code
            if part.startswith("```"):
                # Extract optional language hint: ```python\n... → class="language-python"
                lang_match = re.match(r"^```([\w-]*)\n?", part)
                lang = lang_match.group(1) if lang_match and lang_match.group(1) else ""
                code = re.sub(r"^```[\w-]*\n?", "", part)
                code = re.sub(r"\n?```$", "", code)
                code = _esc(code)
                if lang:
                    result.append(f'<pre><code class="language-{lang}">{code}</code></pre>')
                else:
                    result.append(f"<pre><code>{code}</code></pre>")
            else:
                code = _esc(part[1:-1])
                result.append(f"<code>{code}</code>")
        else:
            p = _esc(part)
            p = _HEADING_RE.sub(r"<b>\1</b>", p)
            p = _BOLD_RE.sub(r"<b>\1</b>", p)
            p = _BOLD_UND_RE.sub(r"<b>\1</b>", p)
            p = _ITAL_STAR_RE.sub(r"<i>\1</i>", p)
            p = _ITAL_UND_RE.sub(r"<i>\1</i>", p)
            p = _STRIKE_RE.sub(r"<s>\1</s>", p)
            p = _LINK_RE.sub(r'<a href="\2">\1</a>', p)
            result.append(p)

    html = "".join(result)
    html = _THINK_RE.sub(_format_think, html)
    # If the model emitted raw Telegram-safe HTML tags (e.g. <b>, <i>, <a href=…>),
    # they got escaped above into &lt;b&gt; etc. Un-escape only the safe set so
    # they render rather than appearing literally. Unknown tags stay escaped.
    html = _unescape_safe_tags(html)

    if len(html) > max_chars:
        html = html[: max_chars - 80] + "\n\n<i>... [message truncated due to Telegram 4096 limit]</i>"

    return html


# Telegram-supported tags (subset that won't break parse_mode=HTML).
# See https://core.telegram.org/bots/api#html-style
_SAFE_TAGS = ("b", "strong", "i", "em", "u", "ins", "s", "strike", "del",
              "code", "pre", "blockquote", "tg-spoiler", "span", "br")
# Build a regex that matches escaped versions of each tag (open + close + self-closing for <br/>)
_SAFE_TAG_RE = re.compile(
    r"&lt;(/?(?:" + "|".join(re.escape(t) for t in _SAFE_TAGS) +
    r")(?:\s+[^&]*?)?/?)&gt;",
    re.IGNORECASE,
)
# Escaped <a href="..."> with double or single quotes; only http/https URLs allowed.
_SAFE_A_RE = re.compile(
    r"&lt;a\s+href=(?:&quot;|\")(https?://[^&\"<>]+?)(?:&quot;|\")&gt;",
    re.IGNORECASE,
)
_SAFE_A_CLOSE_RE = re.compile(r"&lt;/a&gt;", re.IGNORECASE)


# Match <pre>…</pre> and <code>…</code> regions so we can leave their contents alone.
_PRE_CODE_RE = re.compile(r"(<pre>.*?</pre>|<code>.*?</code>|<code [^>]*>.*?</code>)", re.DOTALL)


def _unescape_outside_code(html: str, transform) -> str:
    """Apply `transform` to text outside <pre>/<code> regions; leave inside untouched."""
    out = []
    last = 0
    for m in _PRE_CODE_RE.finditer(html):
        out.append(transform(html[last:m.start()]))
        out.append(m.group(0))  # preserve code/pre region as-is
        last = m.end()
    out.append(transform(html[last:]))
    return "".join(out)


def _unescape_safe_tags(html: str) -> str:
    def _do(seg: str) -> str:
        seg = _SAFE_TAG_RE.sub(lambda m: "<" + m.group(1) + ">", seg)
        seg = _SAFE_A_RE.sub(lambda m: f'<a href="{m.group(1)}">', seg)
        seg = _SAFE_A_CLOSE_RE.sub("</a>", seg)
        return seg
    return _unescape_outside_code(html, _do)


def _strip_html(html: str) -> str:
    """Last-resort plain-text fallback when Telegram refuses HTML."""
    plain = re.sub(r"<[^>]+>", "", html)
    return (plain.replace("&amp;", "&")
                .replace("&lt;", "<")
                .replace("&gt;", ">")
                .replace("&#39;", "'")
                .replace("&quot;", '"'))


def _cli() -> None:
    max_chars = DEFAULT_MAX_CHARS
    args = sys.argv[1:]
    while args:
        if args[0] == "--max-chars" and len(args) >= 2:
            try:
                max_chars = int(args[1])
            except ValueError:
                pass
            args = args[2:]
        elif args[0] == "--strip":
            sys.stdout.write(_strip_html(sys.stdin.read()))
            return
        else:
            break

    text = sys.stdin.read()
    sys.stdout.write(md_to_html(text, max_chars=max_chars))


if __name__ == "__main__":
    _cli()
