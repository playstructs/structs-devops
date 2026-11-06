---
name: structs-migrations
description: Manages structs-pg database migrations (Sqitch, structs-pg-auto-migrate tracking main, writer and signer contracts) and structs-pg server recreates on guild sites. Use when a migration failed or is pending, the schema and webapp or TSA disagree, auto-migrate logs errors, the structs-pg image is bumped, or someone proposes pinning migrations or re-running init.
---

# structs-pg migrations

Migrations are Sqitch changes in `playstructs/structs-pg`. Every guild runs
`structs-pg-auto-migrate`, which fetches `main` every 120 s and runs
`sqitch deploy --verify` to `latest`. Our sites set, on the `x-postgres-env`
anchor, `structs-pg-auto-migrate` and `structs-sync-state`:

```
STRUCTS_PG_MIGRATION_MODE=branch  STRUCTS_PG_BRANCH=main  STRUCTS_PG_REF=""
STRUCTS_PG_MIGRATION_TARGET=latest
STRUCTS_LEDGER_WRITER_CONTRACT=denomination-v1  STRUCTS_SIGNER_CONTRACT=v022-1   (auto-migrate)
```

These override the image's baked-in pinned defaults. **Never re-pin to a
commit** and never run `structs-pg-init` on a live site.

## When to use

- auto-migrate logs an error, or a deploy needs a schema change that has not landed.
- Webapp or TSA errors that name a missing column, function or role grant.
- A structs-pg image bump (`pg-recreate` procedure).

## Decisions

| Situation | Action |
|---|---|
| New change on main, not yet applied | wait one cycle (120 s); check the logs |
| `Refusing migrations from modified tracked sources` | someone edited files inside the container checkout; recreate auto-migrate (tier 2) |
| `git fetch` failures | GitHub/DNS from the host; the run stops rather than deploying stale code |
| Verify failure on a change | stop: report to the structs-pg maintainers with the change name and error; do not revert by hand |
| Server image bump | `devops deploy <site> pg-recreate` (snapshot, confirm window, `up -d --no-deps structs-pg`) |
| Someone suggests `pinned` mode or `RUN_MIGRATIONS=1` | decline; that is the rule above |

## Procedure

1. Observe: `devops logs <site> structs-pg-auto-migrate 100`. Healthy runs
   print `Migration source: mode=branch commit=<sha>` and
   `Deploying Sqitch target: latest` with nothing to deploy.
2. Compare deployed vs upstream: `devops debug pg <site> migrations` (last
   applied Sqitch changes) against
   `git -C .references/structs-pg log --oneline -5 -- sqitch.plan`
   (`devops refs sync structs-pg` first).
3. If a change is failing, read its `deploy/`, `verify/` scripts in
   `.references/structs-pg` and the error. Collect the evidence and hand it to
   the maintainers; schema fixes go through structs-pg `main`, never into the
   live database.
4. For a recreate, follow `structs-deploy` with the `pg-recreate` procedure.
   TSA, sync-state and the crawler connect to `structs-pg:5432` directly and
   reconnect on their own; check `devops check tsa-queue <site>` and
   `devops check sync-lag <site>` afterwards.

## Commands reference

```bash
devops logs <guild> structs-pg-auto-migrate 100
devops debug pg <guild> migrations
devops refs sync structs-pg && git -C .references/structs-pg log --oneline -10 -- sqitch.plan
devops deploy <guild> pg-recreate --dry-run
devops check pg-connections <guild>
```

## Verification

- auto-migrate: last run shows the expected commit and no error.
- `devops debug pg <site> migrations` lists the change you expected.
- `devops health <site>` (pg-connections, sync-lag, tsa-queue) unchanged or better.

## Errors

| Log line | Meaning |
|---|---|
| `Unrecognized writer or signer migration contract` | the contract env vars were edited; restore the values above |
| `Branch migration mode requires an explicit STRUCTS_PG_BRANCH name` | `STRUCTS_PG_BRANCH` was blanked |
| `Pinned migrations require a full STRUCTS_PG_REF commit SHA` | someone set pinned mode; revert to branch/main |
| webapp `permission denied for table ...` after a release | the matching `role-structs-webapp-*` grant change has not deployed yet |

## See also

- `.references/docker-structs-pg/docs/v022-migrations.md`, `postgres-recovery.md`
- [docs/debugging/postgres-reference.md](../../../docs/debugging/postgres-reference.md)
- `structs-debug-postgres`, `structs-deploy`
