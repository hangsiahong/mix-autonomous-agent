#!/usr/bin/env python3
"""Google OAuth PKCE for Gemini Code Assist (gemini-cli compatible).

Uses Google's public gemini-cli desktop OAuth client — these credentials are
baked into every copy of the official gemini-cli npm package and are NOT
confidential (desktop OAuth clients use PKCE for security, not client_secret).

Commands:
  init              Print auth URL and save PKCE state to /tmp
  finish <url>      Exchange code from redirect URL → tokens + discover project
  token             Print current access token (auto-refresh if expired)
  status            Show login status
"""
import argparse, base64, hashlib, json, os, secrets, sys, time, urllib.parse, urllib.request
from pathlib import Path

# Public gemini-cli desktop OAuth client (NOT confidential)
# Source: github.com/google-gemini/gemini-cli packages/core/src/code_assist/oauth2.ts
_CLIENT_ID = (
    "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j"
    ".apps.googleusercontent.com"
)
_CLIENT_SECRET = "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"

AUTH_ENDPOINT   = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_ENDPOINT  = "https://oauth2.googleapis.com/token"
SCOPES = (
    "https://www.googleapis.com/auth/cloud-platform "
    "https://www.googleapis.com/auth/userinfo.email "
    "https://www.googleapis.com/auth/userinfo.profile"
)
REDIRECT_URI = "http://127.0.0.1:8085/oauth2callback"
CODE_ASSIST_ENDPOINT = "https://cloudcode-pa.googleapis.com"

CREDS_FILE = Path.home() / ".mix" / "google_oauth.json"
STATE_FILE  = Path("/tmp") / "ama_google_oauth_state.json"


# ─── Helpers ────────────────────────────────────────────────────────────────

def _pkce_pair():
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode()
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode()).digest()
    ).rstrip(b"=").decode()
    return verifier, challenge


def _save_creds(data: dict):
    CREDS_FILE.parent.mkdir(parents=True, exist_ok=True)
    CREDS_FILE.write_text(json.dumps(data, indent=2))
    CREDS_FILE.chmod(0o600)


def _load_creds() -> dict:
    try:
        return json.loads(CREDS_FILE.read_text())
    except Exception:
        return {}


def _post(url: str, params: dict, *, headers: dict | None = None) -> dict:
    body = urllib.parse.urlencode(params).encode()
    h = {"Content-Type": "application/x-www-form-urlencoded"}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, data=body, headers=h, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return json.loads(e.read() or b"{}") | {"_http_status": e.code}


def _post_json(url: str, payload: dict, token: str) -> dict:
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        url, data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "gemini-cli/0.1.0-beta.5 (ama-bot)",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return json.loads(e.read() or b"{}") | {"_http_status": e.code}


def _exchange_code(code: str, verifier: str) -> dict:
    return _post(TOKEN_ENDPOINT, {
        "client_id":     _CLIENT_ID,
        "client_secret": _CLIENT_SECRET,
        "code":          code,
        "code_verifier": verifier,
        "grant_type":    "authorization_code",
        "redirect_uri":  REDIRECT_URI,
    })


def _refresh(refresh_token: str) -> dict:
    return _post(TOKEN_ENDPOINT, {
        "client_id":     _CLIENT_ID,
        "client_secret": _CLIENT_SECRET,
        "grant_type":    "refresh_token",
        "refresh_token": refresh_token,
    })


def _discover_project(access_token: str) -> str:
    """Call loadCodeAssist to get/register the free-tier managed project."""
    resp = _post_json(
        f"{CODE_ASSIST_ENDPOINT}/v1internal:loadCodeAssist",
        {"product": "code_assist", "onboarding_flow": "default"},
        access_token,
    )
    return str(resp.get("cloudaicompanionProject") or "")


def _get_email(access_token: str) -> str:
    req = urllib.request.Request(
        "https://www.googleapis.com/oauth2/v1/userinfo?alt=json",
        headers={"Authorization": f"Bearer {access_token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read()).get("email", "")
    except Exception:
        return ""


# ─── Commands ────────────────────────────────────────────────────────────────

def cmd_init():
    """Generate auth URL and save PKCE state."""
    verifier, challenge = _pkce_pair()
    state = secrets.token_urlsafe(16)

    params = {
        "client_id":             _CLIENT_ID,
        "redirect_uri":          REDIRECT_URI,
        "response_type":         "code",
        "scope":                 SCOPES,
        "state":                 state,
        "code_challenge":        challenge,
        "code_challenge_method": "S256",
        "access_type":           "offline",
        "prompt":                "consent",
    }
    auth_url = AUTH_ENDPOINT + "?" + urllib.parse.urlencode(params)

    STATE_FILE.write_text(json.dumps({"verifier": verifier, "state": state}))
    STATE_FILE.chmod(0o600)

    print(auth_url)


def cmd_finish(raw: str):
    """Exchange authorization code for tokens and save credentials."""
    try:
        state_data = json.loads(STATE_FILE.read_text())
        verifier = state_data["verifier"]
    except Exception:
        print("ERROR: no pending OAuth state. Run 'init' first.", file=sys.stderr)
        sys.exit(1)

    # Accept full redirect URL, bare query string, or raw code
    code = raw
    if raw.startswith("http"):
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(raw).query)
        code = (qs.get("code") or [""])[0]
    elif raw.startswith("?"):
        qs = urllib.parse.parse_qs(raw[1:])
        code = (qs.get("code") or [""])[0]

    if not code:
        print("ERROR: no authorization code in provided value.", file=sys.stderr)
        sys.exit(1)

    token_data = _exchange_code(code, verifier)
    if "error" in token_data:
        print(f"ERROR: {token_data['error']}: {token_data.get('error_description', '')}", file=sys.stderr)
        sys.exit(1)

    access_token  = token_data.get("access_token", "")
    refresh_token = token_data.get("refresh_token", "")
    expires_in    = int(token_data.get("expires_in", 3600))

    print("Discovering project (this may take a few seconds)…", file=sys.stderr)
    project_id = _discover_project(access_token)
    email      = _get_email(access_token)

    creds = {
        "access_token":  access_token,
        "refresh_token": refresh_token,
        "expires_at":    int(time.time()) + expires_in - 60,
        "project_id":    project_id,
        "email":         email,
    }
    _save_creds(creds)

    try:
        STATE_FILE.unlink()
    except Exception:
        pass

    print(f"OK email={email} project={project_id or '(auto)'}")


def cmd_token() -> str:
    """Print a valid access token, refreshing if needed."""
    creds = _load_creds()
    if not creds or not creds.get("refresh_token"):
        print("ERROR: not logged in. Run 'init' + 'finish'.", file=sys.stderr)
        sys.exit(1)

    if int(time.time()) >= int(creds.get("expires_at", 0)):
        token_data = _refresh(creds["refresh_token"])
        if "error" in token_data:
            print(f"ERROR: refresh failed: {token_data['error']}", file=sys.stderr)
            sys.exit(1)
        creds["access_token"] = token_data.get("access_token", "")
        creds["expires_at"]   = int(time.time()) + int(token_data.get("expires_in", 3600)) - 60
        if token_data.get("refresh_token"):
            creds["refresh_token"] = token_data["refresh_token"]
        _save_creds(creds)

    print(creds["access_token"])
    return creds["access_token"]


def cmd_project() -> str:
    """Print the stored project_id (for pool config generation)."""
    creds = _load_creds()
    project_id = creds.get("project_id", "")
    print(project_id)
    return project_id


def cmd_status():
    """Print human-readable login status."""
    creds = _load_creds()
    if not creds:
        print("not_logged_in")
        return

    now       = int(time.time())
    expires   = int(creds.get("expires_at", 0))
    email     = creds.get("email", "?")
    project   = creds.get("project_id") or "?"
    has_refresh = bool(creds.get("refresh_token"))

    if not has_refresh:
        print(f"needs_relogin  email={email}")
    elif expires > now:
        print(f"logged_in  email={email}  project={project}  expires_in={expires - now}s")
    else:
        print(f"needs_refresh  email={email}  project={project}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("init",    help="Generate auth URL")
    p_f = sub.add_parser("finish", help="Complete login with redirect URL or code")
    p_f.add_argument("url", help="Full redirect URL, query string, or bare auth code")
    sub.add_parser("token",   help="Print valid access token")
    sub.add_parser("project", help="Print stored project_id")
    sub.add_parser("status",  help="Show login status")

    args = ap.parse_args()
    if   args.cmd == "init":    cmd_init()
    elif args.cmd == "finish":  cmd_finish(args.url)
    elif args.cmd == "token":   cmd_token()
    elif args.cmd == "project": cmd_project()
    elif args.cmd == "status":  cmd_status()
