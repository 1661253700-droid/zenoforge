#!/usr/bin/env bash
# Load only the guarded append sink for short-lived telemetry observers.
efficiency_metrics_load_sink() {
  local engine_dir
  engine_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  source "$engine_dir/config.sh" || return 1
  source "$engine_dir/write-guard.sh" || return 1
  agent_pipeline_write_guard 'efficiency metrics' "$AGENT_HOME" || return 1
  source "$engine_dir/lib.d/issue-state.sh" || return 1
}
efficiency_metrics_load_sink
