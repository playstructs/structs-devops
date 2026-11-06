---
name: structs-upgrade-prep
description: Prepares every node for a pending Structs chain upgrade (proposal and plan review, release and image verification, per-site preflight, staging schedule, monitors, and a checklist for the window). Use when a software-upgrade proposal is in voting or has passed, upgrade-watch sends a milestone notification, or the user asks to get ready for an upgrade.
disable-model-invocation: true
---

# Prepare for a chain upgrade

## Procedure

1. **Plan facts.** `devops upgrade status` (name, height, ETA) and
   `devops gov show <id>`. If the proposal is still voting, run `structs-vote` too.
2. **Release review.** `devops refs sync structsd`, then
   `git -C .references/structsd log --oneline <deployed-commit>..<tag>` (the
   deployed commit is `binary.git_commit` in `inventory/network.yaml`). Read
   `app/upgrades/<name>` for migrations and state changes. Note anything
   that affects guild services (new messages, removed queries, schema changes
   that need structs-pg, TSA or webapp releases).
3. **Image.** `devops check new-releases`: the `structs/structsd` digest.
   Confirm the image ships `upgrades/<name>/bin/structsd` and
   `upgrades.conf.sh` has `"<name>:<height>"` (commands in
   `runbooks/chain-upgrade.md`).
4. **Preflight each node site:** `devops upgrade preflight <site>` for every
   site with `nodes:` (the current-state table in `inventory/AGENTS.md`).
5. **Staging schedule.** Propose to the user when to recreate each node
   (public node last, outside busy hours, ≥ 24 h before the height), with the
   procedure names (`devops deploy <site> list`).
6. **Window checklist** (give it to the user):
   - T-3 h: `devops upgrade monitor install <site>` for each node site.
   - T-30 min: `devops upgrade monitor tail <site>`; nobody restarts nodes.
   - Height: watch `devops upgrade status` until every node runs `<name>`.
   - After: `devops health network`, `devops check height-agreement`,
     `devops node <public-node> app-toml check`, validators signing.
   - Record: `network.yaml` binary/upgrades/images, CHANGELOGs, render,
     `devops upgrade monitor stop <site>`.
7. `devops journal add --title "upgrade <name> prep" "<what is staged, what is left>"`.

Staging itself is a change: run it through `structs-change` / `structs-chain-upgrade`.
