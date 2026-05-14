#!/usr/bin/env python3
"""
Token counting with model-aware context window sizes.
Uses tiktoken (cl100k_base) when available; falls back to an improved
char-based estimate that handles CJK and code better than naive chars/4.
"""
import sys
import os
import json

# Known context window sizes per model family
_CONTEXT_WINDOWS = {
    "gemini-3":      1_000_000,
    "gemini-2.5":    1_000_000,
    "gemini-2.0":    1_000_000,
    "gemini-1.5":    1_000_000,
    "claude-opus-4": 200_000,
    "claude-sonnet-4": 200_000,
    "claude-haiku-4":  200_000,
    "claude-3-7":    200_000,
    "claude-3-5":    200_000,
    "claude-3":      200_000,
    "gpt-4o":        128_000,
    "gpt-4":         128_000,
    "gpt-3.5":        16_000,
    "llama-3":       128_000,
    "deepseek":       64_000,
    "mistral":        32_000,
    "glm":           128_000,
    "groq":          128_000,
}
_DEFAULT_WINDOW = 128_000
_COMPRESSION_RATIO = 0.55  # compress when context is 55% full


def context_window(model: str) -> int:
    m = model.lower()
    for key, size in _CONTEXT_WINDOWS.items():
        if key in m:
            return size
    return _DEFAULT_WINDOW


def compression_threshold(model: str) -> int:
    return int(context_window(model) * _COMPRESSION_RATIO)


def count_tokens(text: str) -> int:
    try:
        import tiktoken
        enc = tiktoken.get_encoding("cl100k_base")
        return len(enc.encode(text))
    except ImportError:
        pass
    # Improved estimate: CJK chars tokenize at ~1.5 chars/token; ASCII at ~3.5
    cjk = sum(
        1 for c in text
        if '一' <= c <= '鿿'
        or '぀' <= c <= 'ヿ'
        or '가' <= c <= '힯'
    )
    return int(cjk / 1.5 + (len(text) - cjk) / 3.5)


def count_history(history: list) -> int:
    total = 0
    for msg in history:
        c = msg.get('content') or ''
        if isinstance(c, list):
            c = ' '.join(p.get('text', '') for p in c if isinstance(p, dict))
        total += count_tokens(str(c))
        for tc in (msg.get('tool_calls') or []):
            total += count_tokens(str(tc.get('function', {}).get('arguments', '')))
    return total


if __name__ == '__main__':
    mode = sys.argv[1] if len(sys.argv) > 1 else 'count'

    if mode == 'count':
        history = json.loads(sys.stdin.read())
        print(count_history(history))

    elif mode == 'window':
        model = sys.argv[2] if len(sys.argv) > 2 else os.environ.get('MODEL', '')
        print(context_window(model))

    elif mode == 'threshold':
        model = sys.argv[2] if len(sys.argv) > 2 else os.environ.get('MODEL', '')
        print(compression_threshold(model))
