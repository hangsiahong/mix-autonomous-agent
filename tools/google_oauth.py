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


_GEMINI_CLI_UA  = "google-api-nodejs-client/9.15.1 (gzip)"
_X_GOOG_CLIENT  = "gl-node/24.0.0"

def _ca_headers(token: str) -> dict:
    """Headers that match gemini-cli exactly — Code Assist may reject others."""
    return {
        "Content-Type":          "application/json",
        "Accept":                "application/json",
        "Authorization":         f"Bearer {token}",
        "User-Agent":            _GEMINI_CLI_UA,
        "X-Goog-Api-Client":     _X_GOOG_CLIENT,
        "x-activity-request-id": secrets.token_hex(16),
    }

def _client_metadata() -> dict:
    """Match gemini-cli's metadata fields exactly."""
    return {
        "ideType":    "IDE_UNSPECIFIED",
        "platform":   "PLATFORM_UNSPECIFIED",
        "pluginType": "GEMINI",
    }

def _post_json(url: str, payload: dict, token: str) -> dict:
    body = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=body, headers=_ca_headers(token), method="POST")
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


def _load_code_assist(access_token: str, project_id: str = "") -> dict:
    """Call loadCodeAssist matching hermes/gemini-cli request format exactly."""
    body: dict = {
        "metadata": {
            "duetProject": project_id,
            **_client_metadata(),
        },
    }
    if project_id:
        body["cloudaicompanionProject"] = project_id
    return _post_json(
        f"{CODE_ASSIST_ENDPOINT}/v1internal:loadCodeAssist",
        body,
        access_token,
    )


def _retrieve_quota(access_token: str, project_id: str = "") -> list:
    """Return list of quota bucket dicts from retrieveUserQuota."""
    body = {}
    if project_id:
        body["project"] = project_id
    resp = _post_json(
        f"{CODE_ASSIST_ENDPOINT}/v1internal:retrieveUserQuota",
        body, access_token,
    )
    return resp.get("buckets") or []


def _probe_model(access_token: str, project_id: str, model: str) -> bool:
    """Probe the STREAMING endpoint (:streamGenerateContent?alt=sse) — that's what we
    actually use for inference. :generateContent may support models that streaming doesn't.

    Returns True if streaming endpoint responds (200 or 429).
    Returns False for 404/400 (model not available on streaming).
    """
    try:
        import urllib.request as _ur
        wrapped = {
            "project": project_id,
            "model":   model,
            "user_prompt_id": secrets.token_hex(8),
            "request": {
                "contents": [{"role": "user", "parts": [{"text": "hi"}]}],
                "generationConfig": {"maxOutputTokens": 1},
            },
        }
        body = json.dumps(wrapped).encode()
        h = _ca_headers(access_token)
        h["Accept"] = "text/event-stream"
        req = _ur.Request(
            f"{CODE_ASSIST_ENDPOINT}/v1internal:streamGenerateContent?alt=sse",
            data=body, headers=h, method="POST",
        )
        try:
            with _ur.urlopen(req, timeout=15) as resp:
                # 200 → read a few bytes to confirm it's actually streaming
                resp.read(64)
                return True
        except urllib.error.HTTPError as e:
            return e.code in (429, 503)  # rate-limited but model exists
    except Exception:
        return False


def _best_model_for_tier(tier: str, buckets: list,
                          access_token: str = "", project_id: str = "") -> str:
    """Pick best model: use quota list to get candidates, probe each to confirm it works.

    Preference order: newest/most capable first.
    """
    _PREFS = [
        #"gemini-3.1-pro-preview",
        #"gemini-3-pro-preview",
        #"gemini-3.1-flash-lite-preview",
        #"gemini-3-flash-preview",
        #"gemini-2.5-pro",
        "gemini-2.5-flash",
        "gemini-2.5-flash-lite",
        "gemini-2.0-flash-001",
    ]

    # Build candidate list from quota (non-zero quota only)
    candidates = []
    if buckets:
        available = set()
        for b in buckets:
            mid = str(b.get("modelId", "")).split("/")[-1]
            if mid and float(b.get("remainingFraction", 1.0)) > 0:
                available.add(mid)
        # Keep preference order, filtered to what quota says is available
        for m in _PREFS:
            if m in available:
                candidates.append(m)
        # Append any extras not in our list
        for m in available:
            if m not in candidates:
                candidates.append(m)

    if not candidates:
        candidates = _PREFS

    # Probe each candidate to find one that actually works
    if access_token:
        print(f"Probing {len(candidates)} models to find best working one…", file=sys.stderr)
        for m in candidates:
            print(f"  Testing {m}…", file=sys.stderr)
            if _probe_model(access_token, project_id, m):
                print(f"  ✓ {m} works", file=sys.stderr)
                return m
            print(f"  ✗ {m} not available", file=sys.stderr)

    # No probe (or all failed) — return safest default
    return "gemini-2.5-flash"


def _discover_project(access_token: str) -> tuple:
    """Call loadCodeAssist; onboard free tier if needed.
    Returns (cloudaicompanionProject, tier_id, best_model).
    """
    resp = _load_code_assist(access_token)

    # Parse tier — field is currentTier.id in some responses, currentTierId in others
    current_tier = resp.get("currentTier") or {}
    tier = (str(current_tier.get("id") or "") if isinstance(current_tier, dict) else "") \
        or str(resp.get("currentTierId") or "")
    project = str(resp.get("cloudaicompanionProject") or "")

    print(f"Tier: {tier or '(none yet)'}, Project: {project or '(none yet)'}", file=sys.stderr)

    # New user — not onboarded yet. Provision free tier (LRO with polling).
    if not tier:
        print("Onboarding free tier (one-time, may take ~30s)…", file=sys.stderr)
        onboard_resp = _post_json(
            f"{CODE_ASSIST_ENDPOINT}/v1internal:onboardUser",
            {"tierId": "free-tier", "metadata": _client_metadata()},
            access_token,
        )
        if not onboard_resp.get("done"):
            op_name = onboard_resp.get("name", "")
            for _ in range(12):
                time.sleep(5)
                if not op_name:
                    break
                poll = _post_json(
                    f"{CODE_ASSIST_ENDPOINT}/v1internal/{op_name}",
                    {}, access_token,
                )
                if poll.get("done"):
                    onboard_resp = poll
                    break
        body = onboard_resp.get("response") or onboard_resp
        project = project or str(body.get("cloudaicompanionProject") or "")
        tier = "free-tier"

    # Get quota then probe to find best actually-working model
    buckets = _retrieve_quota(access_token, project)
    best_model = _best_model_for_tier(tier, buckets, access_token, project)
    print(f"Best working model: {best_model}", file=sys.stderr)

    return project, tier, best_model


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

    print("Discovering project and quota (this may take ~10s)…", file=sys.stderr)
    project_id, tier, best_model = _discover_project(access_token)
    email = _get_email(access_token)

    creds = {
        "access_token":  access_token,
        "refresh_token": refresh_token,
        "expires_at":    int(time.time()) + expires_in - 60,
        "project_id":    project_id,
        "tier":          tier,
        "best_model":    best_model,
        "email":         email,
    }
    _save_creds(creds)

    try:
        STATE_FILE.unlink()
    except Exception:
        pass

    print(f"OK email={email} tier={tier} model={best_model} project={project_id or '(auto)'}")


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
    """Print the stored project_id."""
    creds = _load_creds()
    print(creds.get("project_id", ""))
    return creds.get("project_id", "")


def cmd_model() -> str:
    """Print the best model for this account (from stored creds)."""
    creds = _load_creds()
    model = creds.get("best_model", "gemini-2.5-flash")
    print(model)
    return model


def cmd_status():
    """Print human-readable login status."""
    creds = _load_creds()
    if not creds:
        print("not_logged_in")
        return

    now       = int(time.time())
    expires   = int(creds.get("expires_at", 0))
    email     = creds.get("email", "?")
    project   = creds.get("project_id") or "auto"
    tier      = creds.get("tier", "?")
    model     = creds.get("best_model", "?")
    has_refresh = bool(creds.get("refresh_token"))

    if not has_refresh:
        print(f"needs_relogin  email={email}")
    elif expires > now:
        print(f"logged_in  email={email}  tier={tier}  model={model}  project={project}  expires_in={expires - now}s")
    else:
        print(f"needs_refresh  email={email}  tier={tier}  model={model}  project={project}")


def cmd_rediscover():
    """Re-run project/tier/model discovery using stored refresh token (no re-login)."""
    creds = _load_creds()
    if not creds or not creds.get("refresh_token"):
        print("ERROR: not logged in. Run 'init' + 'finish'.", file=sys.stderr)
        sys.exit(1)

    # Refresh token to get fresh access token
    token_data = _refresh(creds["refresh_token"])
    if "error" in token_data:
        print(f"ERROR: refresh failed: {token_data['error']}", file=sys.stderr)
        sys.exit(1)
    access_token = token_data.get("access_token", "")
    creds["access_token"] = access_token
    creds["expires_at"] = int(time.time()) + int(token_data.get("expires_in", 3600)) - 60

    print("Re-discovering project, tier, and best model…", file=sys.stderr)
    project_id, tier, best_model = _discover_project(access_token)

    creds["project_id"] = project_id
    creds["tier"]       = tier
    creds["best_model"] = best_model
    _save_creds(creds)

    print(f"OK tier={tier} model={best_model} project={project_id or '(auto)'}")


def cmd_quota():
    """Show available models and remaining quota for this account."""
    creds = _load_creds()
    if not creds or not creds.get("refresh_token"):
        print("ERROR: not logged in.", file=sys.stderr)
        sys.exit(1)

    # Get fresh token
    import io
    old_stdout = sys.stdout
    sys.stdout = io.StringIO()
    token = cmd_token()
    sys.stdout = old_stdout
    if not token:
        token = creds.get("access_token", "")

    project = creds.get("project_id", "")
    buckets = _retrieve_quota(token, project)

    if not buckets:
        print(f"No quota data returned. Tier: {creds.get('tier','?')}")
        return

    print(f"Account: {creds.get('email','?')}  Tier: {creds.get('tier','?')}")
    print(f"{'Model':<45} {'Remaining':>10}  Reset")
    print("-" * 70)
    for b in sorted(buckets, key=lambda x: x.get("modelId", "")):
        model_id = str(b.get("modelId", "")).split("/")[-1]
        fraction = float(b.get("remainingFraction", 0))
        reset    = str(b.get("resetTime", ""))[:10]
        bar = "█" * int(fraction * 10) + "░" * (10 - int(fraction * 10))
        print(f"  {model_id:<43} {bar} {fraction*100:5.1f}%  {reset}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("init",    help="Generate auth URL")
    p_f = sub.add_parser("finish", help="Complete login with redirect URL or code")
    p_f.add_argument("url", help="Full redirect URL, query string, or bare auth code")
    sub.add_parser("token",   help="Print valid access token")
    sub.add_parser("project", help="Print stored project_id")
    sub.add_parser("model",      help="Print best model for this account")
    sub.add_parser("quota",      help="Show available models and quota")
    sub.add_parser("rediscover", help="Re-run project/tier/model discovery without re-login")
    sub.add_parser("status",     help="Show login status")

    args = ap.parse_args()
    if   args.cmd == "init":       cmd_init()
    elif args.cmd == "finish":     cmd_finish(args.url)
    elif args.cmd == "token":      cmd_token()
    elif args.cmd == "project":    cmd_project()
    elif args.cmd == "model":      cmd_model()
    elif args.cmd == "quota":      cmd_quota()
    elif args.cmd == "rediscover": cmd_rediscover()
    elif args.cmd == "status":     cmd_status()
