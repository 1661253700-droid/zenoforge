# Chain the next advisor batch when one completes and tickets wait, so the advisor does not idle until the next tick.
# The held batch lock is handed over, never released: the next batch is the same process (exec) and keeps the open lock fd.

# Take the batch lock, or adopt the one the previous batch handed over (ZF_ADVISOR_BATCH_HELD_FD, checked to be this lock file).
advisor_batch_lock_acquire() {
  local fd="${ZF_ADVISOR_BATCH_HELD_FD:-}" lock_file
  unset ZF_ADVISOR_BATCH_HELD_FD
  lock_file="$(advisor_batch_lock_file)"
  if [[ "$fd" =~ ^[0-9]+$ && -e "/dev/fd/$fd" && "/dev/fd/$fd" -ef "$lock_file" ]]; then
    BATCH_LOCK_FD="$fd"
    return 0
  fi
  try_lock_nonblocking "$lock_file" BATCH_LOCK_FD
}

# Print the waiting queue ids, priority first, whose spend budget is clear. Fails when GitHub cannot be read.
advisor_batch_waiting_ids() {
  local queue n state
  queue="$(gh issue list --repo "$REPO" --limit 1000 --label "$ADVISOR_QUEUE_LABEL" --state open --json number,labels,createdAt \
    | jq -r --arg p "$ADVISOR_PRIORITY_LABEL" 'sort_by([(if (.labels | any(.name == $p)) then 0 else 1 end), .createdAt]) | .[].number')" || return 1
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    state="$(issue_spend_budget_status "$n" | cut -f1)" || continue
    [ "$state" = clear ] && printf '%s\n' "$n"
  done <<< "$queue"
  return 0
}

# End of cleanup(): exec the next batch on the held lock when the finished batch completed cleanly and tickets wait; otherwise release the lock.
# Reads the persisted result, so a browser fault, a wedge, a dry run, an empty queue or a batch that was itself chained never chains.
advisor_batch_chain_handover() {
  local result="$1" codes ids=() n
  if [ -n "$BATCH_LOCK_FD" ] && [ "${DRY_RUN:-0}" != 1 ] && [ -z "${ZF_ADVISOR_BATCH_CHAINED:-}" ] \
    && jq -e '.outcome == "completed" and .exit_code == 0' "$result" >/dev/null 2>&1 \
    && codes="$(jq -r '(.advisor_error_codes // []) | join(" ")' "$result")" \
    && ! advisor_batch_is_browser_fault "$codes" && ! advisor_batch_is_wedge_failure "$codes" \
    && agent_memory_floor_allows advisor \
    && mapfile -t ids < <(advisor_batch_waiting_ids) && [ "${#ids[@]}" -gt 0 ]; then
    echo "run-advisor-batch: chained next batch after $ADVISOR_TICK_ID waiting=${#ids[@]} chained=1" >&2
    ZF_ADVISOR_BATCH_HELD_FD="$BATCH_LOCK_FD" ZF_ADVISOR_BATCH_CHAINED=1 exec "$0" --scheduled "${ids[@]}"
  fi
  unlock_fd "$BATCH_LOCK_FD"
}
