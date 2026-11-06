---
name: structs-debug-postgres
description: Debugs structs-pg (PostgreSQL 18 with TimescaleDB, pg_cron, pg_stat_statements) and PgBouncer on Structs guild sites, read-only first. Covers CPU hogs, the TSA claim spin, OFFSET paging and temp spill, keyset plans, write amplification and HOT updates, connection and pool exhaustion, bouncer auth and sslmode failures, locks, migrations, and pg_cron. Use when the database is slow or saturated, queries or connections fail, the bouncer rejects clients, or a migration or cron job did not run.
---

# Debugging structs-pg and PgBouncer

Reference for schemas, roles, key tables and functions:
[docs/debugging/postgres-reference.md](../../../docs/debugging/postgres-reference.md).
Worked examples of a full read-only review are summarized at the end of that
reference; keep your own reviews in `inventory/reports/<topic>-<date>/`.

## When to use

- Host load is high and `docker stats` shows `structs-pg` on top.
- Webapp errors mention the database, connections, or timeouts.
- structs.app `/healthz` is 503, or the bouncer logs auth failures.
- A migration from `structs-pg` main has not shown up, or a pg_cron job fails.

## Decisions

| Question | Pack |
|---|---|
| What is running right now, and which backend burns CPU? | `activity` (adds `docker top` sorted by CPU) |
| Which statements cost the most since the stats reset? | `top-statements` |
| Are we near 100 connections? Who holds them? | `connections` |
| Is the webapp pool waiting? | `bouncer` (`cl_waiting`, `maxwait`) |
| Is something blocked? | `locks` |
| Temp files, deep OFFSET paging | `temp-spill` |
| WAL volume, vacuum churn, HOT ratio | `wal`, `hot-autovacuum` |
| Hypertables, compression, job failures | `timescale` |
| pg_cron jobs and failures | `pg-cron` |
| Is the schema current? | `migrations` (compares with `.references/structs-pg/sqitch.plan`) |
| TSA or indexer tables | `signer-queue`, `signer-accounts`, `sync-state`, `ledger-sanity` |

## Procedure

1. `devops debug pg <site> activity`. Note the top CPU backend, its
   `usename`, `application_name` and query.
2. Match it against the signatures below. If none match, run
   `top-statements` and read the top five by total and by mean time.
3. For one slow SELECT, `devops debug pg <site> explain "<query>"`. Look for
   `Filter` where you expect `Index Cond`, `Rows Removed by Filter`, external
   sorts, and buffers read from disk.
4. Connection trouble: `connections` then `bouncer`. Count every client
   (webapp pool 30, structs.app 8, TSA workers, indexer, crawler, GRASS,
   Synapse, MAS) before blaming one.
5. Record the finding; known fixes go through `structs-change`.

## Signatures

| Signature | Meaning | Next |
|---|---|---|
| One `structs-tsa-v022` backend at 100% CPU on `SELECT signer.CLAIM_TRANSACTION_V022($1)`; `top-statements` shows billions of `MEMBERSHIP_CONTEXT_CHECK` / `PROXY_CONTEXT_CHECK_V022` calls | Ineligible `pending` rows re-authorized on every claim | `structs-debug-tsa`, "stuck rows" |
| `struct_attribute ORDER BY updated_at DESC NULLS LAST, id LIMIT $1 OFFSET $2` on top, temp files in the GB | Scrapers dumping `/api/*/all/page/N?limit=10000` | `devops debug nginx-top <site>` to find the client; rate limit in nginx |
| Cursor query plan shows `Filter: COALESCE(updated_at, '-infinity') …` | Keyset predicate cannot use the index | Upstream webapp fix (332 ms to 3 ms measured) |
| `api_leaderboard_player`, `api_inventory` with inserts ≈ deletes in the hundreds of millions; `grid` HOT 0% | Delete-and-reinsert per block; indexed `updated_at`/`val` | Not an incident; upstream sync-state and schema work |
| `cl_waiting` above 0 for minutes, Apache workers near 450 | Pool exhausted by a request storm | `structs-debug-http` (apache saturation) |
| Bouncer log `password authentication failed for user "structs_app"` | `userlist.txt` lost the `structs_app` row | Rotate per the site's structs-app runbook (`inventory/sites/<site>/runbooks/`), HUP the bouncer [2] |
| Bouncer log `unsupported startup parameter: statement_timeout` | `ignore_startup_parameters` lost `statement_timeout` | Restore the `pgbouncer.ini` overlay, HUP the bouncer [2] |
| Webapp cannot connect after a bouncer change | `sslmode=prefer` to the plaintext listener, or plaintext to the hostssl-only server | Webapp URL `sslmode=disable`; bouncer `server_tls_sslmode=require` |
| MAS log: TLS error connecting to Postgres | Server certificate is X.509 v1 | Reissue as v3 [2] |
| `locks` shows a blocker `idle in transaction` | A client left a transaction open | Identify the owner by `application_name`; terminating it is [2] |
| `migrations`: deployed count below the upstream plan for more than a few minutes | Auto-migrate failing or not fetching | `devops logs <site> structs-pg-auto-migrate 200`; `structs-migrations` |

## Commands reference

```bash
devops debug pg <guild> list                       # packs and what they answer
devops debug pg <guild> activity
devops debug pg <guild> top-statements --timeout-ms 60000
devops debug pg <guild> bouncer
devops debug pg <guild> sql "SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY 2 DESC LIMIT 10"
devops debug pg <guild> explain "SELECT id FROM structs.struct_attribute ORDER BY updated_at DESC NULLS LAST, id LIMIT 100"
devops logs <guild> structs-pg 200
devops logs <guild> structs-pg-bouncer 200
```

`sql` accepts only SELECT, WITH, SHOW, TABLE, VALUES and EXPLAIN, and refuses
write or admin keywords. Output is saved under `inventory/reports/runs/<date>/debug/`.

## Verification

Re-run the pack that showed the problem: the backend is gone from
`activity`, `cl_waiting` is 0, the migration count matches upstream. Then
`devops check pg-connections <site>` and `devops check bouncer <site>`.

## Errors

| Output | Meaning |
|---|---|
| `canceling statement due to statement timeout` | raise `--timeout-ms` for heavy packs (`ledger-sanity`, `top-statements`) |
| `cannot execute … in a read-only transaction` | the statement writes (a function can); this is the guard working |
| `relation "pg_stat_statements" does not exist` | extension lives in another database; check `\dx` in `structs` |
| `no structs-pg-bouncer` | the site has no bouncer (public node, local) |

## See also

- `structs-debug` (router), `structs-debug-tsa`, `structs-debug-indexer`, `structs-migrations`
- [docs/debugging/data-flows.md](../../../docs/debugging/data-flows.md)
