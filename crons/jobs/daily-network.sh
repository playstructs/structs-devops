#!/usr/bin/env bash
# Daily: the daily check group, minus checks that have their own jobs
# (tls-expiry/certbot, new-releases, gov-pending, upgrade-plan).
. "$DEVOPS_ROOT/crons/jobs/_job.sh"
job_begin daily-network
rc=0
run_group daily all "" "tls-expiry,certbot,new-releases,gov-pending,upgrade-plan" || rc=$?
job_end
exit "$rc"
