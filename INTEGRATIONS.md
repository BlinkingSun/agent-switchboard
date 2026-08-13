# Agent Switchboard — using it with any AI agent

Agent Switchboard tracks **lanes** — background agent processes — without
requiring the agents to cooperate. Liveness is derived (pids + output-file
mtimes), so anything you can launch from a shell can be tracked: a Claude
subagent, a Grok Build run, a Codex exec, a plain script.

**The contract is three verbs:**

| Verb | Command | What it does |
|---|---|---|
| dispatch | `agent-dispatch --task T --lane L -- <worker cmd...>` | registers a slot, runs the worker, records its exit code |
| observe | `switchboard status [--task T] [--json]` | derived state of every lane, instantly |
| wait | `switchboard wait --task T [--lane L] [--watch-file F] --timeout 570 [--json]` | blocks until a lane finishes/dies/stalls/needs input, a refuse is logged, or a file changes (exit 0) or timeout (exit 3). `--json` prints the advise payload. |

Plus an HTTP API for tools/UIs on `127.0.0.1:17920` (`switchboard serve`):

| Endpoint | Notes |
|---|---|
| `GET /v1/health` | `version`, `boot_id`, `busy`, `busy_reasons` |
| `GET /v1/tasks` | task list |
| `GET /v1/status[?task=T]` | lanes with derived `state`; terminal rows include `ended_s` |
| `GET /v1/events?task=T` | observation log tail |
| `GET /v1/cli` | spawn-tree forest (`kind`: `claude` \| `grok` \| `agent_dispatch`, plus pid-less virtual `grok-sub` children on grok nodes; optional `model`) |
| `GET /v1/advise?task=T` | current advise payload (closed `next` verbs) |
| `GET /v1/wait?cursor=N[&task=T][&lanes=a,b][&timeout=55]` | long-poll; `gap:true` if cursor behind ring; HTTP 503 + `Retry-After` when wait capacity is full |

Everything is **observe-only**: the switchboard never kills, restarts, or
re-dispatches — your orchestrator reads the alerts and decides. (The viewer
**START DAEMON** button and CLI `--ensure` only kickstart the launchd job for
the daemon itself.) `state/<task>/advise.json` is rewritten on every wait
return and on lane transitions. A sample Claude `SubagentStop` hook at
`bin/exec-master-stop-hook.py` can block an execution-master from ending its
turn while lanes are still ACTIVE.

## The pattern for ANY orchestrating agent

1. Wrap every spawned worker in `agent-dispatch` instead of launching it bare.
   Output redirection, arguments, and the exit code pass straight through.
2. Replace every `sleep`-and-check loop with ONE `switchboard wait --json`
   call — it returns the moment something actually happens and writes
   `state/<task>/advise.json` with a closed `next` verb list. Read that
   payload (or `switchboard advise --task T`) on every wake. Timeout (exit
   3) is a rescan, not an abort.
3. On wake, execute `advise.next` then wait again:
   `review_done:<lane>` → read the lane report now (don't wait for the others).
   `investigate_died:<lane>` → process was killed without finishing.
   `inspect_stalled:<lane>` → alive but silent past the stall budget; inspect,
   do not treat as dead and do not auto-re-dispatch.
   `waiting_input:<lane>` → permission/input prompt.
   `investigate_orphan:<lane>` → wrapper died; worker may still be progressing.
   `retry_refuse:<lane>` → capacity or same-lane refuse (exit 2); try later.
   `QUIET` is not a wake (long compiles). `--alert-quiet` is human-only.

Optional: `switchboard status --ensure` / `wait --ensure` (or
`AGENT_SWITCHBOARD_ENSURE=1`) best-effort starts the daemon before observing
so dashboards and long-polls have a live backend.

## Harness recipes

### Claude Code — primary session
The primary session IS re-invoked when a background Bash task exits — combine
that with the wrapper and you get event-driven fan-out with liveness:

```bash
# dispatch lanes as background tasks (run_in_background), wrapped:
agent-dispatch --task mytask --lane worker-1 -- \
    <worker cmd...> > lane1.log 2>&1
# then END the tool round. Task notifications wake you per completion;
# `switchboard wait --task mytask --timeout 570` is the belt-and-braces
# fallback (Bash timeout 600000). NEVER write `until ...; do sleep 30` loops.
```
Optionally register a `PostToolUse` hook that runs `switchboard status` after
dispatches, so lane state is visible in-transcript.

### Claude Code — Agent-tool subagents (important difference)
A subagent that ends its turn is DONE — it is **not** re-woken by
background-task notifications the way the primary session is. A supervising
subagent (e.g. an execution-master) must therefore stay in its loop and
**block** on `switchboard wait --json` between reviews, and only return once
every watched lane is terminal. Ending its turn with lanes still RUNNING
silently abandons supervision. Optionally register `bin/exec-master-stop-hook.py`
as a Claude `SubagentStop` hook (set `AGENT_SWITCHBOARD_BIN` if `switchboard`
is not next to the hook or on `PATH`).

### Grok Build
Headless Grok runs (`grok -p ... --output-format json`) are just processes:

```bash
agent-dispatch --task mytask --lane research \
    --exec ~/.grok/bin/grok -- -p "..." --output-format json --cwd /work/dir
```
If you drive Grok through a bridge script (e.g. a thin `grok-ask` wrapper),
wrap the bridge — the wrapper reads `-c <channel>` / `-d <cwd>` from the args
and uses Grok's own session files as the activity heartbeat, so QUIET
detection is free. Set `AGENT_SWITCHBOARD_CHANNEL_DIR` if you keep a
channel→sessionId map on disk.

### OpenAI Codex CLI
```bash
agent-dispatch --task mytask --lane refactor \
    --exec codex -- exec --full-auto "refactor X per SPEC.md" 
```
`codex exec` is non-interactive; exit code lands in the slot. Point
`--report` at the file you told Codex to write its summary into.

### Cursor
Cursor's background/CLI agents (`cursor-agent`) wrap the same way:
```bash
agent-dispatch --task mytask --lane fix-tests \
    --exec cursor-agent -- -p "make the test suite green" --output-format text
```
For IDE-side agents you can't wrap, you still get the observe side: have your
orchestrator watch their declared output artifact with
`switchboard wait --watch-file <artifact>`.

### Anything else
If it runs from a shell, `--exec <prog>` wraps it. If you can't wrap it,
`--watch-file` its output. The HTTP long-poll (`/v1/wait?cursor=N`) serves
dashboards, TVs, and other tools without polling cost. The `/v1/cli` forest
classifies live claude/grok processes (and `agent-dispatch` nodes) for the
viewer's CLI SESSIONS panel.

## Notes
- Capacity: the wrapper refuses dispatch past the configured cap (exit 2) —
  backpressure your orchestrator can see, instead of a silent pile-up. The
  cap is **per task**: concurrent tasks each get their own budget
  (`AGENT_SWITCHBOARD_MAX`, default 10).
- QUIET detection reads the worker's own session/log files (for a grok bridge,
  the grok CLI session dir). It is reliable when the lane has a resumed channel
  or a **unique `-d` working dir per lane**; with several fresh sessions
  sharing one cwd, activity may attach to the wrong session — pid liveness
  (RUNNING/DIED) is unaffected.
- `AGENT_SWITCHBOARD_ROOT` relocates all state (useful for tests/CI).
- Memory hygiene: `events.jsonl` rotates at `AGENT_SWITCHBOARD_EVENTS_MAX_BYTES`;
  terminal slots cold-archive after `AGENT_SWITCHBOARD_COLD_AFTER` (default 24h).
- Lifecycle: idle self-exit after `AGENT_SWITCHBOARD_IDLE_GRACE` when no CLI,
  viewer, or active slot is present; `/v1/wait` returns 503 past
  `AGENT_SWITCHBOARD_WAIT_CAP` concurrent waiters.
- Stall: headless silence past `AGENT_SWITCHBOARD_STALL_AFTER` (default 90s)
  becomes `STALLED` and wakes `wait`. Already-`STALLED` / `WAITING_INPUT` at
  wait start returns immediately. `QUIET` still does not wake unless
  `--alert-quiet`.
- Windows: fully supported; liveness uses `OpenProcess`, never `os.kill`
  (which would terminate the probed process on Windows).
- Subscription/billing: pick your worker deliberately — e.g. for grok,
  a CLI on subscription login vs. a paid API entrypoint. The wrapper runs
  whatever `--exec` names; it does not vet billing for you.
