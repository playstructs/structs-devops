# Local Docker stack (site `local`)

Run the guild stack on the hub, read-only against the public node: Postgres
with migrations from `structs-pg` `main`, sync-state indexing the chain,
NATS + GRASS, and the webapp. No structsd, no TSA, no validator, no guild keys.
Use it to try patches, migrations and webapp builds before a remote site.

## Prerequisites

- Docker Desktop (or OrbStack/Colima) with ~8 GB RAM for the stack and 20+ GB disk.
- `./setup.sh` has run (`.references` cloned, `yq`/`jq` installed).

## 1. Check out the sources

```bash
mkdir -p local/stack
git clone https://github.com/playstructs/docker-structs-guild.git local/stack/docker-structs-guild
git clone https://github.com/playstructs/structs-webapp.git      local/stack/structs-webapp
```

`local/` is git-ignored. The `local` site's `stacks[].path` points here.

## 2. Configure `.env`

```bash
cd local/stack/docker-structs-guild
cp .env.example .env
```

Set, at minimum:

| Key | Value |
|---|---|
| `NETWORK_CHAIN_ID` | `structstestnet-111` |
| `STRUCTS_NODE_API_SEED` | `https://public.testnet.structs.network` |
| `STRUCTS_RPC_SEED`, `STRUCTS_RPC_PRIMARY` | `https://public.testnet.structs.network:26657` |
| `WEBAPP_SOURCE` | `../structs-webapp/src` |
| `STRUCTS_PG_BRANCH` | `main` |
| `WEBAPP_APP_ENV` | `dev` |
| `WEBAPP_APP_SECRET`, `NATS_*_PASSWORD` | fresh values (`openssl rand -hex 32`); local only |

Leave `GUILD_ID` and every mnemonic empty. Store the generated local values as
`local-env:` pointers only if a tool needs them (`local/secrets.env`).

## 3. Start the read-only subset

```bash
devops deploy local up          # or by hand:
cd local/stack/docker-structs-guild
docker compose -p structs-local up -d structs-pg structs-pg-auto-migrate structs-sync-state structs-nats structs-grass structs-webapp
```

Do not start `structsd`, `structs-tsa`, `structs-crawler` or `structs-control`.
`structs-pg-init` runs once as a dependency of `structs-pg` on a fresh volume;
that is fine locally (on live sites it is never re-run).

## 4. Watch it come up

```bash
devops ps local
devops health local
devops logs local structs-sync-state 100
devops debug pg local sync-state
```

sync-state backfills from the v0.22 activation height (3353000). Expect hours
before the lag reaches zero; `sync-lag` reports progress.

## 5. Use it

| Task | How |
|---|---|
| Try a webapp branch | `git -C local/stack/structs-webapp switch <branch>`, then `docker exec structs-local-structs-webapp-1 bash -lc 'cd /src && npm run build'` |
| Try a migration | point `STRUCTS_PG_BRANCH` at the branch, `docker compose -p structs-local restart structs-pg-auto-migrate`, watch its logs |
| Try a patch overlay | add it under `inventory/sites/local/patches/`, then `devops patches local check` / `apply` |
| Query the read model | `devops debug pg local <pack>` |

## 6. Stop or reset

```bash
devops deploy local down                                   # stop, keep volumes
docker compose -p structs-local down                        # remove containers, keep volumes
docker compose -p structs-local down -v                     # also delete the database (re-index from scratch)
```

The `local` site has `checks.in_all: false`, so cron runs over `all` skip it.
