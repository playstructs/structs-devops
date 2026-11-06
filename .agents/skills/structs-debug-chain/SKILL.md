---
name: structs-debug-chain
description: Debugs structsd nodes (the public archive node and guild validators) running under cosmovisor in Docker. Covers the "healthy stall" (RPC 200, catching_up false, old blocks), LastResultsHash and AppHash consensus failures, header comparison across nodes, the cosmovisor UPGRADE NEEDED symlink race, duplicate node_key pong timeouts, odd-length-hex peer crash loops, gRPC reset to localhost after a recreate, and transactions hanging on a catching-up node. Use when block height stops advancing, nodes disagree, a node crash-loops, gRPC or LCD stops working, or transactions do not land.
---

# Debugging structsd nodes

Nodes: `devops node <site> status`; the inventory lists every node under
`nodes:` in each site. The guilds index from the public node, so a public
node stall shows up as stale data everywhere.

## When to use

- `block-progress` or `node-health` is CRIT, or users report a frozen chain.
- `height-agreement` WARN: nodes report different heights.
- structsd restarts in a loop, or after an upgrade height.
- After a recreate: gRPC, swagger, CORS or pruning changed (public node).

## Decisions

| Situation | First command |
|---|---|
| Height not advancing | `devops check block-progress`, `devops node <site> status` |
| Nodes disagree | `devops debug compare-nodes` (default: public tip − 2) |
| Crash loop | `devops logs <site> structsd 300` |
| Around an upgrade | `devops upgrade status`, `structs-chain-upgrade` |
| gRPC/LCD/swagger broken on the public node | `devops check app-toml <public-node>` |

## Procedure

1. **Is the chain moving?** `devops check block-progress` compares block time
   with now. HTTP 200, `catching_up=false` and a healthy container do **not**
   mean the node is advancing.
2. **Snapshot before any restart:** `devops debug snapshot <site>`, then read
   `node.txt`: status, peers, the cosmovisor `current` link, and the
   consensus signatures grep.
3. **Compare nodes:** `devops debug compare-nodes <height>` around the
   frozen height. The header at H+1 commits to H's results
   (`last_results_hash`) and state (`app_hash`); the node that differs from
   the network executed H differently.
4. Match the signatures below. Consensus failures are evidence: keep the
   node stopped at the bad height until the data is collected and the
   maintainers have it (see the 2026-09-13 incident).
5. Recovery steps that rewrite chain data (rollback, resync, resetting
   state) are tier 3 and need explicit approval.

## Signatures

| Log or observation | Cause | Fix |
|---|---|---|
| `wrong Block.Header.LastResultsHash`, then `CONSENSUS FAILURE!!!`; RPC still serves the frozen height | This node computed different block results (events, gas) for the previous height | Collect evidence (seen 2026-09-13: one node froze while the others moved on), compare nodes, roll back one height or resync [3] |
| `wrong Block.Header.AppHash` | State divergence | Same as above; never `unsafe-reset-all` without a backup [3] |
| `UPGRADE "v0.X.0" NEEDED at height …`, node exits repeatedly | `cosmovisor/current` still on the old binary | [runbooks/cosmovisor-recovery.md](../../../runbooks/cosmovisor-recovery.md) fix path 1 [2] |
| Pong timeouts, peer churn, frozen height, RAM fine | Two live nodes share `config/node_key.json` (copied chaindata) | `devops node <site> rotate-node-key` on the copy [2] |
| `encoding/hex: odd length hex string` crash loop | Typo in `persistent_peers` or `seeds` (ids are 40 hex chars) | Fix the peer list [2] |
| `nc :9090` connects, gRPC calls hang or reset | `[grpc] address` back to `localhost:9090` after a recreate | `devops node <public-node> app-toml apply` [1], restart structsd [2] |
| swagger 404, CORS gone, pruning reset after a recreate | `network-config.sh` re-templated `app.toml` | Same as above; [runbooks/post-recreate-app-toml-fix.md](../../../runbooks/post-recreate-app-toml-fix.md) |
| `devops tx` refuses: `node catching_up=true` | The broadcast node is syncing | Use a synced node; wait |
| Validator `missed blocks` climbing | Validator node stalled or not signing | `devops check validator <site>`; the same steps as a stall |

## Commands reference

```bash
devops check block-progress                 # network: block age on the public RPC
devops check height-agreement               # network: every node vs the public node
devops node <public-node> status           # height, peers, cosmovisor current, disk
devops debug compare-nodes                  # tip - 2 and tip - 1
devops debug compare-nodes 2586840          # a specific height
devops debug snapshot <public-node>        # node.txt has the consensus grep
devops logs <public-node> structsd 500
devops upgrade status                       # plan, ETA, staged binaries
```

## Verification

Height advances again (`block-progress` OK), `compare-nodes` reports all
reachable nodes agree, `height-agreement` OK, and for the public node the
dependent sites' `sync-lag` returns to OK.

## Errors

| Output | Meaning |
|---|---|
| `unavailable (pruned, down or ssh failed)` in compare-nodes | the node no longer keeps that height, is down, or ssh failed; pick a recent height |
| `MISMATCH at H` | stop and collect evidence before restarting |
| `node-health UNKNOWN` | the node's local RPC did not answer from its host |

## See also

- `structs-chain-upgrade`, `structs-upgrade-prep`, `structs-debug` (router)
- [docs/reference/public-node-config.md](../../../docs/reference/public-node-config.md),
  [docs/reference/pruning-and-archive.md](../../../docs/reference/pruning-and-archive.md),
  [runbooks/deploy/public-node.md](../../../runbooks/deploy/public-node.md)
