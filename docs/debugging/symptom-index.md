# Symptom index

Find the symptom, run the first command (all read-only), and confirm the signature before applying the fix. Fixes marked [2] or [3] go through the approval gate. When you find something new, add a row here and to the site's `known_issues` in `inventory/sites/<site>/site.yaml`.

Skills: [router](../../.agents/skills/structs-debug/SKILL.md) · [postgres](../../.agents/skills/structs-debug-postgres/SKILL.md) · [http](../../.agents/skills/structs-debug-http/SKILL.md) · [chain](../../.agents/skills/structs-debug-chain/SKILL.md) · [indexer](../../.agents/skills/structs-debug-indexer/SKILL.md) · [tsa](../../.agents/skills/structs-debug-tsa/SKILL.md). Hop map: [data-flows.md](data-flows.md).

Before restarting anything, run `devops debug snapshot <site>`: a restart clears `pg_stat_activity` and rotates the logs you need.

## Web and API

| Symptom | Likely cause | First command | Skill | Fix |
|---|---|---|---|---|
| Site times out, "Loading Assets" hangs, load high | Apache workers exhausted by desktop polling of `/api/allocation/*`, `/api/infusion/*`, or a scraper | `devops check apache-workers <site>`, `devops debug nginx-top <site>` | http | `devops deploy <site> quick-recovery` [2]; confirm cache HITs and `MaxRequestWorkers 450` |
| `X-Cache-Status` never `HIT` on `/api/*` | Cache key includes the session, or upstream `Cache-Control: private` is honored | `devops debug http-trace <site> /api/setting` twice within 5 s | http | Key the cache on the URL only and ignore `Cache-Control: private` for `/api/*` in the site's nginx overlay, then `devops patches <site> apply --restart` [2] |
| Login returns 500 on `POST /api/player-address/meta` | nginx appends to `X-Forwarded-For` (`$proxy_add_x_forwarded_for`), so `client, 172.18.0.1` lands in an `inet` column | `devops patches <site> check` | http | `devops patches <site> apply --only webapp-nginx-xff --restart` [2]: pass Caddy's header through unchanged |
| Logout does not log out | `GET /api/auth/logout` cached | `devops debug http-trace <site> /api/auth/logout` (cache must be `-` or `BYPASS`) | http | Exclude `/api/auth/logout` from the cache in the nginx overlay, as above [2] |
| One host fails with 502, inner hops fine | Caddy upstream wrong or nginx container down | `devops debug http-trace <site> /` | http | `devops restart <site> structs-webapp-cache` [2] |
| `systemctl reload caddy` fails | Global `admin off` | `caddy validate` on the host | http | Validate, then `systemctl restart caddy` (`devops deploy <site> caddy-restart`) [2] |
| Caddy will not start after a certificate renewal (public node) | certbot replaced PEMs and dropped the caddy ACL | `devops check certbot <public-node>` | http | Run the deploy hook `00-fix-cert-acls.sh`; [tls-cert-renewal.md](../../runbooks/tls-cert-renewal.md). Never `certbot --dry-run` there (its pre-hook stops Caddy) |
| Caddy cannot bind `:1443` or `:26657` | docker-proxy holds the loopback port; Caddy needs an explicit `bind <public IP>` | `ss -ltnp` in the snapshot (`host.txt`) | http | Restore the `bind` line in the Caddyfile overlay, restart Caddy [2] |
| Browser console: mixed content `ws://` | Bundle built without the HTTPS patch (GRASS or signing client `publicEndpoint`) | View source / `guild.json` (`grass_nats_websocket` must be `wss://…:1443`) | http | Re-apply patches, rebuild webpack in the container [2] |
| `https://<host>:1443/` returns 400 | Healthy: TLS works, it is just not a websocket upgrade | `devops check endpoints <site>` | http | Nothing |
| Site loads stale JS after a GA4 change | An old `base.html.twig` was overlaid | `devops webapp <site> status` | http | `devops webapp <site> ga4` inserts into the current template [1]; never overlay the template |
| Port reachable from the internet that UFW "blocks" | Docker-published ports bypass UFW | `firewall.txt` and `ss -ltnp` in the snapshot | http | Publish on `127.0.0.1` in compose [2] |
| structs.app `/healthz` 503, bouncer logs `password authentication failed for user "structs_app"` | `userlist.txt` lost the `structs_app` row (old bouncer helper overwrote it) | `devops check structs-app <guild>`, `devops debug pg <guild> bouncer` | postgres | Rotate per the site's structs-app runbook, `docker kill -s HUP` the bouncer [2] |
| structs.app player or OG pages 503 while `/healthz` is OK | Page-level database query failing (role grants, query error) | `devops debug snapshot <guild>` (`logs/structs-app-*.log`) | http | Depends on the log; open an issue on structs-app if it is a query bug |
| structs.app 502 | `structs-app` container down | `devops check containers <guild>` | http | `cd /root/structs-app && docker compose up -d` [2] |

## OIDC and Matrix

| Symptom | Likely cause | First command | Skill | Fix |
|---|---|---|---|---|
| MAS looks down; webapp `/.well-known/openid-configuration` 404 after a pull | Tracked `src/.env` reset `OIDC_ENABLED=false` and blanked `MATRIX_SIGNIN_CLIENT_ID`, `OIDC_ENCRYPTION_KEY` | `devops debug oidc-probe <site>` | http | `devops webapp <site> env-restore` [1], then `oidc-from-tel` [2] |
| Matrix login fails at the token step, token probe 401 `invalid_client` | Client secret mismatch, or a base64 secret (`+ / =` break RFC 6749 Basic auth) | `devops debug oidc-probe <site>` | http | Rotate to a hex secret in both `.env` files [2] |
| MAS callback 500 | Upstream provider misconfigured (issuer, redirect URI) or MAS cannot reach Postgres | `devops debug oidc-probe <site>`, MAS log in the snapshot | http | Match `OIDC_MAS_REDIRECT_URI` to MAS's upstream callback |
| MAS fails connecting to Postgres over TLS | structs-pg certificate is X.509 v1 | MAS log | postgres | Reissue the Postgres TLS certificate as v3 [2] |
| Synapse crash loop: `signing.key` Permission denied | Secret not owned by uid 991 | Synapse log in the snapshot | http | `chown 991:991 /root/structs-tel/config/secrets/signing.key` [1] |

## Database

| Symptom | Likely cause | First command | Skill | Fix |
|---|---|---|---|---|
| One Postgres backend at 100% CPU, `application_name=structs-tsa-v022`, query `CLAIM_TRANSACTION_V022` | Permanently ineligible `pending` `signer.tx` rows re-authorized on every claim | `devops debug pg <site> activity`, then `signer-queue` | tsa | Fail the stuck rows after saving them to `inventory/reports/` [2] (seen 2026-11-03: 724 join-proxy rows) |
| High DB CPU, temp files growing, `LIMIT … OFFSET` statements on top | Scrapers dumping `/api/*/all/page/N?limit=10000` | `devops debug pg <site> temp-spill`, `devops debug nginx-top <site>` | postgres | nginx `limit_req` or a longer TTL on `/all/page` paths [2]; webapp cursor fix upstream |
| Cursor (`after_id`) paging still slow | `COALESCE(updated_at, …)` predicate is a `Filter`, not an `Index Cond` | `devops debug pg <site> explain "<the page query>"` | postgres | Upstream webapp fix (332 ms to 3 ms measured) |
| WAL volume high, constant autovacuum on small tables | Delete-and-reinsert of `api_leaderboard_*`, `api_inventory` per block; indexes on `updated_at`/`val` block HOT | `devops debug pg <site> hot-autovacuum`, `wal` | postgres | Upstream sync-state and schema fixes; not an incident |
| Webapp errors `too many connections` or long waits; `cl_waiting` above 0 | Bouncer pool exhausted (Apache storm) or Postgres slots used up by direct clients | `devops debug pg <site> bouncer`, `connections` | postgres | Recover Apache first (quick-recovery); count all clients before raising `default_pool_size` |
| Webapp cannot connect after enabling the bouncer | PDO `sslmode=prefer` to a listener without a certificate, or plaintext to the hostssl-only server | Webapp log, `devops debug pg <site> bouncer` | postgres | Webapp URL `sslmode=disable`; bouncer `server_tls_sslmode=require` [2] |
| Bouncer rejects structs.app: `unsupported startup parameter: statement_timeout` | `ignore_startup_parameters` lost `statement_timeout` (overlay regression); it must be `extra_float_digits,options,statement_timeout` | bouncer log in the snapshot | postgres | Restore the `pgbouncer.ini` overlay, `docker kill -s HUP` the bouncer [2] |
| Queries wait, nothing progresses | Lock chain, often an `idle in transaction` session | `devops debug pg <site> locks`, `activity` | postgres | Find the blocker's owner; terminating a backend is [2] |
| A new migration did not apply | Auto-migrate failed or `main` has not been fetched yet (every 120 s) | `devops debug pg <site> migrations`; `structs-pg-auto-migrate` log | postgres | See [structs-migrations](../../.agents/skills/structs-migrations/SKILL.md); never re-pin to a commit |
| pg_cron job failing | Function error, or the job runs in the wrong database | `devops debug pg <site> pg-cron` | postgres | Fix forward in structs-pg |

## Indexer and realtime

| Symptom | Likely cause | First command | Skill | Fix |
|---|---|---|---|---|
| Site data stale, `sync-lag` WARN/CRIT | RPC source behind or unreachable; handler errors; sync-state down | `devops check sync-lag <site>`, `devops debug pg <site> sync-state` | indexer | Fix the RPC source first; then restart sync-state [2] (never scale it) |
| `handler_error_log` filling with one `composite_key` | Handler bug for a message type, often right after a chain upgrade | `devops debug pg <site> sync-state` | indexer | Report upstream (structs-pg); do not resolve rows without a fix |
| Balances differ between guilds, or negative ledger amounts | History replayed into a live database (seen 2026-09-28) | `devops debug pg <site> ledger-sanity`; compare with the LCD | indexer | Hand-correct with a backup and approval [2]. Never replay into a live DB |
| `structs-grass` unhealthy | Known chronic state: notify backlog and `LISTEN` re-issue loop | `devops debug grass-tap <site>` | indexer | Ignored by checks. If events stop, restart grass once sync-state is at the tip [2] |
| No realtime updates in the browser | GRASS not publishing (NATS `grass_pub` auth), NATS down, or the `:1443` path | `devops debug grass-tap <site>`, `devops check endpoints <site>` | indexer | Fix the failing hop; `NATS_PUB_PASSWORD` must match `nats.conf` |
| Guild missing from other guilds' lists, or wrong "this guild" | Crawler: `GUILD_ID`, manifest not `application/json`, wrong on-chain endpoint | `devops check endpoints <site>` (`guild-manifest`), crawler log | indexer | Fix the manifest overlay or `GUILD_ID` [1]/[2] |

## Signer (TSA)

| Symptom | Likely cause | First command | Skill | Fix |
|---|---|---|---|---|
| Queue does not drain, actions never land | Ineligible rows, no fresh keys, or TSA down | `devops check tsa-queue <site>`, `devops debug pg <site> signer-queue` | tsa | Depends on which; see the skill |
| Load ~37, about one commit per minute, TSA retrying | `TSA_WORKERS` too high for the cores; signing outlasts a block so `SAVE_SIGNED_TRANSACTION_V022` rejects (`source_height < indexed_height`) | `devops check tsa-queue <site>`, TSA log | tsa | `TSA_WORKERS: 6` on 4 cores, recreate the TSA [2] |
| New players cannot join (no accounts available) | Join pool empty: accounts stuck `pending`/`generating`, or keys not `ready`/fresh | `devops debug pg <site> signer-accounts` | tsa | Restart the TSA once [2]; never touch the accounts volume |
| `account sequence mismatch` | Two signers used one account (manual tx with a TSA key, two TSA instances) | TSA log, `devops debug pg <site> signer-queue` | tsa | Wait a block; make sure only one TSA uses the keyring |

## Chain and nodes

| Symptom | Likely cause | First command | Skill | Fix |
|---|---|---|---|---|
| RPC 200, `catching_up=false`, container healthy, but the newest block is minutes old | Consensus failure (`wrong Block.Header.LastResultsHash`, `AppHash`), or peer loss | `devops check block-progress`, `devops debug compare-nodes`, `node.txt` in the snapshot | chain | Do not restart first: snapshot, compare nodes, read the consensus error; then [cosmovisor-recovery.md](../../runbooks/cosmovisor-recovery.md) |
| Hash mismatch at a height between nodes | That node executed a block differently | `devops debug compare-nodes <height>` | chain | Roll back or resync that node with approval [3]; report upstream |
| Node exits in a loop with `UPGRADE "v0.X.0" NEEDED` | `cosmovisor/current` symlink still on the old binary (race at the upgrade height) | `devops node <site> status` | chain | [cosmovisor-recovery.md](../../runbooks/cosmovisor-recovery.md) fix path 1 [2] |
| Pong timeouts, peer churn, height frozen, RAM fine | Two live nodes with the same `node_key.json` (chaindata copied with config) | `devops node <site> status` (node id), compare with the other node | chain | `devops node <site> rotate-node-key` [2] |
| Crash loop `encoding/hex: odd length hex string` | Typo in a peer id in `persistent_peers`/`seeds` | node log | chain | Fix the peer list (ids are 40 hex chars) [2] |
| After a recreate: gRPC unreachable, swagger 404, pruning or CORS back to defaults (public node) | `app.toml` re-templated when the docker-config marker changed | `devops check app-toml <public-node>` | chain | `devops node <public-node> app-toml apply` [1], restart structsd [2] |
| `nc :9090` connects but gRPC calls hang | `[grpc] address` back to `localhost:9090` | `devops check app-toml <public-node>` | chain | Same as above (sets `0.0.0.0:9090`) |
| Transactions hang or time out | The node used for broadcast is catching up | `devops node <site> status` | chain | Use a synced RPC; `devops tx` refuses when `catching_up=true` |
| Archive disk filling | Archive growth (`pruning = "nothing"`) | `devops check archive-growth <public-node>` | chain | Plan disk; [pruning-and-archive.md](../reference/pruning-and-archive.md) |

## Local Docker

| Symptom | Likely cause | First command | Skill | Fix |
|---|---|---|---|---|
| Checks for `local` fail with Docker errors | `ssh: local` runs on the hub; Docker Desktop is not running | `docker info` | router | Start Docker Desktop |
| Local webapp shows no chain data | Local sync-state points at an RPC it cannot reach, or the stack was started without it | `devops check sync-lag local`, `devops debug pg local sync-state` | indexer | Set the RPC source in the local `.env`, `devops restart local structs-sync-state` [2] |
