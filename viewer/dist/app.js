/* Agent Switchboard viewer — plain ES2020, no modules */
(function () {
  "use strict";

  var BASE = "http://127.0.0.1:17920";
  var STATES = ["RUNNING", "QUIET", "ORPHAN", "DONE", "FAILED", "DIED"];
  var TILE_STATES = ["RUNNING", "QUIET", "DIED", "FAILED", "DONE"];
  var MAX_EVENTS = 40;
  var STATUS_INTERVAL_MS = 30000;
  var BACKOFF_MIN = 2000;
  var BACKOFF_MAX = 10000;

  var els = {
    chips: document.getElementById("task-chips"),
    totals: document.getElementById("global-totals"),
    density: document.getElementById("density-toggle"),
    offline: document.getElementById("offline-banner"),
    main: document.getElementById("main"),
    rail: document.getElementById("rail"),
    tickerInner: document.getElementById("ticker-inner"),
  };

  var state = {
    mock: false,
    cursor: 0,
    status: [],
    events: [],
    taskFilter: "ALL",
    stateFilter: null,
    density: loadDensity(),
    collapse: loadCollapse(),
    offline: false,
    backoff: BACKOFF_MIN,
    mockTick: 0,
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
      // accept "YYYY-MM-DDTHH:MM:SS" without Z
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
    return { RUNNING: 0, QUIET: 0, ORPHAN: 0, DONE: 0, FAILED: 0, DIED: 0 };
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
    // default: fully-DONE tasks start collapsed
    return taskAllDone(slots || []);
  }

  function effectiveDensity(laneCount) {
    if (state.density === "PANEL") return "PANEL";
    if (state.density === "GRID") return "GRID";
    return laneCount > 15 ? "GRID" : "PANEL";
  }

  /* ── mock generator ───────────────────────────────── */

  var MOCK_TASKS = [
    "build-alpha",
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
    // Realistic mix: many DONE, many RUNNING, some QUIET, few alerts
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
    // Aim for ~120 lanes across 5 tasks with uneven distribution
    var sizes = [8, 22, 35, 18, 40]; // sum = 123
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
      // Force one fully-DONE task occasionally (pipeline-b tends DONE-heavy)
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
      els.tickerInner.textContent = "awaiting events";
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
    // Keep selected task visible even if temporarily empty
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
    var order = ["RUNNING", "QUIET", "DIED", "FAILED", "DONE", "ORPHAN"];
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
        n +
        "</span>" +
        "</button>";
    }
    els.rail.innerHTML = html;
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

  function renderMain() {
    var tasks = sortTasks(filteredTasks());
    if (!tasks.length) {
      els.main.innerHTML =
        '<div class="empty-msg">No tasks' +
        (state.offline ? " (daemon offline)" : "") +
        "</div>";
      return;
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
    els.main.innerHTML = html;
  }

  function renderAll() {
    renderDensity();
    renderChips();
    renderTotals();
    renderRail();
    renderMain();
    renderTicker();
  }

  /* ── events (delegation) ──────────────────────────── */

  function onClick(e) {
    var t = e.target;
    if (!t) return;

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

    // collapse
    var head = t.closest ? t.closest(".task-head") : null;
    if (head) {
      var name = head.getAttribute("data-collapse");
      if (name) {
        var currently = isCollapsed(name, []);
        // If key missing, isCollapsed may use default DONE rule — resolve from DOM
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
  }

  function fetchJson(url, opts) {
    return fetch(url, opts).then(function (res) {
      if (!res.ok) throw new Error("HTTP " + res.status);
      return res.json();
    });
  }

  function applyStatus(data) {
    if (Array.isArray(data)) {
      state.status = data;
    } else {
      state.status = [];
    }
  }

  function sleep(ms) {
    return new Promise(function (resolve) {
      setTimeout(resolve, ms);
    });
  }

  /* ── live loop ────────────────────────────────────── */

  async function initialLoad() {
    var health = await fetchJson(BASE + "/v1/health");
    if (health && typeof health.cursor === "number") {
      state.cursor = health.cursor;
    }
    var status = await fetchJson(BASE + "/v1/status");
    applyStatus(status);
    setOffline(false);
    renderAll();
  }

  async function refreshStatus() {
    var status = await fetchJson(BASE + "/v1/status");
    applyStatus(status);
    setOffline(false);
    renderAll();
  }

  async function waitLoop() {
    while (true) {
      try {
        var url =
          BASE +
          "/v1/wait?cursor=" +
          encodeURIComponent(state.cursor) +
          "&timeout=55";
        var data = await fetchJson(url);
        setOffline(false);
        if (data && typeof data.cursor === "number") {
          state.cursor = data.cursor;
        }
        if (data && data.events && data.events.length) {
          pushEvents(data.events);
          await refreshStatus();
        }
        // loop immediately (even on timeout with empty events)
      } catch (err) {
        setOffline(true);
        renderAll();
        await sleep(state.backoff);
        state.backoff = Math.min(BACKOFF_MAX, state.backoff + 1000);
        // try a status probe to recover cursor
        try {
          await initialLoad();
        } catch (e2) {
          /* stay offline */
        }
      }
    }
  }

  async function statusTickLoop() {
    while (true) {
      await sleep(STATUS_INTERVAL_MS);
      if (state.mock) continue;
      try {
        await refreshStatus();
      } catch (e) {
        setOffline(true);
      }
    }
  }

  /* ── mock loop ────────────────────────────────────── */

  async function mockLoop() {
    state.status = buildMockStatus();
    state.cursor = 1;
    setOffline(false);
    renderAll();

    while (true) {
      await sleep(2500 + Math.floor(Math.random() * 1500));
      var ev = mockEvent();
      pushEvents([ev]);
      // drift ages
      state.status = buildMockStatus();
      renderAll();
    }
  }

  /* ── boot ─────────────────────────────────────────── */

  function isMock() {
    try {
      return /(?:\?|&)mock=1(?:&|$)/.test(location.search);
    } catch (e) {
      return false;
    }
  }

  async function boot() {
    state.mock = isMock();
    renderDensity();
    renderTicker();

    if (state.mock) {
      await mockLoop();
      return;
    }

    try {
      await initialLoad();
    } catch (e) {
      setOffline(true);
      renderAll();
    }

    // parallel loops
    waitLoop();
    statusTickLoop();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
