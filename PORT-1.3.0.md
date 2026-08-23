# OSS Port Report — Agent Switchboard 1.3.0

**Date:** 2026-08-13  
**Staging repo:** `/Users/jroberts/oss-widgets/agent-switchboard`  
**Canonical:** private Agent Switchboard **0.3.0** (`~/agent-team/bin/switchboard` etc.)  
**Git:** no commit / no push (orchestrator owns git). Full test suite not run here.

## Status

| Field | Value |
|---|---|
| **DONE** | Feature port + sanitization + docs + `VERSION = "1.3.0"` |
| **TEST** | `python3 -m py_compile` on `bin/switchboard`, `bin/agent-dispatch`, `bin/exec-master-stop-hook.py`. Kind smoke: both `agent-dispatch` and `team-dispatch` classify as keep-kind; `_KIND_OUT` emits `agent_dispatch`. |
| **OPEN** | Orchestrator should run `bash tests/sb_test.sh` (canonical 0.3.0 suite was 89/89). |
| **BLOCKERS** | None known |

## Files changed

| Path | Notes |
|---|---|
| `bin/switchboard` | 0.3.0 → **1.3.0**. New states, advise, stall, model truth, launcher reattach, `/v1/advise`. OSS env/naming. |
| `bin/agent-dispatch` | Port of `team-dispatch`. Refuse events, `launcher_cli_*`, `wrapper_base`. Worker/cap from env. |
| `bin/exec-master-stop-hook.py` | **New** sanitized sample `SubagentStop` hook. |
| `tests/sb_test.sh` | OSS env/wrapper names; T23/T35 fixtures generic; **T35–T39** ported. |
| `viewer/dist/{app.js,index.html,style.css}` | 0.3.0 UI states + sanitized mock forest. |
| `README.md` | 1.3.0 features merged; OSS naming kept. |
| `INTEGRATIONS.md` | advise / stall / hook / `/v1/advise` merged. |
| `PORT-1.3.0.md` | This report. |

Not touched: `~/agent-team`, live `state/`, `_team/`, `viewer/src-tauri` (tauri.conf stays **1.1.0**).

## 1.3.0 features ported

- Derived states: `WORKING_TOOL`, `WAITING_INPUT`, `STALLED`
- `switchboard wait --json` writes `state/<task>/advise.json`; `switchboard advise`; `GET /v1/advise`
- Closed `next` verbs (`review_done`, `inspect_stalled`, `investigate_died`, `investigate_orphan`, `retry_refuse`, …)
- `agent-dispatch` emits `refuse` before exit 2
- `launcher_cli_pid` recorded at dispatch; forest reattach / `tree_orphans`
- Model resolution: argv `-m` → session `current_model_id` → `[models].default` → `null` (no hardcoded `grok-4.5`)
- `grok leader` excluded from the forest
- Sample `SubagentStop` hook (fail-open)

## Sanitization

| Canonical | OSS |
|---|---|
| `TEAM_SWITCHBOARD_ROOT` / `~/agent-team/switchboard/state` | `AGENT_SWITCHBOARD_ROOT` / `~/.agent-switchboard/state` |
| `SWITCHBOARD_*` knobs | `AGENT_SWITCHBOARD_*` (incl. `STALL_*`, `GROK_*`, `CLAUDE_*`) |
| `team-dispatch` / public kind `team_dispatch` | `agent-dispatch` / `agent_dispatch` |
| `com.blinkingsun.switchboard` | `com.agent-switchboard` |
| `~/grok-bridge/bin/grok-ask` | `$AGENT_SWITCHBOARD_WORKER` (required if unset) |
| `team.json` caps | `AGENT_SWITCHBOARD_MAX` |
| `TEAM_JSON` / channel hardcodes | `AGENT_SWITCHBOARD_CHANNEL_DIR` |
| `TEAM_EXEC_MASTER` | `AGENT_SWITCHBOARD_EXEC_MASTER` |
| Hook `~/agent-team/bin/switchboard` | next to hook, then `AGENT_SWITCHBOARD_BIN` / `SB_BIN` / PATH |
| Private slugs/paths | `mytask`, `demo-task`, `/usr/local/bin/…`, `/tmp/lane` |

Internal keep-kind is **`agent_dispatch`** (matches existing OSS 1.2.0 public enum). `kind_from_command` still accepts basename **`team-dispatch`** for live compat; `_KIND_OUT` always emits `agent_dispatch`.

## Leak-audit leftovers

Grep of `bin/`, `tests/`, `viewer/dist/`, `INTEGRATIONS.md`, `README.md` for  
`jroberts|agent-team|blinkingsun|studio-pro|sbhard|sidecar|grok-bridge|TEAM_SWITCHBOARD|com.blinkingsun`  
→ **CLEAN**.

**Intentional (not leaks):**

- Detect alias `team-dispatch` in `kind_from_command` / flag parser / hook needles
- Viewer mock + `formatModelLabel` **display sample** `grok-4.5` (not a model default)
- T35 asserts model is **never** hardcoded `grok-4.5`

No hardcoded `grok-4.5` fallback in `bin/switchboard` or `bin/agent-dispatch`.

## How to run tests

From the staging root (suite sets `AGENT_SWITCHBOARD_ENSURE_DISABLE=1`):

```bash
cd /Users/jroberts/oss-widgets/agent-switchboard
bash tests/sb_test.sh
```

Optional overrides: `SB_BIN`, `TD_BIN`, `AGENT_SWITCHBOARD_ROOT`.  
Expect T1–T39 (canonical 0.3.0 was **89/89**).
