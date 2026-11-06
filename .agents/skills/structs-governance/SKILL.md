---
name: structs-governance
description: Tracks Structs governance proposals and casts votes for the inventory's voter accounts (list, show, verify, vote with simulate and a tier-3 approval). Use when a proposal is in deposit or voting, gov-watch or gov-pending reports outstanding votes, a software-upgrade proposal appears, or someone asks how our accounts voted.
---

# Structs governance

Voters are listed in `inventory/network.yaml` under `gov.voters`
(`site` + `account`); their addresses come from each site's
`onchain.accounts`. **Votes are never automatic.** Crons only remind
(`gov-watch` every 6 h, `gov-pending` daily, CRIT under 24 h left). A person
decides every vote, and the vote is signed on the host holding the key.

## When to use

- A notification about a new proposal or pending votes.
- A software-upgrade proposal (also start `structs-chain-upgrade`).
- "How did we vote on #N?", "Is anything waiting for us?"

## Decisions

| Situation | Action |
|---|---|
| New proposal | `devops gov show <id>`: messages, plan height and ETA, tally, deadline |
| Upgrade proposal | check the release (`devops refs sync structsd`, notes) before voting |
| User decided | `devops gov vote <id> <option> --as <site>.<account>` then `--broadcast` |
| Several voters | one vote per voter; each is its own approval |
| Unsure | present the facts and ask; do not pick an option for the user |

Options: `yes`, `no`, `abstain`, `no_with_veto`.

## Procedure

1. `devops gov list`: proposals in deposit and voting, with each voter's
   current vote or `NOT VOTED`.
2. `devops gov show <id>`. For an upgrade, note the plan name and height,
   and compute the window with `devops upgrade status` once it passes.
3. Present a short summary to the user: what it does, deadline, how other
   validators are voting (tally), and any risk. Ask for the decision.
4. Simulate: `devops gov vote <id> <option> --as <site>.<account>`.
5. Broadcast: add `--broadcast`; show the Approval Block; after an explicit
   yes, re-run with `--approve <token>`.
6. `devops gov verify <id>`: exits 0 when every inventory voter has voted.

## Commands reference

```bash
devops gov list
devops gov show 8
devops gov vote 8 yes --as <guild>.guild_admin
devops gov vote 8 yes --as <guild>.guild_admin --broadcast
devops gov verify 8
devops check gov-pending
devops cron run gov-watch
```

## Verification

`devops gov verify <id>` exits 0 and `devops gov list` shows the option for
each voter. The tx is in `reports/tx-log/<date>.tsv`.

## Errors

| Error | Fix |
|---|---|
| `inactive proposal` | voting closed; nothing to do |
| voter missing from list | add it to `gov.voters` and `onchain.accounts` (`structs-inventory`) |
| `account sequence mismatch` | another signer used the account; retry after a block |
| vote shows NOT VOTED after broadcast | check `RESULT code`; LCD can lag a block |

## See also

- `structs-vote` (workflow), `structs-chain-upgrade`, `structs-transactions`
- [docs/automations.md](../../../docs/automations.md) (gov-watch, reminders)
