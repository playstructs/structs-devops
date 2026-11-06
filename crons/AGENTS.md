# crons/

Jobs run on the hub on a schedule (`schedules.yaml`). Read `README.md` and `docs/automations.md`.

- Jobs are read-only toward hosts and the chain. They may run checks, fetch `.references`, write reports/state, and notify. They never restart, apply, recreate, vote or broadcast; those stay with a person (tiers 2–3).
- Keep jobs idempotent and safe to run twice (`job_begin` holds a lock; a second instance exits 0).
- `devops cron install` writes to `~/Library/LaunchAgents` or the user's crontab. That is a change to the user's machine: run it only when the user asks, and show `--dry-run` output first.
- Reminder-style notifications (pending votes) are deliberate; status notifications go through `notify_on_change` so they fire on change, not every run.
