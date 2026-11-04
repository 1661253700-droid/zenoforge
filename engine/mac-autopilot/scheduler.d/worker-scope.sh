worker_scope_systemd_run_path() { type -P systemd-run 2>/dev/null; }

worker_scope_unavailable() { # reason; one warning for this scheduler tick
  local reason="$1"
  WORKER_SCOPE_MODE=unavailable
  if [[ "${WORKER_SCOPE_WARNED:-false}" != true ]]; then
    say "worker scope unavailable: $reason"
    WORKER_SCOPE_WARNED=true
  fi
}

worker_scope_prepare() { # config/systemd probe, cached for this scheduler tick
  local configured probe status config="${CFG:-}"
  [[ "${WORKER_SCOPE_PREPARED:-false}" == true ]] && return 0
  WORKER_SCOPE_PREPARED=true
  WORKER_SCOPE_MODE=disabled
  [[ -n "$config" ]] || config='{}'
  configured="$(jq -r '.engine.worker_tasks_max // 2000' <<<"$config" 2>/dev/null)" || configured=2000
  [[ "$configured" =~ ^[0-9]+$ ]] || configured=2000
  WORKER_TASKS_MAX="$configured"
  (( WORKER_TASKS_MAX > 0 )) || return 0
  if ! command -v setsid >/dev/null 2>&1; then
    worker_scope_unavailable 'setsid unavailable'
    return 0
  fi
  WORKER_SCOPE_SYSTEMD_RUN="$(worker_scope_systemd_run_path || true)"
  if [[ -z "$WORKER_SCOPE_SYSTEMD_RUN" ]]; then
    worker_scope_unavailable 'systemd-run unavailable'
    return 0
  fi
  probe="$(type -P true 2>/dev/null || true)"
  [[ -n "$probe" ]] || probe=true
  status=0
  "$WORKER_SCOPE_SYSTEMD_RUN" --user --scope --quiet -p "TasksMax=$WORKER_TASKS_MAX" -- "$probe" \
    >/dev/null 2>&1 || status=$?
  if (( status != 0 )); then
    worker_scope_unavailable "systemd-run --user probe failed (exit $status)"
    return 0
  fi
  WORKER_SCOPE_MODE=scope
}

worker_scope_exec() { # pid-file launcher... -- command...; executed inside the worker's output/session wrapper
  local pid_file="$1"; shift
  local -a launcher=() worker_command=()
  while (($#)) && [[ "$1" != -- ]]; do launcher+=("$1"); shift; done
  [[ "${1:-}" == -- ]] || return 2
  shift
  worker_command=("$@")
  if [[ "$WORKER_SCOPE_MODE" == scope ]]; then
    exec "$WORKER_SCOPE_SYSTEMD_RUN" --user --scope --quiet -p "TasksMax=$WORKER_TASKS_MAX" -- \
      setsid bash -c 'pid_file=$1; shift; printf "%s\n" "$$" > "$pid_file" || exit 125; exec "$@"' \
      worker-scope "$pid_file" "${worker_command[@]}"
  fi
  exec "${launcher[@]}" "${worker_command[@]}"
}

worker_scope_launch() { # pid-file workdir output-file launcher... -- command...; sets WORKER_SCOPE_PID and WORKER_SCOPE_LAUNCHER_PID
  local pid_file="$1" workdir="$2" output_file="$3" scope_client status state
  shift 3
  local -a launcher=() worker_command=()
  while (($#)) && [[ "$1" != -- ]]; do launcher+=("$1"); shift; done
  [[ "${1:-}" == -- ]] || return 2
  shift
  worker_command=("$@")
  ((${#worker_command[@]})) || return 2
  worker_scope_prepare

  if [[ "$WORKER_SCOPE_MODE" == scope ]]; then
    rm -f -- "$pid_file"
    (cd "$workdir" && worker_scope_exec "$pid_file" "${launcher[@]}" -- "${worker_command[@]}") \
      >"$output_file" 2>&1 < /dev/null &
    scope_client=$!
    WORKER_SCOPE_LAUNCHER_PID="$scope_client"
    while [[ ! -s "$pid_file" ]]; do
      state="$(ps -o stat= -p "$scope_client" 2>/dev/null | tr -d '[:space:]' || true)"
      if [[ -z "$state" || "$state" == Z* ]]; then
        status=0
        wait "$scope_client" || status=$?
        worker_scope_unavailable "systemd-run scope launch failed (exit $status)"
        rm -f -- "$pid_file"
        break
      fi
      sleep 0.02
    done
    if [[ -s "$pid_file" ]]; then
      WORKER_SCOPE_PID="$(cat "$pid_file" 2>/dev/null || true)"
      if [[ "$WORKER_SCOPE_PID" =~ ^[1-9][0-9]*$ ]]; then
        rm -f -- "$pid_file"
        return 0
      fi
      # The scoped launcher only writes this file before it execs the worker; no worker can be running without it.
      status=0
      wait "$scope_client" || status=$?
      worker_scope_unavailable "systemd-run worker PID unavailable (exit $status)"
      rm -f -- "$pid_file"
    fi
  fi

  (cd "$workdir" && exec "${launcher[@]}" "${worker_command[@]}") >"$output_file" 2>&1 < /dev/null &
  WORKER_SCOPE_PID=$!
  WORKER_SCOPE_LAUNCHER_PID="$WORKER_SCOPE_PID"
}
