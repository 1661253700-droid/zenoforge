#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/test-env.sh"
task_root="$test_env_root/worker-tasksmax"
fake_bin="$task_root/bin"
mkdir -p "$fake_bin"
export TASK_ROOT="$task_root" SCOPE_CALLS="$task_root/systemd-run.calls"
declare -a ALL_WORKER_PIDS=() ALL_LAUNCHER_PIDS=()

cat > "$fake_bin/systemd-run" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf '%s\n' BEGIN
  printf '%s\n' "$@"
  printf '%s\n' END
} >> "$SCOPE_CALLS"
if [[ "${SYSTEMD_RUN_STUB_FAIL:-}" == probe && " $* " == *' /usr/bin/true '* ]]; then
  exit 27
fi
if [[ "${SYSTEMD_RUN_STUB_FAIL:-}" == launch && " $* " != *' /usr/bin/true '* ]]; then
  exit 31
fi
while (($#)); do
  if [[ "$1" == -- ]]; then
    shift
    exec "$@"
  fi
  shift
done
exit 97
SH
chmod +x "$fake_bin/systemd-run"
PATH="$fake_bin:$PATH"
export PATH

cat > "$task_root/fake-worker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$WORKER_ACTUAL_PID_FILE"
sleep 60 &
printf '%s\n' "$!" > "$WORKER_CHILD_PID_FILE"
wait
SH
chmod +x "$task_root/fake-worker"

say() { printf '%s\n' "$*" >> "$task_root/scheduler.log"; }
alive() { kill -0 "$1" 2>/dev/null; }
source "$script_dir/scheduler.d/worker-scope.sh"
source "$script_dir/scheduler.d/harvest-workers.sh"

fail() { printf 'worker-tasksmax.test.sh: %s\n' "$*" >&2; exit 1; }
for launch_file in dispatch.sh evals-arbiter.sh land-lane.sh; do
  grep -Fq 'worker_scope_launch' "$script_dir/scheduler.d/$launch_file" \
    || fail "$launch_file bypasses the bounded worker launcher"
done
grep -Fq 'source "$HERE/scheduler.d/worker-scope.sh"' "$script_dir/scheduler.sh" \
  || fail 'scheduler.sh does not load the bounded worker launcher'
cleanup() {
  local i
  for ((i=0; i<${#ALL_WORKER_PIDS[@]}; i++)); do
    stuck_worker_stop "${ALL_WORKER_PIDS[i]}" 2>/dev/null || true
    wait "${ALL_LAUNCHER_PIDS[i]}" 2>/dev/null || true
  done
}
trap cleanup EXIT
reset_tick() {
  WORKER_SCOPE_PREPARED=false
  WORKER_SCOPE_WARNED=false
  WORKER_SCOPE_MODE=''
  WORKER_SCOPE_SYSTEMD_RUN=''
  WORKER_SCOPE_PID=''
  WORKER_SCOPE_LAUNCHER_PID=''
  : > "$task_root/scheduler.log"
  : > "$SCOPE_CALLS"
}
start_worker() {
  local label="$1" launcher="$2"; shift 2
  local pid_file="$task_root/$label.pid" worker_pid_file="$task_root/$label.actual.pid" child_pid_file="$task_root/$label.child.pid"
  rm -f "$pid_file" "$worker_pid_file" "$child_pid_file"
  worker_scope_launch "$pid_file" "$task_root" "$task_root/$label.log" "$launcher" -- \
    env "WORKER_ACTUAL_PID_FILE=$worker_pid_file" "WORKER_CHILD_PID_FILE=$child_pid_file" "$task_root/fake-worker"
  [[ "$WORKER_SCOPE_PID" =~ ^[1-9][0-9]*$ ]] || fail "$label did not return a worker PID: $WORKER_SCOPE_PID"
  for _ in {1..100}; do [[ -s "$child_pid_file" ]] && break; sleep 0.02; done
  [[ -s "$worker_pid_file" && -s "$child_pid_file" ]] || fail "$label worker tree did not start"
  [[ "$(cat "$worker_pid_file")" == "$WORKER_SCOPE_PID" ]] || fail "$label recorded PID is not the worker process"
  TEST_WORKER_PID="$WORKER_SCOPE_PID"
  TEST_LAUNCHER_PID="$WORKER_SCOPE_LAUNCHER_PID"
  TEST_CHILD_PID="$(cat "$child_pid_file")"
  ALL_WORKER_PIDS+=("$TEST_WORKER_PID")
  ALL_LAUNCHER_PIDS+=("$TEST_LAUNCHER_PID")
}
stop_worker() {
  local pid="$1" launcher_pid="$2" child_pid="$3" i state
  stuck_worker_stop "$pid"
  wait "$launcher_pid" 2>/dev/null || true
  for ((i=0; i<100; i++)); do
    if [[ ! -r "/proc/$child_pid/stat" ]]; then return 0; fi
    state="$(awk '{print $3}' "/proc/$child_pid/stat" 2>/dev/null || true)"
    [[ "$state" == Z ]] && return 0
    sleep 0.02
  done
  fail "kill-tree did not stop descendant $child_pid for worker $pid"
}

CFG='{"engine":{"worker_tasks_max":3456}}'
reset_tick
start_worker configured setsid
grep -Fxq 'TasksMax=3456' "$SCOPE_CALLS" || fail 'worker command was not wrapped with configured TasksMax'
grep -Fq "$task_root/fake-worker" "$SCOPE_CALLS" || fail 'systemd-run did not receive the worker command'
workers_json="$(jq -cn --argjson pid "$TEST_WORKER_PID" '{workers:[{pid:$pid}]}')"
recorded_pid="$(jq -r '.workers[0].pid' <<<"$workers_json")"
[[ "$(ps -o pgid= -p "$recorded_pid" | tr -d ' ')" == "$recorded_pid" ]] \
  || fail 'recorded worker PID is not the process-group leader used by kill-tree'
stop_worker "$recorded_pid" "$TEST_LAUNCHER_PID" "$TEST_CHILD_PID"
printf '%s\n' 'PASS configured TasksMax wraps the worker and its recorded PID kills the process tree'

CFG='{}'
reset_tick
start_worker defaulted setsid
grep -Fxq 'TasksMax=2000' "$SCOPE_CALLS" || fail 'missing config key did not use the 2000 default'
stop_worker "$TEST_WORKER_PID" "$TEST_LAUNCHER_PID" "$TEST_CHILD_PID"
[[ "$(jq -r '.engine.worker_tasks_max' "$script_dir/config.template.json")" == 2000 ]] \
  || fail 'config.template.json does not set engine.worker_tasks_max to 2000'
printf '%s\n' 'PASS worker task limit defaults to 2000'

worker_scope_systemd_run_path() { return 1; }
CFG='{"engine":{"worker_tasks_max":2000}}'
reset_tick
start_worker missing-one setsid
missing_pid_one="$TEST_WORKER_PID" missing_launcher_one="$TEST_LAUNCHER_PID" missing_child_one="$TEST_CHILD_PID"
start_worker missing-two setsid
[[ ! -s "$SCOPE_CALLS" ]] || fail 'missing systemd-run unexpectedly invoked a scope'
[[ "$(grep -c '^worker scope unavailable:' "$task_root/scheduler.log")" == 1 ]] \
  || fail 'missing systemd-run did not log exactly once for the tick'
stop_worker "$missing_pid_one" "$missing_launcher_one" "$missing_child_one"
stop_worker "$TEST_WORKER_PID" "$TEST_LAUNCHER_PID" "$TEST_CHILD_PID"
printf '%s\n' 'PASS missing systemd-run falls back unchanged and logs once per tick'

worker_scope_systemd_run_path() { type -P systemd-run; }
export SYSTEMD_RUN_STUB_FAIL=probe
reset_tick
start_worker failed setsid
[[ "$WORKER_SCOPE_MODE" == unavailable ]] || fail 'failed systemd-run probe did not disable scopes for the tick'
[[ "$(grep -c '^worker scope unavailable:' "$task_root/scheduler.log")" == 1 ]] \
  || fail 'failed systemd-run did not log one fallback line'
stop_worker "$TEST_WORKER_PID" "$TEST_LAUNCHER_PID" "$TEST_CHILD_PID"
unset SYSTEMD_RUN_STUB_FAIL
printf '%s\n' 'PASS failed systemd-run falls back unchanged'

export SYSTEMD_RUN_STUB_FAIL=launch
reset_tick
start_worker launch-failed setsid
[[ "$WORKER_SCOPE_MODE" == unavailable ]] || fail 'failed worker scope launch did not disable scopes for the tick'
[[ "$(grep -c '^worker scope unavailable:' "$task_root/scheduler.log")" == 1 ]] \
  || fail 'failed worker scope launch did not log one fallback line'
stop_worker "$TEST_WORKER_PID" "$TEST_LAUNCHER_PID" "$TEST_CHILD_PID"
unset SYSTEMD_RUN_STUB_FAIL
printf '%s\n' 'PASS failed worker scope launch falls back unchanged'

CFG='{"engine":{"worker_tasks_max":0}}'
reset_tick
start_worker disabled setsid
[[ ! -s "$SCOPE_CALLS" ]] || fail 'worker_tasks_max=0 invoked systemd-run'
[[ ! -s "$task_root/scheduler.log" ]] || fail 'disabled scopes logged an unavailable warning'
stop_worker "$TEST_WORKER_PID" "$TEST_LAUNCHER_PID" "$TEST_CHILD_PID"
printf '%s\n' 'PASS worker_tasks_max=0 disables scopes'
