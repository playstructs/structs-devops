---
name: structs-vote
description: Walks the user through voting on open Structs governance proposals for each inventory voter (summarize, get the user's decision, simulate, approve, broadcast, verify). Use when proposals are in voting, gov-pending or gov-watch reminds about missing votes, or the user asks to vote.
disable-model-invocation: true
---

# Vote on proposals

## Procedure

1. `devops gov list`: open proposals and each voter's status.
2. For each proposal with a missing vote, `devops gov show <id>` and give the
   user a short brief: what it does, deadline, current tally, and for an
   upgrade the height and ETA. Point out risks; do not recommend an option
   unless asked, and never choose one.
3. Ask for the decision per proposal and per voter (`yes`, `no`, `abstain`,
   `no_with_veto`).
4. Simulate: `devops gov vote <id> <option> --as <site>.<account>`.
5. Broadcast: same command with `--broadcast`. Show the Approval Block; after
   an explicit yes, re-run with `--approve <token>`. One approval per vote.
6. `devops gov verify <id>` must exit 0.
7. If it was an upgrade proposal, continue with `structs-upgrade-prep`.
8. `devops journal add --title "gov votes" "<id: option per voter>"`.
