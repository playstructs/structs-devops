#!/usr/bin/env bash
# Hourly: host resources, block progression, heights, containers, endpoints,
# Postgres connections, TSA queue, sync lag, bouncer, Apache workers.
. "$DEVOPS_ROOT/crons/jobs/_job.sh"
job_begin hourly-health
rc=0
run_group hourly all || rc=$?
job_end
exit "$rc"
