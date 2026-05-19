#!/usr/bin/env python3
"""
browser.py — Playwright-based browser automation for AMA.

Hermes-inspired design: uses accessibility tree (aria snapshot) for
text-based page representation. No vision required.

Actions:
  navigate <url>              — open URL, return page snapshot
  snapshot                    — get current page as readable text
  click <selector_or_text>   — click element by CSS selector or visible text
  type <selector> <text>      — type text into an input
  scroll <up|down>            — scroll the page
  back                        — go back in history
  close                       — close the browser session

Session: a single browser instance is kept alive per invocation of this
script (each tool call is a fresh process, so sessions don't persist — 
stateless by design).
"""

import asyncio
import json
import os
import re
import sys
from urllib.parse import urlparse
import ipaddress
import socket

# ── SSRF guard (same logic as fetch_url.sh) ──────────────────────────────
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
                return False, f"private/internal IP (SSRF blocked): {ip}"
        return True, ""
    except Exception as e:
        return False, str(e)


# ── Page snapshot helpers ────────────────────────────────────────────────
MAX_TEXT = int(os.environ.get("BROWSER_MAX_CHARS", "6000"))


async def page_to_text(page) -> str:
    """Convert page content to readable text using inner_text (most reliable)."""
    try:
        text = await page.inner_text("body", timeout=5000)
        # Collapse excess whitespace
        text = re.sub(r"\n{3,}", "\n\n", text.strip())
        text = re.sub(r"[ \t]{3,}", "  ", text)
        if len(text) > MAX_TEXT:
            text = text[:MAX_TEXT] + f"\n\n...[{len(text) - MAX_TEXT} chars truncated]"
        return text
    except Exception as e:
        return f"[snapshot failed: {e}]"


async def get_interactive_elements(page) -> str:
    """Return a compact list of clickable/fillable elements with ref-style labels."""
    try:
        elements = await page.evaluate("""() => {
            const results = [];
            const selectors = ['a[href]', 'button', 'input', 'textarea', 'select', '[role="button"]', '[role="link"]'];
            let idx = 1;
            for (const sel of selectors) {
                for (const el of document.querySelectorAll(sel)) {
                    const rect = el.getBoundingClientRect();
                    if (rect.width === 0 && rect.height === 0) continue;
                    const label = (el.textContent || el.placeholder || el.value || el.getAttribute('aria-label') || el.getAttribute('name') || el.tagName).trim().slice(0, 60);
                    const tag = el.tagName.toLowerCase();
                    const type = el.type || '';
                    const href = el.href || '';
                    if (!label && !href) continue;
                    results.push({ref: `@e${idx++}`, tag, type, label, href: href.slice(0, 100)});
                    if (results.length >= 30) break;
                }
                if (results.length >= 30) break;
            }
            return results;
        }""")
        if not elements:
            return ""
        lines = ["\n\n[Interactive elements:]"]
        for e in elements:
            info = f"  {e['ref']} [{e['tag']}] {e['label']}"
            if e.get('href'):
                info += f" → {e['href']}"
            lines.append(info)
        return "\n".join(lines)
    except Exception:
        return ""


async def run_browser(action: str, url: str = "", selector: str = "", text_to_type: str = ""):
    from playwright.async_api import async_playwright

    async with async_playwright() as pw:
        browser = await pw.chromium.launch(
            headless=True,
            args=["--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu"],
        )
        page = await browser.new_page(
            user_agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            viewport={"width": 1280, "height": 800},
        )

        try:
            if action == "navigate":
                safe, reason = is_safe_url(url)
                if not safe:
                    print(f"Error: URL blocked — {reason}")
                    return
                await page.goto(url, wait_until="domcontentloaded", timeout=30000)
                # Wait a moment for JS to settle
                try:
                    await page.wait_for_load_state("networkidle", timeout=5000)
                except Exception:
                    pass
                title = await page.title()
                current_url = page.url
                body = await page_to_text(page)
                elements = await get_interactive_elements(page)
                print(f"[Browser] {title}\nURL: {current_url}\n\n{body}{elements}")

            elif action == "snapshot":
                title = await page.title()
                current_url = page.url
                body = await page_to_text(page)
                elements = await get_interactive_elements(page)
                print(f"[Browser snapshot] {title}\nURL: {current_url}\n\n{body}{elements}")

            elif action == "click":
                # Try CSS selector first, then visible text
                clicked = False
                if selector.startswith("@e"):
                    # ref selector — find by index in interactive elements list
                    print("Error: ref selectors (@e1, @e2...) require a stateful session. Use text or CSS selector instead.")
                    return
                try:
                    await page.click(selector, timeout=5000)
                    clicked = True
                except Exception:
                    pass
                if not clicked:
                    try:
                        await page.get_by_text(selector, exact=False).first.click(timeout=5000)
                        clicked = True
                    except Exception:
                        pass
                if clicked:
                    try:
                        await page.wait_for_load_state("networkidle", timeout=5000)
                    except Exception:
                        pass
                    body = await page_to_text(page)
                    elements = await get_interactive_elements(page)
                    title = await page.title()
                    print(f"[Clicked '{selector}'] {title}\nURL: {page.url}\n\n{body}{elements}")
                else:
                    print(f"Error: Could not find element '{selector}'")

            elif action == "type":
                await page.fill(selector, text_to_type, timeout=5000)
                print(f"[Typed into '{selector}']: {text_to_type}")

            elif action == "scroll":
                direction = selector.lower()
                delta = -600 if direction == "up" else 600
                await page.evaluate(f"window.scrollBy(0, {delta})")
                body = await page_to_text(page)
                print(f"[Scrolled {direction}]\n\n{body}")

            else:
                print(f"Error: unknown action '{action}'. Use: navigate, snapshot, click, type, scroll")

        finally:
            await browser.close()


if __name__ == "__main__":
    action = os.environ.get("BROWSER_ACTION", "navigate").strip()
    url = os.environ.get("BROWSER_URL", "").strip()
    selector = os.environ.get("BROWSER_SELECTOR", "").strip()
    text_to_type = os.environ.get("BROWSER_TEXT", "").strip()

    asyncio.run(run_browser(action, url, selector, text_to_type))
