---
name: structs-debug-indexer
description: Debugs the Structs indexer and realtime path (structs-sync-state writing chain data into structs-pg, the api_* read models and ledger, GRASS pg_notify to NATS to the browser websocket, and the guild crawler). Covers sync lag, handler errors, unknown events, ledger correctness and replay damage, GRASS buffer drops and the LISTEN loop, NATS auth, and crawler manifest issues. Use when site data is stale, balances or inventories look wrong, realtime updates stop, or a guild shows up wrong in other guilds' lists.
---

# Debugging sync-state, GRASS and the crawler

Path: structsd RPC (the public node) -> `structs-sync-state` -> structs-pg
(`sync_state.*`, `structs.*`) -> `pg_notify('grass')` -> `structs-grass` ->
NATS -> Caddy `:1443` -> browser. Details in
[docs/debugging/data-flows.md](../../../docs/debugging/data-flows.md).

## When to use

- `sync-lag` WARN/CRIT, or the site shows old heights or old state.
- A player reports a balance that differs from the chain or from the other
  guild.
- Realtime updates stop in the browser.
- The guild appears with the wrong data, or not at all, on other guilds.

## Decisions

| Situation | First command |
|---|---|
| Stale data | `devops check sync-lag <site>`, `devops debug pg <site> sync-state` |
| Wrong balance | `devops debug pg <site> ledger-sanity`, then compare with the LCD |
| No realtime | `devops debug grass-tap <site>` |
| Crawler / manifest | `devops check endpoints <site>` (`guild-manifest`), `devops logs <site> structs-crawler 200` |

## Procedure

**Stale data**

1. Check the source first: is the public node advancing
   (`devops check block-progress`)? If not, this is `structs-debug-chain`.
2. `devops debug pg <site> sync-state`: `lag_blocks`, `updated_ago`, blocks
   per 10 minutes, and unresolved handler errors.
3. `devops logs <site> structs-sync-state 300`: RPC errors, writer-lock
   messages, panics.
4. Restarting sync-state is tier 2 and safe once the cause is understood.
   Never run a second instance (writer lock) and never point it at history
   it has already indexed.

**Wrong balance**

1. `ledger-sanity`: negative `amount_p` rows (expected 0), the
   `block_log.ingested_at` histogram (a burst far above ~600 blocks/hour is
   a backfill or replay), identical rows, and the reconciler count.
2. The reconciler compares the index with itself, so a replayed ledger
   reconciles cleanly. Compare one player with the chain:
   `curl -s https://public.testnet.structs.network/cosmos/bank/v1beta1/balances/<address>`
   and with the other guild (`devops debug pg <other-site> sql "SELECT … FROM structs.api_inventory WHERE owner_id = '<player>'"`).
3. Corrections are writes: save the rows you change first.
   **Never fix a ledger by replaying blocks into a live database** (seen
   2026-09-28: a replay double-counted infusions and left negative balances).

**No realtime updates**

1. `devops debug grass-tap <site>`: messages per subject in 15 s, GRASS
   container state, dropped-notification and `LISTEN` counts. The subscriber
   needs `natsio/nats-box` on the host; without it only the log counts run,
   and `--pull` fetches the image (ask first: it writes to the host).
2. Zero messages and sync-state is at the tip: GRASS is not publishing.
   Check its log for NATS auth errors (`grass_pub`, `NATS_PUB_PASSWORD` must
   match `config/nats/nats.conf`).
3. Messages flow but the browser gets nothing: the `:1443` hop
   (`structs-debug-http`).

## Signatures

| Signature | Meaning | Next |
|---|---|---|
| `lag_blocks` growing, RPC errors in the sync-state log | Source RPC slow or down | Fix the source (public node) |
| One `composite_key` filling `handler_error_log` | Handler bug for that message, often after an upgrade | Report to structs-pg; do not mark rows resolved without a fix |
| `unknown_event_log` growing after an upgrade | New event types not handled yet | Expected until structs-pg catches up |
| Negative `amount_p` rows | Replay over existing state | Hand-correct with backup [2]; incident report |
| `structs-grass` unhealthy, events still flow | Known chronic state on some guilds; those sites list it in `checks.ignore_unhealthy` | Nothing |
| `dropped notification due to full buffer` climbing | GRASS cannot keep up with `pg_notify` | Restart grass once sync-state is at the tip [2] |
| `LISTEN` lines in the thousands per hour | Re-issue loop (6.1M `LISTEN` calls in the Nov 3 review) | Upstream GRASS bug; restart only if streaming stops |
| `Authorization Violation` in GRASS or NATS logs | `grass_pub` password mismatch | Align `.env` and `nats.conf`, restart nats and grass [2] |
| `guild.json` not `application/json` or wrong endpoint | Manifest overlay or Caddy route wrong | Patch `guild-manifest` [1] |
| Wrong guild flagged as "this guild" | Crawler `GUILD_ID` | Fix the env, restart the crawler [2] |

## Commands reference

```bash
devops check sync-lag <guild>
devops debug pg <guild> sync-state
devops debug pg <guild> ledger-sanity --timeout-ms 120000
devops debug grass-tap <guild> --seconds 20
devops debug grass-tap <guild> --subject 'structs.>'
devops logs <guild> structs-sync-state 300
devops logs <guild> structs-grass 200
```

## Verification

`sync-lag` OK and `lag_blocks` near 0; `ledger-sanity` shows no negative
rows and the player's balance matches the LCD; `grass-tap` shows messages
on the expected subjects.

## Errors

| Output | Meaning |
|---|---|
| `canceling statement due to statement timeout` on `ledger-sanity` | the reconciler is a full scan; raise `--timeout-ms` |
| `no events in 15s` | quiet chain or broken publisher; compare with sync-state's block rate |
| nats-box pull fails | the host cannot reach Docker Hub; the tap needs `natsio/nats-box` once |

## See also

- `structs-debug` (router), `structs-debug-postgres`, `structs-debug-chain`
