---
name: structs-start
description: Starts a Structs infrastructure session by walking the session protocol (orient on current state and the latest journal, identify site and intent, route to the right skill, observe before changing). Use when beginning any conversation about Structs infrastructure, picking up from a previous session, or when unsure where to start.
disable-model-invocation: true
---

# Start a session

## Procedure

1. **Orient.**
   - `devops context`: your inventory's `AGENTS.md` (chain version, sites,
     what runs where, known issues, site rules) and the latest journal
     hand-off (what changed, what to watch, open follow-ups).
   - No inventory yet (`devops context` says so): `devops init`, then
     `structs-inventory` to describe the first site.
   - `devops cron status` (when the scheduled checks last ran; gaps mean the hub was off).
   - If the last scheduled run is older than a few hours: `devops health all`.
2. **Identify the site(s) and the intent.** Ask the user if it is not clear.
   Intents: observe, diagnose, change, deploy, migrate, upgrade, transact,
   vote, catalogue, secrets.
3. **Route** with the intent table in `AGENTS.md` and open that skill.
4. **Get going.** A quick look with the read-only commands the skill lists
   usually shows the cause fast; then do the work, with `devops` helpers or
   directly on the host, whichever is quicker.
5. Tell the user, in two or three sentences: the state of the sites that
   matter for this request, anything already red, and what you did or are
   doing next.

## For the whole session

- On-chain transactions (sends, votes, guild and player actions) need the
  user's explicit yes; `devops tx` and friends simulate first and print an
  Approval Block. Nothing else needs permission.
- Keep secret values out of chat and files; `devops secrets audit` checks them.
- Record what changed (inventory, CHANGELOG, incident report) and finish
  with `structs-handoff`.
