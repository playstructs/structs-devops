# shellcheck shell=bash
# Sourced by every job in crons/jobs/. Jobs are read-only towards hosts and
# the chain: they run checks, fetch .references, and notify. They never
# restart, apply, vote or broadcast.
set -uo pipefail
. "$DEVOPS_ROOT/lib/common.sh"
. "$DEVOPS_ROOT/lib/inventory.sh"
. "$DEVOPS_ROOT/lib/ssh.sh"
. "$DEVOPS_ROOT/lib/chain.sh"
. "$DEVOPS_ROOT/lib/notify.sh"
. "$DEVOPS_ROOT/lib/job.sh"

# run_group GROUP TARGET [ONLY] [SKIP] -> runs checks, logs the summary, returns worst rc
run_group() {
  local rc=0 out
  out="$(CHECKS_ONLY="${3:-}" CHECKS_SKIP="${4:-}" "$DEVOPS_ROOT/checks/run.sh" "$1" "$2" 2>&1)" || rc=$?
  job_log '```'
  job_log "$out"
  job_log '```'
  printf '%s\n' "$out"
  return "$rc"
}
