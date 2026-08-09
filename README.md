# Agent Switchboard

<img src="assets/icon.png" width="128" align="right" alt="Agent Switchboard icon">

**A patch panel for your AI agent fleet.** Track every spawned agent as a
"lane" with a live derived state — no polling loops, no self-reported
heartbeats, no silent deaths — plus a native dashboard for watching 100+
agents across concurrent orchestrations.

Born from a measured pathology: a 7-hour multi-agent build in which the
coordinating agent spent **309 of its 448 minutes blocked inside blind
`sleep 30` polling loops**, and one worker process was silently killed and
sat undetected for ~70 minutes because a log file read "still running."
Agent Switchboard replaces that pattern with derived liveness and
event-driven waits.

![Dashboard with 123 lanes across 5 tasks](assets/dashboard-123-lanes.png)

## How it works

Workers never have to cooperate or heartbeat. The wrapper records facts at
dispatch (pids, program identity, start time); the CLI/daemon derives state
from what the OS already knows:

| State | Meaning |
|---|---|
| `RUNNING` | worker alive, activity fresh (or unknown) |
| `QUIET` | worker alive but silent past a threshold — warning, not failure |
| `ORPHAN` | worker alive but its wrapper died; exit will never be auto-recorded |
| `DONE` / `FAILED` | wrapper recorded exit 0 / non-zero |
| `DIED` | worker **and** wrapper gone without finalizing — the silent kill |
| `CORRUPT` | slot file unreadable — surfaced, never silently dropped |

**Observe/alert only, by design:** the switchboard never kills, restarts, or
re-dispatches anything. It tells your orchestrator; your orchestrator decides.

## The three verbs

```bash
# dispatch — wrap any worker; args, redirections, and exit code pass through
agent-dispatch --task mytask --lane worker-1 --exec <prog> -- <args...> > lane1.log 2>&1

# observe — derived state of every lane, instantly
switchboard status [--task mytask] [--json]

# wait — block until a lane finishes/dies or a file changes (exit 0), or timeout (exit 3)
switchboard wait --task mytask [--lane worker-1] [--watch-file PHASE.txt] --timeout 570
```

`agent-dispatch` also enforces a per-task capacity cap (refusal = exit 2,
nothing starts) and refuses to double-dispatch a lane whose worker is still
alive. Dispatch decisions are lock-serialized, finalization is
ownership-checked (`run_id`), and pid liveness is identity-checked against
the process table so a recycled pid can't fake a live lane.

## Background service + HTTP API

```bash
switchboard serve            # 127.0.0.1:17920, read-only
```

`GET /v1/health` · `GET /v1/tasks` · `GET /v1/status[?task=T]` ·
`GET /v1/events?task=T` · long-poll `GET /v1/wait?cursor=N[&task=T]` —
returns within ~1s of any observed transition. Autostart templates for
launchd / systemd / Task Scheduler are in [`service/`](service/).

## Viewer app

A Tauri 2 desktop app (macOS + Windows) renders the daemon live: collapsible
per-task sections, panel rows or dense lamp grid (auto past 15 lanes),
attention-sorted DIED/FAILED, clickable state-filter tiles, event ticker.
Grab the signed DMG from [Releases](../../releases), or build it yourself:

```bash
cd viewer && npx @tauri-apps/cli@^2 build   # needs Rust + platform toolchain
```

Frontend is framework-free static HTML/CSS/JS; `viewer/dist/index.html?mock=1`
renders a 123-lane demo with no daemon at all.

## Integrating your harness

See [INTEGRATIONS.md](INTEGRATIONS.md) for the general pattern plus concrete
recipes: **Claude Code** (primary sessions vs subagents — they wait
differently, and getting this wrong silently abandons supervision),
**Grok Build**, **OpenAI Codex CLI**, **Cursor**, and anything else you can
launch from a shell.

## Configuration

| Env | Default | |
|---|---|---|
| `AGENT_SWITCHBOARD_ROOT` | `~/.agent-switchboard/state` | state location |
| `AGENT_SWITCHBOARD_WORKER` | *(unset)* | default `--exec` worker |
| `AGENT_SWITCHBOARD_MAX` | `10` | per-task capacity cap |

Python 3.9+ stdlib only — no dependencies. macOS / Linux / Windows.
(Windows liveness uses `OpenProcess` via ctypes; `os.kill(pid, 0)` there
would *terminate* the probed process — don't roll your own with it.)

## Tests

```bash
bash tests/sb_test.sh    # 29 checks in an isolated temp state root
```

Covers the happy paths and the dangerous ones: silent kills, the
finalize-window DIED false alarm, stale-wrapper clobbering, parallel
capacity races, corrupt slots, orphan lanes, path-escape names.

## License

MIT — see [LICENSE](LICENSE).
