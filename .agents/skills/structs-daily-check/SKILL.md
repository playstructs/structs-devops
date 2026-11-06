---
name: structs-daily-check
description: Runs the daily Structs operations review (hourly and daily health groups across all sites, governance, upgrade plan, new releases, TLS) and produces a short prioritized summary. Use when asked for a morning check, a status report, "is everything OK", or before planning the day's work.
disable-model-invocation: true
---

# Daily check

## Procedure

1. `devops health all` (hourly group: hosts, containers, endpoints, nodes,
   Postgres, TSA queue, sync lag, bouncer).
2. `devops health all daily` (TLS, patches drift, secrets audit, app.toml,
   certbot, archive growth, structs.app, governance, upgrade plan, new
   releases, inventory freshness).
3. `devops gov list` and `devops upgrade status` if either daily check is not OK.
4. For each WARN/CRIT: read the detail lines and the site's `known_issues`;
   mark it known (with the known fix) or new.
5. Report to the user, most urgent first:

   | Site | Check | Status | What it means | Next step |
   |---|---|---|---|---|

   Then one line each for: pending votes (deadline), upgrade plan (height,
   ETA), new releases worth deploying, certificates under 30 days.
6. Do not fix anything in this workflow. Offer the next step
   (`structs-change`, `structs-investigate`, `structs-vote`, `structs-upgrade-prep`).
7. `devops journal add --title "daily check" "<summary and open items>"`.
