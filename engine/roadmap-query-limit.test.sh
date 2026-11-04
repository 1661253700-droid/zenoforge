#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/roadmap.sh"
export REPO=fixture/repo

# The stub refuses any GraphQL page above 25 issues with the real shape seen in
# production: one "Resource limits for this query exceeded" errors-array entry
# per requested path (~296 lines), exactly as one gh invocation prints them.
cat > "$test_env_bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${*//$'\n'/ }" >> "$GH_LIMIT_LOG"
page=""
for a in "$@"; do
  [[ "$a" == pageSize=* ]] && page="${a#pageSize=}"
done
if [[ -z "$page" || ! "$page" =~ ^[0-9]+$ || "$page" -gt 25 ]]; then
  for _ in $(seq 1 296); do echo 'Resource limits for this query exceeded.' >&2; done
  exit 1
fi
cat "$GH_LIMIT_RESPONSE"
GH
chmod +x "$test_env_bin/gh"

jq -cn '[{data:{repository:{issues:{nodes:[
  {number:1,title:"Roadmap",state:"OPEN",labels:{nodes:[{name:"roadmap"}]},subIssues:{nodes:[{number:2}]}},
  {number:2,title:"Ready",state:"OPEN",labels:{nodes:[]},subIssues:{nodes:[]}}
]}}}}]' > "$AGENT_HOME/response.json"
export GH_LIMIT_LOG="$AGENT_HOME/gh.log"
export GH_LIMIT_RESPONSE="$AGENT_HOME/response.json"
: > "$GH_LIMIT_LOG"

cache="$AGENT_HOME/roadmap-tree.json"
snapshot="$AGENT_HOME/night/roadmap-tree.snapshot.json"

# The halving mechanism itself: an explicit bound above the limit pages down.
ZF_ROADMAP_QUERY_PAGE_SIZE=50 ZF_ROADMAP_SNAPSHOT_FILE="$snapshot" \
  roadmap_fetch_tree "$cache" "$REPO" 2> "$AGENT_HOME/fetch-1.log"
jq -e '(.roots | length) == 1 and .roots[0].number == 1' "$cache" >/dev/null
jq -e '.repo == "fixture/repo" and (.tree.roots | length) == 1' "$snapshot" >/dev/null

# The read paged down: first attempt at the configured bound, one retry at half.
[[ "$(grep -c '^api graphql' "$GH_LIMIT_LOG")" == 2 ]]
[[ "$(grep -c 'pageSize=50' "$GH_LIMIT_LOG")" == 1 ]]
[[ "$(grep -c 'pageSize=25' "$GH_LIMIT_LOG")" == 1 ]]
awk 'NR==1' "$GH_LIMIT_LOG" | grep -q 'pageSize=50$'
awk 'NR==2' "$GH_LIMIT_LOG" | grep -q 'pageSize=25$'

# One log line for the downshift, and none of gh's per-path limit spam.
[[ "$(grep -c 'Resource limits for this query exceeded' "$AGENT_HOME/fetch-1.log")" == 0 ]]
[[ "$(grep -c 'gh query resource limit' "$AGENT_HOME/fetch-1.log")" == 1 ]]
[[ "$(wc -l < "$AGENT_HOME/fetch-1.log" | tr -d ' ')" == 1 ]]

# A second loop (the tick retries the live read every admission) still logs one
# line per fetch, never the 296-line block per loop.
rm -f -- "$cache"
ZF_ROADMAP_QUERY_PAGE_SIZE=50 ZF_ROADMAP_SNAPSHOT_FILE="$snapshot" \
  roadmap_fetch_tree "$cache" "$REPO" 2> "$AGENT_HOME/fetch-2.log"
jq -e '(.roots | length) == 1' "$cache" >/dev/null
[[ "$(grep -c 'Resource limits for this query exceeded' "$AGENT_HOME/fetch-2.log")" == 0 ]]
[[ "$(wc -l < "$AGENT_HOME/fetch-2.log" | tr -d ' ')" == 1 ]]
echo 'ok - oversized roadmap page retries once at half size and logs one line, not one per path'

# The DEFAULT bound (no ZF_ROADMAP_QUERY_PAGE_SIZE) must already fit the limit:
# a default above it pays a doomed first request on every tick and falls back to
# the stale snapshot whenever the half-size retry is still over (2026-11-04:
# 50 → 25 both refused; 20 served). 1 + 261 × 20 = 5,221 possible nodes per page.
: > "$GH_LIMIT_LOG"
rm -f -- "$cache"
ZF_ROADMAP_SNAPSHOT_FILE="$snapshot" roadmap_fetch_tree "$cache" "$REPO" 2> "$AGENT_HOME/fetch-default.log"
jq -e '(.roots | length) == 1' "$cache" >/dev/null
[[ "$(grep -c '^api graphql' "$GH_LIMIT_LOG")" == 1 ]]
[[ "$(grep -c 'pageSize=20' "$GH_LIMIT_LOG")" == 1 ]]
[[ "$(wc -l < "$AGENT_HOME/fetch-default.log" | tr -d ' ')" == 0 ]]
echo 'ok - the default page size fetches in one attempt without a doomed request'

# Both attempts refused (the whole accepted band moved, as on 2026-11-03):
# exactly ONE stderr line, the snapshot untouched, the failure code kept.
cat > "$test_env_bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${*//$'\n'/ }" >> "$GH_LIMIT_LOG"
for _ in $(seq 1 296); do echo 'Resource limits for this query exceeded.' >&2; done
exit 1
GH
chmod +x "$test_env_bin/gh"
: > "$GH_LIMIT_LOG"
rm -f -- "$cache"
snapshot_before="$(jq -c . "$snapshot")"
rc=0
ZF_ROADMAP_SNAPSHOT_FILE="$snapshot" roadmap_fetch_tree "$cache" "$REPO" 2> "$AGENT_HOME/fetch-both-fail.log" || rc=$?
[[ "$rc" != 0 ]]
[[ ! -e "$cache" ]]
[[ "$(cat -- "$snapshot")" == "$snapshot_before" ]]
[[ "$(grep -c '^api graphql' "$GH_LIMIT_LOG")" == 2 ]]
[[ "$(grep -c 'pageSize=20' "$GH_LIMIT_LOG")" == 1 ]]
[[ "$(grep -c 'pageSize=10' "$GH_LIMIT_LOG")" == 1 ]]
awk 'NR==1' "$GH_LIMIT_LOG" | grep -q 'pageSize=20$'
awk 'NR==2' "$GH_LIMIT_LOG" | grep -q 'pageSize=10$'
[[ "$(grep -c 'Resource limits for this query exceeded' "$AGENT_HOME/fetch-both-fail.log")" == 0 ]]
[[ "$(grep -c 'gh query resource limit' "$AGENT_HOME/fetch-both-fail.log")" == 1 ]]
[[ "$(wc -l < "$AGENT_HOME/fetch-both-fail.log" | tr -d ' ')" == 1 ]]
grep -q 'retried once at page=10 and failed' "$AGENT_HOME/fetch-both-fail.log"
echo 'ok - both attempts over the limit log exactly one stderr line and keep the failure code'

# A different failure on the retry stays visible but bounded: the per-path
# repeats collapse to one line plus a suppressed count, never the raw block.
cat > "$test_env_bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${*//$'\n'/ }" >> "$GH_LIMIT_LOG"
page=""
for a in "$@"; do
  [[ "$a" == pageSize=* ]] && page="${a#pageSize=}"
done
if [[ -z "$page" || ! "$page" =~ ^[0-9]+$ || "$page" -gt 25 ]]; then
  for _ in $(seq 1 296); do echo 'Resource limits for this query exceeded.' >&2; done
else
  for _ in $(seq 1 296); do echo 'gh: Could not resolve to a Repository with the name unknown/repo.' >&2; done
fi
exit 1
GH
chmod +x "$test_env_bin/gh"
rc=0
ZF_ROADMAP_SNAPSHOT_FILE="$snapshot" ZF_ROADMAP_QUERY_PAGE_SIZE=50 \
  roadmap_fetch_tree "$AGENT_HOME/other-cache.json" "$REPO" 2> "$AGENT_HOME/fetch-retry-other.log" || rc=$?
[[ "$rc" != 0 ]]
grep -q 'gh query resource limit at page=50; retried once at page=25 and failed' "$AGENT_HOME/fetch-retry-other.log"
grep -q 'Could not resolve to a Repository' "$AGENT_HOME/fetch-retry-other.log"
grep -q '295 further stderr lines suppressed' "$AGENT_HOME/fetch-retry-other.log"
[[ "$(wc -l < "$AGENT_HOME/fetch-retry-other.log" | tr -d ' ')" == 3 ]]
echo 'ok - a non-limit retry failure emits its message once, not one line per path'

# The limit refusal is not a blanket stderr swallow: other gh failures still
# pass their message and exit code through.
cat > "$test_env_bin/gh" <<'GH'
#!/usr/bin/env bash
echo 'gh: Could not resolve to a Repository with the name unknown/repo.' >&2
exit 1
GH
chmod +x "$test_env_bin/gh"
if gh_bound_query_run roadmap 50 -- gh api graphql -F pageSize=__ZF_QUERY_PAGE__ \
  > "$AGENT_HOME/other-out.log" 2> "$AGENT_HOME/other-err.log"; then
  echo 'not ok - non-limit failures must keep their exit code' >&2
  exit 1
fi
grep -q 'Could not resolve to a Repository' "$AGENT_HOME/other-err.log"
[[ "$(wc -l < "$AGENT_HOME/other-err.log" | tr -d ' ')" == 1 ]]
[[ -s "$AGENT_HOME/other-err.log" && ! -s "$AGENT_HOME/other-out.log" ]]
echo 'ok - non-limit gh failures pass stderr and exit code through untouched'
