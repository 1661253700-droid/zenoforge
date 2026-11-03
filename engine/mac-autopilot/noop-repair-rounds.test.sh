#!/usr/bin/env bash
# Focused regression for accounting and routing empty repair rounds.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/noop-repair-rounds"
sup="$fixture/supervisor"
mkdir -p "$sup/autopi/alerts" "$fixture/repo"
jq '.auto_merge = false | .advisor = false | .precheck = false' \
  "$script_dir/config.template.json" > "$sup/autopi/config.json"
printf '%s\n' '{"units":[]}' > "$sup/autopi/units.json"
printf '%s\n' '{"workers":[]}' > "$sup/autopi/workers.json"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" MAC_AUTOPILOT_RUNTIME_DIR="$sup/autopi"
export REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
SCHED_LOCK_HELD=true

fail() { printf 'noop-repair-rounds.test.sh: %s\n' "$*" >&2; exit 1; }
units() { printf '%s\n' "$1" > "$UNITS"; printf '%s\n' '{"workers":[]}' > "$WORKERS"; }
field() { jq -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }
sha1=1111111111111111111111111111111111111111
sha2=2222222222222222222222222222222222222222
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Replay: implement + a real repair, followed by an empty review and a repair
# that delivered no new head. The three write-starts must spend only two rounds.
replay="$(jq -cn --arg sha1 "$sha1" --arg sha2 "$sha2" --arg at "$now" '{
  units:[{id:"pr-noop",pr:91,lane:"pr",branch:"agent/pr-noop",stage:"supervisor-review",
    reviewed_sha:$sha2,reviewed_pr_head:$sha2,
    review_findings:[
      {round:1,block:"ok",findings:[{id:"F1",severity:"P1",status:"open"}],all_findings:[{id:"F1",severity:"P1",status:"open"}]},
      {round:2,block:"ok",findings:[],all_findings:[]}
    ],
    history:[
      {stage:"write-start",work_type:"implement",at:$at},
      {stage:"review-request-changes",result:$sha1},
      {stage:"write-start",work_type:"repair",at:$at},
      {stage:"repair-delivered"},
      {stage:"review-request-changes",result:$sha2},
      {stage:"write-start",work_type:"repair",at:$at},
      {stage:"repair-delivered"},
      {stage:"repair-no-push",result:("head "+$sha2+" unchanged after repair")}
    ]
  }]
}')"
unit="$(jq -c '.units[0]' <<<"$replay")"
TICKET_ROUND_BUDGET=2
[[ "$(ticket_budget_reason "$unit")" == 'rounds 2 of 2' ]] \
  || fail "the findings-less unchanged repair must be excluded so exactly two rounds count (got: $(ticket_budget_reason "$unit"))"
TICKET_ROUND_BUDGET=3
[[ -z "$(ticket_budget_reason "$unit")" ]] \
  || fail "three write-starts with one findings-less no-op must not trip 3 of 3 (got: $(ticket_budget_reason "$unit"))"
[[ "$(repair_rounds_since_ruling "$unit")" == 1 ]] \
  || fail "the no-op repair must not consume the repair cap (got: $(repair_rounds_since_ruling "$unit"))"
mismatched_head="$(jq -c --arg sha "$sha1" '.units[0] | .history[-1].result=("head "+$sha+" unchanged after repair")' <<<"$replay")"
TICKET_ROUND_BUDGET=3
[[ "$(ticket_budget_reason "$mismatched_head")" == 'rounds 3 of 3' && "$(repair_rounds_since_ruling "$mismatched_head")" == 2 ]] \
  || fail 'a no-push event naming a different SHA must remain counted'

# The same history must requeue to a fresh rereview, not another empty repair.
units "$replay"
supervisor_requeue_unit pr-noop requeue 'fresh independent review' null
[[ "$(field pr-noop .stage)" == rereview-pending ]] \
  || fail "an unchanged head after a findings-less review must requeue to rereview-pending (got: $(field pr-noop .stage))"
[[ "$(field pr-noop .reviewed_sha)" == null && "$(field pr-noop .reviewed_pr_head)" == null ]] \
  || fail 'the fresh rereview must clear the prior reviewed-head pair'
[[ "$(field pr-noop '.history[-1].stage')" == supervisor-requeue ]] \
  || fail 'rereview requeue must keep its supervisor-requeue history entry'

# A valid no-actionable review with no intervening write is also sent directly
# to a fresh reviewer.
empty_review="$(jq -cn --arg sha "$sha1" '{units:[{id:"pr-empty",pr:93,lane:"pr",branch:"agent/pr-empty",stage:"supervisor-review",
  reviewed_sha:$sha,reviewed_pr_head:$sha,review_findings:[{round:1,block:"ok",findings:[],all_findings:[]}],
  history:[{stage:"review-request-changes",result:$sha}]}]}')"
units "$empty_review"
supervisor_requeue_unit pr-empty requeue 'fresh independent review' null
[[ "$(field pr-empty .stage)" == rereview-pending ]] \
  || fail 'a no-actionable unchanged review must requeue to rereview-pending'

# A repair that made no push also gets a fresh review, even when its triggering
# review did contain an actionable finding.
noop_with_finding="$(jq -cn --arg sha "$sha1" --arg at "$now" '{units:[{id:"pr-no-push",pr:94,lane:"pr",branch:"agent/pr-no-push",stage:"supervisor-review",
  reviewed_sha:$sha,reviewed_pr_head:$sha,
  review_findings:[{round:1,block:"ok",findings:[{id:"F1",severity:"P1",status:"open"}],all_findings:[{id:"F1",severity:"P1",status:"open"}]}],
  history:[{stage:"review-request-changes",result:$sha},{stage:"write-start",work_type:"repair",at:$at},
    {stage:"repair-delivered"},{stage:"repair-no-push",result:("head "+$sha+" unchanged after repair")}]}]}')"
noop_with_finding_unit="$(jq -c '.units[0]' <<<"$noop_with_finding")"
TICKET_ROUND_BUDGET=1
[[ "$(ticket_budget_reason "$noop_with_finding_unit")" == 'rounds 1 of 1' && "$(repair_rounds_since_ruling "$noop_with_finding_unit")" == 1 ]] \
  || fail 'a repair-no-push after an actionable finding must still count as a failed repair'
units "$noop_with_finding"
supervisor_requeue_unit pr-no-push requeue 'fresh independent review' null
[[ "$(field pr-no-push .stage)" == rereview-pending ]] \
  || fail 'a confirmed no-push repair must requeue to rereview-pending'

# A real unresolved finding and a delivered repair remain counted and return to repair.
real="$(jq -cn --arg sha1 "$sha1" --arg sha2 "$sha2" --arg at "$now" '{units:[{id:"pr-real",pr:92,lane:"pr",branch:"agent/pr-real",stage:"supervisor-review",
  reviewed_sha:$sha2,reviewed_pr_head:$sha2,
  review_findings:[
    {round:1,block:"ok",findings:[{id:"F1",severity:"P1",status:"open"}],all_findings:[{id:"F1",severity:"P1",status:"open"}]},
    {round:2,block:"ok",findings:[{id:"F1",severity:"P1",status:"open"}],all_findings:[{id:"F1",severity:"P1",status:"open"}]}
  ],
  history:[{stage:"review-request-changes",result:$sha1},{stage:"write-start",work_type:"repair",at:$at},
    {stage:"repair-delivered"},{stage:"review-request-changes",result:$sha2}]}]}')"
real_unit="$(jq -c '.units[0]' <<<"$real")"
[[ "$(repair_rounds_since_ruling "$real_unit")" == 1 ]] \
  || fail 'a real failed repair must still consume one repair round'
TICKET_ROUND_BUDGET=1
[[ "$(ticket_budget_reason "$real_unit")" == 'rounds 1 of 1' ]] \
  || fail 'a real failed repair must still consume the stop-loss budget'
units "$real"
supervisor_requeue_unit pr-real requeue 'repair the open finding' null
[[ "$(field pr-real .stage)" == repair-pending ]] \
  || fail "a real failed repair must still requeue to repair-pending (got: $(field pr-real .stage))"

node "$script_dir/../lesson-guard-schema.mjs"
printf 'noop-repair-rounds.test.sh: 3 write-starts -> 2 counted; 3-of-3 stop-loss clear; repair-cap count 1\n'
printf 'noop-repair-rounds.test.sh: 13 focused assertions passed\n'
