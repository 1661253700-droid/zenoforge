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
ZF_ROADMAP_SNAPSHOT_FILE="$snapshot" roadmap_fetch_tree "$cache" "$REPO" 2> "$AGENT_HOME/fetch-1.log"
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
ZF_ROADMAP_SNAPSHOT_FILE="$snapshot" roadmap_fetch_tree "$cache" "$REPO" 2> "$AGENT_HOME/fetch-2.log"
jq -e '(.roots | length) == 1' "$cache" >/dev/null
[[ "$(grep -c 'Resource limits for this query exceeded' "$AGENT_HOME/fetch-2.log")" == 0 ]]
[[ "$(wc -l < "$AGENT_HOME/fetch-2.log" | tr -d ' ')" == 1 ]]
echo 'ok - oversized roadmap page retries once at half size and logs one line, not one per path'

# A page under the bound never pays the doomed first request.
: > "$GH_LIMIT_LOG"
rm -f -- "$cache"
ZF_ROADMAP_QUERY_PAGE_SIZE=25 ZF_ROADMAP_SNAPSHOT_FILE="$snapshot" \
  roadmap_fetch_tree "$cache" "$REPO" 2> "$AGENT_HOME/fetch-3.log"
jq -e '(.roots | length) == 1' "$cache" >/dev/null
[[ "$(grep -c '^api graphql' "$GH_LIMIT_LOG")" == 1 ]]
[[ "$(wc -l < "$AGENT_HOME/fetch-3.log" | tr -d ' ')" == 0 ]]
echo 'ok - a configured bound already under the limit fetches in one attempt'

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
[[ -s "$AGENT_HOME/other-err.log" && ! -s "$AGENT_HOME/other-out.log" ]]
echo 'ok - non-limit gh failures pass stderr and exit code through untouched'
