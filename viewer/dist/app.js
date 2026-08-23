/* Agent Switchboard viewer — plain ES2020, no modules, no frameworks */
(function () {
  "use strict";

  /* ════════════════════════════════════════════════════
   * PURE functions (no DOM) — ordering guard + self-test
   * Exported on window.__sbTest / global.__sbTest
   * ════════════════════════════════════════════════════ */

  /**
   * Monotonic apply-ordering guard.
   * Every fetch is tagged with a rising seq; apply only if seq > lastApplied.
   * @param {number} fetchSeq
   * @param {number} lastAppliedSeq
   * @returns {boolean}
   */
  function shouldApplyStatus(fetchSeq, lastAppliedSeq) {
    if (typeof fetchSeq !== "number" || !isFinite(fetchSeq)) return false;
    var last =
      typeof lastAppliedSeq === "number" && isFinite(lastAppliedSeq)
        ? lastAppliedSeq
        : -1;
    return fetchSeq > last;
  }

  /**
   * Apply or drop a payload under the ordering guard.
   * @returns {{applied:boolean, lastAppliedSeq:number, payload:*} }
   */
  function applyOrderingResult(fetchSeq, lastAppliedSeq, payload) {
    if (!shouldApplyStatus(fetchSeq, lastAppliedSeq)) {
      return {
        applied: false,
        lastAppliedSeq:
          typeof lastAppliedSeq === "number" && isFinite(lastAppliedSeq)
            ? lastAppliedSeq
            : -1,
        payload: null,
      };
    }
    return { applied: true, lastAppliedSeq: fetchSeq, payload: payload };
  }

  /**
   * Stable tree-collapse identity: pid + started (never raw pid alone).
   * pids churn / reuse; started anchors the process identity.
   */
  function cliNodeCollapseKey(node) {
    if (!node) return "";
    if (node.pid == null) {
      if (node.subagent_id) return "sub:" + String(node.subagent_id);
      return "";
    }
    var started =
      node.started != null && node.started !== ""
        ? String(node.started)
        : "";
    return String(node.pid) + ":" + started;
  }

  /**
   * Family for a CLI tree node. Wrappers (agent_dispatch) return null.
   * grok-sub counts as grok; cursor-sub counts as cursor.
   */
  function cliFamily(kind) {
    if (kind === "claude" || kind === "claude-sub") return "claude";
    if (kind === "grok" || kind === "grok-sub") return "grok";
    if (kind === "cursor" || kind === "cursor-sub") return "cursor";
    return null;
  }

  /**
   * Counts every live agent instance: sessions AND subagents.
   * Excludes agent_dispatch wrappers. kind enum:
   *   claude | grok | cursor | grok-sub | cursor-sub | agent_dispatch
   */
  function countCliKinds(roots) {
    var c = { claude: 0, grok: 0, cursor: 0 };
    function walk(nodes) {
      if (!nodes) return;
      for (var i = 0; i < nodes.length; i++) {
        var n = nodes[i];
        var fam = cliFamily(n.kind);
        if (fam) c[fam]++;
        if (n.children && n.children.length) walk(n.children);
      }
    }
    walk(roots || []);
    return c;
  }

  /**
   * Flatten /v1/cli counts whether nested
   *   {claude:{interactive,headless}, grok_subagents:N}
   * or already flat {claude:N, grok:N, cursor:N}.
   */
  function flattenCliCounts(counts) {
    var out = { claude: 0, grok: 0, cursor: 0 };
    if (!counts || typeof counts !== "object") return out;
    function fam(key) {
      var v = counts[key];
      if (typeof v === "number") return v;
      if (v && typeof v === "object") {
        return (v.interactive || 0) + (v.headless || 0);
      }
      return 0;
    }
    out.claude = fam("claude");
    out.grok = fam("grok") + (counts.grok_subagents || 0);
    out.cursor = fam("cursor") + (counts.cursor_subagents || 0);
    return out;
  }

  /** Fixed display order for the CLI harness families. */
  var CLI_FAMILIES = ["claude", "grok", "cursor"];

  /**
   * Harness families with at least one live instance, in display order.
   * A harness with nothing running is omitted entirely — a machine without
   * grok or cursor installed never sees those names in the bar.
   * @returns {Array<{key:string, n:number}>}
   */
  function liveCliFamilies(counts) {
    var out = [];
    if (!counts) return out;
    for (var i = 0; i < CLI_FAMILIES.length; i++) {
      var k = CLI_FAMILIES[i];
      var n = counts[k] || 0;
      if (n > 0) out.push({ key: k, n: n });
    }
    return out;
  }

  /**
   * display label for node.model.
   * Truncate long ids to family name: claude-fable-5 -> fable.
   * Short names (opus, sonnet, grok-4.5, default) pass through.
   * @returns {string|null} null when nothing to show
   */
  function formatModelLabel(model) {
    if (model == null || model === "") return null;
    var s = String(model).trim();
    if (!s) return null;
    // claude-<family>(-<rest>...) → family (e.g. claude-fable-5 → fable)
    var m = /^claude-([A-Za-z][\w]*)(?:-[\w.]+)*$/i.exec(s);
    if (m && m[1]) return m[1];
    return s;
  }

  function runApplyOrderingSelfTest() {
    var results = [];
    function check(name, cond) {
      results.push({ name: name, ok: !!cond });
    }

    // Basic comparisons
    check("apply 1 over 0", shouldApplyStatus(1, 0) === true);
    check("reject equal", shouldApplyStatus(2, 2) === false);
    check("reject stale", shouldApplyStatus(1, 5) === false);
    check("apply newer", shouldApplyStatus(6, 5) === true);
    check("reject non-number seq", shouldApplyStatus(null, 0) === false);
    check("reject NaN", shouldApplyStatus(NaN, 0) === false);
    check("treat missing last as -1", shouldApplyStatus(0, undefined) === true);

    // Concurrent refresh scenario: tick( gen2 ) returns before wait( gen1 )
    var last = 0;
    var a = applyOrderingResult(1, last, { slots: "old" });
    check("seq1 applied", a.applied === true && a.lastAppliedSeq === 1);
    last = a.lastAppliedSeq;
    var b = applyOrderingResult(2, last, { slots: "new" });
    check("seq2 applied", b.applied === true && b.payload.slots === "new");
    last = b.lastAppliedSeq;
    var stale = applyOrderingResult(1, last, { slots: "old-again" });
    check(
      "stale seq1 dropped after seq2",
      stale.applied === false && stale.lastAppliedSeq === 2 && stale.payload === null
    );

    // Out-of-order: gen5 finishes first, then gen3 and gen4 drop
    last = 0;
    var g5 = applyOrderingResult(5, last, "five");
    last = g5.lastAppliedSeq;
    check("g5 wins", last === 5 && g5.applied);
    check("g3 drops", applyOrderingResult(3, last, "three").applied === false);
    check("g4 drops", applyOrderingResult(4, last, "four").applied === false);
    check("g6 applies", applyOrderingResult(6, last, "six").applied === true);

    // Collapse key stability (T3)
    check(
      "collapse key pid+started",
      cliNodeCollapseKey({ pid: 42, started: "2026-08-09T12:00:00" }) ===
        "42:2026-08-09T12:00:00"
    );
    check(
      "collapse key not raw pid",
      cliNodeCollapseKey({ pid: 42, started: "a" }) !== "42" &&
        cliNodeCollapseKey({ pid: 42, started: "a" }).indexOf(":") !== -1
    );
    check(
      "same pid different started differ",
      cliNodeCollapseKey({ pid: 9, started: "t1" }) !==
        cliNodeCollapseKey({ pid: 9, started: "t2" })
    );

    // Counts exclude agent_dispatch (T5)
    var roots = [
      {
        kind: "claude",
        children: [
          {
            kind: "agent_dispatch",
            children: [{ kind: "grok", children: [] }],
          },
        ],
      },
      { kind: "grok", children: [] },
    ];
    var cnt = countCliKinds(roots);
    check("count claude=1", cnt.claude === 1);
    check("count grok=2", cnt.grok === 2);
    check("count cursor=0", cnt.cursor === 0);
    check("agent_dispatch not in counts", cnt.claude + cnt.grok + cnt.cursor === 3);

    var withSubs = [
      {
        kind: "claude",
        children: [
          {
            kind: "agent_dispatch",
            children: [
              {
                kind: "grok",
                children: [{ kind: "grok-sub", children: [] }],
              },
              {
                kind: "cursor",
                children: [{ kind: "cursor-sub", children: [] }],
              },
            ],
          },
        ],
      },
    ];
    var c2 = countCliKinds(withSubs);
    check("subagents count as family", c2.claude === 1 && c2.grok === 2 && c2.cursor === 2);
    check("live includes subagents", c2.claude + c2.grok + c2.cursor === 5);
    var flat = flattenCliCounts({
      claude: { interactive: 2, headless: 0 },
      grok: { interactive: 1, headless: 0 },
      cursor: { interactive: 1, headless: 1 },
      grok_subagents: 3,
      cursor_subagents: 1,
    });
    check("flatten nested + subagents", flat.claude === 2 && flat.grok === 4 && flat.cursor === 3);

    // Harness chips: only families with live instances are named (T40)
    var famAll = liveCliFamilies({ claude: 2, grok: 2, cursor: 3 });
    check(
      "all three live -> all three named",
      famAll.length === 3 &&
        famAll[0].key === "claude" &&
        famAll[1].key === "grok" &&
        famAll[2].key === "cursor"
    );
    var famSolo = liveCliFamilies({ claude: 1, grok: 0, cursor: 0 });
    check(
      "claude only -> grok/cursor hidden",
      famSolo.length === 1 && famSolo[0].key === "claude" && famSolo[0].n === 1
    );
    var famGap = liveCliFamilies({ claude: 0, grok: 0, cursor: 4 });
    check(
      "cursor only -> order preserved, claude hidden",
      famGap.length === 1 && famGap[0].key === "cursor" && famGap[0].n === 4
    );
    check("no families live -> empty", liveCliFamilies({ claude: 0, grok: 0, cursor: 0 }).length === 0);
    check("missing keys treated as zero", liveCliFamilies({ claude: 3 }).length === 1);
    check("null counts -> empty", liveCliFamilies(null).length === 0);

    // model family truncation
    check("model null -> null", formatModelLabel(null) === null);
    check("model empty -> null", formatModelLabel("") === null);
    check("model claude-fable-5 -> fable", formatModelLabel("claude-fable-5") === "fable");
    check("model opus passthrough", formatModelLabel("opus") === "opus");
    check("model sonnet passthrough", formatModelLabel("sonnet") === "sonnet");
    check("model grok-4.5 passthrough", formatModelLabel("grok-4.5") === "grok-4.5");
    check("model grok-4.6 passthrough", formatModelLabel("grok-4.6") === "grok-4.6");
    check("model default passthrough", formatModelLabel("default") === "default");
    check("model auto passthrough", formatModelLabel("auto") === "auto");
    check("model composer passthrough", formatModelLabel("composer") === "composer");

    var failed = [];
    for (var i = 0; i < results.length; i++) {
      if (!results[i].ok) failed.push(results[i].name);
    }
    return {
      ok: failed.length === 0,
      pass: results.length - failed.length,
      fail: failed.length,
      total: results.length,
      failed: failed,
      results: results,
    };
  }

  var __sbTest = {
    shouldApplyStatus: shouldApplyStatus,
    applyOrderingResult: applyOrderingResult,
    cliNodeCollapseKey: cliNodeCollapseKey,
    countCliKinds: countCliKinds,
    flattenCliCounts: flattenCliCounts,
    cliFamily: cliFamily,
    liveCliFamilies: liveCliFamilies,
    formatModelLabel: formatModelLabel,
    runApplyOrderingSelfTest: runApplyOrderingSelfTest,
  };
  if (typeof window !== "undefined") window.__sbTest = __sbTest;
  if (typeof globalThis !== "undefined") globalThis.__sbTest = __sbTest;

  // Headless entry: `node app.js` runs the self-test and exits.
  if (typeof document === "undefined") {
    var report = runApplyOrderingSelfTest();
    var line =
      "apply-ordering self-test: " +
      (report.ok ? "PASS" : "FAIL") +
      " " +
      report.pass +
      "/" +
      report.total;
    if (typeof console !== "undefined" && console.log) {
      console.log(line);
      if (!report.ok) console.log(JSON.stringify(report, null, 2));
      else console.log(JSON.stringify({ ok: true, pass: report.pass, total: report.total }));
    }
    if (typeof process !== "undefined" && process.exit) {
      process.exit(report.ok ? 0 : 1);
    }
    return;
  }

  /* ════════════════════════════════════════════════════
   * DOM app
   * ════════════════════════════════════════════════════ */

  var BASE = "http://127.0.0.1:17920";
  var STATES = ["RUNNING", "WORKING_TOOL", "WAITING_INPUT", "QUIET", "STALLED", "ORPHAN", "DONE", "FAILED", "DIED"];
  var TILE_STATES = ["RUNNING", "WORKING_TOOL", "WAITING_INPUT", "QUIET", "STALLED", "DIED", "FAILED", "DONE"];
  var MAX_EVENTS = 40;
  var STATUS_INTERVAL_MS = 30000;
  var RETENTION_S = 1800; // finished lanes drop off the board after 30 min
  var LIVE_STATES = { RUNNING: 1, WORKING_TOOL: 1, WAITING_INPUT: 1, QUIET: 1, STALLED: 1, ORPHAN: 1, CORRUPT: 1 };
  var BACKOFF_MIN = 2000;
  var BACKOFF_MAX = 10000;

  var els = {
    app: document.getElementById("app"),
    edgeHost: document.getElementById("edge-host"),
    edgeFrame: document.getElementById("edge-frame"),
    sourceBadge: document.getElementById("source-badge"),
    chips: document.getElementById("task-chips"),
    totals: document.getElementById("global-totals"),
    density: document.getElementById("density-toggle"),
    offline: document.getElementById("offline-banner"),
    startBtn: document.getElementById("start-daemon-btn"),
    main: document.getElementById("main"),
    rail: document.getElementById("rail"),
    tickerInner: document.getElementById("ticker-inner"),
  };

  var state = {
    mock: false,
    fixture: false,
    dataSource: "none", // "local" | "edge" | "none"
    edgeFrameReady: false,
    localLoopsRunning: false,
    cursor: 0,
    status: [],
    events: [],
    cli: null, // { counts:{claude,grok}, roots:[] } or null
    cliSectionCollapsed: loadCliSectionCollapsed(),
    cliTreeCollapse: loadCliTreeCollapse(),
    taskFilter: "ALL",
    stateFilter: null,
    density: loadDensity(),
    collapse: loadCollapse(),
    offline: false,
    backoff: BACKOFF_MIN,
    mockTick: 0,
    hidden: 0,
    // race / ordering
    statusGen: 0,
    lastAppliedSeq: 0,
    bootId: null,
    startBusy: false,
  };

  /* ── localStorage helpers ─────────────────────────── */

  function loadDensity() {
    try {
      var d = localStorage.getItem("sb-density");
      if (d === "AUTO" || d === "PANEL" || d === "GRID") return d;
    } catch (e) { /* ignore */ }
    return "AUTO";
  }

  function saveDensity(d) {
    try { localStorage.setItem("sb-density", d); } catch (e) { /* ignore */ }
  }

  function loadCollapse() {
    try {
      var raw = localStorage.getItem("sb-collapse");
      if (raw) return JSON.parse(raw) || {};
    } catch (e) { /* ignore */ }
    return {};
  }

  function saveCollapse() {
    try {
      localStorage.setItem("sb-collapse", JSON.stringify(state.collapse));
    } catch (e) { /* ignore */ }
  }

  function loadCliSectionCollapsed() {
    try {
      return localStorage.getItem("sb-cli-section-collapsed") === "1";
    } catch (e) {
      return false;
    }
  }

  function saveCliSectionCollapsed() {
    try {
      localStorage.setItem(
        "sb-cli-section-collapsed",
        state.cliSectionCollapsed ? "1" : "0"
      );
    } catch (e) { /* ignore */ }
  }

  function loadCliTreeCollapse() {
    try {
      var raw = localStorage.getItem("sb-cli-tree-collapse");
      if (raw) return JSON.parse(raw) || {};
    } catch (e) { /* ignore */ }
    return {};
  }

  function saveCliTreeCollapse() {
    try {
      localStorage.setItem(
        "sb-cli-tree-collapse",
        JSON.stringify(state.cliTreeCollapse)
      );
    } catch (e) { /* ignore */ }
  }

  /* ── formatting ───────────────────────────────────── */

  function pad2(n) {
    return n < 10 ? "0" + n : String(n);
  }

  function formatAge(seconds) {
    if (seconds == null || !isFinite(seconds)) return "--";
    var s = Math.max(0, Math.floor(seconds));
    if (s < 60) return s + "s";
    var m = Math.floor(s / 60);
    if (m < 60) return m + "m " + (s % 60) + "s";
    var h = Math.floor(m / 60);
    m = m % 60;
    if (h < 48) return h + "h " + m + "m";
    var d = Math.floor(h / 24);
    h = h % 24;
    return d + "d " + h + "h";
  }

  function formatUp(seconds) {
    return "UP " + formatAge(seconds);
  }

  function formatActivity(seconds) {
    if (seconds == null || !isFinite(seconds)) return "activity --";
    return "activity " + formatAge(seconds) + " ago";
  }

  function formatExit(code) {
    if (code === null || code === undefined) return "EXIT --";
    return "EXIT " + code;
  }

  function timeHMS(ts) {
    if (!ts) {
      var now = new Date();
      return pad2(now.getHours()) + ":" + pad2(now.getMinutes()) + ":" + pad2(now.getSeconds());
    }
    var d = new Date(ts);
    if (isNaN(d.getTime())) {
      var m = String(ts).match(/T(\d{2}):(\d{2}):(\d{2})/);
      if (m) return m[1] + ":" + m[2] + ":" + m[3];
      return String(ts).slice(0, 8);
    }
    return pad2(d.getHours()) + ":" + pad2(d.getMinutes()) + ":" + pad2(d.getSeconds());
  }

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function escapeAttr(s) {
    return escapeHtml(s).replace(/'/g, "&#39;");
  }

  /* ── counting / sorting ───────────────────────────── */

  function emptyCounts() {
    return { RUNNING: 0, WORKING_TOOL: 0, WAITING_INPUT: 0, QUIET: 0, STALLED: 0, ORPHAN: 0, DONE: 0, FAILED: 0, DIED: 0 };
  }

  function countSlots(slots) {
    var c = emptyCounts();
    for (var i = 0; i < slots.length; i++) {
      var st = slots[i].state;
      if (c[st] !== undefined) c[st]++;
      else c[st] = (c[st] || 0) + 1;
    }
    return c;
  }

  function totalCounts(tasks) {
    var c = emptyCounts();
    for (var i = 0; i < tasks.length; i++) {
      var sc = countSlots(tasks[i].slots || []);
      for (var k in sc) {
        if (Object.prototype.hasOwnProperty.call(sc, k)) {
          c[k] = (c[k] || 0) + sc[k];
        }
      }
    }
    return c;
  }

  function taskHasAlert(slots) {
    for (var i = 0; i < slots.length; i++) {
      if (slots[i].state === "DIED" || slots[i].state === "FAILED") return true;
    }
    return false;
  }

  function taskAllDone(slots) {
    if (!slots.length) return false;
    for (var i = 0; i < slots.length; i++) {
      if (slots[i].state !== "DONE") return false;
    }
    return true;
  }

  function sortTasks(tasks) {
    var copy = tasks.slice();
    copy.sort(function (a, b) {
      var aAlert = taskHasAlert(a.slots || []);
      var bAlert = taskHasAlert(b.slots || []);
      if (aAlert !== bAlert) return aAlert ? -1 : 1;
      var aDone = taskAllDone(a.slots || []);
      var bDone = taskAllDone(b.slots || []);
      if (aDone !== bDone) return aDone ? 1 : -1;
      return String(a.task).localeCompare(String(b.task));
    });
    return copy;
  }

  function isCollapsed(taskName, slots) {
    if (Object.prototype.hasOwnProperty.call(state.collapse, taskName)) {
      return !!state.collapse[taskName];
    }
    return taskAllDone(slots || []);
  }

  function effectiveDensity(laneCount) {
    if (state.density === "PANEL") return "PANEL";
    if (state.density === "GRID") return "GRID";
    return laneCount > 15 ? "GRID" : "PANEL";
  }

  /* ── PLAN REV 2 /v1/cli fixture (matches cli-tree-v2 mockup) ── */

  function buildMockCliForest() {
    // Forest shape: {counts:{claude,grok,cursor}, roots:[node…]}
    // kind: claude | grok | cursor | agent_dispatch; each node may carry model
    // Counts exclude agent_dispatch: claude 2, grok 5, cursor 1
    return {
      counts: { claude: 2, grok: 5, cursor: 1 },
      roots: [
        {
          pid: 41001,
          kind: "claude",
          mode: "interactive",
          tty: "ttys004",
          uptime_s: 4320,
          started: "2026-08-09T20:42:00",
          label: null,
          model: "claude-fable-5",
          children: [
            {
              pid: 42010,
              kind: "agent_dispatch",
              mode: "headless",
              tty: null,
              uptime_s: 840,
              started: "2026-08-09T22:40:00",
              label: "mytask/worker-a",
              model: null,
              children: [
                {
                  pid: 43011,
                  kind: "grok",
                  mode: "headless",
                  tty: null,
                  uptime_s: 840,
                  started: "2026-08-09T22:40:05",
                  label: "mytask-worker-a",
                  channel: "mytask-worker-a",
                  model: "grok-4.5",
                  children: [],
                },
              ],
            },
          ],
        },
        {
          pid: 41002,
          kind: "claude",
          mode: "headless",
          tty: null,
          uptime_s: 2520,
          started: "2026-08-09T21:12:00",
          label: "(exec-master)",
          model: "opus",
          children: [
            {
              pid: 43101,
              kind: "grok",
              mode: "headless",
              tty: null,
              uptime_s: 1140,
              started: "2026-08-09T22:15:00",
              label: "mytask-worker-1",
              channel: "mytask-worker-1",
              model: "grok-4.5",
              children: [],
            },
            {
              pid: 43102,
              kind: "grok",
              mode: "headless",
              tty: null,
              uptime_s: 480,
              started: "2026-08-09T22:26:00",
              label: "mytask-worker-2",
              channel: "mytask-worker-2",
              model: "grok-4.5",
              children: [],
            },
            {
              pid: 43103,
              kind: "grok",
              mode: "headless",
              tty: null,
              uptime_s: 300,
              started: "2026-08-09T22:29:00",
              label: "mytask-worker-3",
              channel: "mytask-worker-3",
              model: "grok-4.5",
              children: [],
            },
            {
              pid: 43104,
              kind: "cursor",
              mode: "headless",
              tty: null,
              uptime_s: 280,
              started: "2026-08-09T22:29:20",
              label: "mytask-worker-4",
              channel: "mytask-worker-4",
              model: "auto",
              children: [],
            },
          ],
        },
        {
          pid: 44001,
          kind: "grok",
          mode: "interactive",
          tty: "ttys009",
          uptime_s: 360,
          started: "2026-08-09T22:48:00",
          label: null,
          model: "grok-4.5",
          children: [],
        },
      ],
    };
  }

  /* ── mock status generator ────────────────────────── */

  var MOCK_TASKS = [
    "demo-task",
    "pipeline-a",
    "pipeline-b",
    "infra-ops",
    "research-lab",
  ];

  var MOCK_LANE_PREFIXES = [
    "gen", "exec", "gate", "lint", "test", "build", "ship", "sync",
    "scan", "pack", "review", "plan", "fetch", "write", "check",
  ];

  function mockStateMix(i) {
    var r = (i * 17 + 3) % 100;
    if (r < 38) return "RUNNING";
    if (r < 55) return "QUIET";
    if (r < 88) return "DONE";
    if (r < 93) return "ORPHAN";
    if (r < 97) return "FAILED";
    return "DIED";
  }

  function buildMockStatus() {
    var tasks = [];
    var laneIdx = 0;
    var sizes = [8, 22, 35, 18, 40];
    for (var t = 0; t < MOCK_TASKS.length; t++) {
      var n = sizes[t];
      var slots = [];
      for (var i = 0; i < n; i++) {
        var name =
          MOCK_LANE_PREFIXES[laneIdx % MOCK_LANE_PREFIXES.length] +
          "-" +
          MOCK_TASKS[t].slice(0, 3) +
          "-" +
          pad2(i + 1);
        var st = mockStateMix(laneIdx + state.mockTick);
        var age = 30 + ((laneIdx * 97 + state.mockTick * 3) % 12000);
        var act =
          st === "RUNNING"
            ? (laneIdx + state.mockTick) % 45
            : st === "QUIET"
              ? 60 + ((laneIdx * 13) % 600)
              : 120 + ((laneIdx * 7) % 3600);
        var exit = st === "DONE" ? 0 : st === "FAILED" || st === "DIED" ? 1 : null;
        slots.push({
          lane: name,
          state: st,
          pid: st === "RUNNING" || st === "QUIET" ? 20000 + laneIdx : null,
          started: "2026-08-09T00:00:00",
          age_s: age,
          activity_s: act,
          exit_code: exit,
          channel: "exec-" + MOCK_TASKS[t] + "-" + name,
          report: null,
        });
        laneIdx++;
      }
      if (t === 2 && state.mockTick % 7 === 0) {
        for (var j = 0; j < slots.length; j++) {
          slots[j].state = "DONE";
          slots[j].exit_code = 0;
          slots[j].pid = null;
        }
      }
      tasks.push({ task: MOCK_TASKS[t], slots: slots });
    }
    return tasks;
  }

  function mockEvent() {
    var task = MOCK_TASKS[state.mockTick % MOCK_TASKS.length];
    var froms = ["RUNNING", "QUIET", "RUNNING"];
    var tos = ["DONE", "QUIET", "DIED", "FAILED", "RUNNING"];
    var from = froms[state.mockTick % froms.length];
    var to = tos[state.mockTick % tos.length];
    var lane =
      MOCK_LANE_PREFIXES[state.mockTick % MOCK_LANE_PREFIXES.length] +
      "-" +
      task.slice(0, 3) +
      "-" +
      pad2((state.mockTick % 20) + 1);
    state.mockTick++;
    state.cursor++;
    return {
      seq: state.cursor,
      task: task,
      event: "lane",
      lane: lane,
      from: from,
      to: to,
      ts: new Date().toISOString().replace(/\.\d{3}Z$/, ""),
    };
  }

  /* ── event ticker ─────────────────────────────────── */

  function pushEvents(events) {
    if (!events || !events.length) return;
    for (var i = 0; i < events.length; i++) {
      state.events.unshift(events[i]);
    }
    if (state.events.length > MAX_EVENTS) {
      state.events = state.events.slice(0, MAX_EVENTS);
    }
  }

  function renderTicker() {
    if (!state.events.length) {
      els.tickerInner.textContent = state.offline
        ? "no events — offline"
        : "awaiting events";
      return;
    }
    var parts = [];
    for (var i = 0; i < state.events.length; i++) {
      var e = state.events[i];
      var lane = e.lane || e.task || "?";
      var from = e.from || "";
      var to = e.to || e.event || "";
      var t = timeHMS(e.ts);
      var seg =
        '<span class="ev-time">' +
        escapeHtml(t) +
        "</span> " +
        '<span class="ev-lane">' +
        escapeHtml(lane) +
        "</span> " +
        (from
          ? '<span class="ev-from state-' +
            escapeAttr(from) +
            '">' +
            escapeHtml(from) +
            "</span>→"
          : "") +
        '<span class="ev-to state-' +
        escapeAttr(to) +
        '">' +
        escapeHtml(to) +
        "</span>";
      parts.push(seg);
    }
    els.tickerInner.innerHTML = parts.join('<span class="ev-sep"> · </span>');
  }

  /* ── CLI tree render ──────────────────────────────── */

  function kindDisplayName(kind) {
    if (kind === "agent_dispatch") return "agent-dispatch";
    if (kind === "claude") return "claude";
    if (kind === "grok") return "grok";
    if (kind === "cursor") return "cursor";
    if (kind === "cursor-sub") return "cursor-sub";
    if (kind === "grok-sub") return "grok-sub";
    return kind || "?";
  }

  /** muted model chip markup (empty if no model). */
  function renderModelChip(model) {
    var label = formatModelLabel(model);
    if (!label) return "";
    return (
      '<span class="badge model" title="' +
      escapeAttr(String(model)) +
      '">' +
      escapeHtml(label) +
      "</span>"
    );
  }

  function isTreeNodeCollapsed(node) {
    var key = cliNodeCollapseKey(node);
    if (!key) return false;
    return !!state.cliTreeCollapse[key];
  }

  function renderTreeNode(node, depth) {
    if (!node) return "";
    var kids = node.children || [];
    var hasKids = kids.length > 0;
    var collapsed = hasKids && isTreeNodeCollapsed(node);
    var key = cliNodeCollapseKey(node);
    var isBridge = node.kind === "agent_dispatch";
    var mode = node.mode === "interactive" ? "interactive" : "headless";
    var html = "";
    html +=
      '<div class="tree-node' +
      (collapsed ? " collapsed" : "") +
      '" data-cli-key="' +
      escapeAttr(key) +
      '">';
    html +=
      '<div class="tree-row' +
      (isBridge ? " bridge" : "") +
      '">';

    if (hasKids) {
      html +=
        '<button type="button" class="twisty has-kids" data-cli-toggle="' +
        escapeAttr(key) +
        '" aria-label="Toggle">' +
        '<span class="tri" aria-hidden="true"></span>' +
        "</button>";
    } else {
      html += '<span class="twisty empty" aria-hidden="true"></span>';
    }

    if (!isBridge) {
      html += '<span class="lamp lamp-live" aria-hidden="true"></span>';
    }

    html +=
      '<span class="name">' +
      escapeHtml(kindDisplayName(node.kind)) +
      "</span>";

    if (isBridge) {
      // agent-dispatch: label is task/lane
      if (node.label) {
        html +=
          '<span class="meta">' + escapeHtml(String(node.label)) + "</span>";
      }
      //  model chip on every row when present (bridge has no mode badge)
      html += renderModelChip(node.model);
    } else {
      html +=
        '<span class="badge ' +
        mode +
        '">' +
        (mode === "interactive" ? "INTERACTIVE" : "HEADLESS") +
        "</span>";
      //  muted model chip immediately after INTERACTIVE/HEADLESS
      html += renderModelChip(node.model);
      if (node.mode === "interactive" && node.tty) {
        html +=
          '<span class="meta">' + escapeHtml(String(node.tty)) + "</span>";
      } else if (node.label && String(node.label).indexOf("(") === 0) {
        // e.g. (exec-master)
        html +=
          '<span class="meta">' + escapeHtml(String(node.label)) + "</span>";
      } else if (
        node.channel ||
        (node.label && (node.kind === "grok" || node.kind === "cursor"))
      ) {
        var ch = node.channel || node.label;
        html +=
          '<span class="channel">channel ' +
          escapeHtml(String(ch)) +
          "</span>";
      } else if (node.label) {
        html +=
          '<span class="meta">' + escapeHtml(String(node.label)) + "</span>";
      }
    }

    html +=
      '<span class="uptime">' +
      escapeHtml(formatUp(node.uptime_s)) +
      "</span>";
    html += "</div>"; // tree-row

    if (hasKids) {
      html += '<div class="tree-children">';
      for (var i = 0; i < kids.length; i++) {
        html += renderTreeNode(kids[i], depth + 1);
      }
      html += "</div>";
    }
    html += "</div>"; // tree-node
    return html;
  }

  function cliCountsFromState() {
    if (!state.cli) return { claude: 0, grok: 0, cursor: 0 };
    // Tree walk is the source of truth (sessions + subagents, all families).
    if (state.cli.roots && state.cli.roots.length) {
      return countCliKinds(state.cli.roots);
    }
    return flattenCliCounts(state.cli.counts);
  }

  function renderCliSection() {
    var offline = state.offline;
    var counts = cliCountsFromState();
    var live = counts.claude + counts.grok + (counts.cursor || 0);
    var meta;
    if (offline && !state.cli) {
      meta = '<span class="unreachable">unreachable</span>';
    } else {
      // Name only the harnesses that actually have something running.
      var segs = [];
      var fams = liveCliFamilies(counts);
      for (var fi = 0; fi < fams.length; fi++) {
        segs.push("<b>" + fams[fi].key.toUpperCase() + " " + fams[fi].n + "</b>");
      }
      segs.push('<span class="ok">' + live + " live</span>");
      meta = segs.join(" · ");
    }

    var body;
    if (offline && !state.cli) {
      body =
        '<div class="empty-msg dim">no data — daemon not connected</div>';
    } else if (!state.cli || !(state.cli.roots && state.cli.roots.length)) {
      body = '<div class="empty-msg dim">no CLI sessions</div>';
    } else {
      body = '<div class="cli-tree">';
      for (var i = 0; i < state.cli.roots.length; i++) {
        body += renderTreeNode(state.cli.roots[i], 0);
      }
      body += "</div>";
    }

    return (
      '<section class="cli-section task-section' +
      (state.cliSectionCollapsed ? " collapsed" : "") +
      '" id="cli-sessions">' +
      '<button type="button" class="cli-head task-head" data-cli-section="1">' +
      '<span class="disclosure" aria-hidden="true"></span>' +
      '<span class="cli-title task-name">CLI SESSIONS</span>' +
      '<span class="cli-meta task-rollup">' +
      meta +
      "</span>" +
      "</button>" +
      '<div class="cli-body task-body">' +
      body +
      "</div>" +
      "</section>"
    );
  }

  /* ── render pieces ────────────────────────────────── */

  function rollupText(counts) {
    var parts = [];
    for (var i = 0; i < STATES.length; i++) {
      var s = STATES[i];
      if (counts[s]) parts.push(counts[s] + " " + s);
    }
    return parts.length ? parts.join(" · ") : "0 lanes";
  }

  function filterSlots(slots) {
    if (!state.stateFilter) return slots;
    var out = [];
    for (var i = 0; i < slots.length; i++) {
      if (slots[i].state === state.stateFilter) out.push(slots[i]);
    }
    return out;
  }

  function filteredTasks() {
    var tasks = state.status || [];
    if (state.taskFilter === "ALL") return tasks;
    var out = [];
    for (var i = 0; i < tasks.length; i++) {
      if (tasks[i].task === state.taskFilter) out.push(tasks[i]);
    }
    return out;
  }

  function renderChips() {
    var tasks = state.status || [];
    var names = ["ALL"];
    for (var i = 0; i < tasks.length; i++) {
      if (names.indexOf(tasks[i].task) === -1) names.push(tasks[i].task);
    }
    if (state.taskFilter !== "ALL" && names.indexOf(state.taskFilter) === -1) {
      names.push(state.taskFilter);
    }
    var html = "";
    for (var j = 0; j < names.length; j++) {
      var n = names[j];
      var active = n === state.taskFilter ? " active" : "";
      html +=
        '<button type="button" class="chip' +
        active +
        '" data-task="' +
        escapeAttr(n) +
        '">' +
        escapeHtml(n) +
        "</button>";
    }
    els.chips.innerHTML = html;
  }

  function renderTotals() {
    var c = totalCounts(state.status || []);
    var order = ["RUNNING", "WORKING_TOOL", "WAITING_INPUT", "QUIET", "STALLED", "DIED", "FAILED", "DONE", "ORPHAN"];
    var html = "";
    for (var i = 0; i < order.length; i++) {
      var s = order[i];
      if (!c[s] && s === "ORPHAN") continue;
      html +=
        '<span class="gt" data-state="' +
        s +
        '"><strong>' +
        (c[s] || 0) +
        "</strong> " +
        s +
        "</span>";
    }
    if (state.hidden) {
      html +=
        '<span class="gt gt-hidden">' +
        state.hidden +
        " finished hidden</span>";
    }
    // CLI chips (T5: exclude agent_dispatch). A harness with nothing live
    // gets no chip at all — no "cursor 0" on a machine without cursor.
    var cliFams = liveCliFamilies(cliCountsFromState());
    if ((!state.offline || state.cli) && cliFams.length) {
      for (var f = 0; f < cliFams.length; f++) {
        html +=
          '<span class="gt gt-cli">' +
          (f === 0 ? "CLI: " : "") +
          cliFams[f].key +
          " <strong>" +
          cliFams[f].n +
          "</strong></span>";
      }
    } else {
      html += '<span class="gt gt-cli">CLI: —</span>';
    }
    els.totals.innerHTML = html;
  }

  function renderDensity() {
    var btns = els.density.querySelectorAll(".density-btn");
    for (var i = 0; i < btns.length; i++) {
      var b = btns[i];
      if (b.getAttribute("data-density") === state.density) {
        b.classList.add("active");
      } else {
        b.classList.remove("active");
      }
    }
  }

  function renderRail() {
    var c = totalCounts(state.status || []);
    var html = "";
    for (var i = 0; i < TILE_STATES.length; i++) {
      var s = TILE_STATES[i];
      var n = c[s] || 0;
      var active = state.stateFilter === s ? " active" : "";
      var nz = n > 0 ? " nonzero" : "";
      html +=
        '<button type="button" class="tile' +
        active +
        nz +
        '" data-state="' +
        s +
        '">' +
        '<span class="tile-label">' +
        s +
        "</span>" +
        '<span class="tile-num">' +
        (state.offline && !state.status.length ? "—" : n) +
        "</span>" +
        "</button>";
    }
    els.rail.innerHTML = html;
    if (state.offline) els.rail.classList.add("is-offline");
    else els.rail.classList.remove("is-offline");
  }

  function tooltipFor(slot) {
    var parts = [
      slot.lane,
      "state " + slot.state,
      formatUp(slot.age_s),
      formatActivity(slot.activity_s),
      formatExit(slot.exit_code),
      slot.channel || "",
      slot.pid != null ? "pid " + slot.pid : "",
    ];
    return parts.filter(Boolean).join(" · ");
  }

  function renderPanelRows(slots) {
    var html = '<div class="lane-panel">';
    for (var i = 0; i < slots.length; i++) {
      var s = slots[i];
      html +=
        '<div class="lane-row" title="' +
        escapeAttr(tooltipFor(s)) +
        '">' +
        '<span class="lamp lamp-lg" data-state="' +
        escapeAttr(s.state) +
        '"></span>' +
        '<span class="lane-name">' +
        escapeHtml(s.lane) +
        "</span>" +
        '<span class="lane-meta">' +
        escapeHtml(formatUp(s.age_s)) +
        "</span>" +
        '<span class="lane-meta">' +
        escapeHtml(formatActivity(s.activity_s)) +
        "</span>" +
        '<span class="lane-meta">' +
        escapeHtml(formatExit(s.exit_code)) +
        "</span>" +
        '<span class="lane-channel">' +
        escapeHtml(s.channel || "") +
        "</span>" +
        "</div>";
    }
    html += "</div>";
    return html;
  }

  function renderGridCells(slots) {
    var html = '<div class="lane-grid">';
    for (var i = 0; i < slots.length; i++) {
      var s = slots[i];
      html +=
        '<div class="lane-cell" title="' +
        escapeAttr(tooltipFor(s)) +
        '">' +
        '<span class="lamp lamp-sm" data-state="' +
        escapeAttr(s.state) +
        '"></span>' +
        '<span class="cell-name">' +
        escapeHtml(s.lane) +
        "</span>" +
        '<span class="cell-age">' +
        escapeHtml(formatAge(s.age_s)) +
        "</span>" +
        "</div>";
    }
    html += "</div>";
    return html;
  }

  function renderTaskSections() {
    var tasks = sortTasks(filteredTasks());
    if (!tasks.length) {
      if (state.offline) {
        return (
          '<section class="task-section">' +
          '<div class="task-head" style="cursor:default">' +
          '<span class="disclosure" aria-hidden="true"></span>' +
          '<span class="task-name">TASKS</span>' +
          '<span class="task-rollup">—</span>' +
          "</div>" +
          '<div class="task-body">' +
          '<div class="empty-msg dim">waiting for /v1/status</div>' +
          "</div>" +
          "</section>"
        );
      }
      var msg = "No tasks";
      if (state.hidden) {
        msg =
          "No live activity — " +
          state.hidden +
          " finished lane" +
          (state.hidden === 1 ? "" : "s") +
          " hidden";
      }
      return '<div class="empty-msg">' + msg + "</div>";
    }
    var html = "";
    for (var i = 0; i < tasks.length; i++) {
      var t = tasks[i];
      var allSlots = t.slots || [];
      var slots = filterSlots(allSlots);
      var counts = countSlots(allSlots);
      var collapsed = isCollapsed(t.task, allSlots);
      var dens = effectiveDensity(slots.length);
      var body =
        dens === "GRID" ? renderGridCells(slots) : renderPanelRows(slots);
      if (!slots.length) {
        body = '<div class="empty-msg">No lanes match filter</div>';
      }
      html +=
        '<section class="task-section' +
        (collapsed ? " collapsed" : "") +
        '" data-task="' +
        escapeAttr(t.task) +
        '">' +
        '<button type="button" class="task-head" data-collapse="' +
        escapeAttr(t.task) +
        '">' +
        '<span class="disclosure" aria-hidden="true"></span>' +
        '<span class="task-name">' +
        escapeHtml(t.task) +
        "</span>" +
        '<span class="task-rollup">' +
        escapeHtml(rollupText(counts)) +
        "</span>" +
        "</button>" +
        '<div class="task-body">' +
        body +
        "</div>" +
        "</section>";
    }
    return html;
  }

  function renderMain() {
    // CLI SESSIONS pinned above task sections
    var html = renderCliSection() + renderTaskSections();
    els.main.innerHTML = html;
    if (state.offline) els.main.classList.add("is-offline");
    else els.main.classList.remove("is-offline");
  }

  function renderAll() {
    renderDensity();
    renderChips();
    renderTotals();
    renderRail();
    renderMain();
    renderTicker();
    updateStartButton();
  }

  /* ── Tauri START DAEMON + edge fallback ───────────── */

  function tauriInvoke(cmd, args) {
    if (window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke) {
      return window.__TAURI__.core.invoke(cmd, args || {});
    }
    if (window.__TAURI_INTERNALS__ && window.__TAURI_INTERNALS__.invoke) {
      return window.__TAURI_INTERNALS__.invoke(cmd, args || {});
    }
    return Promise.reject(new Error("no tauri api"));
  }

  function hasTauriApi() {
    try {
      if (window.__TAURI__ && window.__TAURI__.core && typeof window.__TAURI__.core.invoke === "function") {
        return true;
      }
      // Tauri 2 internals / older shapes
      if (window.__TAURI_INTERNALS__ && typeof window.__TAURI_INTERNALS__.invoke === "function") {
        return true;
      }
    } catch (e) { /* ignore */ }
    return false;
  }

  function invokeStartDaemon() {
    return tauriInvoke("start_daemon");
  }

  function updateSourceBadge() {
    if (!els.sourceBadge) return;
    if (state.dataSource === "local") {
      els.sourceBadge.textContent = "LOCAL";
      els.sourceBadge.classList.remove("source-fleet");
      els.sourceBadge.hidden = false;
      els.sourceBadge.removeAttribute("hidden");
    } else if (state.dataSource === "edge") {
      els.sourceBadge.hidden = true;
      els.sourceBadge.setAttribute("hidden", "");
    } else {
      els.sourceBadge.hidden = true;
      els.sourceBadge.setAttribute("hidden", "");
    }
  }

  function showLocalChrome() {
    if (els.app) {
      els.app.hidden = false;
      els.app.removeAttribute("hidden");
    }
    if (els.edgeHost) {
      els.edgeHost.hidden = true;
      els.edgeHost.setAttribute("hidden", "");
    }
    updateSourceBadge();
  }

  function showEdgeChrome() {
    if (els.app) {
      els.app.hidden = true;
      els.app.setAttribute("hidden", "");
    }
    if (els.edgeHost) {
      els.edgeHost.hidden = false;
      els.edgeHost.removeAttribute("hidden");
    }
    updateSourceBadge();
  }

  function renderEdgeDoc(doc) {
    if (!els.edgeFrame || !els.edgeFrame.contentWindow) return false;
    var win = els.edgeFrame.contentWindow;
    if (typeof win.overwatchRender !== "function") return false;
    try {
      win.overwatchRender(doc);
      return true;
    } catch (e) {
      return false;
    }
  }

  function ensureEdgeFrameReady() {
    if (state.edgeFrameReady) return Promise.resolve();
    if (!els.edgeFrame) return Promise.reject(new Error("no edge frame"));
    return new Promise(function (resolve, reject) {
      function onLoad() {
        state.edgeFrameReady = true;
        try {
          if (els.edgeFrame.contentWindow) {
            els.edgeFrame.contentWindow.__hosted = 1;
          }
        } catch (e) { /* cross-origin guard */ }
        resolve();
      }
      if (els.edgeFrame.contentDocument && els.edgeFrame.contentDocument.readyState === "complete") {
        onLoad();
        return;
      }
      els.edgeFrame.addEventListener("load", onLoad, { once: true });
      els.edgeFrame.addEventListener(
        "error",
        function () {
          reject(new Error("edge frame load failed"));
        },
        { once: true }
      );
    });
  }

  async function fetchEdgeDashboard() {
    return tauriInvoke("fetch_edge_dashboard");
  }

  async function tryEnterEdgeMode(doc) {
    if (!hasTauriApi()) return false;
    try {
      var payload = doc != null ? doc : await fetchEdgeDashboard();
      await ensureEdgeFrameReady();
      if (!renderEdgeDoc(payload)) {
        await sleep(50);
        if (!renderEdgeDoc(payload)) return false;
      }
      state.dataSource = "edge";
      state.localLoopsRunning = false;
      setOffline(false);
      showEdgeChrome();
      edgePollLoop();
      localProbeLoop();
      return true;
    } catch (e) {
      return false;
    }
  }

  function enterLocalMode() {
    if (state.dataSource === "edge") {
      state.localLoopsRunning = false;
    }
    state.dataSource = "local";
    showLocalChrome();
    setOffline(false);
  }

  async function edgePollLoop() {
    while (state.dataSource === "edge") {
      await sleep(STATUS_INTERVAL_MS);
      if (state.dataSource !== "edge") return;
      try {
        var doc = await fetchEdgeDashboard();
        renderEdgeDoc(doc);
      } catch (e) {
        /* keep last snapshot; overwatch STALE badge handles age */
      }
    }
  }

  async function localProbeLoop() {
    while (state.dataSource === "edge") {
      await sleep(15000);
      if (state.dataSource !== "edge") return;
      try {
        await fetchJson(BASE + "/v1/health");
        await initialLoad();
        enterLocalMode();
        if (!state.localLoopsRunning) {
          state.localLoopsRunning = true;
          waitLoop();
          statusTickLoop();
        }
        return;
      } catch (e) {
        /* stay on fleet view */
      }
    }
  }

  async function offlineRecoveryLoop() {
    while (state.dataSource !== "local") {
      await sleep(state.backoff);
      try {
        await initialLoad();
        enterLocalMode();
        if (!state.localLoopsRunning) {
          state.localLoopsRunning = true;
          waitLoop();
          statusTickLoop();
        }
        return;
      } catch (e) {
        /* still down */
      }
      if (state.dataSource !== "edge") {
        var ok = await tryEnterEdgeMode();
        if (ok) return;
      }
      state.backoff = Math.min(BACKOFF_MAX, state.backoff + 1000);
    }
  }

  function startLocalLoops() {
    if (state.localLoopsRunning) return;
    state.localLoopsRunning = true;
    waitLoop();
    statusTickLoop();
  }

  function updateStartButton() {
    if (!els.startBtn) return;
    if (!hasTauriApi()) {
      els.startBtn.hidden = true;
      els.startBtn.setAttribute("hidden", "");
      return;
    }
    // Show only when offline on local path (not fleet fallback)
    if (state.offline && state.dataSource !== "edge") {
      els.startBtn.hidden = false;
      els.startBtn.removeAttribute("hidden");
      els.startBtn.disabled = !!state.startBusy;
      els.startBtn.textContent = state.startBusy ? "STARTING…" : "START DAEMON";
    } else {
      els.startBtn.hidden = true;
      els.startBtn.setAttribute("hidden", "");
    }
  }

  async function onStartDaemon() {
    if (state.startBusy || !hasTauriApi()) return;
    state.startBusy = true;
    updateStartButton();
    try {
      await invokeStartDaemon();
      // Probe health a few times after kickstart
      for (var i = 0; i < 8; i++) {
        await sleep(500);
        try {
          await initialLoad();
          enterLocalMode();
          if (!state.localLoopsRunning) startLocalLoops();
          if (!state.offline) break;
        } catch (e) { /* keep trying */ }
      }
    } catch (err) {
      // Stay offline; button re-enabled
      if (typeof console !== "undefined" && console.warn) {
        console.warn("start_daemon failed", err);
      }
    } finally {
      state.startBusy = false;
      updateStartButton();
    }
  }

  /* ── events (delegation) ──────────────────────────── */

  function onClick(e) {
    var t = e.target;
    if (!t) return;

    // START DAEMON
    if (t.id === "start-daemon-btn" || (t.closest && t.closest("#start-daemon-btn"))) {
      onStartDaemon();
      return;
    }

    // density
    var densBtn = t.closest ? t.closest(".density-btn") : null;
    if (densBtn) {
      var d = densBtn.getAttribute("data-density");
      if (d) {
        state.density = d;
        saveDensity(d);
        renderAll();
      }
      return;
    }

    // task chip
    var chip = t.closest ? t.closest(".chip") : null;
    if (chip) {
      state.taskFilter = chip.getAttribute("data-task") || "ALL";
      renderAll();
      return;
    }

    // rail tile
    var tile = t.closest ? t.closest(".tile") : null;
    if (tile) {
      var st = tile.getAttribute("data-state");
      if (state.stateFilter === st) state.stateFilter = null;
      else state.stateFilter = st;
      renderAll();
      return;
    }

    // CLI tree node toggle (pid:started key)
    var twisty = t.closest ? t.closest("[data-cli-toggle]") : null;
    if (twisty) {
      var ck = twisty.getAttribute("data-cli-toggle");
      if (ck) {
        state.cliTreeCollapse[ck] = !state.cliTreeCollapse[ck];
        saveCliTreeCollapse();
        var nodeEl = twisty.closest(".tree-node");
        if (nodeEl) {
          if (state.cliTreeCollapse[ck]) nodeEl.classList.add("collapsed");
          else nodeEl.classList.remove("collapsed");
        }
      }
      return;
    }

    // CLI section collapse
    var cliHead = t.closest ? t.closest("[data-cli-section]") : null;
    if (cliHead) {
      state.cliSectionCollapsed = !state.cliSectionCollapsed;
      saveCliSectionCollapsed();
      var sec = cliHead.closest(".cli-section");
      if (sec) {
        if (state.cliSectionCollapsed) sec.classList.add("collapsed");
        else sec.classList.remove("collapsed");
      }
      return;
    }

    // task collapse
    var head = t.closest ? t.closest(".task-head") : null;
    if (head && !head.getAttribute("data-cli-section")) {
      var name = head.getAttribute("data-collapse");
      if (name) {
        var section = head.closest(".task-section");
        var isNowCollapsed = section && section.classList.contains("collapsed");
        state.collapse[name] = !isNowCollapsed;
        saveCollapse();
        if (section) {
          if (state.collapse[name]) section.classList.add("collapsed");
          else section.classList.remove("collapsed");
        }
      }
    }
  }

  document.addEventListener("click", onClick);

  /* ── network ──────────────────────────────────────── */

  function setOffline(off) {
    state.offline = off;
    if (off) {
      els.offline.hidden = false;
      els.offline.removeAttribute("hidden");
    } else {
      els.offline.hidden = true;
      els.offline.setAttribute("hidden", "");
      state.backoff = BACKOFF_MIN;
    }
    updateStartButton();
  }

  /**
   * fetchJson with 503 Retry-After awareness.
   * Throws Error with .status and optional .retryAfterSec
   */
  function fetchJson(url, opts) {
    return fetch(url, opts).then(function (res) {
      if (res.status === 503) {
        var ra = res.headers.get("Retry-After");
        var err = new Error("HTTP 503");
        err.status = 503;
        err.retryAfterSec = ra != null && ra !== "" ? parseInt(ra, 10) : null;
        if (err.retryAfterSec != null && !isFinite(err.retryAfterSec)) {
          err.retryAfterSec = null;
        }
        // Try to parse body for wait_capacity etc. (optional)
        return res.json().catch(function () { return null; }).then(function (body) {
          err.body = body;
          throw err;
        });
      }
      if (!res.ok) {
        var e2 = new Error("HTTP " + res.status);
        e2.status = res.status;
        throw e2;
      }
      return res.json();
    });
  }

  function pruneFinished(tasks) {
    var out = [];
    var hidden = 0;
    for (var i = 0; i < tasks.length; i++) {
      var slots = tasks[i].slots || [];
      var keep = [];
      for (var j = 0; j < slots.length; j++) {
        var s = slots[j];
        if (LIVE_STATES[s.state] || s.ended_s == null || s.ended_s < RETENTION_S) {
          keep.push(s);
        } else {
          hidden++;
        }
      }
      if (keep.length) out.push({ task: tasks[i].task, slots: keep });
    }
    state.hidden = hidden;
    return out;
  }

  function applyStatus(data) {
    if (Array.isArray(data)) {
      state.status = pruneFinished(data);
    } else {
      state.status = [];
    }
  }

  function applyCli(data) {
    if (!data || typeof data !== "object") {
      state.cli = null;
      return;
    }
    // Accept REV 2 forest {counts, roots} or tolerate {instances} legacy empty
    if (Array.isArray(data.roots)) {
      state.cli = {
        counts: data.counts || countCliKinds(data.roots),
        roots: data.roots,
      };
    } else if (Array.isArray(data.instances)) {
      // Flat list fallback: promote to single-level roots
      state.cli = {
        counts: data.counts || countCliKinds(data.instances),
        roots: data.instances,
      };
    } else {
      state.cli = { counts: { claude: 0, grok: 0, cursor: 0 }, roots: [] };
    }
  }

  function sleep(ms) {
    return new Promise(function (resolve) {
      setTimeout(resolve, ms);
    });
  }

  /* ── live loop (ordering guard + cli piggyback) ───── */

  /**
   * Single status+cli refresh with monotonic apply seq (R6a / SPEC item 3).
   * /v1/cli piggybacks this path — no extra long-poll (T4).
   */
  async function refreshStatus() {
    var g = ++state.statusGen;
    var status;
    var cliData = null;
    try {
      status = await fetchJson(BASE + "/v1/status");
    } catch (e) {
      // If this fetch is still the latest, surface offline
      if (shouldApplyStatus(g, state.lastAppliedSeq)) {
        // Do not advance lastApplied on hard failure; let next succeed
        throw e;
      }
      return; // superseded
    }
    // Best-effort /v1/cli (daemon may not serve it yet — lane b2)
    try {
      cliData = await fetchJson(BASE + "/v1/cli");
    } catch (eCli) {
      if (state.fixture || state.mock) {
        cliData = buildMockCliForest();
      } else {
        cliData = null; // leave previous tree if any
      }
    }

    var decision = applyOrderingResult(g, state.lastAppliedSeq, {
      status: status,
      cli: cliData,
    });
    if (!decision.applied) return;
    state.lastAppliedSeq = decision.lastAppliedSeq;
    applyStatus(status);
    if (cliData) applyCli(cliData);
    setOffline(false);
    renderAll();
  }

  /**
   * Full bootstrap: health (boot_id + cursor) then status+cli.
   * Used only at boot and intentional resync — NOT from waitLoop catch.
   */
  async function initialLoad() {
    var health = await fetchJson(BASE + "/v1/health");
    if (health && typeof health.cursor === "number") {
      state.cursor = health.cursor;
    }
    if (health && health.boot_id != null) {
      if (state.bootId != null && health.boot_id !== state.bootId) {
        // Daemon restarted — force full refresh path
        state.cursor = typeof health.cursor === "number" ? health.cursor : 0;
      }
      state.bootId = health.boot_id;
    }
    await refreshStatus();
  }

  /**
   * Cursor recovery without nesting full initialLoad inside waitLoop (R6c).
   * Uses health + generation-guarded refreshStatus.
   */
  async function recoverFromWaitError() {
    try {
      var health = await fetchJson(BASE + "/v1/health");
      if (health && health.boot_id != null) {
        if (state.bootId != null && health.boot_id !== state.bootId) {
          state.cursor = typeof health.cursor === "number" ? health.cursor : 0;
        } else if (typeof health.cursor === "number") {
          state.cursor = health.cursor;
        }
        state.bootId = health.boot_id;
      } else if (health && typeof health.cursor === "number") {
        state.cursor = health.cursor;
      }
      await refreshStatus();
    } catch (e) {
      if (state.dataSource === "local") {
        var edgeOk = await tryEnterEdgeMode();
        if (edgeOk) return;
      }
      setOffline(true);
      renderAll();
    }
  }

  async function waitLoop() {
    while (state.dataSource === "local") {
      try {
        var url =
          BASE +
          "/v1/wait?cursor=" +
          encodeURIComponent(state.cursor) +
          "&timeout=55";
        var data = await fetchJson(url);
        setOffline(false);
        // Success path: reset backoff (R6c / G15)
        state.backoff = BACKOFF_MIN;

        // boot_id change or gap → full resync
        if (data && data.boot_id != null) {
          if (state.bootId != null && data.boot_id !== state.bootId) {
            state.bootId = data.boot_id;
            state.cursor = typeof data.cursor === "number" ? data.cursor : 0;
            await refreshStatus();
            continue;
          }
          state.bootId = data.boot_id;
        }
        if (data && (data.gap || data.trimmed)) {
          if (typeof data.cursor === "number") state.cursor = data.cursor;
          await refreshStatus();
          continue;
        }

        if (data && typeof data.cursor === "number") {
          state.cursor = data.cursor;
        }
        if (data && data.events && data.events.length) {
          pushEvents(data.events);
          // Piggyback status + /v1/cli on wait events (T4)
          await refreshStatus();
        }
      } catch (err) {
        // 503 wait capacity: honor Retry-After, backoff, no error spiral
        if (err && err.status === 503) {
          var waitMs =
            err.retryAfterSec != null && err.retryAfterSec > 0
              ? err.retryAfterSec * 1000
              : state.backoff;
          waitMs = Math.max(waitMs, BACKOFF_MIN);
          await sleep(waitMs);
          state.backoff = Math.min(BACKOFF_MAX, state.backoff + 1000);
          // Do NOT mark offline / do NOT initialLoad — capacity is temporary
          continue;
        }

        setOffline(true);
        renderAll();
        await sleep(state.backoff);
        state.backoff = Math.min(BACKOFF_MAX, state.backoff + 1000);
        // Single recovery path — no initialLoad inside catch (R6c)
        await recoverFromWaitError();
      }
    }
  }

  async function statusTickLoop() {
    while (state.dataSource === "local") {
      await sleep(STATUS_INTERVAL_MS);
      if (state.mock) continue;
      try {
        // 30s tick also refreshes /v1/cli (T4)
        await refreshStatus();
      } catch (e) {
        setOffline(true);
        renderAll();
        if (state.dataSource === "local") {
          await tryEnterEdgeMode();
        }
      }
    }
  }

  /* ── mock / fixture loops ─────────────────────────── */

  async function mockLoop() {
    state.status = buildMockStatus();
    state.cli = buildMockCliForest();
    state.cursor = 1;
    setOffline(false);
    renderAll();

    while (true) {
      await sleep(2500 + Math.floor(Math.random() * 1500));
      var ev = mockEvent();
      pushEvents([ev]);
      state.status = buildMockStatus();
      state.cli = buildMockCliForest();
      renderAll();
    }
  }

  /** Fixture mode: drive tree from mock /v1/cli JSON even if daemon lacks endpoint */
  async function fixtureBoot() {
    state.fixture = true;
    try {
      await initialLoad();
    } catch (e) {
      // Daemon down — still show fixture tree offline-style? Prefer online tree.
      state.status = [];
      setOffline(true);
    }
    // Always apply CLI fixture for UI work while B2 is not deployed
    applyCli(buildMockCliForest());
    if (!state.offline) setOffline(false);
    renderAll();
    waitLoop();
    statusTickLoop();
  }

  /* ── boot ─────────────────────────────────────────── */

  function isMock() {
    try {
      return /(?:\?|&)mock=1(?:&|$)/.test(location.search);
    } catch (e) {
      return false;
    }
  }

  function isFixture() {
    try {
      // default fixture when ?fixture=1 OR when mock — also auto if ?cli=1
      return /(?:\?|&)(?:fixture|cli)=1(?:&|$)/.test(location.search);
    } catch (e) {
      return false;
    }
  }

  async function boot() {
    state.mock = isMock();
    state.fixture = isFixture();
    renderDensity();
    renderTicker();
    updateStartButton();

    // Auto-run pure self-test once at boot (result on __sbTest.lastRun)
    try {
      __sbTest.lastRun = runApplyOrderingSelfTest();
    } catch (e) {
      __sbTest.lastRun = { ok: false, error: String(e) };
    }

    if (state.mock) {
      await mockLoop();
      return;
    }

    if (state.fixture) {
      await fixtureBoot();
      return;
    }

    try {
      await initialLoad();
      enterLocalMode();
      startLocalLoops();
    } catch (e) {
      var edgeOk = await tryEnterEdgeMode();
      if (!edgeOk) {
        setOffline(true);
        renderAll();
        offlineRecoveryLoop();
      }
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
