# SPEC — Agent Switchboard viewer frontend (dist/)

You are building the static frontend for **Agent Switchboard**, a read-only
live dashboard over a fleet of AI agent lanes. It runs inside a Tauri 2
webview. NO frameworks, NO bundler, NO external assets, NO emojis anywhere.

## Files you may write (ONLY these)
- dist/index.html
- dist/style.css
- dist/app.js

Do not touch anything else. `node --check dist/app.js` must pass. Plain
ES2020, no modules required (single script tag is fine).

## Data source (the daemon; already running on this machine)
Base URL: `http://127.0.0.1:17920`

GET /v1/status  →
```json
[{"task":"build-alpha","slots":[{"lane":"worker-3","state":"RUNNING",
  "pid":28759,"started":"2026-08-09T00:39:01","age_s":4210,"activity_s":3,
  "exit_code":null,"channel":"ch-build-alpha-3","report":null}]}]
```
states: RUNNING | QUIET | ORPHAN | DONE | FAILED | DIED

GET /v1/health → `{"ok":true,"version":"0.1.0","uptime_s":123,"cursor":42}`

GET /v1/wait?cursor=N&timeout=55 → long-poll; blocks until an observed
transition with seq > N or timeout; →
`{"cursor":57,"events":[{"seq":57,"task":"build-alpha","event":"lane",
  "lane":"worker-1","from":"RUNNING","to":"DONE","ts":"2026-08-09T01:09:12"}]}`
(`event` may also be `"dispatch"`/`"exit"`/`"file"`; render what makes sense,
ignore unknown shapes gracefully.)

## Behavior
1. On load: fetch /v1/health (grab cursor) + /v1/status, render everything.
2. Live loop: long-poll /v1/wait with the cursor; on ANY events, re-fetch
   /v1/status and re-render (cheap and correct beats clever diffing); update
   cursor; loop immediately. On fetch failure: show a slim red "DAEMON
   OFFLINE — retrying" banner under the header and retry with 2s→10s backoff.
3. Also refresh /v1/status every 30s regardless (activity ages tick).
4. Event ticker (bottom, single line): newest-first accumulation of received
   events as `HH:MM:SS lane from→to` segments separated by bullets; keep the
   last ~40 in memory.
5. `?mock=1` in the URL: skip the network entirely and render generated fake
   data — 5 tasks, ~120 lanes with a realistic state mix and drifting
   activity ages, plus a fake event every few seconds. This is how scale is
   verified. Mock generator lives in app.js behind the flag.

## Layout (approved mockup + scale addition — this is binding)
- Slim header: "AGENT SWITCHBOARD" left (monospace, letterspaced), task
  filter chips right ("ALL" + one per task), then global lamp-count totals.
- Main column: one collapsible section per task. Section header row: disclosure
  triangle (CSS, not emoji), task name, mini lamp-count rollup
  (e.g. `7 RUNNING · 1 QUIET · 1 DIED`), collapse persists in localStorage.
  Sections containing DIED or FAILED sort to the top; fully-DONE tasks sink
  to the bottom and start collapsed.
- Within a section, two densities:
  - **Panel** (≤15 lanes): patch-panel rows like the approved mockup — big
    circular glowing lamp, lane name (mono, large), `UP 2h 11m`,
    `activity 3s ago`, `EXIT 0`, channel name dimmed.
  - **Grid** (>15 lanes, or when the header density toggle says so): dense
    responsive grid of small cells — lamp dot + lane name + tiny age. Cell
    ~150px wide. 100+ lanes must fit on one screen with at most light
    scrolling. Hovering a cell shows a tooltip with the full row data
    (title attribute is fine).
  - Header has a global density toggle: AUTO / PANEL / GRID (localStorage).
- Right rail: summary tiles — RUNNING, QUIET, DIED, FAILED, DONE with big
  mono numbers; DIED/FAILED tiles get a red accent when nonzero. Clicking a
  tile filters all sections to that state (click again to clear).
- Bottom: the one-line event ticker.

## Aesthetic (from the approved mockup — match it closely)
- Near-black layered charcoal (#0b0e12 page, #14181f panels, #1b212a slots),
  1px #262d38 borders, subtle inner shadows for the patch-panel feel.
- Lamps: radial-gradient circles with soft outer glow. Green #35d07a
  RUNNING · amber #e0a52e QUIET · red #e5484d DIED and FAILED (FAILED lamp
  steady, DIED lamp slow 1.5s pulse) · dim #4a5261 DONE · ORPHAN = hollow
  ring (border only, amber).
- Text: monospace stack `"SF Mono", ui-monospace, Menlo, Consolas, monospace`;
  muted grey #8b93a1 secondary, #e8ecf2 primary; state words colored like
  their lamps. NO emojis, NO icon fonts, NO images.
- Motion: lamp glow pulse on DIED, 150ms ease on hover/collapse. Nothing
  gratuitous.

## Acceptance criteria
- `node --check dist/app.js` exits 0.
- `?mock=1` renders 5 tasks / ~120 lanes instantly, readable, no horizontal
  page scroll, sections auto-switch to Grid where >15 lanes.
- With the daemon up, the real view renders and a lane state change appears
  without a manual refresh (long-poll loop works, cursor advances).
- Zero network requests except to 127.0.0.1:17920; zero external resources.
- Works at 720px width without breakage (rail wraps under, ticker truncates).

Reply DONE / DECISIONS / OPEN / TEST / BLOCKERS / FILES CHANGED.
