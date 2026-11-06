# Health checks

`devops health [site|all] [hourly|daily]` runs a check group; `devops check <id> [site]`
runs one and prints all its detail; `devops checks` lists the catalog.
Every run writes `inventory/reports/runs/<date>/health-<group>-<target>-<HHMM>.md` and
records each result in `state/checks/<scope>/<id>.{last,status}`.

Statuses: **OK**, **WARN** (look today), **CRIT** (look now), **UNKNOWN** (the
check could not see; often ssh or the LCD). Notifications fire on a status
change and repeat every `DEVOPS_CRIT_REMIND_HOURS` (default 6) while CRIT.

## Where checks run

Everything runs on the hub. Hub-only checks use public HTTPS (LCD, RPC, site
endpoints, GitHub, Docker Hub). Host checks stream a small read-only probe
over ssh (`checks/host/*.sh`) that prints `key=value` lines; the hub compares
them with inventory thresholds. A connection is multiplexed per host for the
whole run.

## Catalog

| Check | Scope | Group | Runs on | Looks at | Thresholds (`check_defaults`) |
|---|---|---|---|---|---|
| block-progress | network | hourly | all | Public RPC tip: block age, blocks/hour since the previous run, catching_up, chain id | `chain.stall_seconds_warn/crit`, `chain.blocks_per_hour_min` |
| height-agreement | network | hourly | all | Height of the public RPC and every inventory node | `heights.disagree_blocks_warn/crit` |
| host-resources | site | hourly | all | Load per core, MemAvailable, swap, disk %, inodes, OOM kills, days until disk full (7-day trend) | `host.*` |
| containers | site | hourly | all | `docker compose ps` per stack: running/healthy, one-shots exited 0, restart-count increases, declared services missing | `checks.ignore_unhealthy` |
| endpoints | site | hourly | all | Every `endpoints:` entry: status, content type, JSON assertion, CORS header, latency, TCP | `sync.lag_blocks_*` for `lag_json` |
| node-health | site | hourly | nodes | Local structsd: block age, catching_up, peers, node_id vs inventory, image digest, cosmovisor current, validator voting power | `chain.*` |
| pg-connections | site | hourly | guild | Connections vs `max_connections`, idle in transaction > 5 min, longest active query, lock waits, xid age, pg_cron failures | `pg.conn_pct_warn/crit` |
| tsa-queue | site | hourly | extra | `signer.tx` pending/claimed and oldest pending, 24 h-old rows, broadcasts and errors per hour, available `signer.account`, stuck `signer.tx_submission`, TSA_WORKERS vs inventory | `tsa.*` |
| sync-lag | site | hourly | extra | `sync_state.sync_cursor` vs chain tip, cursor freshness, handler errors, `structs.api_refresh_state` ages, `api_readiness` data/transaction ready | `sync.lag_blocks_*` |
| bouncer | site | hourly | extra | PgBouncer `SHOW POOLS`: clients waiting, maxwait | `bouncer.cl_waiting_*` |
| apache-workers | site | hourly | extra | Apache prefork children vs MaxRequestWorkers (and that the bind-mount took) | `apache.busy_pct_*`, `checks.apache.max_workers` |
| validator | site | daily | extra | Bonded, jailed, tombstoned, missed blocks in the slashing window | 5 % / 30 % missed |
| tls-expiry | site | daily | all | Every `tls:` name × port: days left, SAN covers the name, issuer | `tls.days_warn/crit` |
| patches-drift | site | daily | manifest | `apply-patches.sh --check` on the host (needs a current host bundle) | — |
| secrets-audit | site | daily | all | Every pointer: present / EMPTY / missing, mode, owner, expected line | — |
| app-toml | site | daily | extra | app.toml vs the site's `app-toml.overrides` | — |
| certbot | site | daily | extra | certbot.timer, renewal pre/post hooks, deploy hooks, Caddy ACL on the key. Never runs certbot. | — |
| archive-growth | site | daily | extra | Chain data GB/day and days until the volume is full | `host.disk_days_left_*` |
| structs-app | site | daily | extra | structs.app `/healthz` ok + lag, container health | `sync.lag_blocks_*` |
| gov-pending | network | daily | all | Proposals in voting and inventory voters who have not voted | < 24 h left = CRIT |
| upgrade-plan | network | daily | all | On-chain plan, ETA, `upgrades/<name>` staged on every node; inventory binary has an applied plan | ETA 48 h / 6 h |
| new-releases | network | daily | all | New structsd tags, Docker Hub digests vs pins, moved repo heads, pins that landed on main | — |
| inventory-freshness | network | daily | all | Validator errors, stale generated docs, `last_verified` age, `unverified:` fields | `inventory.stale_days` |

`applies`: **all**; a site **kind** (`guild`, `public-node`, `local`); **nodes**
(the site has `nodes:`); **manifest** (the site has `patches/manifest.tsv`);
**extra** (only when the id is in the site's `checks.extra`). A site opts out
with `checks.skip: [id]`; `checks.in_all: false` keeps a site out of `all` runs.

## Reading results the Structs way

- **sync-lag WARN + tsa-queue CRIT** together usually means the indexer fell behind and the TSA rejects every signing attempt (`save_signed_transaction_v022` needs `source_height < indexed_height`). Fix the indexer first.
- **tsa-queue "queue not draining"** with plenty of available accounts: check `TSA_WORKERS` (30 workers on 4 cores outlast a block), then the TSA logs.
- **tsa-queue rows older than 24 h** for one command (for example `guild-membership-join-proxy`): rows the TSA can never claim. See skill `structs-debug-tsa`.
- **containers: structs-grass unhealthy** is known and ignored on the guild sites.
- **apache-workers high + endpoints slow** with low CPU: a client hammering `/api/*`; the nginx 5 s cache should absorb GETs, so check it is in the path (`devops patches <site> check`).
- **endpoints structs-app-og 503 while healthz is OK**: the preview renderer, not the database. Check `devops logs <site> structs-app`.
- **node-health node_id differs**: someone copied `node_key.json` between nodes. Two nodes with one id fight for peers.
- **app-toml drift after an upgrade or recreate** on the public node: `devops node <public-node> app-toml apply`, then a tier-2 restart.

## Running from cron

`crons/` runs these groups on a schedule (see `docs/automations.md`). Each job
notes when the hub was asleep (`gap:` in the report) instead of pretending it
watched continuously.
