#!/usr/bin/env python3
"""
AMA Delegate Tool — spawn a focused sub-agent to complete a specific task.

Modes:
  sync  (default) — blocking: run task, wait for result, return summary
  async — non-blocking: start task in tmux, return session name immediately
  check — poll a running async session for progress / completion
  kill  — terminate an async session early
  list  — list all active AMA delegate tmux sessions

Backends (sync + async):
  claude  — Claude Code CLI (-p non-interactive / tmux window)
  codex   — OpenAI Codex CLI (exec non-interactive / tmux window)
  self    — Mini AMA sub-agent (sync only; always available via API)
  auto    — picks best available (default)

Usage via TOOL_ env vars:
  TOOL_goal="Refactor auth module to use JWT"
  TOOL_context="Auth is in src/auth.py. Use PyJWT library."
  TOOL_mode="sync"            # sync | async | check | kill | list
  TOOL_session="ama_abc12345" # required for check/kill
  TOOL_backend="auto"         # claude | codex | self | auto
  TOOL_timeout="300"          # seconds (default 300)
  TOOL_max_turns="20"         # for self backend only
  TOOL_workdir="."            # working directory (default: project root)
"""
import json, sys, os, subprocess, time, shutil, shlex, hashlib
from pathlib import Path

DIR = Path(os.environ.get("AMA_DIR", str(Path(__file__).parent.parent))).resolve()
STATE_DIR = DIR / "brain" / "state"


# ── Auth helpers ──────────────────────────────────────────────────────────────

def _get_api_key() -> str:
    """
    Get the API bearer token for the configured provider.
    - For Google AI Studio: reads GOOGLE_API_KEY / GEMINI_KEY / API_KEY env var
    - For Vertex AI: calls gcloud auth print-access-token (same as the main bot)
    Never blocks >10s; returns empty string on failure so callers can error cleanly.
    """
    # Static key (Google AI Studio or any plain-key provider)
    key = (os.environ.get("GOOGLE_API_KEY") or os.environ.get("GEMINI_KEY")
           or os.environ.get("API_KEY", ""))
    if key:
        return key

    # Vertex AI — get a fresh short-lived gcloud token, exactly as the main bot does
    google_mode = os.environ.get("GOOGLE_MODE", "")
    base_url    = os.environ.get("BASE_URL", "")
    if google_mode == "vertex" or "aiplatform.googleapis.com" in base_url:
        try:
            r = subprocess.run(
                ["gcloud", "auth", "print-access-token"],
                capture_output=True, text=True, timeout=10
            )
            if r.returncode == 0:
                return r.stdout.strip()
        except FileNotFoundError:
            pass  # gcloud not installed

    return key


def _claude_subprocess_env() -> dict:
    """
    Build a clean env dict for a claude -p subprocess.

    Key concerns:
    - HOME must point to the real user home so the binary finds ~/.claude/.credentials.json
    - ANTHROPIC_API_KEY must NOT be set to a non-Anthropic value (e.g. a Vertex gcloud token
      from the bot's env) — that causes "Not logged in" because the binary validates key format
    - CLAUDE_CODE_SIMPLE=1 suppresses interactive prompts
    """
    # Start from current env
    env = dict(os.environ)

    # Ensure HOME is the real user home (pm2/nohup may leave it unset or wrong)
    env["HOME"] = str(Path.home())
    env["CLAUDE_CODE_SIMPLE"] = "1"

    # Remove any ANTHROPIC_API_KEY that isn't actually an Anthropic key.
    # Vertex gcloud tokens (ya29.*) or empty strings would cause auth failures.
    existing_key = env.get("ANTHROPIC_API_KEY", "")
    if existing_key and not existing_key.startswith("sk-ant-"):
        del env["ANTHROPIC_API_KEY"]

    return env


# ── Backend: Claude Code CLI (sync) ──────────────────────────────────────────

def run_claude(goal: str, context: str, timeout: int, workdir: str) -> dict:
    prompt = goal
    if context:
        prompt = f"{goal}\n\nContext:\n{context}"

    cmd = [
        "claude", "-p", prompt,
        "--add-dir", workdir,
        "--dangerously-skip-permissions",
    ]
    if context:
        cmd += ["--append-system-prompt", f"ADDITIONAL CONTEXT:\n{context}"]

    t0 = time.time()
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True,
            cwd=workdir, timeout=timeout,
            env=_claude_subprocess_env()
        )
        output = result.stdout.strip() or result.stderr.strip()
        return {
            "status": "completed" if result.returncode == 0 else "error",
            "backend": "claude",
            "result": output or "(no output)",
            "exit_code": result.returncode,
            "duration_s": round(time.time() - t0, 1),
        }
    except subprocess.TimeoutExpired:
        return {"status": "timeout", "backend": "claude",
                "result": f"Claude Code timed out after {timeout}s", "duration_s": timeout}
    except FileNotFoundError:
        return {"status": "error", "backend": "claude",
                "result": "claude CLI not found", "duration_s": 0}


# ── Backend: Codex CLI (sync) ─────────────────────────────────────────────────

def run_codex(goal: str, context: str, timeout: int, workdir: str) -> dict:
    prompt = goal
    if context:
        prompt = f"{goal}\n\nContext:\n{context}"

    t0 = time.time()
    try:
        result = subprocess.run(
            ["codex", "exec", prompt], capture_output=True, text=True,
            cwd=workdir, timeout=timeout,
        )
        output = result.stdout.strip() or result.stderr.strip()
        return {
            "status": "completed" if result.returncode == 0 else "error",
            "backend": "codex",
            "result": output or "(no output)",
            "exit_code": result.returncode,
            "duration_s": round(time.time() - t0, 1),
        }
    except subprocess.TimeoutExpired:
        return {"status": "timeout", "backend": "codex",
                "result": f"Codex timed out after {timeout}s", "duration_s": timeout}
    except FileNotFoundError:
        return {"status": "error", "backend": "codex",
                "result": "codex CLI not found", "duration_s": 0}


# ── Backend: Self / mini AMA sub-agent (sync) ─────────────────────────────────

def call_tool_sh(name: str, args_json: str, workdir: str) -> str:
    script = DIR / "tools" / f"{name}.sh"
    if not script.exists():
        script = DIR / "tools" / "custom" / f"{name}.sh"
    if not script.exists():
        return f"Error: tool '{name}' not found"

    env = {**os.environ, "AMA_DIR": str(DIR)}
    try:
        args = json.loads(args_json or "{}")
        for k, v in args.items():
            env[f"TOOL_{k}"] = str(v)
    except Exception:
        pass

    try:
        res = subprocess.run(
            ["bash", str(script)], capture_output=True, text=True,
            env=env, cwd=workdir, timeout=120
        )
        out = (res.stdout + res.stderr).strip()
        return out[:5000] if len(out) > 5000 else out
    except subprocess.TimeoutExpired:
        return f"[Tool {name} timed out]"
    except Exception as e:
        return f"[Tool {name} error: {e}]"


def run_self(goal: str, context: str, timeout: int, workdir: str, max_turns: int) -> dict:
    import requests

    base_url = os.environ.get("BASE_URL", "https://generativelanguage.googleapis.com/v1beta/openai")
    api_key  = _get_api_key()   # handles Vertex gcloud token + static keys
    model    = os.environ.get("MODEL", "")
    vertex_prefix = os.environ.get("_GOOGLE_VERTEX_MODEL_PREFIX", "")
    if vertex_prefix and not model.startswith(vertex_prefix):
        model = vertex_prefix + model

    tools_raw = []
    try:
        tools_raw = json.loads((DIR / "brain" / "tools.json").read_text())
        extra_f = DIR / "brain" / "tools_extra.json"
        if extra_f.exists():
            extra = json.loads(extra_f.read_text())
            names = {t.get("name") for t in tools_raw}
            tools_raw += [t for t in extra if t.get("name") not in names]
    except Exception:
        pass

    blocked = {"delegate", "clarify"}
    tools = [t for t in tools_raw
             if t.get("toolset", "core") in {"core", "search"}
             and t.get("name") not in blocked]
    for t in tools:
        t.pop("toolset", None)
    wrapped = [{"type": "function", "function": t} if "type" not in t else t for t in tools]

    sys_prompt = (
        "You are a focused sub-agent completing a specific delegated task.\n"
        "Use tools to accomplish the goal. Work autonomously.\n"
        "When fully done, begin your final message with 'DONE: ' followed by a summary.\n"
        "If blocked, begin with 'BLOCKED: ' followed by the reason.\n"
        "Do not ask for clarification — make reasonable decisions and proceed."
    )

    history = [{"role": "user", "content": f"GOAL: {goal}" + (f"\n\nCONTEXT:\n{context}" if context else "")}]
    tool_calls_count = 0
    final_text = ""
    t0 = time.time()

    for turn in range(max_turns):
        if time.time() - t0 > timeout:
            return {"status": "timeout", "backend": "self",
                    "result": f"Sub-agent timed out after {timeout}s",
                    "tool_calls": tool_calls_count, "turns": turn,
                    "duration_s": round(time.time()-t0, 1)}

        try:
            resp = requests.post(
                f"{base_url}/chat/completions",
                headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
                json={"model": model,
                      "messages": [{"role": "system", "content": sys_prompt}] + history,
                      "tools": wrapped, "tool_choice": "auto", "stream": False},
                timeout=60,
            )
            resp.raise_for_status()
            data = resp.json()
        except Exception as e:
            return {"status": "error", "backend": "self", "result": f"API error: {e}",
                    "turns": turn, "duration_s": round(time.time()-t0, 1)}

        msg = data.get("choices", [{}])[0].get("message", {})
        content = msg.get("content") or ""
        tcs = msg.get("tool_calls") or []

        if content:
            history.append({"role": "assistant", "content": content})
            final_text = content

        if not tcs:
            break

        history.append({"role": "assistant", "content": content or None, "tool_calls": tcs})
        for tc in tcs:
            tool_calls_count += 1
            name = tc.get("function", {}).get("name", "")
            args = tc.get("function", {}).get("arguments", "{}")
            out  = call_tool_sh(name, args, workdir)
            history.append({"role": "tool",
                             "tool_call_id": tc.get("id", f"call_{tool_calls_count}"),
                             "name": name, "content": out})

    status = "completed"
    if not final_text:
        status = "no_response"
    elif final_text.upper().startswith("BLOCKED:"):
        status = "blocked"

    return {
        "status": status, "backend": "self",
        "result": final_text or "(no response generated)",
        "tool_calls": tool_calls_count,
        "turns": min(turn + 1, max_turns),
        "duration_s": round(time.time() - t0, 1),
    }


# ── Tmux async helpers ────────────────────────────────────────────────────────

def _session_name(goal: str) -> str:
    h = hashlib.md5(f"{goal}{time.time()}".encode()).hexdigest()[:8]
    return f"ama_{h}"


def run_tmux_async(goal: str, context: str, timeout: int, workdir: str, backend: str) -> dict:
    """Start task in a detached tmux session. Returns immediately with session name."""
    if not shutil.which("tmux"):
        return {"status": "error", "backend": f"tmux/{backend}",
                "result": "tmux is not installed. Install: sudo pacman -S tmux  (or apt/brew)",
                "duration_s": 0}

    session  = _session_name(goal)
    sentinel = STATE_DIR / f"delegate_{session}.done"
    meta_f   = STATE_DIR / f"delegate_{session}.meta"
    log_f    = STATE_DIR / f"delegate_{session}.log"
    STATE_DIR.mkdir(parents=True, exist_ok=True)

    prompt = goal + (f"\n\nContext:\n{context}" if context else "")

    if backend == "claude":
        # Refresh OAuth token now so the tmux shell finds a valid one
        claude_env = _claude_subprocess_env()
        home_val = shlex.quote(claude_env.get("HOME", str(Path.home())))
        inner = (f"HOME={home_val} CLAUDE_CODE_SIMPLE=1 "
                 f"claude -p {shlex.quote(prompt)}"
                 f" --add-dir {shlex.quote(workdir)}"
                 f" --dangerously-skip-permissions")
    elif backend == "codex":
        inner = f"codex exec {shlex.quote(prompt)}"
    else:
        return {"status": "error", "backend": f"tmux/{backend}",
                "result": f"async mode only supports claude/codex (got '{backend}'). "
                           "Use mode=sync for the self backend.",
                "duration_s": 0}

    # Inject fresh Vertex gcloud token into tmux shell env if needed
    api_key_val = _get_api_key()
    env_prefix = f"API_KEY={shlex.quote(api_key_val)} " if api_key_val else ""

    # cd, run command, tee output to log file, write exit code to sentinel
    full_cmd = (
        f"{env_prefix}cd {shlex.quote(workdir)} && "
        f"{{ {inner}; }} 2>&1 | tee {shlex.quote(str(log_f))}; "
        f"echo ${{PIPESTATUS[0]}} > {shlex.quote(str(sentinel))}"
    )

    # Explicitly use bash — tmux default shell may be sh/fish which lacks PIPESTATUS
    r = subprocess.run(
        ["tmux", "new-session", "-d", "-s", session, "-x", "220", "-y", "50",
         "bash", "-c", full_cmd],
        capture_output=True, text=True
    )
    if r.returncode != 0:
        return {"status": "error", "backend": f"tmux/{backend}",
                "result": f"tmux failed: {(r.stderr or r.stdout).strip()}",
                "duration_s": 0}

    meta_f.write_text(json.dumps({
        "goal": goal[:300], "backend": backend,
        "started_at": time.time(), "timeout": timeout,
        "workdir": workdir, "log_file": str(log_f),
    }))

    return {
        "status": "running",
        "backend": f"tmux/{backend}",
        "session": session,
        "result": (
            f"Task started in tmux session '{session}'.\n"
            f"• Poll:   delegate(mode=check, session={session})\n"
            f"• Cancel: delegate(mode=kill,  session={session})\n"
            f"Check every 30–60s. Coding tasks typically take 2–10 minutes."
        ),
        "duration_s": 0,
    }


def check_tmux(session: str) -> dict:
    """Read output and check completion of a running async delegate session."""
    sentinel = STATE_DIR / f"delegate_{session}.done"
    meta_f   = STATE_DIR / f"delegate_{session}.meta"
    log_f    = STATE_DIR / f"delegate_{session}.log"

    meta = {}
    if meta_f.exists():
        try:
            meta = json.loads(meta_f.read_text())
        except Exception:
            pass

    alive = subprocess.run(
        ["tmux", "has-session", "-t", session], capture_output=True
    ).returncode == 0

    # Read from log file (persists after session ends, no escape codes)
    output = ""
    if log_f.exists():
        try:
            lines = log_f.read_text(errors="replace").splitlines()
            output = "\n".join(lines[-200:]).strip()
        except Exception:
            pass
    # Fallback: capture pane directly (may have escape codes but better than nothing)
    if not output and alive:
        try:
            r = subprocess.run(
                ["tmux", "capture-pane", "-t", session, "-p", "-S", "-200"],
                capture_output=True, text=True
            )
            output = r.stdout.strip()
        except Exception:
            pass

    elapsed = round(time.time() - meta.get("started_at", time.time()))

    # Task finished — sentinel written by the wrapper command
    if sentinel.exists():
        try:
            exit_code = int(sentinel.read_text().strip())
        except Exception:
            exit_code = 0
        status = "completed" if exit_code == 0 else "error"

        sentinel.unlink(missing_ok=True)
        meta_f.unlink(missing_ok=True)
        if alive:
            subprocess.run(["tmux", "kill-session", "-t", session], capture_output=True)

        return {
            "status": status,
            "backend": f"tmux/{meta.get('backend','?')}",
            "session": session,
            "result": output or "(no output captured)",
            "exit_code": exit_code,
            "elapsed_s": elapsed,
            "goal": meta.get("goal", "?")[:100],
        }

    # Session died but never wrote sentinel (crash / manual kill)
    if not alive:
        return {
            "status": "ended_unexpectedly",
            "session": session,
            "result": output or "(session ended with no output)",
            "elapsed_s": elapsed,
        }

    # Timeout exceeded while still running — kill it
    timeout_s = meta.get("timeout", 300)
    if elapsed > timeout_s:
        kill_tmux(session)
        return {
            "status": "timeout",
            "session": session,
            "result": f"Exceeded {timeout_s}s timeout. Session killed.\n\nLast output:\n{output}",
            "elapsed_s": elapsed,
        }

    # Still running — return tail of output so far
    return {
        "status": "running",
        "backend": f"tmux/{meta.get('backend','?')}",
        "session": session,
        "elapsed_s": elapsed,
        "result": output or "(running, no output yet)",
        "goal": meta.get("goal", "?")[:100],
        "hint": f"Still running ({elapsed}s elapsed). Poll again in 30–60s.",
    }


def kill_tmux(session: str) -> dict:
    """Kill an async delegate session and clean up state files."""
    sentinel = STATE_DIR / f"delegate_{session}.done"
    meta_f   = STATE_DIR / f"delegate_{session}.meta"

    r = subprocess.run(["tmux", "kill-session", "-t", session], capture_output=True)
    killed = r.returncode == 0
    sentinel.unlink(missing_ok=True)
    meta_f.unlink(missing_ok=True)

    return {
        "status": "killed" if killed else "not_found",
        "session": session,
        "result": f"Session '{session}' {'terminated.' if killed else 'not found (may have already finished).'}",
    }


def list_tmux() -> dict:
    """List all active AMA delegate tmux sessions."""
    try:
        r = subprocess.run(
            ["tmux", "list-sessions", "-F", "#{session_name}|#{session_created}"],
            capture_output=True, text=True
        )
    except FileNotFoundError:
        return {"status": "error", "result": "tmux not installed."}

    sessions = []
    for line in r.stdout.splitlines():
        parts = line.split("|")
        name = parts[0] if parts else ""
        if not name.startswith("ama_"):
            continue
        created = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
        elapsed = round(time.time() - created) if created else "?"
        meta_f  = STATE_DIR / f"delegate_{name}.meta"
        goal = "?"
        if meta_f.exists():
            try:
                goal = json.loads(meta_f.read_text()).get("goal", "?")[:60]
            except Exception:
                pass
        sessions.append({"session": name, "elapsed_s": elapsed, "goal": goal})

    if not sessions:
        return {"status": "ok", "result": "No active delegate sessions."}
    lines = [f"• {s['session']} ({s['elapsed_s']}s) — {s['goal']}" for s in sessions]
    return {"status": "ok", "result": "Active delegate sessions:\n" + "\n".join(lines)}


# ── Auto-detect best backend ──────────────────────────────────────────────────

def detect_backend() -> str:
    """Pick best available authenticated backend: claude → codex → self."""
    if shutil.which("claude"):
        # ANTHROPIC_API_KEY set explicitly — use it, no probe needed
        if os.environ.get("ANTHROPIC_API_KEY"):
            return "claude"
        # Check OAuth credentials file for a valid (or refreshable) token
        creds_file = Path(os.environ.get("HOME") or str(Path.home())) / ".claude" / ".credentials.json"
        if creds_file.exists():
            try:
                creds = json.loads(creds_file.read_text())
                oauth = creds.get("claudeAiOauth", {})
                token = oauth.get("accessToken", "")
                expires_at = oauth.get("expiresAt", 0) / 1000
                refresh_token = oauth.get("refreshToken", "")
                # Valid token OR expired but refreshable
                if token and (time.time() < expires_at or refresh_token):
                    return "claude"
            except Exception:
                pass
    if shutil.which("codex"):
        return "codex"
    return "self"


# ── Format result for agent output ───────────────────────────────────────────

def format_result(r: dict, goal: str) -> str:
    status  = r.get("status", "?")
    backend = r.get("backend", "?")
    result  = r.get("result", "")
    dur     = r.get("duration_s") or r.get("elapsed_s", 0)
    tcs     = r.get("tool_calls", "")
    turns   = r.get("turns", "")
    session = r.get("session", "")

    icon = {
        "completed": "✅", "error": "❌", "timeout": "⏰", "blocked": "🚧",
        "no_response": "❓", "running": "⏳", "killed": "🛑",
        "not_found": "🔍", "ok": "ℹ️", "ended_unexpectedly": "💥",
    }.get(status, "🔧")

    meta = f"[{backend} | {dur}s"
    if session:
        meta += f" | {session}"
    if tcs:
        meta += f" | {tcs} tool calls"
    if turns:
        meta += f" | {turns} turns"
    meta += "]"

    return "\n".join([
        f"{icon} Delegate {status} {meta}",
        f"Goal: {str(goal)[:100]}",
        "─" * 40,
        result,
    ])


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    mode      = os.environ.get("TOOL_mode", "sync").strip().lower()
    goal      = os.environ.get("TOOL_goal", "").strip()
    context   = os.environ.get("TOOL_context", "").strip()
    backend   = os.environ.get("TOOL_backend", "auto").strip().lower()
    timeout   = int(os.environ.get("TOOL_timeout", "300"))
    max_turns = int(os.environ.get("TOOL_max_turns", "20"))
    workdir   = os.environ.get("TOOL_workdir", str(DIR)).strip() or str(DIR)
    session   = os.environ.get("TOOL_session", "").strip()

    # Modes that don't need a goal
    if mode == "check":
        if not session:
            print("Error: TOOL_session is required for mode=check")
            sys.exit(1)
        result = check_tmux(session)
        print(format_result(result, result.get("goal", session)))
        sys.exit(0)

    if mode == "kill":
        if not session:
            print("Error: TOOL_session is required for mode=kill")
            sys.exit(1)
        result = kill_tmux(session)
        print(format_result(result, session))
        sys.exit(0)

    if mode == "list":
        result = list_tmux()
        print(format_result(result, "list delegate sessions"))
        sys.exit(0)

    # Modes that need a goal
    if not goal:
        print("Error: TOOL_goal is required")
        print(__doc__)
        sys.exit(1)

    if mode == "async":
        if backend == "auto":
            backend = detect_backend()
        # self backend doesn't benefit from tmux (pure API loop, no TTY)
        if backend == "self":
            if shutil.which("claude"):
                backend = "claude"
            elif shutil.which("codex"):
                backend = "codex"
            else:
                print("Error: async mode needs claude or codex CLI. Use mode=sync for self backend.")
                sys.exit(1)
        print(f"[delegate/async → tmux/{backend}] {goal[:80]}...")
        result = run_tmux_async(goal, context, timeout, workdir, backend)

    else:  # mode == "sync"
        if backend == "auto":
            backend = detect_backend()
        print(f"[delegate → {backend}] {goal[:80]}...")

        if backend == "claude":
            result = run_claude(goal, context, timeout, workdir)
        elif backend == "codex":
            result = run_codex(goal, context, timeout, workdir)
        elif backend == "self":
            result = run_self(goal, context, timeout, workdir, max_turns)
        else:
            print(f"Unknown backend '{backend}'. Use: claude | codex | self | auto")
            sys.exit(1)

    print(format_result(result, goal))
    sys.stderr.write(f"DELEGATE_RESULT:{json.dumps(result)}\n")
