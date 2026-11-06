# crons/

Scheduled jobs that run on the hub. Overview and rationale: `docs/automations.md`.

```bash
devops cron list                 # jobs, installed?, last run
devops cron run hourly-health    # run one now
devops cron install --dry-run    # print the launchd plists / crontab lines
devops cron install              # all jobs (tier 1, hub only)
devops cron install hourly-health gov-watch
devops cron status               # adds OVERDUE flags and macOS privacy warnings
devops cron logs hourly-health
devops cron uninstall
```

- `schedules.yaml` is the source of truth (interval, launchd calendar, crontab line, script).
- `jobs/*.sh` source `jobs/_job.sh`: lock (one instance per job), gap detection, a report in `inventory/reports/runs/<date>/`, then `job_end` records the run time.
- Logs: `state/logs/cron-<job>.log`. Job state: `state/jobs/`, `state/gov/`, `state/upgrade/`.

## macOS privacy

launchd agents run `/bin/bash` without your terminal's permissions. If the
workspace lives under `~/Documents`, `~/Desktop` or `~/Downloads`, macOS blocks
those reads ("Operation not permitted") until you either:

1. grant **Full Disk Access** to `/bin/bash` (System Settings → Privacy & Security → Full Disk Access → `+`, then Cmd-Shift-G `/bin/bash`), or
2. move the workspace somewhere unprotected, for example `~/structs-devops`, and re-run `devops cron install`.

`devops cron status` warns when the workspace is in a protected folder.

## Sleep and wake

launchd runs a missed calendar job once when the Mac wakes; interval jobs just
resume. Either way the report says how long the gap was. `caffeinate -s` or an
always-on Linux hub (`devops cron install --crontab`) avoids gaps.

## Adding a job

1. `jobs/<name>.sh`: source `_job.sh`, `job_begin <name>`, do read-only work (`run_group`, `job_log`, `notify`), `job_end`, exit with the worst status.
2. Add it to `schedules.yaml` with `interval_seconds`, `launchd` and `cron`.
3. `devops cron run <name>`, then `devops cron install <name>`.
