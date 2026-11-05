#!/usr/bin/env bash
# A completed advisor batch with waiting tickets hands its held lock to the next batch; faults and an empty queue do not.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
export LOCK="$tmp/advisor-batch.lock" tmp script_dir

# The next batch: adopts the handed-over fd (no second acquire) and proves a fresh open of the lock still fails.
cat > "$tmp/child.sh" <<'CHILD'
#!/usr/bin/env bash
source "$script_dir/lib.d/locks.sh"
source "$script_dir/lib.d/advisor-batch-chain.sh"
advisor_batch_lock_file() { echo "$LOCK"; }
fd="$ZF_ADVISOR_BATCH_HELD_FD"
BATCH_LOCK_FD=""
advisor_batch_lock_acquire
[[ "$BATCH_LOCK_FD" == "$fd" && -z "${ZF_ADVISOR_BATCH_HELD_FD:-}" ]]
exec {probe}>"$LOCK"
if flock -n "$probe"; then held=no; else held=yes; fi
printf 'chained=%s held=%s args=%s\n' "$ZF_ADVISOR_BATCH_CHAINED" "$held" "$*" >> "$tmp/handover"
CHILD
chmod +x "$tmp/child.sh"

# handover <result-json> <queue-json> -> runs the real handover in a process whose $0 is the next batch.
handover() {
  printf '%s\n' "$1" > "$tmp/result.json"
  QUEUE="$2" bash -c '
    source "$script_dir/lib.sh"
    source "$script_dir/lib.d/advisor-batch-chain.sh"
    eval "$(sed -n "/^advisor_batch_is_wedge_failure() {/,/^}/p;/^advisor_batch_is_browser_fault() {/,/^}/p" "$script_dir/run-advisor-batch.sh")"
    gh() { printf "%s\n" "$QUEUE"; }
    issue_spend_budget_status() { [ "$1" = 7 ] && printf "over\t0\t0\n" || printf "clear\t0\t0\n"; }
    agent_memory_floor_allows() { return 0; }
    advisor_batch_lock_file() { echo "$LOCK"; }
    REPO=r ADVISOR_QUEUE_LABEL=q ADVISOR_PRIORITY_LABEL=p ADVISOR_TICK_ID=t
    BATCH_LOCK_FD=""
    try_lock_nonblocking "$LOCK" BATCH_LOCK_FD
    advisor_batch_chain_handover "$tmp/result.json"
    # Not chained: the lock was released, so a fresh open can take it.
    exec {probe}>"$LOCK"; flock -n "$probe" && echo "released" >> "$tmp/handover"
  ' "$tmp/child.sh" 2>"$tmp/err"
}

done_ok='{"outcome":"completed","exit_code":0,"advisor_error_codes":[]}'
queue='[{"number":7,"labels":[],"createdAt":"1"},{"number":5,"labels":[],"createdAt":"2"},{"number":9,"labels":[{"name":"p"}],"createdAt":"3"}]'

# finished batch + waiting tickets: chains once, priority first, over-budget #7 left to the tick, lock held across the hand-over
: > "$tmp/handover"
handover "$done_ok" "$queue"
[[ "$(cat "$tmp/handover")" == 'chained=1 held=yes args=--scheduled 9 5' ]]
grep -Fq 'chained next batch after t waiting=2 chained=1' "$tmp/err"

# browser fault, wedge, failed batch, empty queue, already chained: no chain, lock released
for case in \
  '{"outcome":"completed","exit_code":0,"advisor_error_codes":["ADVISOR_MODEL_UNVERIFIED"]}|'"$queue" \
  '{"outcome":"completed","exit_code":0,"advisor_error_codes":["ADVISOR_ANSWER_TIMEOUT"]}|'"$queue" \
  '{"outcome":"job-failed","exit_code":0,"advisor_error_codes":[]}|'"$queue" \
  "$done_ok|[]"; do
  : > "$tmp/handover"
  handover "${case%%|*}" "${case#*|}"
  [[ "$(cat "$tmp/handover")" == released ]]
done
: > "$tmp/handover"
ZF_ADVISOR_BATCH_CHAINED=1 handover "$done_ok" "$queue"
[[ "$(cat "$tmp/handover")" == released ]]

echo 'ok - advisor batch chains once on completion with waiting tickets and holds the lock across the hand-over'
