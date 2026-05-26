#!/usr/bin/env python3
"""
retry_after.py — extract a sensible retry-after delay from a 429/503 error
blob (stderr text, response body, or both concatenated). Reads from stdin
or argv[1]. Prints one integer (seconds), clamped to [5, 600].

Goal: replace hardcoded 60-second rate-limit timeouts with the value the
provider actually told us, so we stop waiting too long (when the limit
clears in 5s) or too short (when the limit is 5 minutes and we keep
retrying into it).

Recognized hints (first match wins):
  • HTTP header form:        Retry-After: <seconds> | <HTTP-date>
  • Google API "retryDelay": "30s"
  • snake_case retry_after:  "retry_after": 30, "retry_after_seconds": 30
  • Free text:               "retry in 30 seconds" / "please wait 30s"
  • Anthropic-style:         anthropic-ratelimit-*-reset: <unix-ts>

Fallback when nothing matches: 60 seconds (the previous hardcoded value).
"""
import sys, re, time, email.utils

_CLAMP_LO = 5
_CLAMP_HI = 600
_DEFAULT  = 60


def _from_http_date(s: str) -> int | None:
    try:
        t = email.utils.parsedate_to_datetime(s).timestamp()
        return int(t - time.time())
    except Exception:
        return None


def _from_unix_ts(s: str) -> int | None:
    try:
        ts = float(s)
        # Heuristic: if it looks like a future unix timestamp (>= year 2020),
        # treat it as one; otherwise treat as a delta.
        if ts > 1_577_836_800:  # 2020-01-01
            return int(ts - time.time())
    except Exception:
        return None
    return None


def parse(blob: str) -> int:
    if not blob:
        return _DEFAULT

    # 1. HTTP "Retry-After" header — seconds or HTTP-date. The header form
    #    runs to end-of-line; allow commas inside the value so HTTP-dates
    #    like "Mon, 26 May 2026 14:00:00 GMT" parse cleanly.
    m = re.search(r'(?im)^\s*Retry-?After["\']?\s*[:=]\s*["\']?\s*(.+?)\s*["\']?\s*$', blob)
    if not m:
        m = re.search(r'(?i)["\']Retry-?After["\']\s*:\s*["\']?([^"\'\r\n}\]]+)', blob)
    if m:
        val = m.group(1).strip().rstrip(',')
        if re.fullmatch(r'\d+(\.\d+)?', val):
            return int(float(val))
        d = _from_http_date(val)
        if d is not None and d > 0:
            return d

    # 2. Google APIs: {"retryDelay": "30s"} or {"retryDelay":"30.5s"}.
    m = re.search(r'(?i)["\']retry[_\-]?delay["\']\s*:\s*["\']?(\d+(?:\.\d+)?)\s*s?["\']?', blob)
    if m:
        return int(float(m.group(1)))

    # 3. snake_case: "retry_after": 30 or "retry_after_seconds": 30.
    m = re.search(r'(?i)["\']retry[_\-]?after(?:_seconds)?["\']\s*:\s*(\d+(?:\.\d+)?)', blob)
    if m:
        return int(float(m.group(1)))

    # 4. Anthropic-style reset headers (unix timestamp seconds or millis).
    m = re.search(r'(?i)ratelimit[_\-][a-z_-]*reset["\']?\s*[:=]\s*["\']?(\d{9,13})', blob)
    if m:
        raw = m.group(1)
        ts = int(raw[:10]) if len(raw) >= 13 else int(raw)
        d = ts - int(time.time())
        if d > 0:
            return d

    # 5. Free text: "retry in 30 seconds" / "please wait 30s".
    m = re.search(r'(?i)(?:retry|wait|try again)[^\d]{1,20}(\d+)\s*(?:s\b|sec)', blob)
    if m:
        return int(m.group(1))

    return _DEFAULT


def main() -> None:
    blob = ""
    if len(sys.argv) > 1:
        blob = sys.argv[1]
    if not blob:
        try:
            blob = sys.stdin.read()
        except Exception:
            blob = ""
    secs = parse(blob)
    secs = max(_CLAMP_LO, min(_CLAMP_HI, secs))
    print(secs)


if __name__ == "__main__":
    main()
