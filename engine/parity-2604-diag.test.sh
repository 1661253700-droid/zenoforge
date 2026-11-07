#!/usr/bin/env bash
# TEMPORARY ubuntu-26.04 parity diagnostics (parity-2604 branch only; remove before merge).
# Captures the host behaviour behind the three failing suites and always fails so its
# full log is kept in test-logs/ and uploaded with the shard artifact.
set -uo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"
set +e
section() { printf '\n===== %s =====\n' "$1"; }

section "os and shell"
uname -a
head -3 /etc/os-release
bash --version | head -1

section "tool versions"
for t in date timeout tr sleep head tail sort find xargs tee mktemp ps systemd-run true; do
  printf '%-12s -> %-24s | ' "$t" "$(command -v "$t" 2>/dev/null || echo MISSING)"
  "$t" --version 2>&1 | head -1
done

section "timeout exit status after -s KILL (GNU self-kills -> 137)"
timeout --verbose -s KILL 1 bash -c 'sleep 30'
echo "timeout rc=$?"

section "ps stat of a live child"
sleep 5 & live=$!
echo "live pid=$live"
echo "ps -o stat= -p          : [$(ps -o stat= -p "$live" 2>&1)]"
echo "ps --no-headers -o stat : [$(ps --no-headers -o stat -p "$live" 2>&1)]"
wait "$live"

section "cgroup and session layout"
cat /proc/self/cgroup
grep cgroup /proc/mounts
echo "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-unset} DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unset}"

section "systemd-run --user --scope probe (as worker_scope_prepare runs it)"
probe="$(type -P true 2>/dev/null || true)"; [[ -n "$probe" ]] || probe=true
echo "probe command: $probe"
systemd-run --user --scope --quiet -p "TasksMax=2000" -- "$probe"; echo "probe rc=$?"

section "scope cgroup and pids.events visibility (watch-script arithmetic)"
systemd-run --user --scope --quiet -- bash -c '
  read -r first < /proc/self/cgroup
  echo "self cgroup first line: $first"
  p="/sys/fs/cgroup${first#0::}/pids.events"
  echo "computed events path  : $p"
  ls -l "$p" 2>&1
  cat "$p" 2>&1
'; echo "scope cgroup probe rc=$?"

section "TasksMax=10 enforcement inside a user scope"
systemd-run --user --scope --quiet -p "TasksMax=10" -- bash -c '
  n=0
  while (( n < 30 )); do sleep 5 & n=$((n+1)); done 2>/dev/null
  echo "spawned=$n"
  cat "/sys/fs/cgroup$(head -1 /proc/self/cgroup | sed "s/^0:://")/pids.events" 2>&1
'
echo "enforcement rc=$?"

section "worker_scope_launch double-invocation replay (repair-resume suspect)"
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/mac-autopilot" && pwd -P)"
source "$here/scheduler.d/worker-scope.sh"
diag="$TMPDIR/scope-replay"; mkdir -p "$diag"
calls="$diag/calls"
say() { printf '[diag-say] %s\n' "$*" | tee -a "$diag/sched.log"; }
CFG='{"engine":{"worker_tasks_max":2000}}'
WORKER_SCOPE_PREPARED=false WORKER_SCOPE_MODE='' WORKER_SCOPE_WARNED=false
worker_scope_launch "$diag/pid" "$diag" "$diag/worker.out" setsid -- bash -c "printf 'ran\n' >> '$calls'"
launcher=$WORKER_SCOPE_LAUNCHER_PID
echo "mode=$WORKER_SCOPE_MODE pid=$WORKER_SCOPE_PID pid_start=${WORKER_SCOPE_PID_START:-}"
wait "$launcher" 2>/dev/null; echo "launcher rc=$?"
sleep 0.2
echo "call count: $(wc -l < "$calls" 2>/dev/null || echo 0)"
echo "-- worker.out --"; cat "$diag/worker.out" 2>/dev/null
echo "-- sched.log --"; cat "$diag/sched.log" 2>/dev/null

section "real TasksMax=30 fork-loop watch replay (worker-tasksmax suspect)"
LOG="$diag/sched2.log"
CFG='{"engine":{"worker_tasks_max":30}}'
WORKER_SCOPE_PREPARED=false WORKER_SCOPE_MODE='' WORKER_SCOPE_WARNED=false
: > "$LOG"
worker_scope_launch "$diag/real.pid" "$diag" "$diag/real.log" setsid -- \
  python3 -c 'import subprocess,sys
n=0
try:
    while n < 80:
        subprocess.Popen(["sleep", "3"]); n += 1
except OSError:
    pass
sys.exit(1 if n < 80 else 0)'
leader=$WORKER_SCOPE_PID
echo "mode=$WORKER_SCOPE_MODE leader=$leader"
echo "leader cgroup: $(cat "/proc/$leader/cgroup" 2>/dev/null || echo gone)"
for _ in {1..150}; do grep -Fq 'TasksMax=30 reached' "$diag/real.log" 2>/dev/null && break; sleep 0.1; done
echo "-- real.log --"; cat "$diag/real.log" 2>/dev/null
echo "-- sched2.log --"; cat "$LOG" 2>/dev/null
kill -KILL "$leader" 2>/dev/null; wait "$WORKER_SCOPE_LAUNCHER_PID" 2>/dev/null

printf '\n===== DIAGNOSTICS COMPLETE (intentional failure) =====\n'
exit 1
