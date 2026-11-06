# Incident: <short title> (<YYYY-MM-DD>)

**Sites:** <site ids>  **Severity:** <user-visible outage | degraded | latent>
**Detected by:** <check id / user report / cron>  **Duration:** <start - end, UTC>

## Summary

Two or three sentences: what broke, who noticed, what fixed it.

## Timeline (UTC)

| Time | Event |
|---|---|
| hh:mm | First signal (check output, alert, report) |
| hh:mm | Diagnosis step and what it showed |
| hh:mm | Fix applied (exact command, approval token if tier 2+) |
| hh:mm | Verified healthy (which checks) |

## Root cause

What actually happened, with the evidence (log lines, SQL output, heights).

## Fix

Exact commands, in order. Note backups taken and where they are.

## What we changed so it does not recur

- Inventory `known_issues` entry: `<id>`
- `docs/debugging/symptom-index.md` row added
- Check or threshold added/changed: `<check id>`
- Runbook updated: `<path>`

## Open follow-ups

- [ ] ...
