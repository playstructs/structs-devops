# structs-pg reference

What you need to read the database during an incident. Schema source: `.references/structs-pg/deploy/` (Sqitch, project `structs-pg`). Image and migration tooling: `.references/docker-structs-pg/`.

## Server

- `structs/structs-pg` image: PostgreSQL 18.6, TimescaleDB 2.28.1, pg_cron 1.6 (jobs live in the `structs` database), `pg_stat_statements` 1.12 with `track=all` (nested function calls show up as their own rows).
- `max_connections 100`, `shared_buffers 2 GB` inside an 8 GB container limit, `work_mem 30 MB`, `wal_compression lz4`, `log_temp_files 0`.
- No cluster-wide `statement_timeout` or `idle_in_transaction_session_timeout` today. Per-role timeouts are blocked until the TSA stops using `structs_webapp`.
- The server also hosts the Synapse and MAS databases. TCP connections need TLS (hostssl). The certificate must be X.509 v3, or MAS fails.
- Recreate only with `docker compose up -d --no-deps structs-pg`. Never run `structs-pg-init` against a live volume.

## Schemas

| Schema | Written by | Contents |
|---|---|---|
| `structs` | sync-state (chain data), webapp (player metadata), crawler (`guild_meta`) | Chain objects (`player`, `guild`, `planet`, `struct`, `grid`, `*_attribute`), `player_address`, `guild_meta` (`this_infrastructure`), derived `api_*` read models, the `ledger` hypertable, `stat_*` and `planet_activity*` hypertables |
| `sync_state` | sync-state | `sync_cursor`, `block_log`, `handler_error_log`, `unknown_event_log`, `economy_contract`, `native_staking_snapshot` |
| `signer` | webapp (requests), TSA (claims, keys, submissions) | `tx`, `account`, `local_key`, `tx_submission`, plus the claim and authorization functions |
| `view` | migrations | Read views used by the webapp (`view.struct_status`, `view.player_inventory`) |
| `sqitch` | auto-migrate | Migration registry (`changes`, `events`) |
| `cron` | pg_cron | `job`, `job_run_details` |

## Key tables

**`sync_state.sync_cursor`**: one row per chain: `chain_id, last_height, last_block_hash, last_block_time, status, lag_blocks, tip_height, updated_at`. `lag_blocks` and `updated_at` are the first things to read when the site shows stale data.

**`sync_state.block_log`**: one row per indexed block (`height, block_hash, block_time, num_txs, num_events, num_handler_errors, ingested_at`). It is the largest table (no retention). The `ingested_at` histogram is how you spot a backfill or replay: normal is about 600 blocks per hour.

**`sync_state.handler_error_log`**: append-only per-event errors (`height, composite_key, payload, error, severity, resolved_at`). Unresolved rows by `composite_key` point at a handler bug. **`unknown_event_log`** counts events no handler recognizes (expected after a chain upgrade until structs-pg catches up).

**`structs.ledger`**: TimescaleDB hypertable: `time, id, address, counterparty, amount_p, amount (generated), block_height, action, direction, denom`. There should be no rows with `amount_p < 0`. `structs.api_inventory_reconcile(false)` compares `api_inventory` with the ledger without logging. It only checks the index against itself, so a replayed ledger reconciles cleanly; compare balances with the LCD and with the other guild's database too.

**`structs.api_*`**: read models rebuilt per block (`api_inventory`, `api_leaderboard_player|guild|substation`, `api_work`, `api_guild_bank`). `structs.api_refresh_state(model, source_height, source_time, refreshed_at)` shows how fresh each one is.

**`signer.tx`**: request queue: `id, object_id, permission_requirement, priority, account_id, module, command, args, flags, status (pending|claimed|broadcast|error), output, created_at, updated_at`.

**`signer.account`**: TSA accounts: `id, role_id, address, status (stub|generating|pending|available|signing), registration_tx_id, created_at, updated_at`.

**`signer.local_key`**: what each TSA keyring reports: `inventory_id, address, key_name, present, state (unverified|unregistered|held|waiting-index|waiting-registration|conflict|ready), chain_id, player_id, permissions, source_height, observed_height, observed_at, seen_at`. The claim only uses keys seen within 120 s.

**`signer.tx_submission`**: v0.22 broadcast tracking: `tx_id, claim_token, account_id, address, chain_id, tx_hash, sequence, source_height, timeout_height, state (prepared|sending|unknown|accepted|rejected|committed|cancelled), check_tx, deliver_tx, local_error, created_at, send_started_at, resolved_at`. `signed_bytes` and `request` are also stored: never print them.

## Key functions

| Function | Called by | Watch for |
|---|---|---|
| `signer.CLAIM_TRANSACTION_V022(account uuid)` | TSA workers, in a loop | Mean above ~10 ms means ineligible `pending` rows are being re-authorized on every call (1.6 s seen with 724 stuck rows). |
| `signer.AUTHORIZED_ACCOUNTS_V022`, `MEMBERSHIP_CONTEXT_CHECK`, `PROXY_CONTEXT_CHECK_V022`, `PERMISSION_CHECK` | the claim's `EXISTS` | Billions of nested calls in `top-statements` mean the queue problem above. |
| `signer.SAVE_SIGNED_TRANSACTION_V022` | TSA after signing | Rejects when `source_height < indexed_height`: signing took longer than a block (too many workers for the cores). |
| `signer.RECONCILE_LOCAL_KEY_V022`, `SYNC_LOCAL_KEYS_V022` | TSA heartbeat | Rewrites every key row every pass (WAL), harmless but noisy. |
| `structs.api_work_refresh(height, time)` | sync-state per block | Creates a temp table per call (catalog churn in `pg_attribute`). |
| `structs.api_inventory_reconcile(p_log boolean)` | operators | Full scan; pass `false` in read-only sessions. |

## Roles and connections

| Role | Service | Path | Limit |
|---|---|---|---|
| `structs_webapp` | webapp | bouncer, transaction pool 30 | 30 server connections (+5 reserve) |
| `structs_webapp` (`application_name=structs-tsa-v022`) | TSA | direct `structs-pg:5432` | grows with `TSA_WORKERS` (e.g. 6) |
| `structs_indexer` | sync-state, GRASS | direct | sync-state `SYNC_STATE_DB_MAX_CONNS=4` |
| `structs_crawler` | crawler | direct | none set |
| `structs_app` | structs.app, read only | bouncer alias `structs_app` | pool 8 (+2) |
| Synapse and MAS roles | Matrix | direct | their own pool settings |

The 2026-11-03 review saw 26 of 100 connections in use on a normal day; use that as the baseline.

Read the budget with `devops debug pg <site> connections`, the pool with `devops debug pg <site> bouncer` (`cl_waiting` that stays above 0 means the pool is exhausted, usually by Apache worker storms).

## Safe access

- `devops debug pg` connects over the container socket as `postgres` with `default_transaction_read_only=on`, `statement_timeout` (30 s default), `lock_timeout 2 s`, and `application_name=structs-devops-debug`. It refuses statements containing write or admin keywords.
- `explain` runs `EXPLAIN (ANALYZE, BUFFERS, SETTINGS)` only for plain SELECT/WITH. `ANALYZE` executes the statement, so never wrap a function that writes.
- Bouncer admin commands go through the bouncer's `pgbouncer` virtual database, `SHOW` only.
- Before any write (failing stuck `signer.tx` rows, resolving `handler_error_log` rows), save the affected rows to `inventory/reports/` and get explicit approval; it is tier 2.

## Known performance signatures (2026-11-03 review)

Worked examples (from a review of a busy guild database, 2026-11-03):

- **Claim spin**: one `structs-tsa-v022` backend at 100% CPU; `signer.tx` full of `pending` rows of one command from one player.
- **OFFSET paging**: `/api/*/all/page/N?limit=10000` from scrapers; `LIMIT $1 OFFSET $2` statements dominate `top-statements` and cause all temp spill.
- **Keyset filter**: `COALESCE(updated_at, '-infinity')` in the cursor predicate turns an `Index Cond` into a `Filter`: 332 ms instead of 3 ms per page (webapp item 2).
- **Write amplification**: delete-and-reinsert of `api_leaderboard_player` and `api_inventory` per block (half of the WAL); 0% HOT updates on `grid`.
- **GRASS `LISTEN` loop**: `LISTEN "grass"` executed millions of times (sync-state item 8).
