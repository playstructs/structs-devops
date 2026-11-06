---
name: structs-chain-upgrade
description: Runs a structsd chain upgrade end to end across every node in the inventory (proposal tracking, staging the new binary, the upgrade window, post-upgrade checks, inventory bump), and recovers from cosmovisor problems. Use when a software-upgrade proposal appears or passes, an upgrade plan is on chain, a new structsd release or image is published, the upgrade height is near, or a node halted at an upgrade height.
---

# Structs chain upgrades

structsd runs under cosmovisor. A new image carries the new binary at
`/opt/structs/cosmovisor/upgrades/<name>/bin/structsd`; recreating the
container installs it into the volume (`upgrades/<name>`). At the plan
height the chain halts, cosmovisor flips `current` to `upgrades/<name>` and
restarts. Every node in the inventory (validators and the public archive
node) needs the binary staged **before** the height.

## When to use

- `upgrade-watch` or `gov-watch` notified about a software-upgrade proposal or plan.
- `new-releases` reports a new structsd tag or image digest.
- A node is stuck at the upgrade height or logs `UPGRADE NEEDED`.

## Decisions

| Phase | What to do |
|---|---|
| Proposal in voting | vote (`structs-governance`); start preparing |
| Plan on chain, > 24 h out | stage: pull the new image, verify, recreate each node (tier 2) |
| < 3 h out | `devops upgrade monitor install <site>` on each node host (tier 1) |
| At height | watch; do not restart nodes while cosmovisor swaps |
| After | post-checks, app.toml on the public node, inventory bump |
| Node halted, binary missing | stage the binary (recreate with the new image); see the recovery runbook |

## Procedure

1. **Read the plan.** `devops upgrade status` (plan name, height, ETA, staged
   or not on every node) and `devops gov show <id>`.
2. **Verify the release.** `devops refs sync structsd` and read the release
   notes / `app/upgrades/<name>`; `devops check new-releases` shows the image
   digest. Confirm the image contains `upgrades/<name>` and that
   `upgrades.conf.sh` has `"<name>:<height>"` (commands in the runbook).
3. **Preflight each site.** `devops upgrade preflight <site>`: in sync, disk
   room, binary staged.
4. **Stage.** For each node, run the site's recreate procedure
   (`devops deploy <public-node> structsd-recreate`, or the guild's structsd
   step from [runbooks/chain-upgrade.md](../../../runbooks/chain-upgrade.md)).
   Re-run preflight until it says `binary for <name> staged`.
5. **Window.** Install the monitors a few hours before:
   `devops upgrade monitor install <site>`; follow with
   `devops upgrade monitor tail <site>`. Keep the user informed of ETA.
6. **After the height.** `devops health network`, `devops check node-health <site>`
   for each node, `devops check height-agreement`. On the public node:
   `devops node <public-node> app-toml check` (apply if drifted).
7. **Record.** In `inventory/network.yaml`: `binary.version`, `since_height`,
   `cosmovisor_current`, append to `upgrades[]`, update `images.structsd`.
   Update each site's CHANGELOG, `devops inventory render`, then
   `devops upgrade monitor stop <site>`.

## Commands reference

```bash
devops upgrade status
devops upgrade preflight <guild>
devops gov show 7
devops deploy <public-node> structsd-recreate --dry-run
devops upgrade monitor install <public-node>
devops upgrade monitor tail <public-node> 50
devops node <public-node> status
devops check height-agreement
```

## Verification

- Every node: `cosmovisor_current` is `upgrades/<name>`, height advancing,
  `catching_up=false`, versions match (`devops node <site> status`).
- `height-agreement` OK; validators signing (`devops check validator <site>`).
- `upgrade-plan` check shows the plan applied; inventory updated.

## Errors

| Symptom | Fix |
|---|---|
| `UPGRADE NEEDED` and the node exits in a loop | binary not staged: recreate with the new image; [runbooks/cosmovisor-recovery.md](../../../runbooks/cosmovisor-recovery.md) |
| `current` symlink flipped but daemon still old | the symlink race: follow the cosmovisor recovery runbook |
| Public node gRPC on localhost:9090 after recreate | `devops node <public-node> app-toml apply` |
| `AppHash` / `LastResultsHash` mismatch after upgrade | stop; compare nodes (`devops debug compare-nodes <height>`); `structs-debug-chain` |

## See also

- [runbooks/chain-upgrade.md](../../../runbooks/chain-upgrade.md), [runbooks/cosmovisor-recovery.md](../../../runbooks/cosmovisor-recovery.md)
- [docs/automations.md](../../../docs/automations.md) (upgrade lifecycle), `structs-upgrade-prep` (workflow), `structs-governance`
