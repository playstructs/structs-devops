#!/usr/bin/env bash
# Daily: certificate expiry per name/port and the certbot renewal path.
# Read-only; certbot is never invoked (the public node's pre_hook stops Caddy).
. "$DEVOPS_ROOT/crons/jobs/_job.sh"
job_begin tls-expiry
rc=0
run_group any all "tls-expiry,certbot" || rc=$?
job_end
exit "$rc"
