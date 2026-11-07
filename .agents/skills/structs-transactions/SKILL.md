---
name: structs-transactions
description: Sends Structs chain transactions as an inventory account with on-host signing (simulate first, then broadcast once the user approves), runs guild on-chain actions (guild endpoint, agreements, allocations), and creates keys and players with the mnemonic kept on the host. Use when a structsd tx is needed, a guild endpoint or allocation must change, a new account, key or player is requested, or a transaction failed or is stuck.
---

# Structs transactions

All signing happens on the host that holds the key. `devops tx` loads the
mnemonic there, hands it to an ephemeral `structs/structsd` container,
checks the recovered address matches the inventory, simulates or signs,
and returns only `SIMULATE_OK ...` or `RESULT txhash=... code=... height=...`.
Simulation runs freely. Broadcasting is the one action in this framework that
needs the user's explicit yes, however it is sent (`devops tx`, `structsd tx`
on a host, the REST or RPC broadcast endpoints).

## When to use

- Any `structsd tx` on behalf of an inventory account (`onchain.accounts`).
- Guild endpoint updates, energy agreements, allocations (`devops onchain`).
- New keys or players (`devops account`).

## Decisions

| Need | Command |
|---|---|
| Arbitrary message | `devops tx <site> <account> -- <module> <msg> [flags] [-- positionals]` |
| Guild endpoint matches inventory | `devops onchain <site> guild-endpoint` (defaults to the inventory URL) |
| Read on-chain state vs inventory | `devops onchain <site> show` |
| New signing key on a host | `devops account create-key <site> <name>` (tier 2; not a transaction) |
| New player through the guild | `devops account create-player <site> <name> [--username U]` (tier 3) |
| Governance vote | `structs-governance` |

Entity ids such as `0-5` or `1-404` look like flags to the CLI parser: put
them after a second `--`.

## Procedure

1. Confirm the account exists: `devops account list <site>` (address, secret
   pointer, balance).
2. Simulate: `devops tx <site> <account> -- <module> <msg> ... -- <ids>`.
   Read the gas estimate and any error. A failed simulation broadcasts nothing.
3. Broadcast: add `--broadcast` (and `--note "why"`). The command exits **10**
   with an Approval Block showing signer, chain id, message and the
   simulation. Show it to the user; after an explicit yes, re-run with
   `--approve <token>`.
4. Verify: the `RESULT` line must show `code=0` and a height. Query the
   effect (`devops onchain <site> show`, or an LCD query).
5. Record: new ids (guild, substation, allocation, player) go into
   `site.yaml` `onchain:`; new accounts into `onchain.accounts` and
   `secrets:` using the pointer lines the account tools print.

## Commands reference

```bash
devops account list <guild>
devops tx <guild> guild_admin -- structs guild-update-endpoint -- <guild-id> https://<guild-host>/guild.json
devops tx <guild> guild_admin --broadcast --note "endpoint moved" -- structs guild-update-endpoint -- <guild-id> https://<guild-host>/guild.json
devops onchain <guild> show
devops onchain <guild> allocation-create 3-15 1000
devops account create-key <guild> ops_bot
devops account create-player <guild> scout_01 --username scout01
tail -5 reports/tx-log/$(date +%Y-%m-%d).tsv
```

## Verification

- `RESULT ... code=0 height=N`; the row is in `reports/tx-log/<date>.tsv`.
- The on-chain object reflects the change (`devops onchain <site> show`).

## Errors

| Error | Cause / fix |
|---|---|
| `FATAL: recovered X but the inventory expects Y` | the pointer loads a different mnemonic than `onchain.accounts.<a>.address`; fix the inventory, never print the key |
| `FATAL: node catching_up=true; refusing to broadcast` | the RPC node is behind: `devops check node-health <public-node>` |
| `account sequence mismatch` | another signer (TSA, a second session) used the account; wait a block and retry |
| `insufficient fees` / out of gas | raise `DEVOPS_GAS_ADJ` (default 1.5) |
| `RESULT ... code=unknown height=0 (not found after 90 s)` | not committed yet or dropped: `structsd query tx <hash>` before retrying (a retry can double-send) |
| `unknown flag` on an id | ids must follow the second `--` |
| `secret ... is not on a host` | hub-side signing is not supported; keys stay on hosts |

Never pass `--output json` to `structsd keys add`, and never capture stderr
of commands that recover keys.

## See also

- [docs/secrets.md](../../../docs/secrets.md) (how values are handled)
- [runbooks/deploy/new-guild.md](../../../runbooks/deploy/new-guild.md) (guild-create, substation, endpoint)
- `.references/structs-ai/.cursor/skills/` for gameplay message semantics
- `structs-governance`, `structs-inventory`
