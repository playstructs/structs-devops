---
name: structs-debug
description: Triage method and router for debugging Structs infrastructure. Maps a symptom to the right path (web, database, chain, indexer and GRASS, TSA signer, OIDC) and the specialist skill, and sets the read-only-first rules. Use when something on a Structs site is broken, slow, stale, or erroring and you do not yet know which component is at fault.
---

# Debugging Structs: triage and routing

Every problem sits on one of five data paths. Find the path, test it hop by
hop from the outside in, and stop at the first hop that fails. The hop map,
with containers, ports, roles and DSNs, is
[docs/debugging/data-flows.md](../../../docs/debugging/data-flows.md).

## When to use

- A user report ("site is slow", "my action never landed", "balances are
  wrong", "chat login fails") and you do not know the component yet.
- A red check whose cause is not obvious from its detail lines.
- Before restarting anything on a site that is misbehaving.

## Rules (all debugging skills)

1. **Read only first.** Every `devops debug` tool is tier 0. SQL sessions are
   forced read-only with a statement timeout.
2. **Snapshot before restarting.** A restart clears `pg_stat_activity`,
   resets restart counters and rotates logs:
   `devops debug snapshot <site>`.
3. **`EXPLAIN ANALYZE` executes the statement**: plain SELECT/WITH only
   (`devops debug pg <site> explain` enforces it).
4. **Admin SQL over the container socket**, never through PgBouncer
   (`devops debug pg` does this for you).
5. **Any write needs approval and a backup.** Save the affected rows to
   `reports/` first (the `devops debug pg … sql` output is saved
   automatically), then go through the tier gate.
6. **Public node first.** Guilds index from it. If several sites go red at
   once, start with the public node (`devops check endpoints <public-node>`)
   and the network checks (`devops health network`).

## Decisions

| Symptom | Path | Skill |
|---|---|---|
| Timeouts, 5xx, slow pages, cache, Caddy/nginx/Apache, structs.app, OIDC or Matrix login | web, identity | `structs-debug-http` |
| DB CPU, slow queries, connection or pool errors, locks, migrations, pg_cron | database | `structs-debug-postgres` |
| Height frozen, consensus errors, upgrade loop, peers, gRPC, tx hangs | chain | `structs-debug-chain` |
| Stale data, sync lag, wrong balances, no realtime updates, crawler | indexer, GRASS | `structs-debug-indexer` |
| Actions never land, queue not draining, no join accounts, sequence errors | signer | `structs-debug-tsa` |

Not sure? Look the symptom up in
[docs/debugging/symptom-index.md](../../../docs/debugging/symptom-index.md)
and the site's `known_issues` in `inventory/sites/<site>/site.yaml`.

## Procedure

1. **Scope.** Which sites, since when, all users or some? Run
   `devops health <site>` (or `devops health all`) for the current picture.
2. **Evidence.** `devops debug snapshot <site>` before touching anything.
   Read its `README.md`: restarts, unhealthy containers, OOM kills.
3. **Route.** Pick the path from the table above and open that skill.
4. **Bisect.** Use the hop tests in the skill; the first failing hop is the
   component. Match its logs against the skill's signatures.
5. **Fix.** Known fix: follow it through `structs-change` (tier gates apply).
   Unknown: stop, write down what you found, and ask.
6. **Write up.** Journal entry (`devops journal add --site <site>`). If users
   were affected, an incident report from
   [templates/incident-report.md](../../../templates/incident-report.md), plus
   a new row in the symptom index and the site's `known_issues`.

## Commands reference

```bash
devops debug help                          # every debug tool
devops debug snapshot <guild>              # evidence bundle -> reports/runs/<date>/debug/
devops debug http-trace <guild> /api/block # web path, hop by hop
devops debug pg <guild> list               # SQL packs
devops debug compare-nodes                 # header hashes across every node
devops debug grass-tap <guild>       # realtime events through NATS
devops debug oidc-probe <guild>            # webapp <-> MAS
devops logs <guild> structs-tsa 300        # one service's recent log
devops ps <guild>                          # compose state on every stack
```

## Verification

The fix is done when the failing hop passes again (`http-trace`, the SQL
pack, `compare-nodes`), the related check is OK (`devops check <id> <site>`),
and the user-visible symptom is gone.

## Errors

| Output | Meaning |
|---|---|
| `ERROR unknown site` | use an id from `devops site list` |
| `collection FAILED` in a snapshot | ssh failed for that host: `devops doctor` |
| `no structs-pg container for this site` | the site runs no database (public node): wrong site |
| `refused: … Secrets never leave the host` | the command would print a secret; use `devops secrets audit` |

## See also

- `structs-investigate` (workflow wrapper), `structs-health`, `structs-change`
- [docs/debugging/postgres-reference.md](../../../docs/debugging/postgres-reference.md)
