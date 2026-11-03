#!/usr/bin/env bash
# Dispatch build operations to the target repository's configured hook.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$here/config.sh"
config=$(zf_config_file build.json) || { echo 'engine-sync: build.json not found' >&2; exit 1; }
hook=$(jq -er '.hook | select(type == "string" and length > 0)' "$config")
engine=$(jq -er '.engine | select(type == "string" and length > 0)' "$config")
export ZF_BUILD_ENGINE="$engine"
engine_versions="$AGENT_HOME/engine-versions"
engine_failed_marker() {
  [[ "$engine" =~ ^[A-Za-z0-9._-]+$ ]] && [[ -e "$engine_versions/.failed-$engine" ]]
}
engine_version_id() {
  local path="$1"
  if [[ "$path" =~ /engine-versions/([^/]+)/engine/?$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "$(basename -- "$(dirname -- "$path")")"
  fi
}
engine_version_was_live() {
  local id="$1" history="$engine_versions/.swap-history.jsonl"
  [[ -r "$history" ]] || return 1
  jq -e -s --arg id "$id" 'any(.[]; .old_id == $id or .new_id == $id)' "$history" >/dev/null 2>&1
}
if [[ "${1:-}" == --preflight ]]; then
  shift
  if [[ $# -lt 1 || $# -gt 2 || ( $# -eq 2 && -z "$2" ) ]]; then
    echo "usage: engine-sync.sh --preflight <new version dir> [intended-change list]" >&2
    exit 2
  fi
  new_version_dir=$(cd -- "$1" 2>/dev/null && pwd -P) || {
    echo "engine-sync: new version directory not found: $1" >&2
    exit 1
  }
  new_version_id="$(basename -- "$new_version_dir")"
  live_engine_dir=$(readlink -e -- "$AGENT_HOME/engine-live") || {
    echo "engine-sync: cannot resolve $AGENT_HOME/engine-live" >&2
    exit 1
  }
  live_version_dir=$(dirname -- "$live_engine_dir")
  [[ -d "$live_engine_dir" && -d "$new_version_dir/engine" ]] || {
    echo "engine-sync: preflight expects engine directories in the live and new versions" >&2
    exit 1
  }
  # Compare against the target commit each version was built from: at converge time HEAD is already the new commit.
  # A hook that knows the commit the live checkout ran can pass it in ZF_PREFLIGHT_LIVE_REF.
  build_ref() { # product_sha, else the commit in pack_sha; empty when the version has no BUILD-INFO
    local info="$1/BUILD-INFO" ref
    [[ -r "$info" ]] || return 0
    ref=$(sed -n 's/^product_sha=//p' "$info")
    [[ -n "$ref" ]] || ref=$(sed -n 's/^pack_sha=\([0-9a-f]*\):.*/\1/p' "$info")
    printf '%s' "${ref%%$'\n'*}"
  }
  live_ref=${ZF_PREFLIGHT_LIVE_REF:-$(build_ref "$live_version_dir")}
  new_ref=$(build_ref "$new_version_dir")
  [[ -n "$live_ref" ]] || { echo "engine-sync: cannot tell which target commit the live version ran; set ZF_PREFLIGHT_LIVE_REF" >&2; exit 1; }
  preflight_args=("$live_version_dir" "$new_version_dir" "$ZF_REPO_DIR" "$live_ref" "${new_ref:-HEAD}")
  [[ $# -eq 1 ]] || preflight_args+=("$2")
  if engine_version_was_live "$new_version_id"; then
    export ZF_PREFLIGHT_PREVIOUSLY_LIVE=1
    echo "engine-sync: returning to previously live engine $new_version_id; skipping resolved-config and dropped-file-refs comparisons" >&2
  fi
  exec bash "$here/publish-preflight/run.sh" "${preflight_args[@]}"
fi
if [[ "${1:-}" == --converge ]] && engine_failed_marker; then
  echo "engine-sync: skipping previously failed engine $engine"
  exit 0
fi

if [[ "${1:-}" == --converge ]]; then
  live_link="$AGENT_HOME/engine-live"
  autopi_link="${MAC_AUTOPILOT_SUPERVISOR_DIR:-$ZF_REPO_DIR/.scratch-supervisor}/autopi-live"
  old_engine_target="$(readlink -- "$live_link" 2>/dev/null || true)"
  old_engine_dir="$(readlink -e -- "$live_link" 2>/dev/null || true)"
  old_autopi_target="$(readlink -- "$autopi_link" 2>/dev/null || true)"
  hook_status=0
  "$ZF_REPO_DIR/$hook" "$@" || hook_status=$?
  new_engine_dir="$(readlink -e -- "$live_link" 2>/dev/null || true)"
  new_engine_target="$(readlink -- "$live_link" 2>/dev/null || true)"
  new_autopi_target="$(readlink -- "$autopi_link" 2>/dev/null || true)"
  if [[ -n "$old_engine_target" && -n "$old_engine_dir" && -n "$new_engine_dir" && "$old_engine_dir" != "$new_engine_dir" ]]; then
    old_engine_id="$(engine_version_id "$old_engine_dir")"
    new_engine_id="$(engine_version_id "$new_engine_dir")"
    if [[ -n "$old_engine_dir" && "$old_engine_id" != "$new_engine_id" ]]; then
      ZF_ENGINE_DIR="$new_engine_dir" ZF_REPO_DIR="$ZF_REPO_DIR" AGENT_HOME="$AGENT_HOME" \
        MAC_AUTOPILOT_ROOT="$ZF_REPO_DIR" \
        MAC_AUTOPILOT_SUPERVISOR_DIR="${MAC_AUTOPILOT_SUPERVISOR_DIR:-$ZF_REPO_DIR/.scratch-supervisor}" \
        MAC_AUTOPILOT_RUNTIME_DIR="${MAC_AUTOPILOT_RUNTIME_DIR:-${MAC_AUTOPILOT_SUPERVISOR_DIR:-$ZF_REPO_DIR/.scratch-supervisor}/autopi}" \
        bash "$new_engine_dir/mac-autopilot/engine-canary.sh" record-swap \
          "$old_engine_id" "$new_engine_id" "$old_engine_target" "$new_engine_target" \
          "$old_autopi_target" "$new_autopi_target"
    fi
  fi
  exit "$hook_status"
fi
exec "$ZF_REPO_DIR/$hook" "$@"
