# shellcheck shell=bash
# Cron job plumbing: lock, gap detection, report file.
# The hub only runs jobs while it is awake, so every job reports how long it
# has been since its previous run instead of assuming continuity.

job_interval_seconds() {
  yq -r ".jobs.\"$1\".interval_seconds // 3600" "$DEVOPS_ROOT/crons/schedules.yaml"
}

job_begin() {
  JOB_NAME="$1"
  local ldir sdir now last gap interval
  ldir="$(mkstate locks)"; sdir="$(mkstate jobs)"
  JOB_LOCK="$ldir/$JOB_NAME.lock"
  if ! mkdir "$JOB_LOCK" 2>/dev/null; then
    if [ -n "$(find "$JOB_LOCK" -maxdepth 0 -mmin +120 2>/dev/null)" ]; then
      rmdir "$JOB_LOCK" 2>/dev/null || rm -rf "$JOB_LOCK"
      mkdir "$JOB_LOCK" || die "cannot take lock $JOB_LOCK"
      warn "removed stale lock for $JOB_NAME"
    else
      info "$JOB_NAME already running; skipping"
      exit 0
    fi
  fi
  trap 'rmdir "$JOB_LOCK" 2>/dev/null || true' EXIT
  now="$(now_epoch)"
  last="$(cat "$sdir/$JOB_NAME.last" 2>/dev/null || echo 0)"
  interval="$(job_interval_seconds "$JOB_NAME")"
  JOB_GAP_NOTE=""
  if [ "$last" -gt 0 ]; then
    gap=$(( now - last ))
    if [ "$gap" -gt $(( interval * 2 )) ]; then
      JOB_GAP_NOTE="gap: previous run was $(( gap / 3600 ))h$(( (gap % 3600) / 60 ))m ago (expected every $(( interval / 60 ))m; hub asleep or offline)"
    fi
  fi
  JOB_REPORT="$(run_dir)/$JOB_NAME-$(date +%H%M).md"
  {
    echo "# $JOB_NAME $(iso_now)"
    [ -n "$JOB_GAP_NOTE" ] && echo "" && echo "> $JOB_GAP_NOTE"
    echo ""
  } > "$JOB_REPORT"
}

job_log() { printf '%s\n' "$*" >> "$JOB_REPORT"; }

job_end() {
  printf '%s\n' "$(now_epoch)" > "$DEVOPS_STATE/jobs/$JOB_NAME.last"
  info "report: $JOB_REPORT"
}
