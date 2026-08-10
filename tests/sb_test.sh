#!/bin/bash
# switchboard + agent-dispatch self-test in an isolated state root.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SB="${SB_BIN:-$SCRIPT_DIR/../bin/switchboard}"
TD="${TD_BIN:-$SCRIPT_DIR/../bin/agent-dispatch}"
AGENT_SWITCHBOARD_ROOT="${AGENT_SWITCHBOARD_ROOT:-$(mktemp -d)}"
export AGENT_SWITCHBOARD_ROOT
rm -rf "$AGENT_SWITCHBOARD_ROOT"
# ABSOLUTE SAFETY (B1): agent-dispatch now fires a best-effort ensure_daemon()
# before every dispatch. Disable it for the WHOLE suite so none
# of the $TD calls below ever probes/kickstarts/spawns against a real
# daemon or the live :17920 job. Individual tests that need to exercise
# ensure_daemon() itself override this per-command, never for the whole run.
export AGENT_SWITCHBOARD_ENSURE_DISABLE=1
PASS=0; FAIL=0
ck() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "PASS: $3"; else FAIL=$((FAIL+1)); echo "FAIL: $3 (got '$1' want '$2')"; fi }

# T1: normal lane completes -> DONE, wrapper exit passes through
$TD --task demo --lane ok --exec /bin/bash -- -c 'sleep 1; exit 0' >/dev/null 2>&1
ck "$?" "0" "T1a wrapper passes through exit 0"
ST=$($SB status --task demo --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print([s["state"] for s in d[0]["slots"] if s["lane"]=="ok"][0])')
ck "$ST" "DONE" "T1b completed lane derives DONE"

# T2: failing lane -> FAILED with code
$TD --task demo --lane bad --exec /bin/bash -- -c 'exit 7' >/dev/null 2>&1
ck "$?" "7" "T2a wrapper passes through exit 7"
ST=$($SB status --task demo --json | python3 -c 'import json,sys; d=json.load(sys.stdin); s=[s for s in d[0]["slots"] if s["lane"]=="bad"][0]; print(s["state"], s["exit_code"])')
ck "$ST" "FAILED 7" "T2b failing lane derives FAILED 7"

# T3: silent kill (SIGKILL wrapper+child, like a harness group-kill) -> DIED
$TD --task demo --lane dead --exec /bin/bash -- -c 'sleep 60' >/dev/null 2>&1 &
WRAP=$!
sleep 1
CHILD=$(python3 -c "import json;print(json.load(open('$AGENT_SWITCHBOARD_ROOT/demo/slot-dead.json'))['pid'])")
kill -9 "$WRAP" "$CHILD" 2>/dev/null
sleep 1
ST=$($SB status --task demo --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print([s["state"] for s in d[0]["slots"] if s["lane"]=="dead"][0])')
ck "$ST" "DIED" "T3 silently killed lane derives DIED"

# T4: wait returns promptly on a lane completing (not at timeout)
$TD --task demo --lane w1 --exec /bin/bash -- -c 'sleep 3' >/dev/null 2>&1 &
sleep 0.5
T0=$(date +%s)
$SB wait --task demo --lane w1 --timeout 30 --interval 1 >/dev/null
RC=$?
DT=$(( $(date +%s) - T0 ))
ck "$RC" "0" "T4a wait exits 0 on lane event"
[ "$DT" -le 8 ] && ck ok ok "T4b wait returned in ${DT}s (<8s, not timeout)" || ck "$DT" "<=8" "T4b wait returned promptly"
wait

# T5: wait on already-terminal lanes returns immediately
T0=$(date +%s)
$SB wait --task demo --lane ok --timeout 20 >/dev/null
RC=$?
DT=$(( $(date +%s) - T0 ))
ck "$RC" "0" "T5a wait on terminal lane exits 0"
[ "$DT" -le 2 ] && ck ok ok "T5b immediate return (${DT}s)" || ck "$DT" "<=2" "T5b immediate return"

# T6: watch-file trigger
WF="$AGENT_SWITCHBOARD_ROOT/marker.txt"
( sleep 2; echo P3 > "$WF" ) &
T0=$(date +%s)
$SB wait --task demo --watch-file "$WF" --timeout 20 --interval 1 >/dev/null
RC=$?
DT=$(( $(date +%s) - T0 ))
ck "$RC" "0" "T6a wait exits 0 on file change"
[ "$DT" -le 6 ] && ck ok ok "T6b file trigger in ${DT}s" || ck "$DT" "<=6" "T6b file trigger prompt"
wait

# T7: capacity refusal
$TD --task demo --lane cap1 --exec /bin/bash -- -c 'sleep 15' >/dev/null 2>&1 &
sleep 0.5
$TD --task demo --lane cap2 --max 1 --exec /bin/bash -- -c 'true' >/dev/null 2>&1
ck "$?" "2" "T7 second dispatch refused at --max 1 (exit 2)"

# T8: same-lane active refusal without --replace
$TD --task demo --lane cap1 --exec /bin/bash -- -c 'true' >/dev/null 2>&1
ck "$?" "2" "T8 active same-lane dispatch refused (exit 2)"

# T9: timeout path exits 3
$SB wait --task demo --lane cap1 --timeout 3 --interval 1 >/dev/null
ck "$?" "3" "T9 wait timeout exits 3"

# T10: daemon smoke test on a test port
$SB serve --port 17999 >/dev/null 2>&1 &
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
# duplicate now exits 0 (healthy peer already serving — updated from
# the old exit-2 semantics; the bound port is still the real mutex, only the
# duplicate's own exit code changed so KeepAlive.SuccessfulExit=false can't
# thrash on it; keep intentional exit-0 down).
$SB serve --port 17999 >/dev/null 2>&1
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
ST=$($SB status --task demo --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print([s["state"] for s in d[0]["slots"] if s["lane"]=="fin"][0])')
ck "$ST" "RUNNING" "T11a child-dead+wrapper-alive is RUNNING not DIED"
kill -9 "$FAKEW" 2>/dev/null; sleep 0.3
ST=$($SB status --task demo --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print([s["state"] for s in d[0]["slots"] if s["lane"]=="fin"][0])')
ck "$ST" "DIED" "T11b both gone is DIED"

# T12: stale wrapper must NOT clobber a newer slot (finding #2, run_id guard)
$TD --task demo --lane clob --exec /bin/bash -- -c 'sleep 2' >/dev/null 2>&1 &
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
( $TD --task t13 --lane p1 --max 1 --exec /bin/bash -- -c 'sleep 2' >/dev/null 2>&1; echo $? > "$AGENT_SWITCHBOARD_ROOT/t13-rc1" ) &
( $TD --task t13 --lane p2 --max 1 --exec /bin/bash -- -c 'sleep 2' >/dev/null 2>&1; echo $? > "$AGENT_SWITCHBOARD_ROOT/t13-rc2" ) &
wait
RCS=$(sort "$AGENT_SWITCHBOARD_ROOT/t13-rc1" "$AGENT_SWITCHBOARD_ROOT/t13-rc2" | tr '\n' ' ' | xargs)
ck "$RCS" "0 2" "T13 parallel capacity race: exactly one refused"

# T14: corrupt slot surfaces as CORRUPT and blocks capacity (finding #8)
mkdir -p "$AGENT_SWITCHBOARD_ROOT/t14/history"
echo 'garbage{' > "$AGENT_SWITCHBOARD_ROOT/t14/slot-broken.json"
ST=$($SB status --task t14 --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["slots"][0]["state"])')
ck "$ST" "CORRUPT" "T14a corrupt slot visible as CORRUPT"
$TD --task t14 --lane fresh --max 1 --exec /bin/bash -- -c 'true' >/dev/null 2>&1
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
ST=$($SB status --task t16 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["slots"][0]["state"])')
ck "$ST" "ORPHAN" "T16a crafted slot derives ORPHAN"
$SB wait --task t16 --timeout 3 --interval 1 >/dev/null
ck "$?" "3" "T16b wait on ORPHAN-only blocks to timeout (no no-op spin)"
kill -9 "$OW" 2>/dev/null

# T15: task name sanitization (finding #7)
$TD --task '../evil' --lane x --exec /bin/bash -- -c 'true' >/dev/null 2>&1
ck "$?" "2" "T15a dispatch rejects path-escape task name"
$SB status --task '../evil' >/dev/null 2>&1
ck "$?" "2" "T15b status rejects path-escape task name"

# ---- Daemon race + memory hardening ----

# T17: first-sight publish — a brand-new lane must be observable via
# /v1/wait immediately (old=None -> to=state), not only on its next real
# state transition (first-sight publish on the wait bus).
$SB serve --port 17998 >/dev/null 2>&1 &
SRVA=$!
sleep 1.5
CUR=$(curl -s "http://127.0.0.1:17998/v1/health" | python3 -c 'import json,sys; print(json.load(sys.stdin)["cursor"])')
$TD --task t17 --lane fs --exec /bin/bash -- -c 'sleep 5' >/dev/null 2>&1 &
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
# replaced and never unlinked — no visibility gap).
$TD --task t20 --lane swap --exec /bin/bash -- -c 'true' >/dev/null 2>&1
: > "$AGENT_SWITCHBOARD_ROOT/t20-poll.log"
( for i in $(seq 1 60); do
    N=$(curl -s "http://127.0.0.1:17998/v1/status?task=t20" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len([s for s in d[0]["slots"] if s["lane"]=="swap"]))')
    echo "$N" >> "$AGENT_SWITCHBOARD_ROOT/t20-poll.log"
    sleep 0.02
  done ) &
POLLER=$!
sleep 0.1
$TD --task t20 --lane swap --exec /bin/bash -- -c 'sleep 1' >/dev/null 2>&1
wait "$POLLER" 2>/dev/null
MISSING=$(grep -c '^0$' "$AGENT_SWITCHBOARD_ROOT/t20-poll.log" || true)
ck "${MISSING:-0}" "0" "T20 /v1/status never drops the lane during re-dispatch swap"

kill "$SRVA" 2>/dev/null
wait 2>/dev/null

# T21: boot_id in /v1/health + /v1/wait, changes across a restart; a stale
# cursor that predates the trimmed ring gets gap:true and cursor:now.
AGENT_SWITCHBOARD_BUS_MAXLEN=5 $SB serve --port 17997 >/dev/null 2>&1 &
SRVB=$!
sleep 1.5
BOOT1=$(curl -s "http://127.0.0.1:17997/v1/health" | python3 -c 'import json,sys; print(json.load(sys.stdin)["boot_id"])')
ck "${#BOOT1}" "32" "T21a boot_id present in /v1/health (32-char hex)"

for i in 1 2 3 4 5 6 7 8; do
  $TD --task t21 --lane "churn$i" --exec /bin/bash -- -c 'true' >/dev/null 2>&1
done
sleep 1.5   # >= one watcher tick: 8 first-sight publishes overflow the 5-slot ring

WAIT_JSON=$(curl -s "http://127.0.0.1:17997/v1/wait?task=t21&cursor=0&timeout=3")
GAP=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get("gap", False), d["cursor"]>0)' "$WAIT_JSON")
ck "$GAP" "True True" "T21b stale cursor past the ring floor gets gap:true, cursor:now"
# Every /v1/wait reply must carry boot_id matching /v1/health.
WBOOT=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("boot_id",""))' "$WAIT_JSON")
ck "$WBOOT" "$BOOT1" "T21d /v1/wait reply boot_id matches /v1/health"

kill "$SRVB" 2>/dev/null
wait 2>/dev/null
sleep 0.3
AGENT_SWITCHBOARD_BUS_MAXLEN=5 $SB serve --port 17997 >/dev/null 2>&1 &
SRVB2=$!
sleep 1.5
BOOT2=$(curl -s "http://127.0.0.1:17997/v1/health" | python3 -c 'import json,sys; print(json.load(sys.stdin)["boot_id"])')
if [ "$BOOT1" != "$BOOT2" ]; then ck ok ok "T21c boot_id changes across a daemon restart"; else ck "$BOOT1" "!=$BOOT2" "T21c boot_id changes across restart"; fi
kill "$SRVB2" 2>/dev/null
wait 2>/dev/null

# T22: cold-archive moves long-finished slots to history/ on a watcher pass;
# status/watcher exclude them afterward (viewer's own 30-min retention is
# a separate, presentation-only concern and is unaffected by this).
AGENT_SWITCHBOARD_COLD_AFTER=1 $SB serve --port 17996 >/dev/null 2>&1 &
SRVC=$!
sleep 1.5
$TD --task t22 --lane cold --exec /bin/bash -- -c 'true' >/dev/null 2>&1
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

# T23: synthetic-snap forest attach (unit fixtures) — no live ps.
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
        "--task mytask --lane worker-1 --report /tmp/r.md -- "
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
assert_true(kids[0]["label"] == "mytask/worker-1", "i: agent_dispatch label task/lane")
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
$SB serve --port 17985 >/tmp/sb-b2-serve-17985.log 2>&1 &
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
if not (isinstance(c.get("claude"), dict) and isinstance(c.get("grok"), dict)):
    ok=False; msgs.append("counts not nested interactive/headless")
else:
    for k in ("claude","grok"):
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
    if n.get("kind") not in ("claude","grok","agent_dispatch"):
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
AGENT_SWITCHBOARD_ROOT="$IDLE_ROOT" AGENT_SWITCHBOARD_IDLE_GRACE=2 AGENT_SWITCHBOARD_IDLE_TEST_FORCE=1 $SB serve --port 17975 >/tmp/sb-t25.log 2>&1 &
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
AGENT_SWITCHBOARD_ROOT="$IDLE_ROOT" AGENT_SWITCHBOARD_IDLE_GRACE=2 AGENT_SWITCHBOARD_IDLE_TEST_FORCE=1 AGENT_SWITCHBOARD_IDLE_DISABLE=1 $SB serve --port 17975 >/tmp/sb-t25c.log 2>&1 &
SRV25B=$!
sleep 5
if kill -0 "$SRV25B" 2>/dev/null; then ck ok ok "T25c AGENT_SWITCHBOARD_IDLE_DISABLE=1 keeps daemon up past grace+2s"; else ck exited running "T25c AGENT_SWITCHBOARD_IDLE_DISABLE=1 keeps daemon up past grace+2s"; fi
kill "$SRV25B" 2>/dev/null
wait 2>/dev/null

# T26: an ACTIVE slot (RUNNING) in ANY task blocks idle-exit even with
# AGENT_SWITCHBOARD_IDLE_TEST_FORCE=1 — the active-slot OR-term of the busy
# predicate is never masked by the test force hook.
# Same isolated root, plus a fresh task so no other test's slot is involved.
AGENT_SWITCHBOARD_ROOT="$IDLE_ROOT" AGENT_SWITCHBOARD_IDLE_GRACE=2 AGENT_SWITCHBOARD_IDLE_TEST_FORCE=1 $SB serve --port 17976 >/tmp/sb-t26.log 2>&1 &
SRV26=$!
sleep 1.5
AGENT_SWITCHBOARD_ROOT="$IDLE_ROOT" $TD --task t26 --lane busy --exec /bin/bash -- -c 'sleep 8' >/dev/null 2>&1 &
sleep 6
if kill -0 "$SRV26" 2>/dev/null; then ck ok ok "T26a daemon stays up with an ACTIVE slot present (past grace+2s)"; else ck exited running "T26a daemon stays up with an ACTIVE slot present"; fi
BR=$(curl -s --max-time 2 "http://127.0.0.1:17976/v1/health" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("slots" in d.get("busy_reasons",[]))' 2>/dev/null)
ck "$BR" "True" "T26b busy_reasons includes slots (T6 /v1/health nice-to-have)"
kill "$SRV26" 2>/dev/null
wait 2>/dev/null

# T27: two serves on the SAME scratch port — the second sees a healthy peer
# and exits 0 immediately; the first is untouched and keeps serving
# (distinct from T10d, which covers the same contract on b4's port).
$SB serve --port 17977 >/tmp/sb-t27.log 2>&1 &
SRV27=$!
sleep 1.5
H1=$(curl -s --max-time 2 "http://127.0.0.1:17977/v1/health" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ok"])' 2>/dev/null)
ck "$H1" "True" "T27a first daemon on 17977 healthy"
$SB serve --port 17977 >/tmp/sb-t27-dup.log 2>&1
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
$SB serve --port 17978 >/tmp/sb-t28.log 2>&1 &
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
AGENT_SWITCHBOARD_WAIT_CAP=2 $SB serve --port 17979 >/tmp/sb-t29.log 2>&1 &
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

# ---- Gap-closure tests (same-tick double publish, empty-snap
# hardening). Ports 17965-17969 for anything new; reuse owned ranges where
# the gap belongs to that lane's surface. ----

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
# agent_dispatch node under a live dispatched worker.
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
  AGENT_SWITCHBOARD_CLI_CACHE_TTL=0.5 $SB serve --port 17985 >/tmp/sb-t31-serve.log 2>&1 &
  SRV31=$!
  sleep 1.5
  $TD --task t31 --lane forest --exec "$T31_BIN/grok" -- 25 >/dev/null 2>&1 &
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
# reports ps_unavailable (fail-closed when process enumeration fails). Driven via
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
# probe fails; second serve must exit 1 with actionable path.
# Port 17965 (new range).
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

echo; echo "RESULT: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
