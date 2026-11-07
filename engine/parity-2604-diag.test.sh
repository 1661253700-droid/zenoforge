#!/usr/bin/env bash
# TEMPORARY ubuntu-26.04 parity diagnostics, round 2 (parity-2604 branch only; remove before merge).
# Round 1 showed: scoped worker runs, but worker_scope_launch reports "worker PID unavailable"
# and re-runs the worker unsafely; the TasksMax watch's stderr never reaches the worker log.
# This round captures the pid-file bytes, an execution trace of the launch, and scope stdio paths.
set -uo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"
set +e
section() { printf '\n===== %s =====\n' "$1"; }

section "R2: scope stdio inheritance"
so="$TMPDIR/sio.out"; se="$TMPDIR/sio.err"; : > "$so"; : > "$se"
systemd-run --user --scope --quiet -- bash -c 'echo OUT-LINE; echo ERR-LINE >&2' > "$so" 2> "$se"
echo "rc=$?  out=[$(cat "$so")] err=[$(cat "$se")]"

section "R2: setsid-of-group-leader behaviour inside a scope"
systemd-run --user --scope --quiet -- bash -c '
  echo "stat after scope start: $(awk "{print \$1, \$2, \$3, \$5, \$6}" /proc/self/stat)"
  echo "pgid self=$(ps -o pgid= -p $$) pid=$$"
  setsid bash -c "echo INNER-SETSID-OK pgid=$(ps -o pgid= -p $$) pid=$$" w
  echo "setsid rc=$?"
'

section "R2: manual inner-script pid-file bytes"
m="$TMPDIR/r2-manual"; mkdir -p "$m"
pf="$m/manual.pid"; rm -f "$pf" "$pf.snap" "$pf.debug"
# Same inner script as worker_scope_exec, plus an immutable debug copy of what it wrote.
systemd-run --user --scope --quiet -p "TasksMax=2000" -- \
  setsid bash -c 'pid_file=$1; st=$(</proc/$$/stat); st=(${st##*) }); printf "%s %s\n" "$$" "${st[19]}" > "$pid_file" || exit 125
        cp -- "$pid_file" "$pid_file.debug" 2>/dev/null
        setsid bash -c "echo WATCH-STDERR-LINE >&2" worker-scope-watch & shift; exec "$@"' \
  worker-scope "$pf" bash -c 'echo WORKER-STDOUT-LINE; sleep 0.3'
echo "systemd-run rc=$?"
sleep 0.5
echo "manual.pid  cat   : [$(cat "$pf" 2>/dev/null)]"
echo "manual.pid  od    :"; od -c "$pf" 2>/dev/null | head -4
echo "manual.pid.debug od   :"; od -c "$pf.debug" 2>/dev/null | head -4

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/mac-autopilot" && pwd -P)"
source "$here/scheduler.d/worker-scope.sh"

section "R2: traced worker_scope_launch (fast worker, snapshot pid file)"
d2="$TMPDIR/r2-launch"; mkdir -p "$d2"
calls2="$d2/calls"; : > "$calls2"
pf2="$d2/pid"; rm -f "$pf2" "$pf2.snap"
( for _ in {1..2000}; do [[ -s "$pf2" ]] && { cp -- "$pf2" "$pf2.snap" 2>/dev/null; break; }; sleep 0.005; done ) &
snapper=$!
say() { printf '[diag-say] %s\n' "$*" | tee -a "$d2/sched.log"; }
CFG='{"engine":{"worker_tasks_max":2000}}'
WORKER_SCOPE_PREPARED=false WORKER_SCOPE_MODE='' WORKER_SCOPE_WARNED=false
exec {xfd}>>"$d2/trace.log"
BASH_XTRACEFD=$xfd
set -x
worker_scope_launch "$pf2" "$d2" "$d2/worker.out" setsid -- bash -c "printf 'ran\n' >> '$calls2'"
rc=$?
set +x
echo "launch rc=$rc mode=$WORKER_SCOPE_MODE pid=$WORKER_SCOPE_PID start=${WORKER_SCOPE_PID_START:-}"
wait "$WORKER_SCOPE_LAUNCHER_PID" 2>/dev/null; echo "launcher rc=$?"
kill "$snapper" 2>/dev/null; wait "$snapper" 2>/dev/null
sleep 0.2
echo "call count: $(wc -l < "$calls2" 2>/dev/null || echo 0)"
echo "pid file cat : [$(cat "$pf2" 2>/dev/null)]"
echo "pid snap cat : [$(cat "$pf2.snap" 2>/dev/null)]"
echo "pid snap od  :"; od -c "$pf2.snap" 2>/dev/null | head -4
echo "-- worker.out --"; cat "$d2/worker.out" 2>/dev/null
echo "-- sched.log --"; cat "$d2/sched.log" 2>/dev/null
echo "-- trace (regex/read/ps lines) --"
grep -E "read -r WORKER_SCOPE_PID|=~|\[\[ -s|ps -o stat|worker PID unavailable|scope launch failed" "$d2/trace.log" | head -30
echo "-- trace (exec/systemd-run line) --"
grep -E "^\+ exec|systemd-run" "$d2/trace.log" | head -6
echo "-- trace tail --"; tail -12 "$d2/trace.log"

section "R2: real TasksMax=30 fork loop with watch-debug (does the watch start at all?)"
d3="$TMPDIR/r2-real"; mkdir -p "$d3"
LOG="$d3/sched2.log"; : > "$LOG"
CFG='{"engine":{"worker_tasks_max":30}}'
WORKER_SCOPE_PREPARED=false WORKER_SCOPE_MODE='' WORKER_SCOPE_WARNED=false
worker_scope_launch "$d3/real.pid" "$d3" "$d3/real.log" setsid -- \
  python3 -c 'import subprocess,sys
n=0
try:
    while n < 80:
        subprocess.Popen(["sleep", "3"]); n += 1
except OSError:
    pass
sys.exit(1 if n < 80 else 0)'
echo "mode=$WORKER_SCOPE_MODE leader=${WORKER_SCOPE_PID:-none}"
for _ in {1..150}; do grep -Fq 'TasksMax=30 reached' "$d3/real.log" 2>/dev/null && break; sleep 0.1; done
echo "-- real.log --"; cat "$d3/real.log" 2>/dev/null
echo "-- sched2.log --"; cat "$LOG" 2>/dev/null
echo "-- leader cgroup --"; cat "/proc/${WORKER_SCOPE_PID:-0}/cgroup" 2>/dev/null
for _ in {1..100}; do kill -0 "${WORKER_SCOPE_PID:-0}" 2>/dev/null || break; sleep 0.1; done
kill -KILL "${WORKER_SCOPE_PID:-0}" 2>/dev/null
wait "$WORKER_SCOPE_LAUNCHER_PID" 2>/dev/null
echo "-- scope dir listing --"; ls -la "$d3" 2>/dev/null

printf '\n===== R2 DIAGNOSTICS COMPLETE (intentional failure) =====\n'
exit 1
