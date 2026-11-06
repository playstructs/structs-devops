---
name: structs-health
description: Runs and interprets Structs infrastructure health checks (host CPU/disk/RAM, block progression, height agreement, containers, endpoints, TLS expiry, Postgres, TSA queue, sync lag, PgBouncer, validator, patches drift, governance, upgrades, new releases) and writes incident reports. Use when asked whether sites are healthy, after an alert or notification, before and after any change, or when a check result needs explaining.
---

# Structs health checks

Every check is read-only (tier 0). Checks print `STATUS id scope: message`
plus detail lines and exit 0 OK, 1 WARN, 2 CRIT, 3 UNKNOWN. The catalog is
`checks/catalog.tsv`; thresholds and meanings are in
[docs/health-checks.md](../../../docs/health-checks.md).

## When to use

- "Is everything OK?", morning check, after a notification.
- Before a change (baseline) and after it (verification).
- When one check is red and you need to know what it means and what to do next.

## Decisions

| Situation | Run |
|---|---|
| Broad sweep | `devops health all` (hourly group), `devops health all daily` |
| One site | `devops health <site>` / `devops health <site> daily` |
| Chain only (no ssh) | `devops health network` and `devops health network daily` |
| One check | `devops check <id> <site>` (network checks take no site) |
| What exists | `devops checks` |
| Limit a run | `CHECKS_ONLY=tsa-queue,sync-lag devops health <guild>`, or `CHECKS_SKIP=...` |

UNKNOWN means the check could not observe (ssh failed, RPC down, bundle
stale). Treat it as "find out", not "fine". CRIT on the public node affects
every dependent site; look there first when several sites go red together.

## Procedure

1. Run the group for the scope you care about. The last line is
   `HEALTH group= target= ok= warn= crit= unknown= report=`; the report
   path holds every check's full output.
2. For each WARN/CRIT, read its detail lines, then the matching section of
   [docs/health-checks.md](../../../docs/health-checks.md).
3. Check whether it is a known issue: the site's `known_issues` in
   `inventory/sites/<site>/site.yaml` and
   [docs/debugging/symptom-index.md](../../../docs/debugging/symptom-index.md).
4. Known issue with a known fix: follow `structs-change` (tier gates apply).
   Unknown or unclear: switch to `structs-investigate` / `structs-debug`.
5. If users were affected, write an incident report from
   [templates/incident-report.md](../../../templates/incident-report.md) into
   `inventory/reports/incidents/YYYY-MM-DD-<slug>.md`, add the symptom to the symptom
   index and the site's `known_issues`.

## Commands reference

```bash
devops health all                     # hourly group, every site + network
devops health <guild> daily           # daily group for one site
devops check tsa-queue <guild>        # one check
devops check block-progress           # network-scoped check
devops checks                         # catalog: id, scope, group, applies, description
devops cron status                    # when the scheduled runs last happened
ls state/checks/<scope>/              # last output (.last) and status (.status) per check
```

Checks that compare against the host bundle (`patches-drift`, `app-toml`)
WARN with `run: devops host sync <site>` when the bundle on the host is
stale; syncing is tier 1.

## Verification

After a fix, re-run the specific check (`devops check <id> <site>`) and then
the group. A check returning to OK clears its alert state; the next
notification fires only on another change.

## Errors

| Output | Meaning |
|---|---|
| `UNKNOWN ... ssh failed` | BatchMode ssh failed: `devops doctor`; keys not loaded for launchd/cron |
| `UNKNOWN ... timed out` | check exceeded `DEVOPS_CHECK_TIMEOUT` (90 s); host overloaded or RPC hung |
| `WARN ... bundle` | host bundle older than the hub copy: `devops host sync <site>` |
| `CRIT node-health ... block age` with HTTP 200 | the "healthy stall": see `structs-debug-chain` |
| `WARN containers structs-grass unhealthy` | known on some guilds; list it in the site's `checks.ignore_unhealthy` |

## See also

- [docs/health-checks.md](../../../docs/health-checks.md), [docs/automations.md](../../../docs/automations.md)
- `structs-daily-check` (workflow), `structs-investigate`, `structs-debug`
