---
name: structs-debug-tsa
description: Debugs the Structs transaction signing agent (structs-tsa) and its queue in structs-pg (signer.tx, signer.account, signer.local_key, signer.tx_submission). Covers a queue that will not drain, ineligible rows and the claim CPU spin, TSA_WORKERS too high for the cores, an empty join-account pool, stale keys, accounts stuck pending, and account sequence mismatches. Use when player actions never land on chain, the tsa-queue check is red, new players cannot join, or the TSA or its claim function burns CPU.
---

# Debugging the TSA

Flow: the webapp inserts `signer.tx` rows (`pending`), TSA workers claim them
with `signer.CLAIM_TRANSACTION_V022`, sign with keys in the `tsa-keyring`
volume, save with `SAVE_SIGNED_TRANSACTION_V022`, broadcast, and track the
result in `signer.tx_submission`. The TSA connects directly to
`structs-pg:5432` as `structs_webapp`; it stays off PgBouncer on purpose.

## When to use

- `tsa-queue` WARN/CRIT, or players report actions that never happen.
- One Postgres backend at 100% CPU with `application_name=structs-tsa-v022`.
- New players cannot join a guild.
- Host load far above the core count with the TSA retrying.

## Decisions

| Situation | First command |
|---|---|
| Queue size and age | `devops debug pg <site> signer-queue` |
| Accounts and keys | `devops debug pg <site> signer-accounts` |
| CPU | `devops debug pg <site> activity` |
| TSA behavior | `devops logs <site> structs-tsa 300` |

## Procedure

1. `signer-queue`: counts by status, `pending` by command with `older_24h`,
   `pending` by object, long `claimed` rows, unresolved submissions.
2. `signer-accounts`: accounts by status, accounts stuck in
   `generating`/`pending`/`signing`, keys by state and freshness (the claim
   only uses keys seen within 120 s).
3. Read the TSA log for `save` rejections, sequence errors, RPC errors.
4. Match the signatures below.

**Stuck rows (tier 2 write).** Rows that can never pass authorization stay
`pending` and are re-checked on every claim. To fail them:

1. Save them: `devops debug pg <site> sql "SELECT id, command, object_id, created_at FROM signer.tx WHERE status = 'pending' AND command = '<command>' AND created_at < now() - interval '24 hours' ORDER BY id"`
   (output is saved under `inventory/reports/runs/<date>/debug/`). Attach that file
   to the journal entry.
2. Fail them, and tell the user how many and why:
   `devops ssh <site> -- "docker exec -i -u postgres <structs-pg container> psql -d structs -c \"UPDATE signer.tx SET status = 'error', output = 'expired by operator <date>: never eligible', updated_at = now() WHERE status = 'pending' AND id IN (<ids>) AND NOT EXISTS (SELECT 1 FROM signer.tx_submission s WHERE s.tx_id = signer.tx.id)\""`
3. Verify with `signer-queue` and `activity` (the claim backend should go
   idle within seconds).

## Signatures

| Signature | Cause | Fix |
|---|---|---|
| Hundreds of `pending` rows of one command from one player, `older_24h` high, claim backend at 100% CPU, claim mean in seconds | Client retry loop queued requests that can never be authorized (seen 2026-11-03: 724 join-proxy rows on one guild) | Stuck-rows procedure above [2]; report the client loop upstream |
| Load ~37 on 4 cores, about one commit per minute, log shows save rejections | `TSA_WORKERS` too high: signing outlasts a block, so `SAVE_SIGNED_TRANSACTION_V022` rejects (`source_height < indexed_height`) | `TSA_WORKERS: 6` in compose, recreate the TSA [2] |
| `signer.account` has no `available` rows; joins fail | Join pool empty: accounts stuck `generating`/`pending`, or keys not `ready` | Restart the TSA once [2]; if keys stay stale, check the keyring volume is mounted |
| `local_key` rows with `fresh_120s = 0` | TSA heartbeat stopped (TSA down or cannot reach the DB) | `devops logs <site> structs-tsa`; restart [2] |
| Accounts `pending` after a TSA restart and not moving | Registration not confirmed back through the indexer | Wait a few blocks; if they stay, check `sync-lag` and the TSA log before restarting again |
| `account sequence mismatch` | Two signers used one account (a manual tx with a TSA key, or two TSA instances on one keyring) | Wait a block; ensure one TSA per keyring |
| `claimed` rows older than 10 minutes | A worker died or hung mid-claim | Read the TSA log first; a restart [2] lets its recovery pass page in-flight submissions. Re-run `signer-queue` and confirm the rows moved |
| Unresolved `tx_submission` in `unknown` | Broadcast result not seen yet | Wait; check the RPC the TSA uses |

Never delete or recreate the `tsa-keyring` volume (it holds every account
key). Never point the TSA `DATABASE_URL` at the bouncer.

## Commands reference

```bash
devops check tsa-queue <guild>
devops debug pg <guild> signer-queue
devops debug pg <guild> signer-accounts
devops debug pg <guild> activity
devops logs <guild> structs-tsa 300
devops deploy <guild> tsa-update --dry-run     # pull and recreate, keeps TSA_WORKERS and the volume
```

## Verification

`signer-queue` shows `pending` near zero and no old rows, the claim
backend is idle in `activity`, `tsa-queue` is OK, and a test action from the
webapp lands on chain.

## Errors

| Output | Meaning |
|---|---|
| `signed request identity is immutable` | the row has a submission; it is past the point where an operator may fail it |
| `aborted unsigned request is immutable` | the row was already aborted by the TSA |
| `cannot execute UPDATE in a read-only transaction` | you used `devops debug pg` for a write; write with `psql` on the host (`devops ssh <site> -- "docker exec …"` or plain ssh) |

## See also

- `structs-debug` (router), `structs-debug-postgres`, `structs-transactions`
