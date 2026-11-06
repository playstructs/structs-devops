# reports/

| Path | Tracked | What |
|---|---|---|
| `incidents/` | yes | One file per incident from the framework's `templates/incident-report.md`: `YYYY-MM-DD-<slug>.md` |
| `journal/` | yes | Session hand-offs (`devops journal add`); newest file is read at session start |
| `<topic>-<date>/` | yes | Reviews and investigations worth keeping (e.g. `postgres-efficiency-2026-11-03/`) |
| `runs/` | no | Check, job, deploy and debug run reports |
| `tx-log/` | no | One TSV line per broadcast transaction |
| `audit.log` | no | Approvals, tier-1+ actions, bundle pushes |

- Never paste secret values, raw `.env` contents or full `docker inspect` output here. Quote pointers and states.
- Incidents: what happened, timeline (UTC), impact, root cause, fix, follow-ups; add the symptom to the site's `known_issues`. If the symptom can happen to any operator, also add it (without site names) to the framework's `docs/debugging/symptom-index.md`.
