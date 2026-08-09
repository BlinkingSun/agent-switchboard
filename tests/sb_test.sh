#!/bin/bash
# switchboard + agent-dispatch self-test in an isolated state root.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
export AGENT_SWITCHBOARD_ROOT="$(mktemp -d)/state"
SB="$HERE/bin/switchboard"
TD="$HERE/bin/agent-dispatch"
rm -rf "$AGENT_SWITCHBOARD_ROOT"
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
# second serve on the SAME port refuses — the bound port is the mutex
$SB serve --port 17999 >/dev/null 2>&1
ck "$?" "2" "T10d second serve on same port refused"
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

echo; echo "RESULT: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
