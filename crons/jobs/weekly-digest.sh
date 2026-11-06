#!/usr/bin/env bash
# Weekly: one summary of the last 7 days (check states, hub gaps, tx log, journal).
. "$DEVOPS_ROOT/crons/jobs/_job.sh"
job_begin weekly-digest

job_log "## Current check states"
job_log ""
job_log "| Status | Check | Scope | Since |"
job_log "|---|---|---|---|"
for f in "$DEVOPS_STATE"/checks/*/*.status; do
  [ -f "$f" ] || continue
  read -r st t < "$f"
  scope="$(basename "$(dirname "$f")")"; id="$(basename "$f" .status)"
  [ "$st" = "OK" ] && continue
  job_log "| $st | $id | $scope | $(date -r "$t" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@$t" '+%Y-%m-%d %H:%M') |"
done
job_log ""
job_log "## Hub gaps (jobs that did not run on schedule)"
gaps="$(find "$DEVOPS_REPORTS/runs" -name '*.md' -mtime -7 -exec grep -h '^> gap:' {} + 2>/dev/null | sort | uniq -c | head -20)"
job_log "${gaps:-none}"
job_log ""
job_log "## Transactions"
txs="$(find "$DEVOPS_REPORTS/tx-log" -name '*.tsv' -mtime -7 -exec cat {} + 2>/dev/null)"
job_log "${txs:-none}"
job_log ""
job_log "## Journal"
jr="$(find "$DEVOPS_REPORTS/journal" -name '*.md' -mtime -7 2>/dev/null | sort)"
job_log "${jr:-none}"
nonok="$(grep -c '^| \(WARN\|CRIT\|UNKNOWN\) ' "$JOB_REPORT" || true)"
notify INFO "weekly digest" "$nonok check(s) not OK; report ${JOB_REPORT#"$DEVOPS_ROOT"/}"
job_end
