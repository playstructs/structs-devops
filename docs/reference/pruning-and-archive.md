# Pruning and "full archive" — the nuance

This page exists because the phrase "no trimming of data" means at least two different things in Cosmos SDK terms, and getting it wrong leads to surprises 6 months later when someone asks for historical state.

## Two independent data stores

A Cosmos SDK node keeps two storage layers, with **independent** retention rules:

1. **Blockstore** (`data/blockstore.db`) — block headers + bodies + tx results.
   - Controlled by `min-retain-blocks` in `app.toml`.
   - **Never affected by `pruning` setting.**
   - `min-retain-blocks = 0` (the default) → keep all blocks forever.
   - This is what enables "give me the contents of block 100,000" and `tx` history queries.

2. **Application state / IAVL** (`data/application.db`, `data/state.db`) — account balances, module state, validator set, etc., snapshotted per height.
   - Controlled by `pruning` in `app.toml`.
   - This is what enables historical state queries: "balance of address X at height 100,000".

So you can have all blocks intact while still only being able to query *state* for the last 10 minutes.

## `pruning` settings

| Setting | Behavior |
|---|---|
| `"default"` | Keep last 362,880 heights of state + every 100th height. ~30 days of full state at 6s/block. |
| `"everything"` | Keep last 2 heights only, prune every 10. Aggressive — for relayers / signers that only need current state. |
| `"nothing"` | Never prune. **True full archive.** Disk grows unbounded — plan for it. |
| `"custom"` | Use `pruning-keep-recent` and `pruning-interval` literally. |

`pruning-keep-recent`: how many of the most-recent heights of state to keep on disk.
`pruning-interval`: how often (in blocks) to actually run a prune pass.

## What the public node is set to now (2026-06-14)

```toml
pruning = "nothing"
pruning-keep-recent = "0"        # ignored when pruning=nothing
pruning-interval = "0"           # ignored when pruning=nothing
min-retain-blocks = 0            # keep all blocks (default)
```

So from this restart forward, all state is retained.

## ⚠️ Past pruning is irreversible

Setting `pruning="nothing"` at height H means:

- State at heights ≥ H will be kept forever.
- State at heights < H **that was already pruned by previous settings is gone.** No amount of config will bring it back.

This node ran with `pruning="custom" keep-recent=10000` for most of its life, which means state for heights more than ~10,000 blocks behind the current tip was being pruned continuously. Specifically:

- At the moment of the pruning switch (around height 1,156,500), state for heights below roughly `1,156,500 − 10,000 = 1,146,500` had already been pruned and is unrecoverable.
- All historical state queries to `height < ~1,146,500` will return `state at height X is pruned` errors.
- All historical state queries to `height ≥ ~1,146,500` (with some imprecision for in-flight intervals) will work fine.
- All block / tx queries to any past height will work fine because `blockstore.db` was never pruned.

## How to get a TRUE genesis-to-tip archive

If/when you actually need every historical state from block 1 onward:

1. Provision a new volume.
2. Start a fresh container with `pruning="nothing"` from the very first run.
3. Full-sync from genesis (no state-sync snapshot). This took ~hours on this hardware last time and produces a large (10s of GB) IAVL store. With pruning off, expect that to grow significantly over time.
4. Once caught up, you can switch traffic to the archive node and either keep the original as a "fast" pruned node or retire it.

## What about state-sync snapshots?

`[state-sync] snapshot-interval` and `snapshot-keep-recent` in app.toml are about THIS node producing snapshots for OTHER nodes to consume — not about consuming snapshots ourselves. We set them to `1000` / `5` so peers that want a fast bootstrap can grab from us. This is independent of pruning.

`[statesync]` in `config.toml` is about THIS node consuming someone else's snapshot at startup. We have it `enable = false` because we full-sync from genesis.

## Disk-usage sanity check

```bash
ssh root@<public-node-ip> \
  'du -sh /var/lib/docker/volumes/structsd-chaindata/_data/data/{application,blockstore,state}.db 2>/dev/null'
```

As of 2026-06-14 the total `data/` was 8.4 GB. Growth rate under `pruning=nothing` will be considerably higher than under `pruning=custom keep-recent=10000`. Watch it for the first few weeks and decide whether to spec a larger volume or accept the cost.
