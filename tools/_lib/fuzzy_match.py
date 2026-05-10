"""Multi-strategy fuzzy text matching for AMA edit tools.

Ported and condensed from hermes-agent/tools/fuzzy_match.py.

When an LLM emits an `old_string` to find-and-replace, it often differs from
the file in subtle ways: whitespace, indentation, smart quotes, escape
sequences. This module tries a chain of strategies in order:

    1. exact            — direct string match
    2. line_trimmed     — strip per-line whitespace
    3. ws_normalized    — collapse runs of spaces/tabs to one
    4. indent_flexible  — strip leading whitespace per line
    5. escape_normalized — convert \\n, \\t, \\r literals to real chars
    6. trimmed_boundary — trim only first/last line whitespace
    7. unicode_normalized — smart quotes, em-dashes, ellipsis -> ASCII
    8. block_anchor     — match first+last lines, fuzzy middle (>=50% sim)
    9. context_aware    — line-by-line similarity (>=50% lines >=80% sim)

Returns the first successful strategy. Detects tool-call escape-drift so
spurious backslashes don't get persisted to source files.
"""

import re
from difflib import SequenceMatcher
from typing import Callable, List, Optional, Tuple


_UNICODE_MAP = {
    "\u201c": '"', "\u201d": '"',  # smart double quotes
    "\u2018": "'", "\u2019": "'",  # smart single quotes
    "\u2014": "--", "\u2013": "-",  # em / en dashes
    "\u2026": "...", "\u00a0": " ",  # ellipsis, NBSP
}


def _unicode_normalize(text: str) -> str:
    for char, repl in _UNICODE_MAP.items():
        text = text.replace(char, repl)
    return text


def fuzzy_find_and_replace(
    content: str, old_string: str, new_string: str, replace_all: bool = False
) -> Tuple[str, int, Optional[str], Optional[str]]:
    """Try strategies in order. Returns (new_content, match_count, strategy, error)."""
    if not old_string:
        return content, 0, None, "old_string cannot be empty"
    if old_string == new_string:
        return content, 0, None, "old_string and new_string are identical"

    strategies: List[Tuple[str, Callable]] = [
        ("exact", _s_exact),
        ("line_trimmed", _s_line_trimmed),
        ("ws_normalized", _s_ws_normalized),
        ("indent_flexible", _s_indent_flexible),
        ("escape_normalized", _s_escape_normalized),
        ("trimmed_boundary", _s_trimmed_boundary),
        ("unicode_normalized", _s_unicode_normalized),
        ("block_anchor", _s_block_anchor),
        ("context_aware", _s_context_aware),
    ]

    for name, fn in strategies:
        matches = fn(content, old_string)
        if not matches:
            continue
        if len(matches) > 1 and not replace_all:
            return content, 0, None, (
                f"Found {len(matches)} matches for old_string. "
                f"Provide more surrounding context to make it unique, "
                f"or pass replace_all=true."
            )
        if name != "exact":
            drift_err = _detect_escape_drift(content, matches, old_string, new_string)
            if drift_err:
                return content, 0, None, drift_err
        new_content = _apply_replacements(content, matches, new_string)
        return new_content, len(matches), name, None

    return content, 0, None, "Could not find a match for old_string in the file"


def _detect_escape_drift(content, matches, old_string, new_string) -> Optional[str]:
    if "\\'" not in new_string and '\\"' not in new_string:
        return None
    matched_regions = "".join(content[s:e] for s, e in matches)
    for suspect in ("\\'", '\\"'):
        if suspect in new_string and suspect in old_string and suspect not in matched_regions:
            plain = suspect[1]
            return (
                f"Escape-drift detected: new_string contains literal {suspect!r} "
                f"but the matched region of the file does not. This is usually "
                f"a tool-call serialization artifact (apostrophe/quote got an "
                f"unwanted backslash). Re-read the file and pass strings without "
                f"backslash-escaping {plain!r}."
            )
    return None


def _apply_replacements(content, matches, new_string):
    for start, end in sorted(matches, key=lambda x: x[0], reverse=True):
        content = content[:start] + new_string + content[end:]
    return content


# ── Strategies ─────────────────────────────────────────────────────────────

def _s_exact(content, pattern):
    out = []
    i = 0
    while True:
        p = content.find(pattern, i)
        if p == -1:
            break
        out.append((p, p + len(pattern)))
        i = p + 1
    return out


def _line_match(content, content_lines, content_norm_lines, pattern_norm):
    pat_lines = pattern_norm.split("\n")
    n = len(pat_lines)
    out = []
    for i in range(len(content_norm_lines) - n + 1):
        block = "\n".join(content_norm_lines[i:i + n])
        if block == pattern_norm:
            s, e = _line_positions(content_lines, i, i + n, len(content))
            out.append((s, e))
    return out


def _s_line_trimmed(content, pattern):
    pat_norm = "\n".join(l.strip() for l in pattern.split("\n"))
    cl = content.split("\n")
    return _line_match(content, cl, [l.strip() for l in cl], pat_norm)


def _s_ws_normalized(content, pattern):
    norm = lambda s: re.sub(r"[ \t]+", " ", s)
    matches = _s_exact(norm(content), norm(pattern))
    # Approximate: assume positions roughly correspond. For most real-world
    # cases (single edit) this is fine; for unique matches map via line walk.
    if not matches:
        return []
    return _approx_norm_to_orig(content, norm(content), matches)


def _s_indent_flexible(content, pattern):
    pat_norm = "\n".join(l.lstrip() for l in pattern.split("\n"))
    cl = content.split("\n")
    return _line_match(content, cl, [l.lstrip() for l in cl], pat_norm)


def _s_escape_normalized(content, pattern):
    unesc = pattern.replace("\\n", "\n").replace("\\t", "\t").replace("\\r", "\r")
    if unesc == pattern:
        return []
    return _s_exact(content, unesc)


def _s_trimmed_boundary(content, pattern):
    plines = pattern.split("\n")
    if not plines:
        return []
    plines[0] = plines[0].strip()
    if len(plines) > 1:
        plines[-1] = plines[-1].strip()
    target = "\n".join(plines)
    cl = content.split("\n")
    n = len(plines)
    out = []
    for i in range(len(cl) - n + 1):
        check = cl[i:i + n].copy()
        check[0] = check[0].strip()
        if len(check) > 1:
            check[-1] = check[-1].strip()
        if "\n".join(check) == target:
            s, e = _line_positions(cl, i, i + n, len(content))
            out.append((s, e))
    return out


def _s_unicode_normalized(content, pattern):
    np = _unicode_normalize(pattern)
    nc = _unicode_normalize(content)
    if np == pattern and nc == content:
        return []
    matches = _s_exact(nc, np)
    if not matches:
        cl = nc.split("\n")
        matches = _line_match(nc, cl, [l.strip() for l in cl],
                              "\n".join(l.strip() for l in np.split("\n")))
    if not matches:
        return []
    return _build_unicode_position_map(content, matches)


def _s_block_anchor(content, pattern):
    np = _unicode_normalize(pattern)
    nc = _unicode_normalize(content)
    plines = np.split("\n")
    if len(plines) < 2:
        return []
    first, last = plines[0].strip(), plines[-1].strip()
    norm_lines = nc.split("\n")
    orig_lines = content.split("\n")
    n = len(plines)
    candidates = [
        i for i in range(len(norm_lines) - n + 1)
        if norm_lines[i].strip() == first and norm_lines[i + n - 1].strip() == last
    ]
    threshold = 0.50 if len(candidates) == 1 else 0.70
    out = []
    for i in candidates:
        if n <= 2:
            sim = 1.0
        else:
            cmid = "\n".join(norm_lines[i + 1:i + n - 1])
            pmid = "\n".join(plines[1:-1])
            sim = SequenceMatcher(None, cmid, pmid).ratio()
        if sim >= threshold:
            s, e = _line_positions(orig_lines, i, i + n, len(content))
            out.append((s, e))
    return out


def _s_context_aware(content, pattern):
    plines = pattern.split("\n")
    cl = content.split("\n")
    if not plines:
        return []
    n = len(plines)
    out = []
    for i in range(len(cl) - n + 1):
        block = cl[i:i + n]
        hits = sum(
            1 for p, c in zip(plines, block)
            if SequenceMatcher(None, p.strip(), c.strip()).ratio() >= 0.80
        )
        if hits >= n * 0.5:
            s, e = _line_positions(cl, i, i + n, len(content))
            out.append((s, e))
    return out


# ── Helpers ────────────────────────────────────────────────────────────────

def _line_positions(lines, start, end, total_len):
    s = sum(len(l) + 1 for l in lines[:start])
    e = sum(len(l) + 1 for l in lines[:end]) - 1
    return s, min(e, total_len)


def _approx_norm_to_orig(orig, norm, norm_matches):
    out = []
    for ns, ne in norm_matches:
        # Walk orig advancing norm-equivalent positions.
        oi = ni = 0
        os_pos = oe_pos = None
        while oi < len(orig) and ni <= ne:
            if ni == ns and os_pos is None:
                os_pos = oi
            if ni == ne:
                oe_pos = oi
                break
            if oi < len(orig) and orig[oi] in " \t":
                # collapse runs of whitespace as one normalized space
                oi += 1
                if oi >= len(orig) or orig[oi] not in " \t":
                    ni += 1
            else:
                oi += 1
                ni += 1
        if os_pos is not None and oe_pos is not None:
            out.append((os_pos, oe_pos))
    return out


def _build_unicode_position_map(orig, norm_matches):
    """Map positions in unicode-normalized string back to original."""
    orig_to_norm = []
    nidx = 0
    for c in orig:
        orig_to_norm.append(nidx)
        repl = _UNICODE_MAP.get(c)
        nidx += len(repl) if repl is not None else 1
    orig_to_norm.append(nidx)

    norm_to_orig = {}
    for op, npos in enumerate(orig_to_norm[:-1]):
        if npos not in norm_to_orig:
            norm_to_orig[npos] = op

    out = []
    olen = len(orig_to_norm) - 1
    for ns, ne in norm_matches:
        if ns not in norm_to_orig:
            continue
        os_pos = norm_to_orig[ns]
        oe_pos = os_pos
        while oe_pos < olen and orig_to_norm[oe_pos] < ne:
            oe_pos += 1
        out.append((os_pos, oe_pos))
    return out


# ── Did-you-mean snippet ──────────────────────────────────────────────────

def find_closest_lines(old_string, content, context_lines=2, max_results=3):
    """Suggest the most-similar regions in `content` for did-you-mean hints."""
    if not old_string or not content:
        return ""
    old_lines = old_string.splitlines()
    content_lines = content.splitlines()
    if not old_lines or not content_lines:
        return ""
    candidates = [l.strip() for l in old_lines if l.strip()]
    if not candidates:
        return ""
    anchor = candidates[0]

    scored = []
    for i, line in enumerate(content_lines):
        s = line.strip()
        if not s:
            continue
        ratio = SequenceMatcher(None, anchor, s).ratio()
        if ratio > 0.3:
            scored.append((ratio, i))

    if not scored:
        return ""
    scored.sort(key=lambda x: -x[0])

    out = []
    seen = set()
    for _, idx in scored[:max_results]:
        start = max(0, idx - context_lines)
        end = min(len(content_lines), idx + len(old_lines) + context_lines)
        if (start, end) in seen:
            continue
        seen.add((start, end))
        snippet = "\n".join(
            f"{start + j + 1:4d}| {content_lines[start + j]}"
            for j in range(end - start)
        )
        out.append(snippet)
    return "\n---\n".join(out) if out else ""


def format_no_match_hint(error, count, old_string, content):
    if count != 0:
        return ""
    if not error or not error.startswith("Could not find"):
        return ""
    hint = find_closest_lines(old_string, content)
    if not hint:
        return ""
    return "\n\nDid you mean one of these sections?\n" + hint
