#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/test-env.sh"
ROOT="$MAC_AUTOPILOT_ENV_ROOT"
source "$script_dir/scheduler.d/worker-command.sh"

# Keep this focused on the command builder's public boundary; unrelated scheduler policy is stubbed.
jqf() { command jq "$@"; }
provider_of() { [[ "$1" == claude-* ]] && printf claude || printf codex; }
unit_field() { printf false; }
worker_rules() { :; }
fail() { printf 'worker-command.test.sh: %s\n' "$*" >&2; exit 1; }
contains_arg() { [[ " $1 " == *" $2 "* ]]; }

CFG='{"models":[["gpt-6-luna","max","fast"]]}'
CODEX_ENV_ARGS=(-c shell_environment_policy.inherit=all)
UNITS="$test_env_root/units.json"
printf '%s\n' '{"units":[{"id":"implement-1"},{"id":"review-1"}]}' > "$UNITS"
CODEX_HOME="$test_env_root/codex-home"
export CODEX_HOME
mkdir -p "$CODEX_HOME"
cat > "$CODEX_HOME/config.toml" <<'TOML'
[mcp_servers.chrome-devtools-shared]
command = "fake-chrome"

[mcp_servers.gbrain]
command = "fake-gbrain"
TOML

build_codex_command implement gpt-6-luna max implement-1 'implement prompt'
implement_args=" ${CODEX_COMMAND[*]} "
contains_arg "$implement_args" '-c mcp_servers.chrome-devtools-shared.enabled=false' \
  || fail "implement command omitted chrome MCP override: ${CODEX_COMMAND[*]}"
contains_arg "$implement_args" '-c mcp_servers.gbrain.enabled=false' \
  || fail "implement command omitted gbrain MCP override: ${CODEX_COMMAND[*]}"
contains_arg "$implement_args" '-c tool_output_token_limit=8000' \
  || fail "implement command omitted output limit: ${CODEX_COMMAND[*]}"

build_codex_command review gpt-6-luna max review-1 'review prompt'
review_args=" ${CODEX_COMMAND[*]} "
contains_arg "$review_args" '-c mcp_servers.chrome-devtools-shared.enabled=false' \
  || fail "review command omitted chrome MCP override: ${CODEX_COMMAND[*]}"
contains_arg "$review_args" '-c mcp_servers.gbrain.enabled=false' \
  || fail "review command omitted gbrain MCP override: ${CODEX_COMMAND[*]}"
[[ "$review_args" != *'tool_output_token_limit='* ]] \
  || fail "review command unexpectedly set output limit: ${CODEX_COMMAND[*]}"

eval "$(sed -n '/^CLAUDE_REVIEW_TOOLS=/p' "$script_dir/scheduler.sh")"
ENGINE_ROOT="$(cd -- "$script_dir/../.." && pwd -P)"
build_codex_command review claude-sonnet-4-5 high review-1 'Sonnet fallback review prompt'
allowed_tools=""
for ((i = 0; i < ${#CODEX_COMMAND[@]}; i++)); do
  if [[ "${CODEX_COMMAND[i]}" == --allowedTools ]]; then
    allowed_tools="${CODEX_COMMAND[i + 1]:-}"
    break
  fi
done
[[ -n "$allowed_tools" ]] || fail 'Sonnet fallback command omitted --allowedTools'
[[ "$allowed_tools" == *'Bash(node --test:*)'* ]] || fail "Sonnet fallback cannot rerun node tests: $allowed_tools"
for runner in 'Bash(pnpm:*)' 'Bash(npx vitest:*)' 'Bash(bash *.test.sh)'; do
  [[ "$allowed_tools" == *"$runner"* ]] || fail "Sonnet fallback omitted test runner $runner: $allowed_tools"
done
for push_grant in 'Bash(git push' 'Bash(git:*)' 'Bash(git *)' 'Bash(git*)'; do
  [[ "$allowed_tools" != *"$push_grant"* ]] || fail "Sonnet fallback must not be allowed to push: $allowed_tools"
done
gh_permissions=()
IFS=',' read -r -a permission_entries <<<"$allowed_tools"
for permission in "${permission_entries[@]}"; do
  case "$permission" in
    'Bash(gh pr view:*)'|'Bash(gh pr diff:*)'|'Bash(gh pr checks:*)'|'Bash(gh issue view:*)')
      gh_permissions+=("$permission")
      ;;
    Bash\(gh*) fail "Sonnet fallback has unexpected GitHub permission: $permission" ;;
  esac
done
expected_gh_permissions='Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr checks:*),Bash(gh issue view:*)'
actual_gh_permissions="$(IFS=,; printf '%s' "${gh_permissions[*]}")"
[[ "$actual_gh_permissions" == "$expected_gh_permissions" ]] \
  || fail "Sonnet fallback GitHub read permissions changed: $actual_gh_permissions"
review_prompt="${CODEX_COMMAND[2]}"
for runner in 'pnpm <script>' 'npx vitest <file>' 'node --test <file>' 'bash <file>.test.sh'; do
  [[ "$review_prompt" == *"$runner"* ]] || fail "Sonnet fallback prompt omitted test runner $runner"
done
review_command=" ${CODEX_COMMAND[*]} "
[[ "$review_command" == *' --tools Read,Grep,Glob,Bash '* ]] || fail 'Sonnet fallback tool surface changed'
[[ "$review_command" == *' --permission-mode dontAsk '* ]] || fail 'Sonnet fallback permission mode changed'

printf '%s\n' 'PASS scheduler Codex commands disable configured MCP servers and limit implement tool output'
printf '%s\n' 'PASS Sonnet fallback allows focused test runners and does not allow git push'
