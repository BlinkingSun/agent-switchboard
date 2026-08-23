#!/bin/bash
# switchboard + agent-dispatch self-test in an isolated state root.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SB="${SB_BIN:-$SCRIPT_DIR/../bin/switchboard}"
TD="${TD_BIN:-$SCRIPT_DIR/../bin/agent-dispatch}"
AGENT_SWITCHBOARD_ROOT="${AGENT_SWITCHBOARD_ROOT:-$(mktemp -d)}"
export AGENT_SWITCHBOARD_ROOT
rm -rf "$AGENT_SWITCHBOARD_ROOT"
# ABSOLUTE SAFETY: agent-dispatch now fires a best-effort ensure_daemon()
# before every dispatch. Disable it for the WHOLE suite so none
# of the $TD calls below ever probes/kickstarts/spawns against a real
# daemon or the live :17920 job. Individual tests that need to exercise
# ensure_daemon() itself override this per-command, never for the whole run.
export AGENT_SWITCHBOARD_ENSURE_DISABLE=1
PASS=0; FAIL=0
ck() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "PASS: $3"; else FAIL=$((FAIL+1)); echo "FAIL: $3 (got '$1' want '$2')"; fi }

# T1: normal lane completes -> DONE, wrapper exit passes through
"$TD" --task demo --lane ok --exec /bin/bash -- -c 'sleep 1; exit 0' >/dev/null 2>&1
ck "$?" "0" "T1a wrapper passes through exit 0"
ST=$("$SB" status --task demo --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print([s["state"] for s in d[0]["slots"] if s["lane"]=="ok"][0])')
ck "$ST" "DONE" "T1b completed lane derives DONE"

# T2: failing lane -> FAILED with code
"$TD" --task demo --lane bad --exec /bin/bash -- -c 'exit 7' >/dev/null 2>&1
ck "$?" "7" "T2a wrapper passes through exit 7"
ST=$("$SB" status --task demo --json | python3 -c 'import json,sys; d=json.load(sys.stdin); s=[s for s in d[0]["slots"] if s["lane"]=="bad"][0]; print(s["state"], s["exit_code"])')
ck "$ST" "FAILED 7" "T2b failing lane derives FAILED 7"

# T3: silent kill (SIGKILL wrapper+child, like a harness group-kill) -> DIED
"$TD" --task demo --lane dead --exec /bin/bash -- -c 'sleep 60' >/dev/null 2>&1 &
WRAP=$!
sleep 1
CHILD=$(python3 -c "import json;print(json.load(open('$AGENT_SWITCHBOARD_ROOT/demo/slot-dead.json'))['pid'])")
kill -9 "$WRAP" "$CHILD" 2>/dev/null
sleep 1
ST=$("$SB" status --task demo --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print([s["state"] for s in d[0]["slots"] if s["lane"]=="dead"][0])')
ck "$ST" "DIED" "T3 silently killed lane derives DIED"

# T4: wait returns promptly on a lane completing (not at timeout)
"$TD" --task demo --lane w1 --exec /bin/bash -- -c 'sleep 3' >/dev/null 2>&1 &
sleep 0.5
T0=$(date +%s)
"$SB" wait --task demo --lane w1 --timeout 30 --interval 1 >/dev/null
RC=$?
DT=$(( $(date +%s) - T0 ))
ck "$RC" "0" "T4a wait exits 0 on lane event"
[ "$DT" -le 8 ] && ck ok ok "T4b wait returned in ${DT}s (<8s, not timeout)" || ck "$DT" "<=8" "T4b wait returned promptly"
wait

# T5: wait on already-terminal lanes returns immediately
T0=$(date +%s)
"$SB" wait --task demo --lane ok --timeout 20 >/dev/null
RC=$?
DT=$(( $(date +%s) - T0 ))
ck "$RC" "0" "T5a wait on terminal lane exits 0"
[ "$DT" -le 2 ] && ck ok ok "T5b immediate return (${DT}s)" || ck "$DT" "<=2" "T5b immediate return"

# T6: watch-file trigger
WF="$AGENT_SWITCHBOARD_ROOT/marker.txt"
( sleep 2; echo P3 > "$WF" ) &
T0=$(date +%s)
"$SB" wait --task demo --watch-file "$WF" --timeout 20 --interval 1 >/dev/null
RC=$?
DT=$(( $(date +%s) - T0 ))
ck "$RC" "0" "T6a wait exits 0 on file change"
[ "$DT" -le 6 ] && ck ok ok "T6b file trigger in ${DT}s" || ck "$DT" "<=6" "T6b file trigger prompt"
wait

# T7: capacity refusal
"$TD" --task demo --lane cap1 --exec /bin/bash -- -c 'sleep 15' >/dev/null 2>&1 &
sleep 0.5
"$TD" --task demo --lane cap2 --max 1 --exec /bin/bash -- -c 'true' >/dev/null 2>&1
ck "$?" "2" "T7 second dispatch refused at --max 1 (exit 2)"

# T8: same-lane active refusal without --replace
"$TD" --task demo --lane cap1 --exec /bin/bash -- -c 'true' >/dev/null 2>&1
ck "$?" "2" "T8 active same-lane dispatch refused (exit 2)"

# T9: timeout path exits 3
"$SB" wait --task demo --lane cap1 --timeout 3 --interval 1 >/dev/null
ck "$?" "3" "T9 wait timeout exits 3"

# T10: daemon smoke test on a test port
"$SB" serve --port 17999 >/dev/null 2>&1 &
SRV=$!
sleep 1.5
H=$(curl -s "http://127.0.0.1:17999/v1/health" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ok"])')
ck "$H" "True" "T10a daemon health ok"
N=$(curl -s "http://127.0.0.1:17999/v1/status?task=demo" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)[0]["slots"]))')
# 5 slots expected: ok,bad,dead,w1,cap1 (cap2 was refused, so no slot exists)
[ "$N" -ge 5 ] && ck ok ok "T10b daemon status lists $N slots" || ck "$N" ">=5" "T10b daemon status lists slots"
# long-poll: fires when cap1 finishes (watcher observes RUNNING->DONE)
CUR=$(curl -s "http://127.0.0.1:17999/v1/health" | python3 -c 'import json,sys; print(json.load(sys.stdin)["cursor"])')
T0=$(date +%s)
EV=$(curl -s "http://127.0.0.1:17999/v1/wait?task=demo&cursor=$CUR&timeout=30" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["events"][0]["to"] if d["events"] else "NONE")')
DT=$(( $(date +%s) - T0 ))
ck "$EV" "DONE" "T10c long-poll fired on lane completion (${DT}s)"
# second serve on the SAME port: the first is a HEALTHY peer, so the
# duplicate now exits 0.
"$SB" serve --port 17999 >/dev/null 2>&1
ck "$?" "0" "T10d second serve on same port exits 0 (healthy peer already serving)"
kill "$SRV" 2>/dev/null
wait 2>/dev/null

# ---- audit-round regressions (2026-08-09 grok-master findings) ----

# T11: child dead + wrapper alive => RUNNING (finalizing), NOT DIED (finding #1);
#      then wrapper also gone => DIED. Fake wrapper carries the agent-dispatch name.
bash -c 'exec -a agent-dispatch sleep 30' &
FAKEW=$!
sleep 0.2 &
DEADC=$!
wait $DEADC 2>/dev/null
python3 - "$AGENT_SWITCHBOARD_ROOT" "$DEADC" "$FAKEW" <<'EOF'
import json,sys,os,time
root,dead,fw=sys.argv[1],int(sys.argv[2]),int(sys.argv[3])
d=os.path.join(root,"demo")
json.dump({"task":"demo","lane":"fin","run_id":"t11","status":"running",
 "pid":dead,"wrapper_pid":fw,"prog":"/bin/bash","prog_base":"bash",
 "started":time.time()},open(os.path.join(d,"slot-fin.json"),"w"))
EOF
ST=$("$SB" status --task demo --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print([s["state"] for s in d[0]["slots"] if s["lane"]=="fin"][0])')
ck "$ST" "RUNNING" "T11a child-dead+wrapper-alive is RUNNING not DIED"
kill -9 "$FAKEW" 2>/dev/null; sleep 0.3
ST=$("$SB" status --task demo --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print([s["state"] for s in d[0]["slots"] if s["lane"]=="fin"][0])')
ck "$ST" "DIED" "T11b both gone is DIED"

# T12: stale wrapper must NOT clobber a newer slot (finding #2, run_id guard)
"$TD" --task demo --lane clob --exec /bin/bash -- -c 'sleep 2' >/dev/null 2>&1 &
sleep 0.6
python3 - "$AGENT_SWITCHBOARD_ROOT" <<'EOF'
import json,sys,os,time
p=os.path.join(sys.argv[1],"demo","slot-clob.json")
s=json.load(open(p)); s["run_id"]="NEWOWNER"; json.dump(s,open(p,"w"))
EOF
wait
NR=$(python3 -c "import json;print(json.load(open('$AGENT_SWITCHBOARD_ROOT/demo/slot-clob.json'))['run_id'])")
ck "$NR" "NEWOWNER" "T12a stale finalize did not clobber new owner"
grep -q stale_finalize_skipped "$AGENT_SWITCHBOARD_ROOT/demo/events.jsonl" && ck ok ok "T12b stale finalize logged" || ck missing logged "T12b stale finalize logged"

# T13: parallel dispatch race at --max 1 => exactly one refused (finding #4)
mkdir -p "$AGENT_SWITCHBOARD_ROOT/t13"
( "$TD" --task t13 --lane p1 --max 1 --exec /bin/bash -- -c 'sleep 2' >/dev/null 2>&1; echo $? > "$AGENT_SWITCHBOARD_ROOT/t13-rc1" ) &
( "$TD" --task t13 --lane p2 --max 1 --exec /bin/bash -- -c 'sleep 2' >/dev/null 2>&1; echo $? > "$AGENT_SWITCHBOARD_ROOT/t13-rc2" ) &
wait
RCS=$(sort "$AGENT_SWITCHBOARD_ROOT/t13-rc1" "$AGENT_SWITCHBOARD_ROOT/t13-rc2" | tr '\n' ' ' | xargs)
ck "$RCS" "0 2" "T13 parallel capacity race: exactly one refused"

# T14: corrupt slot surfaces as CORRUPT and blocks capacity (finding #8)
mkdir -p "$AGENT_SWITCHBOARD_ROOT/t14/history"
echo 'garbage{' > "$AGENT_SWITCHBOARD_ROOT/t14/slot-broken.json"
ST=$("$SB" status --task t14 --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["slots"][0]["state"])')
ck "$ST" "CORRUPT" "T14a corrupt slot visible as CORRUPT"
"$TD" --task t14 --lane fresh --max 1 --exec /bin/bash -- -c 'true' >/dev/null 2>&1
ck "$?" "2" "T14b corrupt slot counts toward capacity (fail-safe)"

# T16: wait on an ORPHAN-only task blocks (no early "all terminal" no-op spin)
mkdir -p "$AGENT_SWITCHBOARD_ROOT/t16/history"
bash -c 'exec -a orphanworker sleep 30' &
OW=$!
python3 - "$AGENT_SWITCHBOARD_ROOT" "$OW" <<'EOF'
import json,sys,os,time
root,ow=sys.argv[1],int(sys.argv[2])
json.dump({"task":"t16","lane":"orph","run_id":"t16","status":"running",
 "pid":ow,"wrapper_pid":999999,"prog":"orphanworker","prog_base":"orphanworker",
 "started":time.time()},open(os.path.join(root,"t16","slot-orph.json"),"w"))
EOF
ST=$("$SB" status --task t16 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["slots"][0]["state"])')
ck "$ST" "ORPHAN" "T16a crafted slot derives ORPHAN"
"$SB" wait --task t16 --timeout 3 --interval 1 >/dev/null
ck "$?" "3" "T16b wait on ORPHAN-only blocks to timeout (no no-op spin)"
kill -9 "$OW" 2>/dev/null

# T15: task name sanitization (finding #7)
"$TD" --task '../evil' --lane x --exec /bin/bash -- -c 'true' >/dev/null 2>&1
ck "$?" "2" "T15a dispatch rejects path-escape task name"
"$SB" status --task '../evil' >/dev/null 2>&1
ck "$?" "2" "T15b status rejects path-escape task name"

# ---- Daemon race + memory hardening ----

# T17: first-sight publish — a brand-new lane must be observable via
# /v1/wait immediately (old=None -> to=state), not only on its next real
# state transition (re-dispatch visibility scenario A).
"$SB" serve --port 17998 >/dev/null 2>&1 &
SRVA=$!
sleep 1.5
CUR=$(curl -s "http://127.0.0.1:17998/v1/health" | python3 -c 'import json,sys; print(json.load(sys.stdin)["cursor"])')
"$TD" --task t17 --lane fs --exec /bin/bash -- -c 'sleep 5' >/dev/null 2>&1 &
EV=$(curl -s "http://127.0.0.1:17998/v1/wait?task=t17&cursor=$CUR&timeout=10" | python3 -c '
import json, sys
d = json.load(sys.stdin)
hits = [e for e in d["events"] if e.get("lane") == "fs"]
print(hits[0]["from"], hits[0]["to"]) if hits else print("NONE")')
ck "$EV" "None RUNNING" "T17 first-sight publish observed via /v1/wait"
# NOTE: do not bare `wait` here — SRVA (serve_forever) is still running in
# the background and a plain `wait` would block on it forever; only wait on
# specific PIDs (see T18/T20/T21/T22) until SRVA is explicitly killed below.

# T18: 10 concurrent events.jsonl writers -> no interleaved/corrupt lines
WPIDS=()
for i in $(seq 1 10); do
  ( python3 - "$SB" "$i" <<'EOF'
import importlib.util, importlib.machinery, sys
loader = importlib.machinery.SourceFileLoader("sb", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
sb = importlib.util.module_from_spec(spec)
loader.exec_module(sb)
for j in range(100):
    sb.append_event("t18", {"event": "test", "writer": sys.argv[2], "j": j})
EOF
  ) &
  WPIDS+=($!)
done
for p in "${WPIDS[@]}"; do wait "$p" 2>/dev/null; done
LINES=$(wc -l < "$AGENT_SWITCHBOARD_ROOT/t18/events.jsonl" | tr -d ' ')
ck "$LINES" "1000" "T18a 10x100 concurrent writers produce exactly 1000 lines (no lost writes)"
BAD=$(python3 -c '
import json
bad = 0
for line in open("'"$AGENT_SWITCHBOARD_ROOT"'/t18/events.jsonl"):
    try:
        json.loads(line)
    except Exception:
        bad += 1
print(bad)')
ck "$BAD" "0" "T18b no corrupt/interleaved lines under concurrent append"

# T19: rotation triggers at threshold + /v1/events tail matches what was
# written (across the events.jsonl / events.jsonl.1 boundary), never a full
# readlines() of the whole file.
AGENT_SWITCHBOARD_EVENTS_MAX_BYTES=2000 python3 - "$SB" <<'EOF'
import importlib.util, importlib.machinery, sys
loader = importlib.machinery.SourceFileLoader("sb", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
sb = importlib.util.module_from_spec(spec)
loader.exec_module(sb)
for i in range(80):
    sb.append_event("t19", {"event": "test", "i": i})
EOF
if [ -f "$AGENT_SWITCHBOARD_ROOT/t19/events.jsonl.1" ]; then ck ok ok "T19a rotation created events.jsonl.1 at threshold"; else ck missing present "T19a rotation created events.jsonl.1"; fi
TAIL_IS=$(curl -s "http://127.0.0.1:17998/v1/events?task=t19&n=10" | python3 -c 'import json,sys; print(" ".join(str(e["i"]) for e in json.load(sys.stdin)))')
ck "$TAIL_IS" "70 71 72 73 74 75 76 77 78 79" "T19b /v1/events tail matches last 10 written events across rotation"

# T20: re-dispatch never drops the lane from /v1/status mid-swap (poll
# during the swap; the archive is a copy, the live slot path is atomically
# replaced and never unlinked — re-dispatch visibility).
"$TD" --task t20 --lane swap --exec /bin/bash -- -c 'true' >/dev/null 2>&1
: > "$AGENT_SWITCHBOARD_ROOT/t20-poll.log"
( for i in $(seq 1 60); do
    N=$(curl -s "http://127.0.0.1:17998/v1/status?task=t20" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len([s for s in d[0]["slots"] if s["lane"]=="swap"]))')
    echo "$N" >> "$AGENT_SWITCHBOARD_ROOT/t20-poll.log"
    sleep 0.02
  done ) &
POLLER=$!
sleep 0.1
"$TD" --task t20 --lane swap --exec /bin/bash -- -c 'sleep 1' >/dev/null 2>&1
wait "$POLLER" 2>/dev/null
MISSING=$(grep -c '^0$' "$AGENT_SWITCHBOARD_ROOT/t20-poll.log" || true)
ck "${MISSING:-0}" "0" "T20 /v1/status never drops the lane during re-dispatch swap"

kill "$SRVA" 2>/dev/null
wait 2>/dev/null

# T21: boot_id in /v1/health + /v1/wait, changes across a restart; a stale
# cursor that predates the trimmed ring gets gap:true and cursor:now.
AGENT_SWITCHBOARD_BUS_MAXLEN=5 "$SB" serve --port 17997 >/dev/null 2>&1 &
SRVB=$!
sleep 1.5
BOOT1=$(curl -s "http://127.0.0.1:17997/v1/health" | python3 -c 'import json,sys; print(json.load(sys.stdin)["boot_id"])')
ck "${#BOOT1}" "32" "T21a boot_id present in /v1/health (32-char hex)"

for i in 1 2 3 4 5 6 7 8; do
  "$TD" --task t21 --lane "churn$i" --exec /bin/bash -- -c 'true' >/dev/null 2>&1
done
sleep 1.5   # >= one watcher tick: 8 first-sight publishes overflow the 5-slot ring

WAIT_JSON=$(curl -s "http://127.0.0.1:17997/v1/wait?task=t21&cursor=0&timeout=3")
GAP=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get("gap", False), d["cursor"]>0)' "$WAIT_JSON")
ck "$GAP" "True True" "T21b stale cursor past the ring floor gets gap:true, cursor:now"
# Every /v1/wait reply must carry boot_id matching health.
WBOOT=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("boot_id",""))' "$WAIT_JSON")
ck "$WBOOT" "$BOOT1" "T21d /v1/wait reply boot_id matches /v1/health"

kill "$SRVB" 2>/dev/null
wait 2>/dev/null
sleep 0.3
AGENT_SWITCHBOARD_BUS_MAXLEN=5 "$SB" serve --port 17997 >/dev/null 2>&1 &
SRVB2=$!
sleep 1.5
BOOT2=$(curl -s "http://127.0.0.1:17997/v1/health" | python3 -c 'import json,sys; print(json.load(sys.stdin)["boot_id"])')
if [ "$BOOT1" != "$BOOT2" ]; then ck ok ok "T21c boot_id changes across a daemon restart"; else ck "$BOOT1" "!=$BOOT2" "T21c boot_id changes across restart"; fi
kill "$SRVB2" 2>/dev/null
wait 2>/dev/null

# T22: cold-archive moves long-finished slots to history/ on a watcher pass;
# status/watcher exclude them afterward (T41 is the 15-min served-board
# filter — files stay; this test is the 24h file-move).
AGENT_SWITCHBOARD_COLD_AFTER=1 "$SB" serve --port 17996 >/dev/null 2>&1 &
SRVC=$!
sleep 1.5
"$TD" --task t22 --lane cold --exec /bin/bash -- -c 'true' >/dev/null 2>&1
sleep 3   # well past COLD_AFTER=1s, across a couple of 1s watcher ticks
N=$(curl -s "http://127.0.0.1:17996/v1/status?task=t22" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)[0]["slots"]))')
ck "$N" "0" "T22a cold-archived slot excluded from /v1/status"
HIST=$(ls "$AGENT_SWITCHBOARD_ROOT/t22/history" 2>/dev/null | grep -c '^cold-')
ck "$HIST" "1" "T22b cold-archived slot file moved into history/"
if [ -f "$AGENT_SWITCHBOARD_ROOT/t22/slot-cold.json" ]; then ck present absent "T22c live slot file removed after cold-archive"; else ck ok ok "T22c live slot file removed after cold-archive"; fi
kill "$SRVC" 2>/dev/null
wait 2>/dev/null

# ---- CLI forest + /v1/cli ----
# Ports 17985-17989 only (never 17920; b4 owns 17995-17999).

# T23: synthetic-snap forest attach (R2.1/R2.5 fixtures) — no live ps.
python3 - "$SB" <<'EOF'
import importlib.machinery, importlib.util, sys, json

loader = importlib.machinery.SourceFileLoader("sb", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
sb = importlib.util.module_from_spec(spec)
loader.exec_module(sb)

NOW = 1723252800.0  # fixed for stable uptime
LSTART = "Fri Aug  9 12:00:00 2024"  # parses; uptime computed from NOW


def rec(pid, ppid, tty, command, lstart=LSTART):
    return {"pid": pid, "ppid": ppid, "tty": tty, "lstart": lstart, "command": command}


def find(nodes, pred):
    for n in nodes:
        if pred(n):
            return n
        hit = find(n.get("children") or [], pred)
        if hit:
            return hit
    return None


def assert_true(cond, msg):
    if not cond:
        print("FAIL_ASSERT", msg)
        sys.exit(1)


# --- Fixture (i): claude -> zsh -c -> agent-dispatch -> grok-ask x2 -> grok
# collapses to claude -> agent_dispatch(task/lane) -> grok(channel)
snap_i = {
    100: rec(100, 1, "ttys001", "claude"),
    200: rec(200, 100, "??", "zsh -c 'tool shell'"),
    300: rec(
        300,
        200,
        "??",
        "/usr/bin/Python /usr/local/bin/agent-dispatch "
        "--task mytask --lane spike-x --report /tmp/r.md -- "
        "grok-ask -w -c ch-x",
    ),
    400: rec(
        400,
        300,
        "??",
        "/bin/bash /usr/local/bin/grok-ask -w -c ch-x -d /tmp/lane",
    ),
    401: rec(
        401,
        400,
        "??",
        "/bin/bash /usr/local/bin/grok-ask -w -c ch-x -d /tmp/lane",
    ),
    500: rec(
        500,
        401,
        "??",
        "/home/user/.grok/bin/grok -p HUGE_PROMPT --output-format json "
        "--cwd /tmp/lane --always-approve",
    ),
}
forest_i = sb.build_cli_forest(snap_i, now=NOW)
roots_i = forest_i["roots"]
assert_true(len(roots_i) == 1 and roots_i[0]["kind"] == "claude", "i: one claude root")
assert_true(roots_i[0]["mode"] == "interactive" and roots_i[0]["tty"] == "ttys001", "i: claude interactive tty")
assert_true(roots_i[0].get("started") and roots_i[0].get("started_iso"), "i: started+started_iso")
assert_true(roots_i[0]["started"] == roots_i[0]["started_iso"], "i: started == started_iso")
kids = roots_i[0]["children"]
assert_true(len(kids) == 1 and kids[0]["kind"] == "agent_dispatch", "i: agent_dispatch under claude")
assert_true(kids[0]["label"] == "mytask/spike-x", "i: agent_dispatch label task/lane")
gk = kids[0]["children"]
assert_true(len(gk) == 1 and gk[0]["kind"] == "grok", "i: grok under agent_dispatch")
assert_true(gk[0].get("channel") == "ch-x" or gk[0].get("label") == "ch-x", "i: grok channel")
assert_true(gk[0]["mode"] == "headless", "i: grok headless")
# no grok_ask / shell nodes emitted
def all_kinds(nodes, acc=None):
    acc = acc if acc is not None else []
    for n in nodes:
        acc.append(n["kind"])
        all_kinds(n.get("children") or [], acc)
    return acc
ks = all_kinds(roots_i)
assert_true(ks.count("agent_dispatch") == 1 and "grok_ask" not in ks, "i: no grok_ask nodes")
assert_true(
    forest_i["counts"]["claude"]["interactive"] == 1
    and forest_i["counts"]["claude"]["headless"] == 0
    and forest_i["counts"]["grok"]["interactive"] == 0
    and forest_i["counts"]["grok"]["headless"] == 1,
    "i: counts exclude agent_dispatch, shape nested",
)
# total CLI nodes = 2 (claude+grok), agent_dispatch not in counts
total_cli = (
    forest_i["counts"]["claude"]["interactive"]
    + forest_i["counts"]["claude"]["headless"]
    + forest_i["counts"]["grok"]["interactive"]
    + forest_i["counts"]["grok"]["headless"]
)
assert_true(total_cli == 2, "i: counts total 2 (no agent_dispatch)")
print("PASS_UNIT T23a fixture i bee chain collapse")

# --- Fixture (ii): master without agent-dispatch -> grok child of claude
snap_ii = {
    100: rec(100, 1, "ttys001", "claude"),
    200: rec(200, 100, "??", "zsh -c 'master spawn'"),
    400: rec(
        400,
        200,
        "??",
        "/bin/bash /usr/local/bin/grok-ask -c master-mytask -d /tmp/m",
    ),
    401: rec(
        401,
        400,
        "??",
        "/bin/bash /usr/local/bin/grok-ask -c master-mytask -d /tmp/m",
    ),
    500: rec(500, 401, "??", "/home/user/.grok/bin/grok -p MASTER_PROMPT --cwd /tmp/m"),
}
forest_ii = sb.build_cli_forest(snap_ii, now=NOW)
roots_ii = forest_ii["roots"]
assert_true(len(roots_ii) == 1 and roots_ii[0]["kind"] == "claude", "ii: claude root")
assert_true(
    len(roots_ii[0]["children"]) == 1 and roots_ii[0]["children"][0]["kind"] == "grok",
    "ii: grok direct child of claude",
)
assert_true(
    roots_ii[0]["children"][0].get("label") == "master-mytask"
    or roots_ii[0]["children"][0].get("channel") == "master-mytask",
    "ii: channel master-mytask",
)
assert_true(
    all(n["kind"] != "agent_dispatch" for n in roots_ii[0]["children"]),
    "ii: no agent_dispatch",
)
print("PASS_UNIT T23b fixture ii master collapse")

# --- Fixture (iii): standalone interactive grok is a root with tty
snap_iii = {
    900: rec(900, 1, "ttys009", "/home/user/.grok/bin/grok"),
}
forest_iii = sb.build_cli_forest(snap_iii, now=NOW)
roots_iii = forest_iii["roots"]
assert_true(len(roots_iii) == 1, "iii: one root")
assert_true(roots_iii[0]["kind"] == "grok", "iii: kind grok")
assert_true(roots_iii[0]["mode"] == "interactive", "iii: interactive")
assert_true(roots_iii[0]["tty"] == "ttys009", "iii: tty")
assert_true(roots_iii[0].get("started") == roots_iii[0].get("started_iso"), "iii: started pair")
print("PASS_UNIT T23c fixture iii standalone interactive grok")

# --- Model: -m argv wins; fallback path when absent
snap_m = {
    1: rec(1, 0, "??", "/home/user/.grok/bin/grok -m custom-model-xyz -p hi"),
    2: rec(2, 0, "ttys001", "claude"),
}
forest_m = sb.build_cli_forest(snap_m, now=NOW)
g = find(forest_m["roots"], lambda n: n["pid"] == 1)
c = find(forest_m["roots"], lambda n: n["pid"] == 2)
assert_true(g and g.get("model") == "custom-model-xyz", "model from -m argv")
assert_true(c and c.get("model"), "claude model fallback present")
print("PASS_UNIT T23d model argv + fallback")

# --- viewer_running / cli_busy pure on synthetic snap
snap_v = {
    10: rec(10, 1, "??", "/Applications/Agent Switchboard.app/Contents/MacOS/agent-switchboard"),
    11: rec(11, 1, "??", "/usr/bin/Python /tmp/bin/switchboard serve --port 17920"),
}
assert_true(sb.viewer_running(snap_v) is True, "viewer_running matches app path")
assert_true(sb.cli_busy(snap_v) is False, "viewer is not a CLI; cli_busy false")
snap_cli = {12: rec(12, 1, "ttys001", "claude")}
assert_true(sb.cli_busy(snap_cli) is True, "cli_busy true for claude")
assert_true(sb.viewer_running(snap_cli) is False, "viewer_running false without viewer")
print("PASS_UNIT T23e cli_busy + viewer_running")

# --- TTL: two get_cli_payload within 1s => one sweep (mock ps)
sb.reset_cli_cache()
calls = {"n": 0}
real_ps = sb.ps_cli_snapshot

def fake_ps():
    calls["n"] += 1
    return snap_iii

sb.ps_cli_snapshot = fake_ps
p1 = sb.get_cli_payload(boot_id="a" * 32)
p2 = sb.get_cli_payload(boot_id="a" * 32)
assert_true(calls["n"] == 1, "TTL: one sweep for two calls")
assert_true(p1["cached"] is False and p2["cached"] is True, "TTL: second is cache hit")
assert_true(p1["sweep_count"] == p2["sweep_count"] == 1, "TTL: sweep_count stays 1")
sb.ps_cli_snapshot = real_ps
sb.reset_cli_cache()
print("PASS_UNIT T23f cache TTL one sweep")

print("ALL_UNIT_OK")
EOF
UNIT_RC=$?
if [ "$UNIT_RC" -eq 0 ]; then
  # Count the PASS_UNIT lines as individual assertions for the suite total.
  ck ok ok "T23a synthetic fixture i: claude->agent_dispatch->grok collapse"
  ck ok ok "T23b synthetic fixture ii: master grok under claude (no agent_dispatch)"
  ck ok ok "T23c synthetic fixture iii: standalone interactive grok root+tty"
  ck ok ok "T23d model from -m argv + config fallback"
  ck ok ok "T23e cli_busy / viewer_running (viewer not CLI)"
  ck ok ok "T23f /v1/cli cache TTL: two calls => one sweep"
else
  ck fail ok "T23 synthetic forest unit block (see FAIL_ASSERT above)"
fi

# T24: live GET /v1/cli shape + sweep cost <100ms + TTL via daemon (port 17985)
"$SB" serve --port 17985 >/tmp/sb-b2-serve-17985.log 2>&1 &
SRVD=$!
sleep 1.5
CLI1=$(curl -s "http://127.0.0.1:17985/v1/cli")
CLI2=$(curl -s "http://127.0.0.1:17985/v1/cli")
SHAPE=$(python3 -c '
import json,sys
d1=json.loads(sys.argv[1]); d2=json.loads(sys.argv[2])
ok = True
msgs = []
for key in ("ts","boot_id","counts","roots"):
    if key not in d1:
        ok=False; msgs.append("missing "+key)
c=d1.get("counts") or {}
if not (isinstance(c.get("claude"), dict) and isinstance(c.get("grok"), dict) and isinstance(c.get("cursor"), dict)):
    ok=False; msgs.append("counts not nested interactive/headless (claude/grok/cursor)")
else:
    for k in ("claude","grok","cursor"):
        for m in ("interactive","headless"):
            if m not in c[k]:
                ok=False; msgs.append("counts.%s missing %s"%(k,m))
if not isinstance(d1.get("roots"), list):
    ok=False; msgs.append("roots not list")
# every node has started + started_iso equal, kind enum, model
def walk(nodes):
    for n in nodes or []:
        yield n
        yield from walk(n.get("children") or [])
for n in walk(d1.get("roots")):
    if n.get("kind") not in ("claude","grok","cursor","agent_dispatch","grok-sub","cursor-sub"):
        ok=False; msgs.append("bad kind "+str(n.get("kind")))
    if "started" not in n or "started_iso" not in n:
        ok=False; msgs.append("missing started pair on pid %s"%n.get("pid"))
    elif n.get("started") != n.get("started_iso"):
        ok=False; msgs.append("started!=started_iso pid %s"%n.get("pid"))
    if "model" not in n:
        ok=False; msgs.append("missing model pid %s"%n.get("pid"))
    if n.get("mode") not in ("interactive","headless"):
        ok=False; msgs.append("bad mode")
# TTL: second call must be cache hit, same sweep_count
if d2.get("cached") is not True:
    ok=False; msgs.append("second call not cached")
if d1.get("sweep_count") != d2.get("sweep_count"):
    ok=False; msgs.append("sweep_count changed within TTL")
sm = d1.get("sweep_ms")
if sm is None or float(sm) >= 100:
    ok=False; msgs.append("sweep_ms not under 100 (got %s)"%sm)
print("OK" if ok else "BAD:"+",".join(msgs))
' "$CLI1" "$CLI2")
ck "$SHAPE" "OK" "T24a GET /v1/cli shape + started pair + model + TTL + sweep<100ms"
# boot_id matches health
BCLI=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["boot_id"])' "$CLI1")
BHEALTH=$(curl -s "http://127.0.0.1:17985/v1/health" | python3 -c 'import json,sys; print(json.load(sys.stdin)["boot_id"])')
ck "$BCLI" "$BHEALTH" "T24b /v1/cli boot_id matches /v1/health"
kill "$SRVD" 2>/dev/null
wait 2>/dev/null

# ---- Server lifecycle: single instance + idle
# shutdown + graceful drain + wait cap). Ports 17975-17979 only (never
# 17920; b2 owns 17985-17989, b4 owns 17995-17999). ----

# T25/T26 use an ISOLATED state root, never the shared $AGENT_SWITCHBOARD_ROOT:
# T14 (above) deliberately leaves a permanently-CORRUPT slot behind in the
# shared root (t14/slot-broken.json) to prove CORRUPT surfaces forever — and
# CORRUPT is one of the ACTIVE_SLOT_STATES the busy predicate ORs in. Reusing
# the shared root here would make "any ACTIVE slot" true forever from that
# unrelated leftover fixture, so idle-exit would never arm. A fresh root
# isolates the idle-exit tests from that (and from every other test's slots).
IDLE_ROOT="${AGENT_SWITCHBOARD_ROOT}-idle"
mkdir -p "$IDLE_ROOT"

# T25: idle-exit — AGENT_SWITCHBOARD_IDLE_GRACE=2 + AGENT_SWITCHBOARD_IDLE_TEST_FORCE=1
# (forces the cli/viewer OR-terms to read not-busy on this dev machine,
# which may have a real claude/grok session attached) with no ACTIVE slot
# in any task -> the daemon self-exits 0 within grace+2s.
AGENT_SWITCHBOARD_ROOT="$IDLE_ROOT" AGENT_SWITCHBOARD_IDLE_GRACE=2 AGENT_SWITCHBOARD_IDLE_TEST_FORCE=1 "$SB" serve --port 17975 >/tmp/sb-t25.log 2>&1 &
SRV25=$!
T0=$(date +%s)
wait "$SRV25" 2>/dev/null
RC25=$?
DT25=$(( $(date +%s) - T0 ))
ck "$RC25" "0" "T25a idle-exit process exit code 0"
[ "$DT25" -le 8 ] && ck ok ok "T25b idle-exit total uptime ${DT25}s (grace=2, within tolerance)" || ck "$DT25" "<=8" "T25b idle-exit within grace+2s bound"

# T25c: AGENT_SWITCHBOARD_IDLE_DISABLE=1 is the deploy safety valve — it must
# completely disable idle-exit even with the same short grace + force hook
# + no active slot.
AGENT_SWITCHBOARD_ROOT="$IDLE_ROOT" AGENT_SWITCHBOARD_IDLE_GRACE=2 AGENT_SWITCHBOARD_IDLE_TEST_FORCE=1 AGENT_SWITCHBOARD_IDLE_DISABLE=1 "$SB" serve --port 17975 >/tmp/sb-t25c.log 2>&1 &
SRV25B=$!
sleep 5
if kill -0 "$SRV25B" 2>/dev/null; then ck ok ok "T25c AGENT_SWITCHBOARD_IDLE_DISABLE=1 keeps daemon up past grace+2s"; else ck exited running "T25c AGENT_SWITCHBOARD_IDLE_DISABLE=1 keeps daemon up past grace+2s"; fi
kill "$SRV25B" 2>/dev/null
wait 2>/dev/null

# T26: an ACTIVE slot (RUNNING) in ANY task blocks idle-exit even with
# AGENT_SWITCHBOARD_IDLE_TEST_FORCE=1 — the active-slot OR-term of the busy
# predicate is never masked by the test force hook (R2.5 busy predicate).
# Same isolated root, plus a fresh task so no other test's slot is involved.
AGENT_SWITCHBOARD_ROOT="$IDLE_ROOT" AGENT_SWITCHBOARD_IDLE_GRACE=2 AGENT_SWITCHBOARD_IDLE_TEST_FORCE=1 "$SB" serve --port 17976 >/tmp/sb-t26.log 2>&1 &
SRV26=$!
sleep 1.5
AGENT_SWITCHBOARD_ROOT="$IDLE_ROOT" "$TD" --task t26 --lane busy --exec /bin/bash -- -c 'sleep 8' >/dev/null 2>&1 &
sleep 6
if kill -0 "$SRV26" 2>/dev/null; then ck ok ok "T26a daemon stays up with an ACTIVE slot present (past grace+2s)"; else ck exited running "T26a daemon stays up with an ACTIVE slot present"; fi
BR=$(curl -s --max-time 2 "http://127.0.0.1:17976/v1/health" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("slots" in d.get("busy_reasons",[]))' 2>/dev/null)
ck "$BR" "True" "T26b busy_reasons includes slots (T6 /v1/health nice-to-have)"
kill "$SRV26" 2>/dev/null
wait 2>/dev/null

# T27: two serves on the SAME scratch port — the second sees a healthy peer
# and exits 0 immediately; the first is untouched and keeps serving
# (distinct from T10d, which covers the same contract on b4's port).
"$SB" serve --port 17977 >/tmp/sb-t27.log 2>&1 &
SRV27=$!
sleep 1.5
H1=$(curl -s --max-time 2 "http://127.0.0.1:17977/v1/health" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ok"])' 2>/dev/null)
ck "$H1" "True" "T27a first daemon on 17977 healthy"
"$SB" serve --port 17977 >/tmp/sb-t27-dup.log 2>&1
ck "$?" "0" "T27b duplicate serve on 17977 exits 0 (healthy peer)"
H2=$(curl -s --max-time 2 "http://127.0.0.1:17977/v1/health" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ok"])' 2>/dev/null)
ck "$H2" "True" "T27c first daemon still serving after duplicate exited"
# ensure_daemon() healthy-path smoke test: a PER-COMMAND env override (not
# the whole-suite AGENT_SWITCHBOARD_ENSURE_DISABLE=1) proves the short-circuit —
# health already ok -> True immediately, no kickstart/spawn ever attempted.
EDOK=$(env AGENT_SWITCHBOARD_ENSURE_DISABLE=0 AGENT_SWITCHBOARD_HOST=127.0.0.1 AGENT_SWITCHBOARD_PORT=17977 python3 - "$SB" <<'EOF'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("sb", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
sb = importlib.util.module_from_spec(spec)
loader.exec_module(sb)
print(sb.ensure_daemon())
EOF
)
ck "$EDOK" "True" "T27d ensure_daemon() returns True immediately for an already-healthy peer"
kill "$SRV27" 2>/dev/null
wait 2>/dev/null

# T28: SIGTERM drains gracefully — a pending /v1/wait unblocks and the
# daemon process itself is gone within 3s (bounded join; H1/H2/H5: "a wait
# that cannot be woken is a lane failure").
"$SB" serve --port 17978 >/tmp/sb-t28.log 2>&1 &
SRV28=$!
sleep 1.5
CUR28=$(curl -s --max-time 2 "http://127.0.0.1:17978/v1/health" | python3 -c 'import json,sys; print(json.load(sys.stdin)["cursor"])')
( curl -s --max-time 20 "http://127.0.0.1:17978/v1/wait?task=t28&cursor=$CUR28&timeout=15" > "$AGENT_SWITCHBOARD_ROOT/t28-wait.out" ) &
sleep 1
kill -TERM "$SRV28"
T0=$(date +%s)
wait "$SRV28" 2>/dev/null
DT28=$(( $(date +%s) - T0 ))
[ "$DT28" -le 3 ] && ck ok ok "T28a SIGTERM drain completed in ${DT28}s (<=3s)" || ck "$DT28" "<=3" "T28a SIGTERM drain within 3s"
LEFT=$(pgrep -f "switchboard serve.*--port 17978" | wc -l | tr -d ' ')
ck "$LEFT" "0" "T28b no leaked switchboard process on port 17978 after SIGTERM"
wait 2>/dev/null

# T29: /v1/wait concurrency cap — over cap returns 503 with Retry-After: 5
# (default cap 24, AGENT_SWITCHBOARD_WAIT_CAP overrides for tests).
AGENT_SWITCHBOARD_WAIT_CAP=2 "$SB" serve --port 17979 >/tmp/sb-t29.log 2>&1 &
SRV29=$!
sleep 1.5
CUR29=$(curl -s --max-time 2 "http://127.0.0.1:17979/v1/health" | python3 -c 'import json,sys; print(json.load(sys.stdin)["cursor"])')
curl -s --max-time 20 "http://127.0.0.1:17979/v1/wait?task=t29&cursor=$CUR29&timeout=10" >/dev/null &
curl -s --max-time 20 "http://127.0.0.1:17979/v1/wait?task=t29&cursor=$CUR29&timeout=10" >/dev/null &
sleep 0.5
CODE=$(curl -s -o "$AGENT_SWITCHBOARD_ROOT/t29-body.json" -D "$AGENT_SWITCHBOARD_ROOT/t29-headers.txt" -w "%{http_code}" --max-time 5 "http://127.0.0.1:17979/v1/wait?task=t29&cursor=$CUR29&timeout=10")
ck "$CODE" "503" "T29a wait over-cap returns 503"
RA=$(grep -i '^Retry-After:' "$AGENT_SWITCHBOARD_ROOT/t29-headers.txt" | tr -d '\r' | awk '{print $2}')
ck "$RA" "5" "T29b 503 response carries Retry-After: 5"
BODY_OK=$(python3 -c 'import json; d=json.load(open("'"$AGENT_SWITCHBOARD_ROOT"'/t29-body.json")); print(d.get("error")=="wait_capacity")')
ck "$BODY_OK" "True" "T29c 503 body reports wait_capacity"
kill "$SRV29" 2>/dev/null
wait 2>/dev/null

# ---- Gap-closure tests (empty-snap hardening).
# Ports 17965-17969 for anything new; reuse owned ranges where
# the gap belongs to that surface. ----

# T30: same-tick RUNNING->terminal->RUNNING double bus publish.
# Drive watcher_loop with a controlled slot swap between ticks
# so last stores (RUNNING, old_run_id) then the live slot becomes RUNNING
# with a new run_id + history archive of the old exited run. Expect TWO
# lane events: RUNNING->DONE and DONE->RUNNING (not a silent no-op).
python3 - "$SB" <<'EOF'
import importlib.machinery, importlib.util, json, os, sys, tempfile, threading, time
import subprocess, shutil

root = tempfile.mkdtemp(prefix="sb-t30-")
os.environ["AGENT_SWITCHBOARD_ROOT"] = root  # must be set BEFORE import (ROOT)

loader = importlib.machinery.SourceFileLoader("sb", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
sb = importlib.util.module_from_spec(spec)
loader.exec_module(sb)

task, lane = "t30", "dbl"
tdir = os.path.join(root, task)
os.makedirs(os.path.join(tdir, "history"), exist_ok=True)

# derive() requires wrapper argv to contain "agent-dispatch" (T11 pattern)
# and child identity prog_base in command. Both must be alive for RUNNING.
wrapper = subprocess.Popen(["bash", "-c", "exec -a agent-dispatch sleep 120"])
child = subprocess.Popen(["/bin/sleep", "120"])
old_run = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
new_run = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
slot_path = os.path.join(tdir, f"slot-{lane}.json")

def write_slot(run_id, pid, wrapper_pid, status="running", exit_code=None, ended=None):
    obj = {
        "task": task, "lane": lane, "run_id": run_id, "status": status,
        "pid": pid, "wrapper_pid": wrapper_pid, "prog": "/bin/sleep",
        "prog_base": "sleep", "started": time.time(),
        "exit_code": exit_code, "ended": ended,
    }
    with open(slot_path, "w") as f:
        json.dump(obj, f)
    return obj

write_slot(old_run, child.pid, wrapper.pid)
time.sleep(0.15)  # let procs settle in ps

bus = sb.EventBus(maxlen=50)
stop = threading.Event()
th = threading.Thread(
    target=sb.watcher_loop,
    args=(bus, 30.0, stop),
    kwargs={"tick": 0.15, "idle_cb": None},
    daemon=True,
)
th.start()
time.sleep(0.5)  # >=2 ticks so last[(task,lane)] = (RUNNING, old_run)

# Same-tick re-dispatch simulation: archive old as exited DONE, replace live
# with new RUNNING run_id (agent-dispatch copy-archive + atomic write).
old_slot = json.load(open(slot_path))
old_slot["status"] = "exited"
old_slot["exit_code"] = 0
old_slot["ended"] = time.time()
hist = os.path.join(tdir, "history", f"{lane}-t30test-{old_run[:8]}.json")
with open(hist, "w") as f:
    json.dump(old_slot, f)
# New dispatch reuses fresh worker+wrapper (still alive sleepers work).
write_slot(new_run, child.pid, wrapper.pid)

time.sleep(0.5)  # allow watcher to observe run_id change
stop.set()
th.join(timeout=2)

with bus.cond:
    evs = [e for e in bus.events if e.get("lane") == lane and e.get("event") == "lane"]
pairs = [(e.get("from"), e.get("to")) for e in evs]
ok_double = False
for i in range(len(pairs) - 1):
    if pairs[i] == ("RUNNING", "DONE") and pairs[i + 1] == ("DONE", "RUNNING"):
        ok_double = True
        break
if not ok_double:
    for i in range(len(pairs) - 1):
        if pairs[i][0] == "RUNNING" and pairs[i][1] in ("DONE", "FAILED") and pairs[i + 1][1] == "RUNNING":
            ok_double = True
            break

print("PAIRS", pairs)
print("OK" if ok_double else "BAD")
for p in (child, wrapper):
    try:
        p.kill()
        p.wait(timeout=1)
    except Exception:
        pass
shutil.rmtree(root, ignore_errors=True)
sys.exit(0 if ok_double else 1)
EOF
if [ $? -eq 0 ]; then ck ok ok "T30 same-tick RUNNING->DONE->RUNNING double bus publish"; else ck fail ok "T30 same-tick RUNNING->DONE->RUNNING double bus publish"; fi

# T31: live /v1/cli forest — suite dispatches a real headless "grok" worker
# under agent-dispatch and asserts it appears HEADLESS under its own
# agent_dispatch node.
# Uses a tiny compiled sleeper named `grok` (not a real LLM) so argv0
# identity matches; never binds 17920.
T31_BIN=$(mktemp -d)
cat > "$T31_BIN/g.c" <<'CEOF'
#include <unistd.h>
#include <stdlib.h>
int main(int argc, char **argv) {
  int s = 30;
  if (argc > 1) s = atoi(argv[1]);
  sleep(s);
  return 0;
}
CEOF
cc -O0 -o "$T31_BIN/grok" "$T31_BIN/g.c" 2>/dev/null
if [ ! -x "$T31_BIN/grok" ]; then
  ck missing binary "T31a compiled headless grok fixture available"
else
  ck ok ok "T31a compiled headless grok fixture available"
  # Short TTL so the post-dispatch /v1/cli call is a real sweep, not a
  # pre-dispatch cache hit (default TTL is 5s).
  AGENT_SWITCHBOARD_CLI_CACHE_TTL=0.5 "$SB" serve --port 17985 >/tmp/sb-t31-serve.log 2>&1 &
  SRV31=$!
  sleep 1.5
  "$TD" --task t31 --lane forest --exec "$T31_BIN/grok" -- 25 >/dev/null 2>&1 &
  TD31=$!
  sleep 1.0
  # One more half-second past TTL so the forest reflects the new worker.
  sleep 0.6
  CLI31=$(curl -s --max-time 5 "http://127.0.0.1:17985/v1/cli")
  FOREST_OK=$(python3 -c '
import json,sys
d=json.loads(sys.argv[1])
def walk(nodes):
    for n in nodes or []:
        yield n
        yield from walk(n.get("children") or [])
found=False
for n in walk(d.get("roots")):
    if n.get("kind")=="agent_dispatch" and n.get("label")=="t31/forest":
        for c in (n.get("children") or []):
            if c.get("kind")=="grok" and c.get("mode")=="headless":
                found=True
print("OK" if found else "BAD")
' "$CLI31")
  ck "$FOREST_OK" "OK" "T31b live /v1/cli: dispatched grok HEADLESS under agent_dispatch t31/forest"
  # Cleanup worker + daemon
  if [ -f "$AGENT_SWITCHBOARD_ROOT/t31/slot-forest.json" ]; then
    CHILD31=$(python3 -c "import json;print(json.load(open('$AGENT_SWITCHBOARD_ROOT/t31/slot-forest.json')).get('pid',0))")
    kill -9 "$TD31" "$CHILD31" 2>/dev/null
  else
    kill -9 "$TD31" 2>/dev/null
  fi
  kill "$SRV31" 2>/dev/null
  wait 2>/dev/null
fi
rm -rf "$T31_BIN"

# T32: fail-closed ps path — when ps_cli_snapshot returns None, busy_reasons
# reports ps_unavailable. Driven via
# watcher_loop + monkeypatch (no live serve required for the reason string).
python3 - "$SB" <<'EOF'
import importlib.machinery, importlib.util, sys, tempfile, os, threading, time, shutil

root = tempfile.mkdtemp(prefix="sb-t32-")
os.environ["AGENT_SWITCHBOARD_ROOT"] = root
os.makedirs(root, exist_ok=True)

loader = importlib.machinery.SourceFileLoader("sb", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
sb = importlib.util.module_from_spec(spec)
loader.exec_module(sb)

sb.ps_cli_snapshot = lambda: None
bus = sb.EventBus()
stop = threading.Event()
th = threading.Thread(
    target=sb.watcher_loop, args=(bus, 30.0, stop),
    kwargs={"tick": 0.1, "idle_cb": None}, daemon=True,
)
th.start()
time.sleep(0.35)
reasons = sb.get_busy_reasons()
stop.set()
th.join(timeout=2)
ok = reasons == ["ps_unavailable"]
print("REASONS", reasons)
print("OK" if ok else "BAD")
shutil.rmtree(root, ignore_errors=True)
sys.exit(0 if ok else 1)
EOF
if [ $? -eq 0 ]; then ck ok ok "T32 ps_cli_snapshot=None -> busy_reasons=[ps_unavailable]"; else ck fail ok "T32 ps_cli_snapshot=None -> busy_reasons=[ps_unavailable]"; fi

# T33: dead-socket EADDRINUSE — port held by a non-HTTP listener so health
# probe fails; second serve must exit 1 with actionable path. Port 17965 (new range).
python3 - "$SB" <<'EOF'
import importlib.machinery, importlib.util, socket, subprocess, sys, time, os

PORT = 17965
# Bind TCP and hold it without speaking HTTP.
holder = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
holder.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
holder.bind(("127.0.0.1", PORT))
holder.listen(1)

sb_bin = sys.argv[1]
env = os.environ.copy()
env["AGENT_SWITCHBOARD_ENSURE_DISABLE"] = "1"
# Isolated root so this cannot touch live state.
import tempfile
root = tempfile.mkdtemp(prefix="sb-t33-")
env["AGENT_SWITCHBOARD_ROOT"] = root
p = subprocess.run(
    [sb_bin, "serve", "--port", str(PORT), "--host", "127.0.0.1"],
    capture_output=True, text=True, env=env, timeout=8,
)
holder.close()
import shutil
shutil.rmtree(root, ignore_errors=True)
rc = p.returncode
err = (p.stderr or "") + (p.stdout or "")
ok = rc == 1 and ("lsof" in err.lower() or "no healthy peer" in err.lower() or "cannot bind" in err.lower())
print("RC", rc)
print("ERR_SNIP", err[:300].replace("\n", " | "))
print("OK" if ok else "BAD")
sys.exit(0 if ok else 1)
EOF
if [ $? -eq 0 ]; then ck ok ok "T33 dead-socket EADDRINUSE exits 1 (no healthy peer)"; else ck fail ok "T33 dead-socket EADDRINUSE exits 1 (no healthy peer)"; fi

# T34: empty ps mapping is BUSY (fail-closed) — parse total
# failure must not look like an idle machine.
python3 - "$SB" <<'EOF'
import importlib.machinery, importlib.util, sys, tempfile, os, threading, time, shutil

root = tempfile.mkdtemp(prefix="sb-t34-")
os.environ["AGENT_SWITCHBOARD_ROOT"] = root
os.makedirs(root, exist_ok=True)

loader = importlib.machinery.SourceFileLoader("sb", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
sb = importlib.util.module_from_spec(spec)
loader.exec_module(sb)

sb.ps_cli_snapshot = lambda: {}  # empty mapping = parse failure, not idle
bus = sb.EventBus()
stop = threading.Event()
th = threading.Thread(
    target=sb.watcher_loop, args=(bus, 30.0, stop),
    kwargs={"tick": 0.1, "idle_cb": None}, daemon=True,
)
th.start()
time.sleep(0.35)
reasons = sb.get_busy_reasons()
stop.set()
th.join(timeout=2)
ok = reasons == ["ps_unavailable"]
print("REASONS", reasons)
print("OK" if ok else "BAD")
shutil.rmtree(root, ignore_errors=True)
sys.exit(0 if ok else 1)
EOF
if [ $? -eq 0 ]; then ck ok ok "T34 empty ps mapping -> busy_reasons=[ps_unavailable] (fail-closed)"; else ck fail ok "T34 empty ps mapping -> busy_reasons=[ps_unavailable] (fail-closed)"; fi

# T25c already covers HARDENING (b) AGENT_SWITCHBOARD_IDLE_DISABLE=1; re-asserted
# here as a checklist item only if someone deletes T25c — the
# count still lives under T25c (no duplicate assertion).

# ---- v1.3.0: model truth, sid graft, stall, advise, refuse ----

python3 - "$SB" <<'EOF'
import importlib.machinery, importlib.util, sys, os, json, tempfile, shutil, time

loader = importlib.machinery.SourceFileLoader("sb", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
sb = importlib.util.module_from_spec(spec)
loader.exec_module(sb)

NOW = 1723252800.0
LSTART = "Fri Aug  9 12:00:00 2024"

def rec(pid, ppid, tty, command, lstart=LSTART):
    return {"pid": pid, "ppid": ppid, "tty": tty, "lstart": lstart, "command": command}

def find(nodes, pred):
    for n in nodes:
        if pred(n):
            return n
        hit = find(n.get("children") or [], pred)
        if hit:
            return hit
    return None

tmp = tempfile.mkdtemp(prefix="sb-t35-")
sess = os.path.join(tmp, "sessions")
cfg = os.path.join(tmp, "config.toml")
os.makedirs(sess)
sb.GROK_SESS_ROOT = sess
sb.GROK_CONFIG_PATH = cfg
sb.reset_model_defaults()

# T35a: [models] default is read; no hardcoded 4.5
open(cfg, "w").write('[ui]\nfork_secondary_model = "ignore-me"\n[models]\ndefault = "grok-4.6"\n')
sb.reset_model_defaults()
forest = sb.build_cli_forest({900: rec(900, 1, "ttys009", "/home/user/.grok/bin/grok")}, now=NOW)
g = forest["roots"][0]
assert g["model"] == "grok-4.6", g["model"]
print("PASS_UNIT T35a [models].default -> grok-4.6")

# T35b: missing config + no session => model is None, never grok-4.5
os.remove(cfg)
sb.reset_model_defaults()
forest = sb.build_cli_forest({900: rec(900, 1, "ttys009", "/home/user/.grok/bin/grok")}, now=NOW)
assert forest["roots"][0].get("model") is None, forest["roots"][0].get("model")
print("PASS_UNIT T35b no config => model None (not grok-4.5)")

# T35c: stray top-level default ignored; [models].default wins
open(cfg, "w").write('default = "nope"\n[ui]\ndefault = "also-nope"\n[models]\ndefault = "grok-4.6"\n')
sb.reset_model_defaults()
forest = sb.build_cli_forest({900: rec(900, 1, "ttys009", "/home/user/.grok/bin/grok")}, now=NOW)
assert forest["roots"][0]["model"] == "grok-4.6"
print("PASS_UNIT T35c table-aware toml")

# T35d: -m= parsed
forest = sb.build_cli_forest({1: rec(1, 0, "??", "/home/user/.grok/bin/grok -m=grok-4.6 -p hi")}, now=NOW)
assert find(forest["roots"], lambda n: n["pid"]==1)["model"] == "grok-4.6"
print("PASS_UNIT T35d -m= parsed")

# T35e: summary.json current_model_id beats config
open(cfg, "w").write('[models]\ndefault = "grok-4.5"\n')
sb.reset_model_defaults()
cwd = "/tmp/lane-model"
enc = __import__("urllib.parse").parse.quote(cwd, safe="")
sid = "019ff000-0000-0000-0000-000000000001"
sdir = os.path.join(sess, enc, sid)
os.makedirs(sdir)
json.dump({
    "current_model_id": "grok-4.6",
    "created_at": "2024-08-09T16:00:00Z",
    "session_kind": "session",
}, open(os.path.join(sdir, "summary.json"), "w"))
cmd = "/home/user/.grok/bin/grok --cwd /tmp/lane-model"
# lstart Fri Aug 9 12:00:00 2024 == 1723226400 local? _lstart_ts uses naive local.
# Window is started_ts ± 180s. Use created_at matching parsed lstart.
started = sb._lstart_ts(LSTART)
created = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started))
json.dump({
    "current_model_id": "grok-4.6",
    "created_at": created,
}, open(os.path.join(sdir, "summary.json"), "w"))
forest = sb.build_cli_forest({2: rec(2, 1, "??", "/home/user/.grok/bin/grok --cwd /tmp/lane-model")}, now=NOW)
node = find(forest["roots"], lambda n: n["pid"]==2)
assert node and node["model"] == "grok-4.6", node
print("PASS_UNIT T35e summary.json current_model_id beats config")

# T35f: --resume sid + virtual children; missing effective_model_id inherits parent
sub = os.path.join(sess, enc, sid, "subagents", "sub-aaa")
os.makedirs(sub)
json.dump({
    "subagent_id": "sub-aaa",
    "parent_session_id": sid,
    "status": "running",
    "started_at": created,
    "description": "child-a",
    "effective_model_id": "grok-4.6",
}, open(os.path.join(sub, "meta.json"), "w"))
sub2 = os.path.join(sess, enc, sid, "subagents", "sub-bbb")
os.makedirs(sub2)
json.dump({
    "subagent_id": "sub-bbb",
    "parent_session_id": sid,
    "status": "running",
    "started_at": created,
    "description": "child-b",
}, open(os.path.join(sub2, "meta.json"), "w"))
cmd = "/home/user/.grok/bin/grok --resume %s --cwd /tmp/lane-model" % sid
forest = sb.build_cli_forest({3: rec(3, 1, "??", cmd)}, now=NOW)
node = find(forest["roots"], lambda n: n["pid"]==3)
subs = [c for c in node["children"] if c.get("kind")=="grok-sub"]
assert len(subs) == 2, [c.get("label") for c in node["children"]]
assert forest["counts"]["grok_subagents"] == 2
assert all(s.get("virtual") for s in subs)
assert all(s.get("model") == "grok-4.6" for s in subs), [s.get("model") for s in subs]
assert all(s.get("children") == [] for s in subs)
print("PASS_UNIT T35f sid graft + inherit model, never 4.5")

# T35g: grok leader is not a forest node
forest = sb.build_cli_forest({
    10: rec(10, 1, "??", "/home/user/.grok/bin/grok leader"),
    11: rec(11, 1, "ttys001", "claude"),
}, now=NOW)
assert all(n["kind"] != "grok" for n in forest["roots"])
assert len(forest["roots"]) == 1 and forest["roots"][0]["kind"] == "claude"
print("PASS_UNIT T35g grok leader excluded")

# T35h: toml helper
assert sb._toml_models_default('[models]\ndefault = "grok-4.6"\n') == "grok-4.6"
assert sb._toml_models_default('[ui]\nfork_secondary_model = "x"\n') is None
print("PASS_UNIT T35h _toml_models_default")

# T35l: two grok TUIs, shared cwd, no --resume — active_sessions.json maps pid→sid
active_path = os.path.join(tmp, "active_sessions.json")
sb.GROK_ACTIVE_SESSIONS = active_path
sid_a = "019ff000-0000-0000-0000-0000000000aa"
sid_b = "019ff000-0000-0000-0000-0000000000bb"
shared_cwd = "/tmp/lane-model"
enc_shared = __import__("urllib.parse").parse.quote(shared_cwd, safe="")
for sid_x, desc in ((sid_a, "slice-a"), (sid_b, "slice-b")):
    sdir_x = os.path.join(sess, enc_shared, sid_x)
    os.makedirs(os.path.join(sdir_x, "subagents", "sub-x"), exist_ok=True)
    json.dump({"created_at": created, "current_model_id": "grok-4.6"}, open(os.path.join(sdir_x, "summary.json"), "w"))
    json.dump({
        "subagent_id": "sub-x",
        "parent_session_id": sid_x,
        "status": "running",
        "started_at": created,
        "description": desc,
    }, open(os.path.join(sdir_x, "subagents", "sub-x", "meta.json"), "w"))
json.dump([
    {"session_id": sid_a, "pid": 42607, "cwd": shared_cwd},
    {"session_id": sid_b, "pid": 50908, "cwd": shared_cwd},
], open(active_path, "w"))
forest = sb.build_cli_forest({
    42607: rec(42607, 1, "ttys001", "/home/user/.grok/bin/grok"),
    50908: rec(50908, 1, "ttys003", "/home/user/.grok/bin/grok"),
}, now=NOW)
na = find(forest["roots"], lambda n: n["pid"]==42607)
nb = find(forest["roots"], lambda n: n["pid"]==50908)
sa = [c for c in (na["children"] if na else []) if c.get("kind")=="grok-sub"]
sb_ = [c for c in (nb["children"] if nb else []) if c.get("kind")=="grok-sub"]
assert len(sa)==1 and sa[0].get("label")=="slice-a", (na, sa)
assert len(sb_)==1 and sb_[0].get("label")=="slice-b", (nb, sb_)
print("PASS_UNIT T35l active_sessions.json pid map grafts two shared-cwd groks")
sb.GROK_ACTIVE_SESSIONS = os.path.join(tmp, "no-such-active-sessions.json")

# T35i: reattach agent_dispatch via launcher_cli_pid
sb.ROOT = tmp
os.makedirs(os.path.join(tmp, "demo"), exist_ok=True)
json.dump({
    "task": "demo", "lane": "bee", "status": "running",
    "launcher_cli_pid": 100, "launcher_cli_kind": "claude",
}, open(os.path.join(tmp, "demo", "slot-bee.json"), "w"))
snap = {
    100: rec(100, 1, "ttys001", "claude"),
    300: rec(300, 1, "??",
             "/usr/bin/Python /tmp/bin/agent-dispatch --task demo --lane bee -- grok-ask -w"),
    500: rec(500, 300, "??", "/home/user/.grok/bin/grok -p hi"),
}
forest = sb.build_cli_forest(snap, now=NOW)
assert len(forest["roots"]) == 1 and forest["roots"][0]["kind"] == "claude"
td = forest["roots"][0]["children"]
assert len(td) == 1 and td[0]["kind"] == "agent_dispatch"
print("PASS_UNIT T35i launcher_cli_pid reattaches orphan agent_dispatch")

# T35j: stale launcher pid (not in snap) stays a root
json.dump({
    "task": "demo", "lane": "bee", "status": "running",
    "launcher_cli_pid": 99999, "launcher_cli_kind": "claude",
}, open(os.path.join(tmp, "demo", "slot-bee.json"), "w"))
forest = sb.build_cli_forest(snap, now=NOW)
kinds = [n["kind"] for n in forest["roots"]]
assert "agent_dispatch" in kinds and "claude" in kinds
print("PASS_UNIT T35j stale launcher stays root")

# T35k: long-lived TUI — created_at does not match lstart; last_active does
cwd2 = "/tmp/lane-hot"
enc2 = __import__("urllib.parse").parse.quote(cwd2, safe="")
sid_hot = "019ffhot-0000-0000-0000-000000000099"
sdir2 = os.path.join(sess, enc2, sid_hot)
os.makedirs(sdir2)
now_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
json.dump({
    "current_model_id": "grok-4.6",
    "created_at": "2020-01-01T00:00:00Z",
    "last_active_at": now_iso,
}, open(os.path.join(sdir2, "summary.json"), "w"))
# a stale sibling in the same cwd must not win
sid_old = "019ffold-0000-0000-0000-000000000088"
os.makedirs(os.path.join(sess, enc2, sid_old))
json.dump({
    "current_model_id": "grok-4.5",
    "created_at": "2020-01-01T00:00:00Z",
    "last_active_at": "2020-01-02T00:00:00Z",
}, open(os.path.join(sess, enc2, sid_old, "summary.json"), "w"))
sb.reset_model_defaults()
forest = sb.build_cli_forest(
    {8: rec(8, 1, "ttys001", "/home/user/.grok/bin/grok --cwd /tmp/lane-hot")},
    now=time.time(),
)
node = find(forest["roots"], lambda n: n["pid"] == 8)
assert node and node["model"] == "grok-4.6", node
print("PASS_UNIT T35k last_active sid match for long-lived TUI")

shutil.rmtree(tmp, ignore_errors=True)
print("ALL_T35_OK")
EOF
if [ $? -eq 0 ]; then
  ck ok ok "T35a [models].default parsed"
  ck ok ok "T35b missing config => model None (not grok-4.5)"
  ck ok ok "T35c table-aware toml"
  ck ok ok "T35d -m= parsed"
  ck ok ok "T35e summary.json beats config"
  ck ok ok "T35f virtual children + inherit model"
  ck ok ok "T35g grok leader excluded"
  ck ok ok "T35h toml helper"
  ck ok ok "T35i launcher reattach"
  ck ok ok "T35j stale launcher stays root"
  ck ok ok "T35k last_active sid match for long-lived TUI"
  ck ok ok "T35l active_sessions.json pid map"
else
  ck fail ok "T35 v0.3.0 unit block"
fi

# T40: Cursor is a first-class CLI kind (classify, forest, model, counts)
python3 - "$SB" <<'EOF'
import importlib.machinery, importlib.util, sys, os, json, tempfile, shutil, time

loader = importlib.machinery.SourceFileLoader("sb", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
sb = importlib.util.module_from_spec(spec)
loader.exec_module(sb)

NOW = 1723252800.0
LSTART = "Fri Aug  9 12:00:00 2024"

def rec(pid, ppid, tty, command, lstart=LSTART):
    return {"pid": pid, "ppid": ppid, "tty": tty, "lstart": lstart, "command": command}

def find(nodes, pred):
    for n in nodes:
        if pred(n):
            return n
        hit = find(n.get("children") or [], pred)
        if hit:
            return hit
    return None

def assert_true(cond, msg):
    if not cond:
        print("FAIL_ASSERT", msg)
        sys.exit(1)

CA = "/home/user/.local/share/cursor-agent/versions/2026.08.11-e8db854/cursor-agent"
ASK = "/usr/local/bin/cursor-ask"

assert_true(sb.kind_from_command(CA + " -p hi") == "cursor_cli", "cursor-agent is cursor_cli")
assert_true(
    sb.kind_from_command("/bin/bash %s -w -c ch-x" % ASK) == "cursor_ask",
    "bash cursor-ask is cursor_ask",
)
assert_true(sb.kind_from_command(ASK + " -w -c ch-x") == "cursor_ask", "bare cursor-ask")
assert_true(
    sb.kind_from_command("node %s/index.js -p hi" % os.path.dirname(CA)) == "cursor_cli",
    "node + cursor-agent path",
)
assert_true(
    sb.kind_from_command("/home/user/.grok/bin/agent -p hi") == "grok_cli",
    "grok agent is still grok (not cursor)",
)

tmp = tempfile.mkdtemp(prefix="sb-t40-")
try:
    cfg = os.path.join(tmp, "cli-config.json")
    json.dump({
        "model": {
            "modelId": "default",
            "displayModelId": "auto",
            "displayNameShort": "Auto",
        },
        "selectedModel": {"modelId": "default"},
    }, open(cfg, "w"))
    chdir = os.path.join(tmp, "channels")
    os.makedirs(chdir)
    json.dump({"channel": "ch-x", "sessionId": "sid-1", "model": "composer"},
              open(os.path.join(chdir, "ch-x.json"), "w"))
    sb.CURSOR_CONFIG_PATH = cfg
    sb.CURSOR_CHANNEL_DIR = chdir
    sb.reset_model_defaults()

    snap = {
        100: rec(100, 1, "ttys001", "claude"),
        300: rec(
            300, 100, "??",
            "/usr/bin/Python /usr/local/bin/agent-dispatch "
            "--task teamcursor --lane exec-a --exec %s -- "
            "-w -c ch-x -m composer -d /tmp/lane" % ASK,
        ),
        400: rec(400, 300, "??", "/bin/bash %s -w -c ch-x -m composer -d /tmp/lane" % ASK),
        500: rec(
            500, 400, "??",
            CA + " -p PROMPT --output-format json --trust --workspace /tmp/lane "
            "--model composer --force",
        ),
        600: rec(600, 500, "??", CA + " -p SLAVE --workspace /tmp/lane --model gpt-5"),
    }
    forest = sb.build_cli_forest(snap, now=NOW)
    roots = forest["roots"]
    assert_true(len(roots) == 1 and roots[0]["kind"] == "claude", "claude root")
    td = roots[0]["children"]
    assert_true(len(td) == 1 and td[0]["kind"] == "agent_dispatch", "agent_dispatch under claude")
    kids = td[0]["children"]
    assert_true(len(kids) == 1 and kids[0]["kind"] == "cursor", "cursor under dispatch")
    assert_true(kids[0].get("channel") == "ch-x" or kids[0].get("label") == "ch-x", "channel")
    assert_true(kids[0].get("model") == "composer", "model from --model")
    assert_true(kids[0]["mode"] == "headless", "headless via -p")
    slaves = kids[0]["children"]
    assert_true(len(slaves) == 1 and slaves[0]["kind"] == "cursor", "slave cursor nests via PPID")
    assert_true(slaves[0].get("model") == "gpt-5", "slave model from --model")
    assert_true(forest["counts"]["cursor"]["headless"] == 2, "counts.cursor.headless == 2")
    assert_true(forest["counts"]["cursor"]["interactive"] == 0, "no interactive cursor")
    kinds = []
    def walk(ns):
        for n in ns:
            kinds.append(n["kind"])
            walk(n.get("children") or [])
    walk(roots)
    assert_true("cursor_ask" not in kinds, "cursor_ask not emitted")

    # Interactive cursor TUI is a root with tty; model falls back to cli-config
    sb.reset_model_defaults()
    forest_i = sb.build_cli_forest(
        {9: rec(9, 1, "ttys007", CA)},
        now=NOW,
    )
    node = find(forest_i["roots"], lambda n: n["pid"] == 9)
    assert_true(node and node["kind"] == "cursor", "interactive cursor root")
    assert_true(node["mode"] == "interactive" and node["tty"] == "ttys007", "tty")
    assert_true(node.get("model") == "auto", "cli-config displayModelId fallback")
    assert_true(forest_i["counts"]["cursor"]["interactive"] == 1, "interactive count")

    # Channel state model when argv has none
    sb.reset_model_defaults()
    forest_ch = sb.build_cli_forest({
        10: rec(10, 1, "??", "/bin/bash %s -w -c ch-x -d /tmp/lane" % ASK),
        11: rec(11, 10, "??", CA + " -p HI --workspace /tmp/lane --force"),
    }, now=NOW)
    cur = find(forest_ch["roots"], lambda n: n["kind"] == "cursor")
    assert_true(cur and cur.get("model") == "composer", "model from cursor-ask channel")

    # cli_busy includes cursor
    assert_true(sb.cli_busy({12: rec(12, 1, "??", CA + " -p hi")}) is True, "cli_busy cursor")
    print("ALL_T40_OK")
finally:
    shutil.rmtree(tmp, ignore_errors=True)
EOF
if [ $? -eq 0 ]; then
  ck ok ok "T40a cursor-agent classified as cursor"
  ck ok ok "T40b cursor-ask collapsed; cursor under agent_dispatch"
  ck ok ok "T40c slave cursor nests via PPID with own model"
  ck ok ok "T40d interactive cursor + cli-config model fallback"
  ck ok ok "T40e channel-state model + cli_busy"
else
  ck fail ok "T40 cursor first-class kind unit block"
fi

# T36: refuse event is written
"$TD" --task t36 --lane cap1 --exec /bin/bash -- -c 'sleep 8' >/dev/null 2>&1 &
sleep 0.4
"$TD" --task t36 --lane cap2 --max 1 --exec /bin/bash -- -c 'true' >/dev/null 2>&1
ck "$?" "2" "T36a capacity refuse exit 2"
REF=$(python3 -c '
import json,os
p=os.environ["AGENT_SWITCHBOARD_ROOT"]+"/t36/events.jsonl"
hits=0
for line in open(p):
    e=json.loads(line)
    if e.get("event")=="refuse" and e.get("reason")=="capacity":
        hits+=1
print(hits)
')
ck "$REF" "1" "T36b refuse event in events.jsonl"
wait 2>/dev/null

# T37: stall + wait --json + advise
# Keep bash in the process (a lone `sleep 20` is exec'd; prog_base
# identity would then treat the worker as gone and derive RUNNING).
"$TD" --task t37 --lane hang --exec /bin/bash -- -c 'sleep 20; exit 0' >/dev/null 2>&1 &
sleep 2.2
ST=$("$SB" status --task t37 --stall-after 1 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["slots"][0]["state"])')
ck "$ST" "STALLED" "T37a headless silence past stall budget -> STALLED"
ADV=$("$SB" wait --task t37 --lane hang --stall-after 1 --timeout 2 --interval 0.4 --json)
ADV_RC=$?
ck "$ADV_RC" "0" "T37b wait returns 0 on STALLED"
NEXT=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print("inspect_stalled:hang" in d.get("next",[]), d.get("severity"))' "$ADV")
ck "$NEXT" "True inspect" "T37c advise next=inspect_stalled"
[ -f "$AGENT_SWITCHBOARD_ROOT/t37/advise.json" ] && ck ok ok "T37d advise.json written" || ck missing present "T37d advise.json written"
# already-ORPHAN wait still times out (T16 regression via --json)
# kill hang
if [ -f "$AGENT_SWITCHBOARD_ROOT/t37/slot-hang.json" ]; then
  kill -9 $(python3 -c "import json;print(json.load(open('$AGENT_SWITCHBOARD_ROOT/t37/slot-hang.json')).get('pid',0))") 2>/dev/null
  kill -9 $(python3 -c "import json;print(json.load(open('$AGENT_SWITCHBOARD_ROOT/t37/slot-hang.json')).get('wrapper_pid',0))") 2>/dev/null
fi
wait 2>/dev/null

# T38: WAITING_INPUT from grok events.jsonl
python3 - "$AGENT_SWITCHBOARD_ROOT" <<'EOF'
import json,os,sys,time
root=sys.argv[1]
# fake a running slot pointing at a grok session with permission_prompt
cwd="/tmp/sb-t38-cwd"
os.makedirs(cwd, exist_ok=True)
sess_root=os.environ.get("AGENT_SWITCHBOARD_GROK_SESSIONS")  # may be unset; write under default? 
# Put session next to slot via session_id + cwd under the test's grok root.
# derive uses GROK_SESS_ROOT from the binary (real ~/.grok unless env).
# Use a unique cwd + session_id; do not write into the real session tree.
# Instead craft slot and invoke derive via imported sb with patched GROK_SESS_ROOT
# — done in the next python - "$SB" block.
open(os.path.join(root,"t38-marker"),"w").write("ok")
EOF

python3 - "$SB" "$AGENT_SWITCHBOARD_ROOT" <<'EOF'
import importlib.machinery, importlib.util, sys, os, json, time, tempfile, shutil
loader = importlib.machinery.SourceFileLoader("sb", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
sb = importlib.util.module_from_spec(spec)
loader.exec_module(sb)
tmp = tempfile.mkdtemp(prefix="sb-t38-")
sb.GROK_SESS_ROOT = os.path.join(tmp, "gs")
sb.ROOT = tmp
cwd = "/tmp/sb-t38-lane"
enc = __import__("urllib.parse").parse.quote(cwd, safe="")
sid = "sid-t38"
sdir = os.path.join(sb.GROK_SESS_ROOT, enc, sid)
os.makedirs(sdir)
with open(os.path.join(sdir, "events.jsonl"), "w") as f:
    f.write(json.dumps({"ts": "2026-01-01T00:00:00Z", "type": "phase_changed", "phase": "permission_prompt"})+"\n")
slot = {
    "task": "t38", "lane": "ask", "status": "running",
    "pid": os.getpid(), "wrapper_pid": os.getpid(),
    "prog": "python3", "prog_base": "python3",
    "cwd": cwd, "session_id": sid, "started": time.time(),
}
# wrapper_pid is this python — proc_alive will see it; prog_base python3 is in cmdline.
state, _ = sb.derive(slot, quiet_after=300)
print("STATE", state)
ok = state == "WAITING_INPUT"
# stalled: old events, no permission
with open(os.path.join(sdir, "events.jsonl"), "w") as f:
    f.write(json.dumps({"ts": "2020-01-01T00:00:00Z", "type": "turn_started"})+"\n")
os.utime(os.path.join(sdir, "events.jsonl"), (time.time()-400, time.time()-400))
state2, _ = sb.derive(slot, quiet_after=300, stall_after=1)
print("STATE2", state2)
ok = ok and state2 == "STALLED"
shutil.rmtree(tmp, ignore_errors=True)
sys.exit(0 if ok else 1)
EOF
if [ $? -eq 0 ]; then
  ck ok ok "T38a permission_prompt -> WAITING_INPUT"
  ck ok ok "T38b aged events -> STALLED"
else
  ck fail ok "T38 heartbeat states"
fi

# T39: exec-master stop hook fail-open + block when exec-master + live slot
export SCRIPT_DIR
python3 - <<'EOF'
import json,os,subprocess,sys,tempfile,time
hook=os.path.join(os.environ["SCRIPT_DIR"], "../bin/exec-master-stop-hook.py")
# allow: no needles, no slots needed
p=subprocess.run([sys.executable, hook], input=json.dumps({"cwd":"/tmp","prompt":"hello"}),
                 text=True, capture_output=True)
ok = p.returncode==0 and not p.stdout.strip()
print("ALLOW", ok, p.stdout[:80])
sys.exit(0 if ok else 1)
EOF
if [ $? -eq 0 ]; then ck ok ok "T39a stop hook allows non-exec-master"; else ck fail ok "T39a stop hook allows non-exec-master"; fi

# T41: DONE rows drop from /v1/status after DONE_EXPIRE, slot file remains
# (cold-archive / T22 is the 24h file-move; this is the 15-min board filter).
# Ports 17970-17974 (T10/T21/T22 own 17995-17999; T23 comment reserves 17985-17989).
AGENT_SWITCHBOARD_DONE_EXPIRE=1 "$SB" serve --port 17974 >/dev/null 2>&1 &
SRV41=$!
sleep 1.5
"$TD" --task t41 --lane done --exec /bin/bash -- -c 'true' >/dev/null 2>&1
LANES=$(curl -s "http://127.0.0.1:17974/v1/status?task=t41" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(s["lane"]+":"+s["state"] for s in d[0]["slots"]))')
ck "$LANES" "done:DONE" "T41a freshly DONE row still listed on /v1/status"
sleep 2   # past DONE_EXPIRE=1s, across a watcher tick
# Pin ended well past expire so the drop is not racy against curl/dispatch.
python3 -c "
import json, time, os
p = os.path.join(os.environ['AGENT_SWITCHBOARD_ROOT'], 't41', 'slot-done.json')
d = json.load(open(p))
d['ended'] = time.time() - 5
json.dump(d, open(p, 'w'))
"
"$TD" --task t41 --lane fresh --exec /bin/bash -- -c 'true' >/dev/null 2>&1
LANES=$(curl -s "http://127.0.0.1:17974/v1/status?task=t41" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(s["lane"]+":"+s["state"] for s in d[0]["slots"]))')
ck "$LANES" "fresh:DONE" "T41b expired DONE omitted; fresher DONE stays"
if [ -f "$AGENT_SWITCHBOARD_ROOT/t41/slot-done.json" ]; then ck ok ok "T41c expired DONE slot file remains on disk"; else ck absent present "T41c expired DONE slot file remains on disk"; fi
HIST=$(ls "$AGENT_SWITCHBOARD_ROOT/t41/history" 2>/dev/null | grep -c '^done-' || true)
ck "${HIST:-0}" "0" "T41d history/ has no done-* (not cold-archived)"
CLI=$(AGENT_SWITCHBOARD_DONE_EXPIRE=1 "$SB" status --task t41 --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(s["lane"] for s in d[0]["slots"]))')
ck "$CLI" "fresh" "T41e CLI status --json uses the same task_status omit"
kill "$SRV41" 2>/dev/null
wait 2>/dev/null

# T41f: DONE_EXPIRE=0 disables the filter (stale DONE stays listed)
python3 -c "
import json, time, os
p = os.path.join(os.environ['AGENT_SWITCHBOARD_ROOT'], 't41', 'slot-done.json')
d = json.load(open(p))
d['ended'] = time.time() - 10
json.dump(d, open(p, 'w'))
"
CLI0=$(AGENT_SWITCHBOARD_DONE_EXPIRE=0 "$SB" status --task t41 --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(s["lane"] for s in d[0]["slots"] if s["lane"]=="done"))')
ck "$CLI0" "done" "T41f DONE_EXPIRE=0 keeps stale DONE listed"

# T41g: expired FAILED omitted from served /v1/status (Q7; ports 17950-17954).
AGENT_SWITCHBOARD_DONE_EXPIRE=1 "$SB" serve --port 17950 >/dev/null 2>&1 &
SRV41G=$!
sleep 1.5
"$TD" --task t41g --lane fail --exec /bin/bash -- -c 'exit 1' >/dev/null 2>&1
python3 -c "
import json, time, os
p = os.path.join(os.environ['AGENT_SWITCHBOARD_ROOT'], 't41g', 'slot-fail.json')
d = json.load(open(p))
d['ended'] = time.time() - 5
json.dump(d, open(p, 'w'))
"
"$TD" --task t41g --lane fresh --exec /bin/bash -- -c 'true' >/dev/null 2>&1
LANES41G=$(curl -s "http://127.0.0.1:17950/v1/status?task=t41g" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(s["lane"]+":"+s["state"] for s in d[0]["slots"]))')
ck "$LANES41G" "fresh:DONE" "T41g expired FAILED omitted from served /v1/status; fresher DONE stays"
kill "$SRV41G" 2>/dev/null
wait 2>/dev/null

# T41h: expired DIED omitted; ORPHAN NEVER omitted regardless of age (Q7).
# Craft slots (same class as T16) so ORPHAN does not depend on killing a
# wrapper without also killing its child.
AGENT_SWITCHBOARD_DONE_EXPIRE=1 "$SB" serve --port 17951 >/dev/null 2>&1 &
SRV41H=$!
sleep 1.5
mkdir -p "$AGENT_SWITCHBOARD_ROOT/t41h"
python3 -c "
import json, time, os
root = os.environ['AGENT_SWITCHBOARD_ROOT']
json.dump({
    'task': 't41h', 'lane': 'died', 'run_id': 't41h-died', 'status': 'running',
    'pid': 999998, 'wrapper_pid': 999997,
    'prog': 'goneworker', 'prog_base': 'goneworker',
    'wrapper_base': 'agent-dispatch',
    'started': time.time() - 100, 'ended': time.time() - 10,
}, open(os.path.join(root, 't41h', 'slot-died.json'), 'w'))
"
bash -c 'exec -a t41horph sleep 60' &
OW41H=$!
python3 - "$OW41H" <<'EOF'
import json, os, sys, time
ow = int(sys.argv[1])
root = os.environ["AGENT_SWITCHBOARD_ROOT"]
p = os.path.join(root, "t41h", "slot-orph.json")
json.dump({
    "task": "t41h", "lane": "orph", "run_id": "t41h-orph", "status": "running",
    "pid": ow, "wrapper_pid": 999999,
    "prog": "t41horph", "prog_base": "t41horph",
    "started": time.time() - 10000,
}, open(p, "w"))
os.utime(p, (time.time() - 10000, time.time() - 10000))
EOF
LANES41H=$(curl -s "http://127.0.0.1:17951/v1/status?task=t41h" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(sorted(s["lane"]+":"+s["state"] for s in d[0]["slots"])) )')
ck "$LANES41H" "orph:ORPHAN" "T41h expired DIED omitted; ORPHAN never omitted regardless of age"
kill -9 "$OW41H" 2>/dev/null
kill "$SRV41H" 2>/dev/null
wait 2>/dev/null

# T50: viewer classifier is argv0/path-position only. A path appearing as a
# flag value or inside prompt text must not classify a process as viewer.
python3 - "$SB" <<'EOF'
import importlib.machinery, importlib.util, sys

loader = importlib.machinery.SourceFileLoader("sb", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
sb = importlib.util.module_from_spec(spec)
loader.exec_module(sb)


def assert_true(cond, msg):
    if not cond:
        print("FAIL_ASSERT", msg)
        sys.exit(1)


assert_true(
    sb.kind_from_command("grok --cwd /x/agent-switchboard") == "grok_cli",
    "grok --cwd /x/agent-switchboard is grok_cli not viewer",
)
assert_true(
    sb.kind_from_command("grok --cwd=/tmp/agent-switchboard") == "grok_cli",
    "grok --cwd=/tmp/agent-switchboard is grok_cli not viewer",
)
assert_true(
    sb.kind_from_command("grok -p look at /agent-switchboard please") == "grok_cli",
    "grok with /agent-switchboard in prompt text is grok_cli not viewer",
)
assert_true(
    sb.kind_from_command("/bin/bash /usr/local/bin/grok-ask -d /tmp/agent-switchboard")
    == "grok_ask",
    "grok-ask -d .../agent-switchboard is grok_ask not viewer",
)
assert_true(
    sb.kind_from_command("/opt/agent-switchboard") == "viewer",
    "argv0 /opt/agent-switchboard is viewer",
)
assert_true(
    sb.kind_from_command(
        "/Applications/Agent Switchboard.app/Contents/MacOS/agent-switchboard"
    )
    == "viewer",
    "app-bundle Agent Switchboard.app Contents/MacOS is viewer",
)
# D1b: space-bearing install path (command.split() truncates toks[1] at
# "Internal"). Reconstruct early-argv path tokens; never match flag values
# or prompt text.
_PY = (
    "/Library/Frameworks/Python.framework/Versions/3.13/Resources/"
    "Python.app/Contents/MacOS/Python"
)
_SPACE_AD = (
    "/Users/me/Internal Development/Tools/oss-widgets/bin/agent-dispatch"
    " --task t31 --lane forest --exec /tmp/grok -- 25"
)
assert_true(
    sb.kind_from_command(_PY + " " + _SPACE_AD) == "agent_dispatch",
    "python3 wrapper + space-bearing agent-dispatch is agent_dispatch",
)
_ad_meta = sb._parse_wrapper_flags(_PY + " " + _SPACE_AD, "agent_dispatch")
assert_true(
    _ad_meta.get("task") == "t31" and _ad_meta.get("lane") == "forest",
    "space-bearing agent-dispatch still yields --task/--lane",
)
assert_true(
    sb.kind_from_command(
        "python3 /Users/me/Internal Development/Tools/bin/switchboard serve"
    )
    == "switchboard_daemon",
    "python3 wrapper + space-bearing switchboard is switchboard_daemon",
)
assert_true(
    sb.kind_from_command(
        "/bin/bash /Users/me/Internal Development/bin/grok-ask -w -c ch-x"
    )
    == "grok_ask",
    "bash wrapper + space-bearing grok-ask is grok_ask",
)
assert_true(
    sb.kind_from_command("python3 /tmp/other.py --cwd /x/agent-dispatch") is None,
    "python3 + --cwd /x/agent-dispatch is not agent_dispatch (D1: flag value)",
)
assert_true(
    sb.kind_from_command("python3 -c print('/agent-dispatch')") is None,
    "python3 -c prompt containing /agent-dispatch is not agent_dispatch",
)
assert_true(
    sb.kind_from_command("/bin/bash -c echo /grok-ask") == "shell_tool",
    "bash -c prompt containing /grok-ask is shell_tool not grok_ask",
)
print("ALL_T50_OK")
EOF
if [ $? -eq 0 ]; then
  ck ok ok "T50a grok --cwd /x/agent-switchboard is grok_cli"
  ck ok ok "T50b grok --cwd=/tmp/agent-switchboard is grok_cli"
  ck ok ok "T50c grok prompt text /agent-switchboard is grok_cli"
  ck ok ok "T50d grok-ask -d .../agent-switchboard is grok_ask"
  ck ok ok "T50e argv0 /opt/agent-switchboard is viewer"
  ck ok ok "T50f app-bundle Contents/MacOS is viewer"
else
  ck fail ok "T50 viewer argv0/path-position classifier unit block"
fi

# T51: per-node status (cpu delta, first-obs, epsilon, fallback, allowlist)
python3 - "$SB" <<'EOF'
import importlib.machinery, importlib.util, sys, os, json, tempfile, shutil, time, subprocess

loader = importlib.machinery.SourceFileLoader("sb", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
sb = importlib.util.module_from_spec(spec)
loader.exec_module(sb)

NOW = 1723252800.0
LSTART = "Fri Aug  9 12:00:00 2024"
ALLOW = sb.CLI_TREE_STATUSES


def rec(pid, ppid, tty, command, lstart=LSTART, cputime="0:00.00", cpu_s=0.0):
    return {
        "pid": pid, "ppid": ppid, "tty": tty, "lstart": lstart,
        "command": command, "cputime": cputime, "cpu_s": cpu_s,
    }


def find(nodes, pred):
    for n in nodes:
        if pred(n):
            return n
        hit = find(n.get("children") or [], pred)
        if hit:
            return hit
    return None


def walk(nodes):
    for n in nodes or []:
        yield n
        yield from walk(n.get("children") or [])


def assert_true(cond, msg):
    if not cond:
        print("FAIL_ASSERT", msg)
        sys.exit(1)


def reset_ledger(root):
    sb.ROOT = root
    sb._LEDGER_SEEN_START.clear()
    sb._LEDGER_SEEN_END.clear()
    sb._LEDGER_STARTS.clear()
    sb._LEDGER_ENDS.clear()
    sb._LEDGER_LIVE.clear()
    sb._LEDGER_CWD_DONE.clear()
    sb._LEDGER_GROK_META_MEMO.clear()
    sb._LEDGER_SEEDED = True
    sb.reset_cli_cache()
    sb.reset_model_defaults()


tmp = tempfile.mkdtemp(prefix="sb-t51-")
try:
    reset_ledger(tmp)

    # --- cputime parser unit: BSD unbounded minutes + GNU [DD-]HH:MM:SS
    assert_true(abs(sb._parse_cputime("631:38.69") - (631 * 60 + 38.69)) < 1e-6, "BSD 631:38.69")
    assert_true(sb._parse_cputime("00:00:01") == 1.0, "GNU HH:MM:SS")
    assert_true(sb._parse_cputime("1-02:03:04") == 1 * 86400 + 2 * 3600 + 3 * 60 + 4, "GNU DD-HH:MM:SS")
    assert_true(sb._parse_cputime("not-a-time") is None, "unparseable => None")
    print("PASS_UNIT T51a cputime parser BSD+GNU")

    # lstart-bearing six-group row
    line = "  900  1 ttys009 631:38.69 Fri Aug  9 12:00:00 2024 /home/user/.grok/bin/grok"
    snap6, nlines, nmatch = sb._ps_cli_parse_six(line + "\n")
    assert_true(nlines == 1 and nmatch == 1 and 900 in snap6, "six-group matches lstart row")
    assert_true(snap6[900]["lstart"] == "Fri Aug  9 12:00:00 2024", "lstart captured")
    assert_true(abs(snap6[900]["cpu_s"] - (631 * 60 + 38.69)) < 1e-6, "cpu_s from row")
    gnu_line = "  901  1 ttys009 00:00:01 Fri Aug  9 12:00:00 2024 /home/user/.grok/bin/grok"
    gsnap, _, _ = sb._ps_cli_parse_six(gnu_line + "\n")
    assert_true(gsnap[901]["cpu_s"] == 1.0, "GNU cputime on lstart row")
    print("PASS_UNIT T51b lstart-bearing six-group row")

    # MANDATORY legacy fallback: stub ps output the six-group regex cannot match
    five = "  900  1 ttys009 Fri Aug  9 12:00:00 2024 /home/user/.grok/bin/grok\n"
    calls = []
    real_co = sb.subprocess.check_output

    def fake_co(cmd, *a, **kw):
        calls.append(list(cmd))
        return five

    sb.subprocess.check_output = fake_co
    try:
        snap_fb = sb.ps_cli_snapshot()
    finally:
        sb.subprocess.check_output = real_co
    assert_true(calls[0] == sb.PS_CLI_CMD, "first ps is six-field")
    assert_true(len(calls) >= 2 and calls[1] == sb.PS_CLI_CMD_LEGACY, "retry legacy five-field")
    assert_true(snap_fb and 900 in snap_fb, "fallback snap populated")
    assert_true(snap_fb[900]["cpu_s"] is None, "fallback cpu_s=None")
    forest_fb = sb.build_cli_forest(snap_fb, now=NOW)
    assert_true(forest_fb["roots"] and forest_fb["roots"][0]["kind"] == "grok", "forest still populated")
    print("PASS_UNIT T51c legacy-regex fallback")

    grok_cmd = "/home/user/.grok/bin/grok"

    def payload_for(snap, mono, now=NOW):
        sb.ps_cli_snapshot = lambda: snap
        return sb.get_cli_payload(force=True, now=now, mono=mono)

    # cpu-delta => active; idle => running
    reset_ledger(tmp)
    snap_idle = {900: rec(900, 1, "ttys009", grok_cmd, cpu_s=1.0)}
    p1 = payload_for(snap_idle, 1000.0)
    n1 = find(p1["roots"], lambda n: n["pid"] == 900)
    assert_true(n1 and n1["status"] == "running", "first obs idle => running")
    snap_idle2 = {900: rec(900, 1, "ttys009", grok_cmd, cpu_s=1.0)}
    p2 = payload_for(snap_idle2, 1001.5)
    n2 = find(p2["roots"], lambda n: n["pid"] == 900)
    assert_true(n2 and n2["status"] == "running", "idle delta 0 => running")
    snap_busy = {900: rec(900, 1, "ttys009", grok_cmd, cpu_s=1.20)}
    p3 = payload_for(snap_busy, 1003.0)
    n3 = find(p3["roots"], lambda n: n["pid"] == 900)
    assert_true(n3 and n3["status"] == "active", "cpu-delta => active")
    print("PASS_UNIT T51d cpu-delta active / idle running")

    # live OS child => active (real spawned child, not a virtual grok-sub)
    reset_ledger(tmp)
    child = subprocess.Popen(["sleep", "60"])
    try:
        snap_ch = {
            100: rec(100, 1, "ttys001", grok_cmd, cpu_s=1.0),
            child.pid: rec(
                child.pid, 100, "??", grok_cmd + " -p child-prompt", cpu_s=0.2
            ),
        }
        pch = payload_for(snap_ch, 50.0)
        parent = find(pch["roots"], lambda n: n["pid"] == 100)
        kid = find(pch["roots"], lambda n: n["pid"] == child.pid)
        assert_true(parent and kid, "parent+real child in forest")
        assert_true(kid.get("virtual") is not True and kid.get("pid") is not None, "child is OS pid")
        assert_true(parent["status"] == "active", "live OS child => parent active")
        assert_true(kid["status"] == "running", "child first-obs running")
    finally:
        child.kill()
        child.wait()
    print("PASS_UNIT T51e live OS child => active")

    # first-obs: virtual grok-sub does NOT count as a child
    reset_ledger(tmp)
    sess = os.path.join(tmp, "sessions")
    sb.GROK_SESS_ROOT = sess
    cwd = "/tmp/lane-t51"
    enc = __import__("urllib.parse").parse.quote(cwd, safe="")
    sid = "019ff000-0000-0000-0000-00000000t51a"
    sub = os.path.join(sess, enc, sid, "subagents", "sub-virt")
    os.makedirs(sub)
    started = sb._lstart_ts(LSTART)
    created = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started))
    json.dump({"created_at": created, "current_model_id": "grok-4.6"},
              open(os.path.join(sess, enc, sid, "summary.json"), "w"))
    json.dump({
        "subagent_id": "sub-virt", "parent_session_id": sid,
        "status": "running", "started_at": created, "description": "virt",
    }, open(os.path.join(sub, "meta.json"), "w"))
    cmd = grok_cmd + " --resume %s --cwd /tmp/lane-t51" % sid
    snap_v = {3: rec(3, 1, "??", cmd, cpu_s=0.0)}
    pv = payload_for(snap_v, 70.0)
    node = find(pv["roots"], lambda n: n["pid"] == 3)
    subs = [c for c in (node["children"] if node else []) if c.get("kind") == "grok-sub"]
    assert_true(node and len(subs) == 1 and subs[0].get("virtual") is True, "virtual grok-sub grafted")
    assert_true(node["status"] == "running", "virtual grok-sub does not pin parent active")
    assert_true(subs[0]["status"] == "running", "virtual status from meta running")
    assert_true(subs[0]["status"] in ALLOW, "virtual status in allowlist")
    print("PASS_UNIT T51f first-obs virtual grok-sub excluded")

    # epsilon boundary: 0.04s => running, 0.06s => active
    reset_ledger(tmp)
    payload_for({900: rec(900, 1, "ttys009", grok_cmd, cpu_s=1.00)}, 2000.0)
    p04 = payload_for({900: rec(900, 1, "ttys009", grok_cmd, cpu_s=1.04)}, 2001.5)
    assert_true(find(p04["roots"], lambda n: n["pid"] == 900)["status"] == "running", "0.04s => running")
    reset_ledger(tmp)
    payload_for({900: rec(900, 1, "ttys009", grok_cmd, cpu_s=1.00)}, 2000.0)
    p06 = payload_for({900: rec(900, 1, "ttys009", grok_cmd, cpu_s=1.06)}, 2001.5)
    assert_true(find(p06["roots"], lambda n: n["pid"] == 900)["status"] == "active", "0.06s => active")
    print("PASS_UNIT T51g epsilon 0.04 running / 0.06 active")

    # gap<1.0s carries status forward
    reset_ledger(tmp)
    payload_for({900: rec(900, 1, "ttys009", grok_cmd, cpu_s=1.00)}, 3000.0)
    pgap = payload_for({900: rec(900, 1, "ttys009", grok_cmd, cpu_s=2.00)}, 3000.5)
    assert_true(find(pgap["roots"], lambda n: n["pid"] == 900)["status"] == "running",
                "gap<1.0s carries running despite large delta")
    print("PASS_UNIT T51h gap<1.0s carry-forward")

    # gap>120s re-firsts (would have been active on delta)
    reset_ledger(tmp)
    payload_for({900: rec(900, 1, "ttys009", grok_cmd, cpu_s=1.00)}, 4000.0)
    p120 = payload_for({900: rec(900, 1, "ttys009", grok_cmd, cpu_s=2.00)}, 4121.0)
    assert_true(find(p120["roots"], lambda n: n["pid"] == 900)["status"] == "running",
                "gap>120s re-firsts to running")
    print("PASS_UNIT T51i gap>120s re-first")

    # TTL hit never resamples / never touches _CPU_PREV
    reset_ledger(tmp)
    sb.CLI_CACHE_TTL = 5.0
    nps = {"n": 0}
    snap_t = {900: rec(900, 1, "ttys009", grok_cmd, cpu_s=1.0)}

    def counted_ps():
        nps["n"] += 1
        return snap_t

    sb.ps_cli_snapshot = counted_ps
    sb.reset_cli_cache()
    a = sb.get_cli_payload(now=NOW, mono=5000.0)
    prev_cpu = {k: dict(v) for k, v in sb._CPU_PREV.items()}
    b = sb.get_cli_payload(now=NOW, mono=5001.0)
    assert_true(nps["n"] == 1 and b["cached"] is True, "TTL hit does not resample")
    assert_true({k: dict(v) for k, v in sb._CPU_PREV.items()} == prev_cpu, "TTL hit does not touch _CPU_PREV")
    sb.CLI_CACHE_TTL = float(os.environ.get("AGENT_SWITCHBOARD_CLI_CACHE_TTL", 5.0))
    print("PASS_UNIT T51j TTL hit leaves _CPU_PREV")

    # emitted status always inside the hub allowlist
    bad = []
    for n in walk(p3["roots"]):
        if n.get("status") not in ALLOW:
            bad.append((n.get("pid"), n.get("status")))
    for n in walk(pv["roots"]):
        if n.get("status") not in ALLOW:
            bad.append((n.get("pid"), n.get("status")))
    assert_true(not bad, "status allowlist %s" % bad)
    print("PASS_UNIT T51k status allowlist")

    print("ALL_T51_OK")
finally:
    shutil.rmtree(tmp, ignore_errors=True)
    sb.ps_cli_snapshot = sb.ps_cli_snapshot  # leftover; process exits
EOF
if [ $? -eq 0 ]; then
  ck ok ok "T51a cputime parser BSD unbounded minutes + GNU [DD-]HH:MM:SS"
  ck ok ok "T51b lstart-bearing six-group row"
  ck ok ok "T51c mandatory legacy-regex fallback (stubbed ps, cpu_s=None, forest populated)"
  ck ok ok "T51d cpu-delta => active; idle => running"
  ck ok ok "T51e live OS child => active (real spawned child)"
  ck ok ok "T51f first-obs; virtual grok-sub does not count as a child"
  ck ok ok "T51g epsilon 0.04s running / 0.06s active"
  ck ok ok "T51h gap<1.0s carries status forward"
  ck ok ok "T51i gap>120s re-firsts"
  ck ok ok "T51j TTL hit never resamples / never touches _CPU_PREV"
  ck ok ok "T51k emitted status inside hub allowlist"
else
  ck fail ok "T51 per-node status unit block"
fi

# T52: agent ledger + CLI-grid retention + agents CLI + rollover (ports 17950-17954)
python3 - "$SB" <<'EOF'
import importlib.machinery, importlib.util, sys, os, json, tempfile, shutil, time, subprocess, glob

loader = importlib.machinery.SourceFileLoader("sb", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
sb = importlib.util.module_from_spec(spec)
loader.exec_module(sb)

NOW = 1_700_000_000.0
LSTART = "Tue Aug 18 02:45:07 2026"
GROK = "/home/user/.grok/bin/grok"


def rec(pid, ppid, tty, command, lstart=LSTART, cpu_s=0.0):
    return {
        "pid": pid, "ppid": ppid, "tty": tty, "lstart": lstart,
        "command": command, "cputime": "0:00.00", "cpu_s": cpu_s,
    }


def find(nodes, pred):
    for n in nodes:
        if pred(n):
            return n
        hit = find(n.get("children") or [], pred)
        if hit:
            return hit
    return None


def walk(nodes):
    for n in nodes or []:
        yield n
        yield from walk(n.get("children") or [])


def assert_true(cond, msg):
    if not cond:
        print("FAIL_ASSERT", msg)
        sys.exit(1)


def reset_ledger(root):
    sb.ROOT = root
    sb._LEDGER_SEEN_START.clear()
    sb._LEDGER_SEEN_END.clear()
    sb._LEDGER_STARTS.clear()
    sb._LEDGER_ENDS.clear()
    sb._LEDGER_LIVE.clear()
    sb._LEDGER_CWD_DONE.clear()
    sb._LEDGER_GROK_META_MEMO.clear()
    sb._LEDGER_SEEDED = True
    sb.reset_cli_cache()
    sb.reset_model_defaults()


def payload_for(snap, mono, now):
    sb.ps_cli_snapshot = lambda: snap
    return sb.get_cli_payload(force=True, now=now, mono=mono)


def ledger_rows(root):
    path = os.path.join(root, "agents.jsonl")
    if not os.path.isfile(path):
        return []
    out = []
    for line in open(path):
        line = line.strip()
        if line:
            out.append(json.loads(line))
    return out


tmp = tempfile.mkdtemp(prefix="sb-t52-")
try:
    reset_ledger(tmp)
    dummy = {1: rec(1, 0, "??", "/sbin/launchd", cpu_s=0.0)}  # non-keep, keeps snap nonempty
    snap_g = {
        1: rec(1, 0, "??", "/sbin/launchd", cpu_s=0.0),
        4242: rec(4242, 1, "ttys001", GROK, cpu_s=0.0),
    }
    p1 = payload_for(snap_g, 10.0, NOW)
    node = find(p1["roots"], lambda n: n["pid"] == 4242)
    assert_true(node and node.get("id"), "live node has id")
    want_id = node["id"]
    assert_true(want_id.startswith("p:4242:"), "os id p:<pid>:<lstart>")
    rows = ledger_rows(tmp)
    starts = [r for r in rows if r.get("ev") == "start" and r.get("id") == want_id]
    assert_true(len(starts) == 1, "one start for synthetic run")
    assert_true(starts[0]["observed"] == "live", "observed live")
    assert_true(starts[0]["kind"] == "grok", "kind grok")
    assert_true(starts[0]["pid"] == 4242, "pid int")
    assert_true(starts[0]["parents"] == [], "root parents []")
    assert_true(starts[0]["channel"] is None, "channel null when absent (not synthesised from label)")
    # id reconciliation: ledger id == /v1/cli node id
    assert_true(starts[0]["id"] == want_id, "ledger<->/v1/cli id reconciliation")
    print("PASS_UNIT T52a id reconciliation + live start")

    # gone => completed, served inside window, omitted after expiry
    snap_gone = {1: rec(1, 0, "??", "/sbin/launchd", cpu_s=0.0)}
    p2 = payload_for(snap_gone, 12.0, NOW + 5)
    ended_node = find(p2["roots"], lambda n: n.get("id") == want_id)
    assert_true(ended_node and ended_node.get("status") == "completed",
                "terminal node served with completed inside window")
    ends = [r for r in ledger_rows(tmp) if r.get("ev") == "end" and r.get("id") == want_id]
    assert_true(len(ends) == 1 and ends[0]["ended_source"] == "gone", "gone end")
    assert_true(ends[0]["status"] == "completed", "gone status completed")
    os.environ["AGENT_SWITCHBOARD_DONE_EXPIRE"] = "1"
    p3 = payload_for(snap_gone, 14.0, NOW + 5 + 2)
    omitted = find(p3["roots"], lambda n: n.get("id") == want_id)
    assert_true(omitted is None, "omitted after expiry")
    os.environ["AGENT_SWITCHBOARD_DONE_EXPIRE"] = "900"
    print("PASS_UNIT T52b completed served inside window, omitted after expiry")

    # cancelled path (grok-sub meta)
    reset_ledger(tmp)
    sess = os.path.join(tmp, "gs")
    sb.GROK_SESS_ROOT = sess
    cwd = "/tmp/lane-t52"
    enc = __import__("urllib.parse").parse.quote(cwd, safe="")
    sid = "019ff000-0000-0000-0000-00000000t52c"
    subp = os.path.join(sess, enc, sid, "subagents", "sub-can")
    os.makedirs(subp)
    json.dump({
        "subagent_id": "sub-can", "parent_session_id": sid,
        "status": "cancelled", "started_at": "2026-08-18T02:45:07Z",
        "completed_at": sb._iso_z(NOW),
        "description": "cancelled-sub",
    }, open(os.path.join(subp, "meta.json"), "w"))
    pcan = payload_for({1: rec(1, 0, "??", "/sbin/launchd")}, 20.0, NOW)
    gs_id = "gs:%s:sub-can" % sid
    rows = ledger_rows(tmp)
    st = [r for r in rows if r.get("ev") == "start" and r.get("id") == gs_id]
    en = [r for r in rows if r.get("ev") == "end" and r.get("id") == gs_id]
    assert_true(len(st) == 1 and st[0]["observed"] == "posthoc", "posthoc backfill start")
    assert_true(len(en) == 1 and en[0]["status"] == "cancelled" and en[0]["ended_source"] == "meta",
                "cancelled meta end")
    served = find(pcan["roots"], lambda n: n.get("id") == gs_id)
    assert_true(served and served.get("status") == "cancelled", "cancelled served")
    print("PASS_UNIT T52c cancelled + posthoc backfill")

    # completed grok-sub ingested (terminal skip does not apply to ledger)
    subp2 = os.path.join(sess, enc, sid, "subagents", "sub-done")
    os.makedirs(subp2)
    json.dump({
        "subagent_id": "sub-done", "parent_session_id": sid,
        "status": "completed", "started_at": "2026-08-18T02:45:07Z",
        "description": "done-sub",
    }, open(os.path.join(subp2, "meta.json"), "w"))
    pdone = payload_for({1: rec(1, 0, "??", "/sbin/launchd")}, 21.0, NOW)
    gd_id = "gs:%s:sub-done" % sid
    rows = ledger_rows(tmp)
    st = [r for r in rows if r.get("ev") == "start" and r.get("id") == gd_id]
    en = [r for r in rows if r.get("ev") == "end" and r.get("id") == gd_id]
    assert_true(len(st) == 1 and st[0]["observed"] == "posthoc", "completed grok-sub start posthoc")
    assert_true(len(en) == 1 and en[0]["status"] == "completed" and en[0]["ended_source"] == "meta",
                "completed grok-sub ingested")
    print("PASS_UNIT T52d completed grok-sub ingested")

    # error path: slot DIED wins over gone
    reset_ledger(tmp)
    os.makedirs(os.path.join(tmp, "t52e"), exist_ok=True)
    json.dump({
        "task": "t52e", "lane": "died", "status": "running",
        "pid": 5555, "wrapper_pid": 5554,
        "prog_base": "grok", "wrapper_base": "agent-dispatch",
        "started": NOW - 10,
    }, open(os.path.join(tmp, "t52e", "slot-died.json"), "w"))
    snap_live = {
        1: rec(1, 0, "??", "/sbin/launchd"),
        5555: rec(5555, 1, "??", GROK),
    }
    payload_for(snap_live, 30.0, NOW)
    snap_dead = {1: rec(1, 0, "??", "/sbin/launchd")}
    perr = payload_for(snap_dead, 32.0, NOW + 3)
    rows = ledger_rows(tmp)
    nid = find(
        payload_for(snap_live, 30.0, NOW)["roots"] if False else [r for r in rows if r.get("ev") == "start"],
        lambda r: r.get("pid") == 5555,
    )
    # rows is a list of dicts; find() walks children. Use a list comp.
    st5555 = [r for r in rows if r.get("ev") == "start" and r.get("pid") == 5555]
    assert_true(len(st5555) == 1, "start for slot pid")
    en5555 = [r for r in rows if r.get("ev") == "end" and r.get("id") == st5555[0]["id"]]
    assert_true(len(en5555) == 1, "one end")
    assert_true(en5555[0]["ended_source"] == "slot" and en5555[0]["status"] == "error",
                "DIED slot => error, wins over gone")
    print("PASS_UNIT T52e error path slot DIED")

    # failed/empty sweep never writes ends
    reset_ledger(tmp)
    payload_for({
        1: rec(1, 0, "??", "/sbin/launchd"),
        9: rec(9, 1, "ttys001", GROK),
    }, 40.0, NOW)
    before = [r for r in ledger_rows(tmp) if r.get("ev") == "end"]
    sb.ps_cli_snapshot = lambda: None
    sb.get_cli_payload(force=True, now=NOW + 1, mono=41.0)
    after_none = [r for r in ledger_rows(tmp) if r.get("ev") == "end"]
    sb.ps_cli_snapshot = lambda: {}
    sb.get_cli_payload(force=True, now=NOW + 2, mono=42.0)
    after_empty = [r for r in ledger_rows(tmp) if r.get("ev") == "end"]
    assert_true(before == after_none == after_empty, "failed/empty sweep writes no ends")
    print("PASS_UNIT T52f failed/empty sweep no ends")

    # rollover with MAX_BYTES override env
    roll = tempfile.mkdtemp(prefix="sb-t52-roll-")
    reset_ledger(roll)
    os.environ["AGENT_SWITCHBOARD_AGENTS_MAX_BYTES"] = "180"
    rec_a = {
        "ev": "start", "ts": "2026-08-18T02:45:07Z", "id": "p:1:Tue-Aug-18-02:45:07-2026",
        "kind": "grok", "pid": 1, "parents": [], "channel": None, "label": "x" * 40,
        "model": None, "cwd": None, "task": None, "lane": None, "observed": "live",
    }
    rec_b = dict(rec_a, id="p:2:Tue-Aug-18-02:45:07-2026", pid=2)
    sb._ledger_append(rec_a)
    sb._ledger_append(rec_b)
    assert_true(os.path.isfile(os.path.join(roll, "agents.jsonl.1")), "rollover sibling .1")
    live = open(os.path.join(roll, "agents.jsonl")).read()
    old = open(os.path.join(roll, "agents.jsonl.1")).read()
    assert_true(rec_a["id"] in old and rec_b["id"] in live, "append-line atomicity after rotate")
    os.environ.pop("AGENT_SWITCHBOARD_AGENTS_MAX_BYTES", None)
    shutil.rmtree(roll, ignore_errors=True)
    print("PASS_UNIT T52g rollover MAX_BYTES")

    # agents CLI --since / --live / --json + counts line
    reset_ledger(tmp)
    # plant a start+end in the ledger file; new process will seed
    os.makedirs(tmp, exist_ok=True)
    nid = "p:69697:Tue-Aug-18-02:45:07-2026"
    with open(os.path.join(tmp, "agents.jsonl"), "w") as f:
        f.write(json.dumps({
            "ev": "start", "ts": "2026-08-23T00:00:00Z", "id": nid, "kind": "grok",
            "pid": 69697, "parents": [], "channel": None, "label": "cli-row",
            "model": None, "cwd": None, "task": None, "lane": None, "observed": "live",
        }) + "\n")
        f.write(json.dumps({
            "ev": "end", "ts": "2026-08-23T00:01:00Z", "id": nid,
            "status": "completed", "ended_source": "gone",
        }) + "\n")
    env = os.environ.copy()
    env["AGENT_SWITCHBOARD_ROOT"] = tmp
    env["AGENT_SWITCHBOARD_ENSURE_DISABLE"] = "1"
    env["AGENT_SWITCHBOARD_DONE_EXPIRE"] = "900"
    bin_path = sys.argv[1]
    py = [sys.executable, bin_path]
    r_json = subprocess.run(
        py + ["agents", "--json", "--since", "30d"],
        capture_output=True, text=True, env=env,
    )
    assert_true(r_json.returncode == 0, "agents --json exit 0 got %s %s" % (r_json.returncode, r_json.stderr[-200:]))
    data = json.loads(r_json.stdout)
    assert_true("running" in data and "ended" in data and "counts" in data, "json shape")
    assert_true(data["counts"]["ended"] >= 1, "json counts.ended")
    assert_true(any(e.get("end", e).get("id") == nid or e.get("id") == nid
                    for e in data["ended"]), "ended row in json")
    r_live = subprocess.run(
        py + ["agents", "--json", "--live", "--since", "30d"],
        capture_output=True, text=True, env=env,
    )
    d_live = json.loads(r_live.stdout)
    assert_true(d_live["counts"]["ended"] == 0 and d_live["ended"] == [], "--live skips ended")
    r_h = subprocess.run(
        py + ["agents", "--since", "30d"],
        capture_output=True, text=True, env=env,
    )
    last = [ln for ln in r_h.stdout.splitlines() if ln.startswith("running=")]
    assert_true(len(last) == 1 and "ended=" in last[0], "counts line running=N ended=M")
    r_since = subprocess.run(
        py + ["agents", "--since", "1s"],
        capture_output=True, text=True, env=env,
    )
    # planted ts is 2026-08-23; suite date is 2026-08-23 so 1s window likely excludes it
    r_bad = subprocess.run(
        py + ["agents", "--since", "nope"],
        capture_output=True, text=True, env=env,
    )
    assert_true(r_bad.returncode == 2, "--since grammar reject")
    print("PASS_UNIT T52h agents CLI --since/--live/--json + counts line")

    # seeded OOV DONE is clamped at emit to completed; never served as OOV
    reset_ledger(tmp)
    os.environ["AGENT_SWITCHBOARD_DONE_EXPIRE"] = "900"
    nid_done = "p:7777:Tue-Aug-18-02:45:07-2026"
    os.makedirs(tmp, exist_ok=True)
    with open(os.path.join(tmp, "agents.jsonl"), "w") as f:
        f.write(json.dumps({
            "ev": "start", "ts": sb._iso_z(NOW - 10), "id": nid_done, "kind": "grok",
            "pid": 7777, "parents": [], "channel": None, "label": "oov-done",
            "model": None, "cwd": None, "task": None, "lane": None, "observed": "live",
        }) + "\n")
        f.write(json.dumps({
            "ev": "end", "ts": sb._iso_z(NOW - 2), "id": nid_done,
            "status": "DONE", "ended_source": "slot",
        }) + "\n")
    sb._LEDGER_SEEDED = False
    p_oov = payload_for({1: rec(1, 0, "??", "/sbin/launchd")}, 50.0, NOW)
    served_oov = find(p_oov["roots"], lambda n: n.get("id") == nid_done)
    assert_true(served_oov is not None, "seeded DONE node is served")
    assert_true(served_oov.get("status") == "completed", "DONE maps to completed")
    oov = [n.get("status") for n in walk(p_oov["roots"])
           if n.get("status") not in sb.CLI_TREE_STATUSES]
    assert_true(oov == [], "no OOV status emitted")
    print("PASS_UNIT T52k seeded DONE clamped to completed, never OOV")

    # terminal grok-sub memo short-circuits read_json (one read)
    reset_ledger(tmp)
    sess_memo = os.path.join(tmp, "gs-memo")
    sb.GROK_SESS_ROOT = sess_memo
    cwd_m = "/tmp/lane-t52-memo"
    enc_m = __import__("urllib.parse").parse.quote(cwd_m, safe="")
    sid_m = "019ff000-0000-0000-0000-00000000t52l"
    subp_m = os.path.join(sess_memo, enc_m, sid_m, "subagents", "sub-once")
    os.makedirs(subp_m)
    json.dump({
        "subagent_id": "sub-once", "parent_session_id": sid_m,
        "status": "completed", "started_at": "2026-08-18T02:45:07Z",
        "description": "once-sub",
    }, open(os.path.join(subp_m, "meta.json"), "w"))
    reads = {"n": 0}
    real_rj = sb.read_json

    def counting_read_json(path):
        reads["n"] += 1
        return real_rj(path)

    sb.read_json = counting_read_json
    try:
        forest_empty = {"roots": []}
        sb._ledger_orphan_grok_subs(forest_empty, NOW)
        assert_true(reads["n"] == 1, "first orphan scan reads meta once got %s" % reads["n"])
        sb._ledger_orphan_grok_subs(forest_empty, NOW)
        sb._ledger_orphan_grok_subs(forest_empty, NOW)
        assert_true(reads["n"] == 1, "memo short-circuits further reads got %s" % reads["n"])
    finally:
        sb.read_json = real_rj
    print("PASS_UNIT T52l terminal grok-sub memo reads meta once")

    # T52m: posthoc flood-guard — months-old completed session dir is
    # ledgered with its meta end ts and NEVER served; a fresh one IS
    # served then expires. (ports 17950-17954)
    reset_ledger(tmp)
    sess_m = os.path.join(tmp, "gs-t52m")
    sb.GROK_SESS_ROOT = sess_m
    os.environ["AGENT_SWITCHBOARD_DONE_EXPIRE"] = "900"
    cwd_m = "/tmp/lane-t52m"
    enc_m = __import__("urllib.parse").parse.quote(cwd_m, safe="")
    sid_old = "019ff000-0000-0000-0000-000000t52mo"
    sid_fresh = "019ff000-0000-0000-0000-000000t52mf"
    old_iso = "2023-01-01T00:00:00Z"
    fresh_iso = sb._iso_z(NOW - 5)
    for sid, sub, completed in (
        (sid_old, "sub-old", old_iso),
        (sid_fresh, "sub-fresh", fresh_iso),
    ):
        pth = os.path.join(sess_m, enc_m, sid, "subagents", sub)
        os.makedirs(pth)
        json.dump({
            "subagent_id": sub, "parent_session_id": sid,
            "status": "completed", "started_at": completed,
            "completed_at": completed, "description": sub,
        }, open(os.path.join(pth, "meta.json"), "w"))
    id_old = "gs:%s:sub-old" % sid_old
    id_fresh = "gs:%s:sub-fresh" % sid_fresh
    dummy_m = {1: rec(1, 0, "??", "/sbin/launchd", cpu_s=0.0)}
    p_m = payload_for(dummy_m, 60.0, NOW)
    rows = ledger_rows(tmp)
    en_old = [r for r in rows if r.get("ev") == "end" and r.get("id") == id_old]
    en_fresh = [r for r in rows if r.get("ev") == "end" and r.get("id") == id_fresh]
    assert_true(len(en_old) == 1 and en_old[0]["ended_source"] == "meta",
                "months-old completed grok-sub is ledgered")
    assert_true(en_old[0]["ts"] == old_iso,
                "old end ts is meta completed_at, not observation time")
    assert_true(len(en_fresh) == 1 and en_fresh[0]["ts"] == fresh_iso,
                "fresh completed grok-sub ledgered with its own end ts")
    served_old = find(p_m["roots"], lambda n: n.get("id") == id_old)
    served_fresh = find(p_m["roots"], lambda n: n.get("id") == id_fresh)
    assert_true(served_old is None, "months-old completed grok-sub NOT served")
    assert_true(served_fresh is not None and served_fresh.get("status") == "completed",
                "fresh completed grok-sub IS served")
    os.environ["AGENT_SWITCHBOARD_DONE_EXPIRE"] = "1"
    p_exp = payload_for(dummy_m, 62.0, NOW + 7)
    omitted_fresh = find(p_exp["roots"], lambda n: n.get("id") == id_fresh)
    assert_true(omitted_fresh is None, "fresh omitted after expiry")
    os.environ["AGENT_SWITCHBOARD_DONE_EXPIRE"] = "900"
    print("PASS_UNIT T52m flood-guard keys posthoc retention on meta end ts")

    print("ALL_T52_OK")
finally:
    shutil.rmtree(tmp, ignore_errors=True)
EOF
if [ $? -eq 0 ]; then
  ck ok ok "T52a ledger<->/v1/cli id reconciliation for a synthetic run"
  ck ok ok "T52b terminal completed served inside window, omitted after expiry"
  ck ok ok "T52c cancelled path + posthoc backfill observed=posthoc"
  ck ok ok "T52d completed grok-sub ingested"
  ck ok ok "T52e error path (slot DIED => error, wins over gone)"
  ck ok ok "T52f failed/empty sweep writes no ends"
  ck ok ok "T52g rollover with MAX_BYTES override env"
  ck ok ok "T52h agents CLI --since/--live/--json + counts line"
  ck ok ok "T52k seeded DONE clamped to completed, never OOV"
  ck ok ok "T52l terminal grok-sub memo reads meta once"
  ck ok ok "T52m months-old posthoc grok-sub ledgered not served; fresh served then expires"
else
  ck fail ok "T52 agent ledger unit block"
fi

# T52 serve: terminal node on /v1/cli inside window / omitted after expiry (ports 17952-17953)
T52_ROOT=$(mktemp -d)
python3 - "$T52_ROOT" <<'EOF'
import json, os, sys, time
root = sys.argv[1]
nid = "p:69697:Tue-Aug-18-02:45:07-2026"
now = time.time()
def z(t):
    import datetime
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
open(os.path.join(root, "agents.jsonl"), "w").write(
    json.dumps({
        "ev": "start", "ts": z(now - 10), "id": nid, "kind": "grok",
        "pid": 69697, "parents": [], "channel": None, "label": "served-row",
        "model": None, "cwd": None, "task": None, "lane": None, "observed": "posthoc",
    }) + "\n" + json.dumps({
        "ev": "end", "ts": z(now - 2), "id": nid,
        "status": "completed", "ended_source": "gone",
    }) + "\n"
)
EOF
AGENT_SWITCHBOARD_ROOT="$T52_ROOT" AGENT_SWITCHBOARD_DONE_EXPIRE=900 AGENT_SWITCHBOARD_CLI_CACHE_TTL=0.2 \
  "$SB" serve --port 17952 >/dev/null 2>&1 &
SRV52A=$!
sleep 1.5
CLI52A=$(curl -s "http://127.0.0.1:17952/v1/cli")
HIT52A=$(python3 -c '
import json,sys
d=json.loads(sys.argv[1])
def walk(ns):
    for n in ns or []:
        yield n
        yield from walk(n.get("children") or [])
hit=any(n.get("id")=="p:69697:Tue-Aug-18-02:45:07-2026" and n.get("status")=="completed" for n in walk(d.get("roots")))
print("YES" if hit else "NO")
' "$CLI52A")
ck "$HIT52A" "YES" "T52i served /v1/cli completed node inside DONE_EXPIRE window"
kill "$SRV52A" 2>/dev/null
wait 2>/dev/null

python3 - "$T52_ROOT" <<'EOF'
import json, os, sys, time, datetime
root = sys.argv[1]
nid = "p:69697:Tue-Aug-18-02:45:07-2026"
def z(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
now = time.time()
open(os.path.join(root, "agents.jsonl"), "w").write(
    json.dumps({
        "ev": "start", "ts": z(now - 100), "id": nid, "kind": "grok",
        "pid": 69697, "parents": [], "channel": None, "label": "old-row",
        "model": None, "cwd": None, "task": None, "lane": None, "observed": "posthoc",
    }) + "\n" + json.dumps({
        "ev": "end", "ts": z(now - 50), "id": nid,
        "status": "completed", "ended_source": "gone",
    }) + "\n"
)
EOF
AGENT_SWITCHBOARD_ROOT="$T52_ROOT" AGENT_SWITCHBOARD_DONE_EXPIRE=1 AGENT_SWITCHBOARD_CLI_CACHE_TTL=0.2 \
  "$SB" serve --port 17953 >/dev/null 2>&1 &
SRV52B=$!
sleep 1.5
CLI52B=$(curl -s "http://127.0.0.1:17953/v1/cli")
HIT52B=$(python3 -c '
import json,sys
d=json.loads(sys.argv[1])
def walk(ns):
    for n in ns or []:
        yield n
        yield from walk(n.get("children") or [])
hit=any(n.get("id")=="p:69697:Tue-Aug-18-02:45:07-2026" for n in walk(d.get("roots")))
print("YES" if hit else "NO")
' "$CLI52B")
ck "$HIT52B" "NO" "T52j expired ledger node omitted from served /v1/cli"
kill "$SRV52B" 2>/dev/null
wait 2>/dev/null
rm -rf "$T52_ROOT"

# ---- T53a–T53k reaper safety contract (ports 17955-17959 ONLY) ----
t53_alive() { kill -0 "$1" 2>/dev/null; }
t53_kill() { kill -9 "$@" 2>/dev/null || true; }
t53_confirm() {
  python3 - "$AGENT_SWITCHBOARD_ROOT" "$1" "$2" "${3:-}" "${4:-}" <<'PY'
import json, os, sys, time
root, task, lane = sys.argv[1], sys.argv[2], sys.argv[3]
rid_ov = sys.argv[4] if len(sys.argv) > 4 else ""
pb_ov = sys.argv[5] if len(sys.argv) > 5 else ""
slot = json.load(open(os.path.join(root, task, "slot-%s.json" % lane)))
doc = {
    "lane": lane,
    "run_id": rid_ov or slot["run_id"],
    "pid": slot["pid"],
    "prog_base": pb_ov or slot["prog_base"],
    "confirmed_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
    "reason": "test",
}
path = os.path.join(root, task, "reap-confirm-%s.json" % lane)
json.dump(doc, open(path, "w"), indent=2)
print(path)
PY
}
t53_wait_state() {
  # task lane want [stall_after]
  _t=$1; _l=$2; _w=$3; _sa=${4:-1}
  _i=0
  while [ "$_i" -lt 20 ]; do
    _st=$(AGENT_SWITCHBOARD_STALL_AFTER="$_sa" "$SB" status --task "$_t" --json | python3 -c "import json,sys; d=json.load(sys.stdin); print([s['state'] for s in d[0]['slots'] if s['lane']==sys.argv[1]][0])" "$_l")
    [ "$_st" = "$_w" ] && return 0
    _i=$((_i + 1))
    sleep 0.3
  done
  echo "$_st"
  return 1
}

# T53a: gate off => refuse exit 2, no signal, confirm not consumed; no reap HTTP route
"$SB" serve --port 17955 >/dev/null 2>&1 &
SRV53A=$!
sleep 1.5
HA=$(curl -s "http://127.0.0.1:17955/v1/health" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ok"))' 2>/dev/null || echo fail)
ck "$HA" "True" "T53a0 test daemon health on 17955"
GET53=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:17955/v1/reap")
POST53=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:17955/v1/reap")
[ "$GET53" != "200" ] && ck ok ok "T53a GET /v1/reap is non-200 ($GET53)" || ck "$GET53" "non-200" "T53a GET /v1/reap is non-200"
[ "$POST53" != "200" ] && ck ok ok "T53a POST /v1/reap is non-200 ($POST53)" || ck "$POST53" "non-200" "T53a POST /v1/reap is non-200"
"$TD" --task t53a --lane stuck --exec /bin/sleep -- 60 >/dev/null 2>&1 &
WRAP53A=$!
sleep 0.6
CHILD53A=$(python3 -c "import json,os; print(json.load(open(os.path.join(os.environ['AGENT_SWITCHBOARD_ROOT'],'t53a','slot-stuck.json')))['pid'])")
t53_confirm t53a stuck >/dev/null
unset AGENT_SWITCHBOARD_REAPER || true
AGENT_SWITCHBOARD_STALL_AFTER=1 "$SB" reap --task t53a --lane stuck >/dev/null 2>&1
RC53A=$?
ck "$RC53A" "2" "T53a gate off refuses with exit 2"
t53_alive "$CHILD53A" && ck ok ok "T53a target process untouched" || ck dead alive "T53a target process untouched"
if [ -f "$AGENT_SWITCHBOARD_ROOT/t53a/reap-confirm-stuck.json" ]; then ck ok ok "T53a confirm not consumed"; else ck missing present "T53a confirm not consumed"; fi
grep -q '"reason": "disabled"' "$AGENT_SWITCHBOARD_ROOT/t53a/events.jsonl" && ck ok ok "T53a reap_refused reason=disabled" || ck missing logged "T53a reap_refused reason=disabled"
t53_kill "$CHILD53A" "$WRAP53A"
kill "$SRV53A" 2>/dev/null
wait 2>/dev/null

# T53b: confirmed kill of a fake stuck sleeper
"$TD" --task t53b --lane stuck --exec /bin/sleep -- 60 >/dev/null 2>&1 &
WRAP53B=$!
sleep 0.8
CHILD53B=$(python3 -c "import json,os; print(json.load(open(os.path.join(os.environ['AGENT_SWITCHBOARD_ROOT'],'t53b','slot-stuck.json')))['pid'])")
t53_wait_state t53b stuck STALLED 1 >/dev/null
t53_confirm t53b stuck >/dev/null
AGENT_SWITCHBOARD_REAPER=1 AGENT_SWITCHBOARD_STALL_AFTER=1 "$SB" reap --task t53b --lane stuck >/dev/null 2>&1
RC53B=$?
ck "$RC53B" "0" "T53b reap exits 0"
sleep 0.4
t53_alive "$CHILD53B" && ck alive dead "T53b worker is dead" || ck ok ok "T53b TERM/KILL landed (worker dead)"
ST53B=$(python3 -c "import json,os; s=json.load(open(os.path.join(os.environ['AGENT_SWITCHBOARD_ROOT'],'t53b','slot-stuck.json'))); print(s.get('status'), s.get('exit_code'))")
echo "$ST53B" | grep -q 'exited' && ck ok ok "T53b slot finalized status=exited" || ck "$ST53B" "exited" "T53b slot finalized"
grep -q '"event": "reap"' "$AGENT_SWITCHBOARD_ROOT/t53b/events.jsonl" && ck ok ok "T53b reap event logged" || ck missing logged "T53b reap event logged"
grep -q '"ended_source":"reap"' "$AGENT_SWITCHBOARD_ROOT/agents.jsonl" && ck ok ok "T53b ledger end ended_source=reap" || ck missing logged "T53b ledger end ended_source=reap"
if [ ! -f "$AGENT_SWITCHBOARD_ROOT/t53b/reap-confirm-stuck.json" ] && ls "$AGENT_SWITCHBOARD_ROOT/t53b/history"/reap-confirm-stuck-*.json >/dev/null 2>&1; then
  ck ok ok "T53b confirm consumed into history/"
else
  ck missing history "T53b confirm consumed into history/"
fi
t53_kill "$CHILD53B" "$WRAP53B"
wait "$WRAP53B" 2>/dev/null || true

# T53c: prog_base mismatch => identity_miss, process untouched, confirm consumed
"$TD" --task t53c --lane stuck --exec /bin/sleep -- 60 >/dev/null 2>&1 &
WRAP53C=$!
sleep 0.6
CHILD53C=$(python3 -c "import json,os; print(json.load(open(os.path.join(os.environ['AGENT_SWITCHBOARD_ROOT'],'t53c','slot-stuck.json')))['pid'])")
t53_wait_state t53c stuck STALLED 1 >/dev/null
t53_confirm t53c stuck "" python3 >/dev/null
AGENT_SWITCHBOARD_REAPER=1 AGENT_SWITCHBOARD_STALL_AFTER=1 "$SB" reap --task t53c --lane stuck >/dev/null 2>&1
RC53C=$?
ck "$RC53C" "2" "T53c mismatch refuses with exit 2"
t53_alive "$CHILD53C" && ck ok ok "T53c target process untouched" || ck dead alive "T53c target process untouched"
grep -q '"event": "identity_miss"' "$AGENT_SWITCHBOARD_ROOT/t53c/events.jsonl" && ck ok ok "T53c identity_miss event" || ck missing logged "T53c identity_miss event"
if [ ! -f "$AGENT_SWITCHBOARD_ROOT/t53c/reap-confirm-stuck.json" ]; then ck ok ok "T53c confirm consumed"; else ck present consumed "T53c confirm consumed"; fi
t53_kill "$CHILD53C" "$WRAP53C"
wait "$WRAP53C" 2>/dev/null || true

# T53d: stale confirm run_id => exit 3, confirm consumed
"$TD" --task t53d --lane stuck --exec /bin/sleep -- 60 >/dev/null 2>&1 &
WRAP53D=$!
sleep 0.6
CHILD53D=$(python3 -c "import json,os; print(json.load(open(os.path.join(os.environ['AGENT_SWITCHBOARD_ROOT'],'t53d','slot-stuck.json')))['pid'])")
t53_wait_state t53d stuck STALLED 1 >/dev/null
t53_confirm t53d stuck STALE_RUN >/dev/null
AGENT_SWITCHBOARD_REAPER=1 AGENT_SWITCHBOARD_STALL_AFTER=1 "$SB" reap --task t53d --lane stuck >/dev/null 2>&1
RC53D=$?
ck "$RC53D" "3" "T53d stale run_id exits 3"
t53_alive "$CHILD53D" && ck ok ok "T53d target process untouched" || ck dead alive "T53d target process untouched"
if [ ! -f "$AGENT_SWITCHBOARD_ROOT/t53d/reap-confirm-stuck.json" ]; then ck ok ok "T53d confirm consumed"; else ck present consumed "T53d confirm consumed"; fi
t53_kill "$CHILD53D" "$WRAP53D"
wait "$WRAP53D" 2>/dev/null || true

# T53e: never-kill stall-* lane
"$TD" --task t53e --lane stall-keep --exec /bin/sleep -- 60 >/dev/null 2>&1 &
WRAP53E=$!
sleep 0.6
CHILD53E=$(python3 -c "import json,os; print(json.load(open(os.path.join(os.environ['AGENT_SWITCHBOARD_ROOT'],'t53e','slot-stall-keep.json')))['pid'])")
t53_wait_state t53e stall-keep STALLED 1 >/dev/null
t53_confirm t53e stall-keep >/dev/null
AGENT_SWITCHBOARD_REAPER=1 AGENT_SWITCHBOARD_STALL_AFTER=1 "$SB" reap --task t53e --lane stall-keep >/dev/null 2>&1
RC53E=$?
ck "$RC53E" "2" "T53e stall-* refused with exit 2"
t53_alive "$CHILD53E" && ck ok ok "T53e stall-* process untouched" || ck dead alive "T53e stall-* process untouched"
grep -q '"reason": "never_kill"' "$AGENT_SWITCHBOARD_ROOT/t53e/events.jsonl" && ck ok ok "T53e reason=never_kill" || ck missing logged "T53e reason=never_kill"
t53_kill "$CHILD53E" "$WRAP53E"
wait "$WRAP53E" 2>/dev/null || true

# T53f: wrapper alive => wrapper finalizes, daemon does not write, exactly one exit event
"$TD" --task t53f --lane stuck --exec /bin/sleep -- 60 >/dev/null 2>&1 &
WRAP53F=$!
sleep 0.6
CHILD53F=$(python3 -c "import json,os; print(json.load(open(os.path.join(os.environ['AGENT_SWITCHBOARD_ROOT'],'t53f','slot-stuck.json')))['pid'])")
t53_wait_state t53f stuck STALLED 1 >/dev/null
t53_confirm t53f stuck >/dev/null
AGENT_SWITCHBOARD_REAPER=1 AGENT_SWITCHBOARD_STALL_AFTER=1 "$SB" reap --task t53f --lane stuck >/dev/null 2>&1
RC53F=$?
ck "$RC53F" "0" "T53f reap exits 0"
wait "$WRAP53F" 2>/dev/null || true
sleep 0.3
EX53F=$(grep -c '"event": "exit"' "$AGENT_SWITCHBOARD_ROOT/t53f/events.jsonl" || true)
ck "$EX53F" "1" "T53f exactly one exit event"
REAPED53F=$(python3 -c "import json,os; s=json.load(open(os.path.join(os.environ['AGENT_SWITCHBOARD_ROOT'],'t53f','slot-stuck.json'))); print(s.get('reaped'))")
ck "$REAPED53F" "None" "T53f daemon did not write reaped=true (wrapper finalized)"
t53_kill "$CHILD53F" "$WRAP53F"

# T53g: wedged wrapper (SIGSTOP) => daemon finalizes at ~5s with reaped=true;
# after SIGCONT wrapper does not double-write
"$TD" --task t53g --lane stuck --exec /bin/sleep -- 60 >/dev/null 2>&1 &
WRAP53G=$!
sleep 0.8
CHILD53G=$(python3 -c "import json,os; print(json.load(open(os.path.join(os.environ['AGENT_SWITCHBOARD_ROOT'],'t53g','slot-stuck.json')))['pid'])")
t53_wait_state t53g stuck STALLED 1 >/dev/null
kill -STOP "$WRAP53G" 2>/dev/null
t53_confirm t53g stuck >/dev/null
T0G=$(date +%s)
AGENT_SWITCHBOARD_REAPER=1 AGENT_SWITCHBOARD_STALL_AFTER=1 "$SB" reap --task t53g --lane stuck >/dev/null 2>&1
RC53G=$?
DTG=$(( $(date +%s) - T0G ))
ck "$RC53G" "0" "T53g reap exits 0"
[ "$DTG" -ge 5 ] && ck ok ok "T53g daemon waited ~5s to finalize (dt=${DTG}s)" || ck "$DTG" ">=5" "T53g daemon waited ~5s"
REAPED53G=$(python3 -c "import json,os; s=json.load(open(os.path.join(os.environ['AGENT_SWITCHBOARD_ROOT'],'t53g','slot-stuck.json'))); print(s.get('reaped') is True, s.get('ended'))")
ENDED53G=$(python3 -c "import json,os; print(json.load(open(os.path.join(os.environ['AGENT_SWITCHBOARD_ROOT'],'t53g','slot-stuck.json'))).get('ended'))")
echo "$REAPED53G" | grep -q '^True ' && ck ok ok "T53g slot reaped=true" || ck "$REAPED53G" "True" "T53g slot reaped=true"
kill -CONT "$WRAP53G" 2>/dev/null
wait "$WRAP53G" 2>/dev/null || true
sleep 0.4
grep -q '"event": "reap_finalize_skipped"' "$AGENT_SWITCHBOARD_ROOT/t53g/events.jsonl" && ck ok ok "T53g reap_finalize_skipped after SIGCONT" || ck missing logged "T53g reap_finalize_skipped after SIGCONT"
ENDED53G2=$(python3 -c "import json,os; print(json.load(open(os.path.join(os.environ['AGENT_SWITCHBOARD_ROOT'],'t53g','slot-stuck.json'))).get('ended'))")
ck "$ENDED53G2" "$ENDED53G" "T53g ended unchanged after wrapper woke"
t53_kill "$CHILD53G" "$WRAP53G"

# T53h: ORPHAN (wrapper dead, worker alive) => reaped + daemon-finalized, no 5s wait
"$TD" --task t53h --lane stuck --exec /bin/sleep -- 60 >/dev/null 2>&1 &
WRAP53H=$!
sleep 0.8
CHILD53H=$(python3 -c "import json,os; print(json.load(open(os.path.join(os.environ['AGENT_SWITCHBOARD_ROOT'],'t53h','slot-stuck.json')))['pid'])")
t53_kill "$WRAP53H"
sleep 0.3
t53_wait_state t53h stuck ORPHAN 1 >/dev/null
ck "$(AGENT_SWITCHBOARD_STALL_AFTER=1 "$SB" status --task t53h --json | python3 -c "import json,sys; d=json.load(sys.stdin); print([s['state'] for s in d[0]['slots'] if s['lane']=='stuck'][0])")" "ORPHAN" "T53h derives ORPHAN"
t53_confirm t53h stuck >/dev/null
T0H=$(date +%s)
AGENT_SWITCHBOARD_REAPER=1 AGENT_SWITCHBOARD_STALL_AFTER=1 "$SB" reap --task t53h --lane stuck >/dev/null 2>&1
RC53H=$?
DTH=$(( $(date +%s) - T0H ))
ck "$RC53H" "0" "T53h reap exits 0"
[ "$DTH" -lt 6 ] && ck ok ok "T53h no 5s wait (dt=${DTH}s)" || ck "$DTH" "<6" "T53h no 5s wait"
REAPED53H=$(python3 -c "import json,os; print(json.load(open(os.path.join(os.environ['AGENT_SWITCHBOARD_ROOT'],'t53h','slot-stuck.json'))).get('reaped') is True)")
ck "$REAPED53H" "True" "T53h daemon-finalized reaped=true"
t53_kill "$CHILD53H" "$WRAP53H"

# T53i: knob-off zero-behavior-change + static nt-before-os.kill in reap_lane
(
  unset AGENT_SWITCHBOARD_REAPER || true
  unset AGENT_SWITCHBOARD_INVESTIGATOR || true
  "$TD" --task t53i --lane ok --exec /bin/bash -- -c 'exit 0' >/dev/null 2>&1
  echo $? > "$AGENT_SWITCHBOARD_ROOT/t53i-rc1"
  ST=$( "$SB" status --task t53i --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print([s["state"] for s in d[0]["slots"] if s["lane"]=="ok"][0])' )
  echo "$ST" > "$AGENT_SWITCHBOARD_ROOT/t53i-st1"
  "$TD" --task t53i --lane bad --exec /bin/bash -- -c 'exit 7' >/dev/null 2>&1
  echo $? > "$AGENT_SWITCHBOARD_ROOT/t53i-rc2"
  ST=$( "$SB" status --task t53i --json | python3 -c 'import json,sys; d=json.load(sys.stdin); s=[s for s in d[0]["slots"] if s["lane"]=="bad"][0]; print(s["state"], s["exit_code"])' )
  echo "$ST" > "$AGENT_SWITCHBOARD_ROOT/t53i-st2"
  "$TD" --task t53i --lane cap --exec /bin/bash -- -c 'sleep 15' >/dev/null 2>&1 &
  echo $! > "$AGENT_SWITCHBOARD_ROOT/t53i-wrap"
  sleep 0.5
  "$TD" --task t53i --lane cap --exec /bin/bash -- -c 'true' >/dev/null 2>&1
  echo $? > "$AGENT_SWITCHBOARD_ROOT/t53i-rc3"
)
ck "$(cat "$AGENT_SWITCHBOARD_ROOT/t53i-rc1")" "0" "T53i T1-clone exit 0 with knobs unset"
ck "$(cat "$AGENT_SWITCHBOARD_ROOT/t53i-st1")" "DONE" "T53i T1-clone derives DONE with knobs unset"
ck "$(cat "$AGENT_SWITCHBOARD_ROOT/t53i-rc2")" "7" "T53i T2-clone exit 7 with knobs unset"
ck "$(cat "$AGENT_SWITCHBOARD_ROOT/t53i-st2")" "FAILED 7" "T53i T2-clone derives FAILED 7 with knobs unset"
ck "$(cat "$AGENT_SWITCHBOARD_ROOT/t53i-rc3")" "2" "T53i T8-clone active same-lane refuse with knobs unset"
W53I=$(cat "$AGENT_SWITCHBOARD_ROOT/t53i-wrap")
C53I=$(python3 -c "import json,os; print(json.load(open(os.path.join(os.environ['AGENT_SWITCHBOARD_ROOT'],'t53i','slot-cap.json'))).get('pid') or '')" 2>/dev/null || true)
t53_kill "$W53I" "$C53I"
NT53I=$(python3 - "$SB" <<'PY'
import io, re, sys
src = open(sys.argv[1]).read()
m = re.search(r"\ndef reap_lane\(", src)
if not m:
    print("NO_REAP_LANE")
    sys.exit(0)
rest = src[m.start():]
m2 = re.search(r"\ndef ", rest[1:])
body = rest if not m2 else rest[:m2.start()+1]
nt = body.find('os.name == "nt"')
# first os.kill in reap_lane that is a real call, not the comment
kills = [m.start() for m in re.finditer(r"os\.kill\(", body)]
kill = kills[0] if kills else -1
if nt >= 0 and kill >= 0 and nt < kill:
    print("OK")
else:
    print("nt=%s kill=%s" % (nt, kill))
PY
)
ck "$NT53I" "OK" "T53i os.name == nt refuse precedes os.kill in reap_lane"

# T53j: lstart persistence + start-time identity
"$TD" --task t53j --lane stuck --exec /bin/sleep -- 60 >/dev/null 2>&1 &
WRAP53J=$!
sleep 0.8
LS53J=$(python3 - <<'PY'
import json, os, subprocess, datetime, re
root = os.environ["AGENT_SWITCHBOARD_ROOT"]
slot = json.load(open(os.path.join(root, "t53j", "slot-stuck.json")))
pid = slot["pid"]
ls = slot.get("lstart")
out = subprocess.check_output(["ps", "-o", "lstart=", "-p", str(pid)], text=True).strip()
def ts(s):
    try:
        s = re.sub(r"\s+", " ", (s or "").strip())
        return datetime.datetime.strptime(s, "%a %b %d %H:%M:%S %Y").timestamp()
    except Exception:
        return None
ok = ls is not None and ts(ls) is not None and ts(ls) == ts(out)
print("OK" if ok else "slot=%r ps=%r" % (ls, out))
PY
)
ck "$LS53J" "OK" "T53j fresh slot lstart is non-null and matches ps"
t53_wait_state t53j stuck STALLED 1 >/dev/null
python3 - <<'PY'
import json, os
p = os.path.join(os.environ["AGENT_SWITCHBOARD_ROOT"], "t53j", "slot-stuck.json")
s = json.load(open(p))
s["lstart"] = "Mon Jan  1 00:00:00 2019"
json.dump(s, open(p, "w"), indent=2)
PY
t53_confirm t53j stuck >/dev/null
CHILD53J=$(python3 -c "import json,os; print(json.load(open(os.path.join(os.environ['AGENT_SWITCHBOARD_ROOT'],'t53j','slot-stuck.json')))['pid'])")
AGENT_SWITCHBOARD_REAPER=1 AGENT_SWITCHBOARD_STALL_AFTER=1 "$SB" reap --task t53j --lane stuck >/dev/null 2>&1
RC53J=$?
ck "$RC53J" "2" "T53j doctored lstart refuses"
t53_alive "$CHILD53J" && ck ok ok "T53j process untouched on lstart mismatch" || ck dead alive "T53j process untouched on lstart mismatch"
grep -q '"event": "identity_miss"' "$AGENT_SWITCHBOARD_ROOT/t53j/events.jsonl" && ck ok ok "T53j identity_miss even though pid+prog_base match" || ck missing logged "T53j identity_miss even though pid+prog_base match"
python3 - <<'PY'
import json, os
p = os.path.join(os.environ["AGENT_SWITCHBOARD_ROOT"], "t53j", "slot-stuck.json")
s = json.load(open(p))
s.pop("lstart", None)
json.dump(s, open(p, "w"), indent=2)
PY
t53_confirm t53j stuck >/dev/null
AGENT_SWITCHBOARD_REAPER=1 AGENT_SWITCHBOARD_STALL_AFTER=1 "$SB" reap --task t53j --lane stuck >/dev/null 2>&1
RC53J2=$?
ck "$RC53J2" "2" "T53j absent lstart refuses exit 2"
grep -q '"reason": "no_lstart"' "$AGENT_SWITCHBOARD_ROOT/t53j/events.jsonl" && ck ok ok "T53j reason=no_lstart" || ck missing logged "T53j reason=no_lstart"
t53_alive "$CHILD53J" && ck ok ok "T53j process untouched on no_lstart" || ck dead alive "T53j process untouched on no_lstart"
t53_kill "$CHILD53J" "$WRAP53J"
wait "$WRAP53J" 2>/dev/null || true

# T53k: watcher never reaps; CLI reap then kills (port 17956)
AGENT_SWITCHBOARD_REAPER=1 AGENT_SWITCHBOARD_STALL_AFTER=1 "$SB" serve --port 17956 >/dev/null 2>&1 &
SRV53K=$!
sleep 1.5
HK=$(curl -s "http://127.0.0.1:17956/v1/health" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ok"))' 2>/dev/null || echo fail)
ck "$HK" "True" "T53k watcher daemon health on 17956"
"$TD" --task t53k --lane stuck --exec /bin/sleep -- 60 >/dev/null 2>&1 &
WRAP53K=$!
sleep 0.8
CHILD53K=$(python3 -c "import json,os; print(json.load(open(os.path.join(os.environ['AGENT_SWITCHBOARD_ROOT'],'t53k','slot-stuck.json')))['pid'])")
t53_wait_state t53k stuck STALLED 1 >/dev/null
t53_confirm t53k stuck >/dev/null
sleep 3.5
t53_alive "$CHILD53K" && ck ok ok "T53k worker still alive after >=3 watcher ticks" || ck dead alive "T53k worker still alive after >=3 watcher ticks"
if [ -f "$AGENT_SWITCHBOARD_ROOT/t53k/reap-confirm-stuck.json" ]; then ck ok ok "T53k confirm still present (watcher did not consume)"; else ck missing present "T53k confirm still present (watcher did not consume)"; fi
AGENT_SWITCHBOARD_REAPER=1 AGENT_SWITCHBOARD_STALL_AFTER=1 "$SB" reap --task t53k --lane stuck >/dev/null 2>&1
RC53K=$?
ck "$RC53K" "0" "T53k CLI reap then kills (exit 0)"
sleep 0.3
t53_alive "$CHILD53K" && ck alive dead "T53k CLI reap killed the worker" || ck ok ok "T53k CLI reap killed the worker"
t53_kill "$CHILD53K" "$WRAP53K"
kill "$SRV53K" 2>/dev/null
wait 2>/dev/null

echo; echo "RESULT: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
