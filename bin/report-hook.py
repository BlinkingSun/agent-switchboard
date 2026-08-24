#!/usr/bin/env python3
"""Claude Code lifecycle hook → POST /v1/report.

Reads hook JSON on stdin. Reports SessionStart / SessionEnd / SubagentStart /
SubagentStop as ledger start/end. Ignores Stop (per-turn, not per-session)
and every other event. Fail-open: always exits 0, never prints to stdout,
never blocks the turn.

Lookup order for the switchboard binary:
  $AGENT_SWITCHBOARD_BIN, then $SB_BIN, then a `switchboard` next to this
  hook, then `switchboard` on PATH.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

ENSURE_TIMEOUT_S = 0.6
POST_TIMEOUT_S = 0.3
PS_TIMEOUT_S = 0.2
LOG_MAX_BYTES = 64 * 1024

# SessionStart sources that are actual session births. compact is the same
# session continuing; /clear is a new conversation in the SAME process so
# it cannot mint a new p:<pid>:<lstart> identity.
_SESSION_START_SOURCES = frozenset({"startup", "resume", "fork"})
# SessionEnd fires on /clear and interactive /resume too (process stays
# alive with the same pid+lstart). Only the process-exit reasons are ends.
_SESSION_END_REASONS = frozenset({"logout", "prompt_input_exit", "other"})


def _find_switchboard():
    for key in ("AGENT_SWITCHBOARD_BIN", "SB_BIN"):
        env = os.environ.get(key)
        if env:
            return env
    here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "switchboard")
    if os.path.isfile(here):
        return here
    found = shutil.which("switchboard")
    return found or "switchboard"


def _state_root():
    return os.environ.get(
        "AGENT_SWITCHBOARD_ROOT",
        os.path.expanduser("~/.agent-switchboard/state"),
    )


def _log(msg):
    """Best-effort append to a small local file. Never raises, never stdout."""
    try:
        root = _state_root()
        os.makedirs(root, exist_ok=True)
        path = os.path.join(root, "report-hook.log")
        line = msg if msg.endswith("\n") else msg + "\n"
        try:
            if os.path.getsize(path) > LOG_MAX_BYTES:
                os.replace(path, path + ".1")
        except OSError:
            pass
        with open(path, "a") as f:
            f.write(line)
    except Exception:
        pass


def _parent_pid():
    """Hook runs as a direct child of the real claude process."""
    return os.getppid()


def _lstart(pid):
    """Raw `ps -o lstart=` of pid, stripped. Same source the daemon snapshots."""
    out = subprocess.check_output(
        ["ps", "-o", "lstart=", "-p", str(int(pid))],
        text=True,
        stderr=subprocess.DEVNULL,
        timeout=PS_TIMEOUT_S,
    )
    ls = (out or "").strip()
    if not ls:
        raise RuntimeError("empty lstart for pid %s" % pid)
    return ls


def _p_id(pid, lstart):
    """Same whitespace-collapse as switchboard._ledger_id_os."""
    collapsed = re.sub(r"\s+", "-", (lstart or "").strip())
    return "p:%s:%s" % (pid, collapsed)


def _report_url():
    host = os.environ.get("AGENT_SWITCHBOARD_HOST", "127.0.0.1")
    port = os.environ.get("AGENT_SWITCHBOARD_PORT", "17920")
    return "http://%s:%s/v1/report" % (host, port)


def _ensure(sb):
    subprocess.run(
        [sys.executable, sb, "status", "--ensure", "--json"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=ENSURE_TIMEOUT_S,
    )


def _post(body):
    raw = json.dumps(body, separators=(",", ":")).encode("utf-8")
    req = urllib.request.Request(
        _report_url(),
        data=raw,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Content-Length": str(len(raw)),
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=POST_TIMEOUT_S) as resp:
            code = getattr(resp, "status", None) or resp.getcode()
            if code != 200:
                _log("POST %s -> %s" % (_report_url(), code))
    except urllib.error.HTTPError as e:
        _log("POST %s HTTP %s" % (_report_url(), e.code))
    except Exception as e:
        _log("POST %s failed: %s" % (_report_url(), e))


def _opt_cwd(event):
    cwd = event.get("cwd")
    if isinstance(cwd, str) and cwd.strip():
        return cwd.strip()
    return None


def _session_body(event_name, event):
    """SessionStart / SessionEnd → p:<ppid>:<parent-lstart>."""
    ppid = _parent_pid()
    lstart = _lstart(ppid)
    body = {
        "event": "start" if event_name == "SessionStart" else "end",
        "id": _p_id(ppid, lstart),
        "pid": int(ppid),
        "lstart": lstart,
        "role": "claude-interactive",
    }
    cwd = _opt_cwd(event)
    if cwd:
        body["cwd"] = cwd
    return body


def _subagent_body(event_name, event):
    """SubagentStart / SubagentStop → cs:<session_id>:<agent_id>, no pid."""
    session_id = event.get("session_id")
    agent_id = event.get("agent_id")
    if not isinstance(session_id, str) or not session_id.strip():
        raise RuntimeError("missing session_id")
    if not isinstance(agent_id, str) or not agent_id.strip():
        raise RuntimeError("missing agent_id")
    session_id = session_id.strip()
    agent_id = agent_id.strip()
    body = {
        "event": "start" if event_name == "SubagentStart" else "end",
        "id": "cs:%s:%s" % (session_id, agent_id),
        "role": "claude-sub",
        "session_id": session_id,
    }
    if event_name == "SubagentStart":
        ppid = _parent_pid()
        lstart = _lstart(ppid)
        body["parents"] = [_p_id(ppid, lstart)]
        cwd = _opt_cwd(event)
        if cwd:
            body["cwd"] = cwd
        # SubagentStart payloads have no description/prompt/tool_input.
        # Do not invent a label from agent_type.
    return body


def build_report(event):
    """Return the POST body for a hook payload, or None to skip."""
    if not isinstance(event, dict):
        return None
    name = event.get("hook_event_name")
    if name == "SessionStart":
        source = event.get("source")
        if source not in _SESSION_START_SOURCES:
            return None
        return _session_body(name, event)
    if name == "SessionEnd":
        if event.get("reason") not in _SESSION_END_REASONS:
            return None
        return _session_body(name, event)
    if name == "SubagentStart":
        return _subagent_body(name, event)
    if name == "SubagentStop":
        return _subagent_body(name, event)
    return None


def main():
    try:
        raw = sys.stdin.read()
        event = json.loads(raw) if raw.strip() else {}
    except Exception as e:
        _log("stdin: %s" % e)
        return

    try:
        body = build_report(event)
    except Exception as e:
        _log("build: %s" % e)
        return
    if body is None:
        return

    sb = _find_switchboard()
    try:
        _ensure(sb)
    except Exception as e:
        _log("ensure: %s" % e)

    try:
        _post(body)
    except Exception as e:
        _log("post: %s" % e)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        _log("fatal: %s" % e)
    sys.exit(0)
