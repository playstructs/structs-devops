#!/usr/bin/env bash
# Hourly: look at each pipeline's trigger ref (git ls-remote) and notify when
# it moved. Pipelines with `on_change: prepare` also prepare their stages in
# hub-local clones (commits and builds stay on the hub). Nothing is pushed,
# tagged or deployed: publishing always needs `devops pipeline publish` and
# an approval token.
. "$DEVOPS_ROOT/crons/jobs/_job.sh"
job_begin pipeline-watch

rc=0
out="$(python3 -B "$DEVOPS_ROOT/tools/pipeline/engine.py" watch 2>&1)" || rc=$?
job_log '```'
job_log "$out"
job_log '```'
printf '%s\n' "$out"

moved="$(printf '%s\n' "$out" | awk '$1 == "MOVED" {print $2}' | tr '\n' ' ')"
if [ -n "$moved" ]; then
  notify INFO "pipeline trigger moved" "run: devops pipeline status ${moved% } (report: ${JOB_REPORT#"$DEVOPS_ROOT"/})"
fi
if printf '%s\n' "$out" | grep -q '^ERROR '; then
  job_log "> some triggers could not be read (offline?)"
fi
job_end
exit "$rc"
