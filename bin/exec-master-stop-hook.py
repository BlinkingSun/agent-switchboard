#!/usr/bin/env python3
"""SubagentStop gate — keep an execution-master in its wait loop.

An Agent-tool exec-master is NOT re-woken by background-task notifications
after it ends its turn. If it returns while switchboard still has ACTIVE
lanes (or ready-for-audit work), supervision is silently abandoned.

This hook blocks that turn-end when the stopping agent looks like an
exec-master AND any switchboard slot is still live. Observe-only: it
never kills or re-dispatches anything.

Stdin: Claude Code hook JSON (SubagentStop).
Stdout: {"decision":"block","reason": "..."} or empty allow.
Exit 0 always (fail-open on parse/status errors).

Lookup order for the switchboard binary:
  $AGENT_SWITCHBOARD_BIN, then $SB_BIN, then a `switchboard` next to this
  hook, then `switchboard` on PATH.
"""
import json
import os
import shutil
import subprocess
import sys

ACTIVE = {
    "RUNNING",
    "WORKING_TOOL",
    "WAITING_INPUT",
    "QUIET",
    "STALLED",
    "ORPHAN",
    "CORRUPT",
}
NEEDLES = (
    "execution-master",
    "exec-master",
    "switchboard wait",
    "agent-dispatch",
    "team-dispatch",
    "execution master",
)


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


def _allow():
    sys.exit(0)


def _block(reason):
    payload = {
        "decision": "block",
        "reason": reason,
        "hookSpecificOutput": {
            "hookEventName": "SubagentStop",
            "decision": "block",
            "reason": reason,
        },
    }
    print(json.dumps(payload))
    sys.exit(0)


def looks_like_exec_master(event):
    if os.environ.get("AGENT_SWITCHBOARD_EXEC_MASTER") == "1":
        return True
    blob = json.dumps(event, default=str).lower()
    if any(n in blob for n in NEEDLES):
        return True
    cwd = event.get("cwd") or ""
    for rel in ("MASTER-OWNER", os.path.join(".switchboard", "exec-master")):
        owner = os.path.join(cwd, rel)
        try:
            text = open(owner).read().strip().lower()
        except OSError:
            text = ""
        if text in ("exec-master", "execution-master", "execution_master", "1"):
            return True
    return False


def active_slots():
    try:
        out = subprocess.check_output(
            [sys.executable, _find_switchboard(), "status", "--json"],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=4,
        )
        data = json.loads(out)
    except Exception:
        return []
    found = []
    for task in data or []:
        name = task.get("task")
        for s in task.get("slots") or []:
            if s.get("state") in ACTIVE:
                found.append("%s/%s:%s" % (name, s.get("lane"), s.get("state")))
    return found


def main():
    try:
        raw = sys.stdin.read()
        event = json.loads(raw) if raw.strip() else {}
    except Exception:
        _allow()

    if not looks_like_exec_master(event):
        _allow()

    live = active_slots()
    if not live:
        _allow()

    # Prefer a task name from the first live slot.
    task = live[0].split("/", 1)[0]
    reason = (
        "Exec-master still has live switchboard lanes (%s). "
        "Do not end the turn. Block on: "
        "switchboard wait --task %s --json --timeout 570 "
        "then read advise.json next= verbs. Observe-only: do not kill lanes."
        % (", ".join(live[:8]), task)
    )
    _block(reason)


if __name__ == "__main__":
    main()
