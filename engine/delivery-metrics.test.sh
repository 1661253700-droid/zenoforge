#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
trap 'rm -rf -- "$test_env_root"' EXIT
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/delivery-metrics.sh"
fail() { echo "not ok - $*" >&2; exit 1; }
check() { jq -es "$1" "$metrics" >/dev/null || fail "$2"; echo "ok - $2"; }
ticket=00000000000000000001
base="$(printf '%040d' 1)" head="$(printf '%040d' 2)"
request="$test_env_root/request.json"
jq -n --arg ticket "$ticket" --arg base "$base" --arg head "$head" \
  '{ticket:$ticket,owner:"hand-123",owned_issues:"123,456",base_sha:$base,head_sha:$head,
    state:"queued",enqueued_epoch:1700000000,reason:"PRIVATE_SENTINEL",report:"PRIVATE_SENTINEL"}' > "$request"
metrics="$AGENT_HOME/metrics/efficiency-2023-11.jsonl"
delivery_metrics_observe land-enqueued "$request"
delivery_metrics_observe land-enqueued "$request"
check 'length == 2 and (unique_by(.event_id)|length) == 1' 'duplicate enqueue has one analytical identity'
# The bounded observer needs only the sink, not full lib initialization.
light="$test_env_root/light-engine"
mkdir -p "$light/lib.d" "$test_env_root/light-agent"
cp "$SCRIPT_DIR"/{delivery-metrics.sh,config.sh,write-guard.sh} "$light/"
cp "$SCRIPT_DIR/lib.d/issue-state.sh" "$light/lib.d/"
printf 'exit 99\n' > "$light/lib.sh"
AGENT_HOME="$test_env_root/light-agent" bash "$light/delivery-metrics.sh" land-enqueued "$request" || fail 'observer unnecessarily initialized full library'
jq -e '.event_type == "land-enqueued"' "$test_env_root/light-agent/metrics/efficiency-2023-11.jsonl" >/dev/null || fail 'light observer did not append'
if AGENT_HOME="${test_env_root}-outside" bash "$light/delivery-metrics.sh" land-enqueued "$request" 2>/dev/null; then
  fail 'light observer bypassed the test write guard'
fi
[[ ! -e "${test_env_root}-outside" ]] || fail 'light observer wrote outside the isolated root'
echo 'ok - bounded observer uses guarded metrics sink without full library initialization'
queue_refresh_health_summary() { :; }
eval "$(sed -n '/^queue_update_request() {/,/^}/p' "$SCRIPT_DIR/land-queue.sh")"
queue_update_request "$request" running '' '' '' '' 1700000001
queue_update_request "$request" failed '' '' '' '' 1700000002
first_attempt="$(jq -r '.metrics_attempt_id' "$request")"
[[ "$first_attempt" =~ ^[0-9a-f-]{36}:[0-9]+:[0-9]+$ ]] || fail 'captured actual land writer identity'
[[ "$first_attempt" == *":$BASHPID:"* ]] || fail 'identity names actual writer, not command-substitution child'
queue_update_request "$request" landed '' "$head" '' '' 1700000003
check '[.[]|select(.event_type=="land-terminal" or .event_type=="source-landed")]|length==2 and all(.attempt_id != null)' 'terminal and source events follow durable request'

metrics="$AGENT_HOME/metrics/efficiency-$(date -u +%Y-%m).jsonl"
# Repeated supported direct-land publication keeps one source event identity.
QUEUE_DIR="$test_env_root/direct-queue" REQUEST_DIR="$test_env_root/direct-queue/requests"
mkdir -p "$REQUEST_DIR"
jq '.direct_landing=true | .base_sha=.base_sha | .state="direct-pending-push" |
  .lander_pid=123 | .lander_start_ticks=456 | del(.metrics_attempt_id)' "$request" > "$REQUEST_DIR/$ticket.json"
queue_report_status() { :; }
queue_conclude_landed() { :; }
eval "$(sed -n '/^queue_direct_landed() {/,/^}/p' "$SCRIPT_DIR/land-queue.sh")"
queue_direct_landed "$ticket" "$base" "$head"
queue_direct_landed "$ticket" "$base" "$head"
check '[.[]|select(.entry_kind=="direct")]|length==2 and (unique_by(.event_id)|length)==1 and all(.attempt_id=="00000000000000000001:direct:123:456")' 'direct recovery republication deduplicates captured owner attempt'

# Run the actual enqueue setup/rollback with only external setup dependencies
# stubbed. No real worktree lock, policy process or systemd unit is started.
(
  eval "$(sed -n '/^queue_enqueue() {/,/^}/p' "$SCRIPT_DIR/land-queue.sh")"
  fixture_repo="$test_env_root/enqueue-repo" fixture_head="$head"
  mkdir -p "$fixture_repo"
  git() {
    shift 2
    case "$*" in
      'rev-parse --show-toplevel') printf '%s\n' "$fixture_repo" ;;
      'branch --show-current') echo fixture-topic ;;
      'status --porcelain=v1 --untracked-files=all') : ;;
      'rev-parse --verify HEAD^{commit}') printf '%s\n' "$fixture_head" ;;
      'show -s --format=%s '*) echo '[skip ci] fixture' ;;
      'show -s --format=%B '*) printf '[skip ci] fixture\n\nPlan-Package: fixture\n' ;;
      *) return 1 ;;
    esac
  }
  node() { [[ "$*" == 'scripts/branch-delivery-policy.mjs --check-direct-main-lane' ]]; }
  queue_owner_issue_ids() { echo 123; }
  queue_hand_owner_resume_metadata() { echo null; }
  queue_worktree_state() { reached=worktree; [[ "$phase" != worktree ]] || return 1; : > "$QUEUE_DIR/worktree-lock"; }
  queue_unlock_worktree() { rm -f "$QUEUE_DIR/worktree-lock"; }
  queue_report_status() { reached=report; printf 'partial setup\n' >> "$1"; [[ "$phase" != report ]]; }
  queue_start_unit() { started=1; return 1; }
  mktemp() {
    if [[ "$1" == *.backup.XXXXXX ]]; then
      : > "$QUEUE_DIR/backup-reached"
      [[ "$phase" != backup ]] || return 1
    fi
    command mktemp "$@"
  }
  for phase in worktree backup report launch; do
    QUEUE_DIR="$test_env_root/enqueue-$phase" REQUEST_DIR="$test_env_root/enqueue-$phase/requests"
    report="$test_env_root/enqueue-$phase.report"
    printf 'original report\n' > "$report"
    cp "$report" "$report.original"
    before="$(wc -l < "$metrics")" started=0 reached=''
    if queue_enqueue "$fixture_repo" hand-123 "$report" > "$test_env_root/enqueue-out" 2> "$test_env_root/enqueue-err"; then
      fail "enqueue $phase should fail"
    fi
    cmp -s "$report" "$report.original" || fail "$phase rollback changed report"
    [[ ! -e "$QUEUE_DIR/worktree-lock" ]] || fail "$phase rollback kept setup lock"
    [[ -n "$reached" && -e "$QUEUE_DIR/next" ]] || fail "$phase never reached actual post-persistence setup"
    [[ "$phase" != backup || -e "$QUEUE_DIR/backup-reached" ]] || fail 'backup failure injection not reached'
    [[ "$phase" != report || "$reached" == report ]] || fail 'report failure injection not reached'
    if [[ "$phase" == launch ]]; then
      [[ "$started" == 1 ]] || fail 'launch fixture did not reach startup'
      jq -e '.state=="cancelled"' "$REQUEST_DIR/00000000000000000001.json" >/dev/null || fail 'startup cancellation not retained'
      tail -n 2 "$metrics" | jq -es 'map(.event_type)==["land-enqueued","land-terminal"] and .[1].state=="cancelled"' >/dev/null || fail 'startup failure lost paired events'
      [[ "$(wc -l < "$metrics")" == "$((before+2))" ]] || fail 'startup event count'
    else
      [[ "$started" == 0 && ! -e "$REQUEST_DIR/00000000000000000001.json" ]] || fail "$phase did not delete unaccepted request before startup"
      [[ "$(wc -l < "$metrics")" == "$before" ]] || fail "$phase emitted phantom enqueue"
    fi
    echo "ok - actual enqueue $phase rollback preserves truthful ledger"
  done
)
