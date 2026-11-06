# structs-devops

Operations framework for Structs infrastructure: guild stacks, public archive
nodes, validators, local Docker stacks, in whatever mix the operator's
inventory describes. This machine is the **hub**: it reaches hosts over
outbound ssh and the chain over public HTTPS; hosts never call back.
Everything goes through `bin/devops` (`devops help`).

These instructions apply in any harness (Cursor, Claude Code, Codex, or a chat
with no shell). Skills live in `.agents/skills/<name>/SKILL.md`.

## Session protocol

1. **Orient.** Identify the site(s) and the intent. Read the operator's `inventory/AGENTS.md` (sites and current state; `devops context` prints it wherever the inventory lives) and the newest `inventory/reports/journal/*.md`.
2. **Route.** Open the skill for the intent (table below) and follow it.
3. **Observe first.** Start with tier-0 commands: `devops health <site>`, `devops check <id> <site>`, `devops ps`, `devops logs`, `devops debug …`.
4. **Classify** the next action's tier. Tier 2+ needs an Approval Block and the user's explicit yes.
5. **Execute** through `bin/devops` wherever a tool exists, not ad-hoc ssh. For a one-off host command use `devops ssh <site> -- <cmd>` (classified and gated).
6. **Verify** with the checks the skill names.
7. **Record.** Update `site.yaml` (versions, digests, commits), the site `CHANGELOG.md`, `known_issues`, or an incident report; then `devops inventory render`.
8. **Hand off.** `devops journal add` with what changed, what to watch, and open follow-ups.

## Intent → skill

| Intent | Skill |
|---|---|
| Start a session / not sure | `structs-start` |
| Morning check, "is everything OK?" | `structs-daily-check`, `structs-health` |
| Something is broken or slow | `structs-investigate` → `structs-debug` (routes to `-postgres`, `-http`, `-chain`, `-indexer`, `-tsa`) |
| Change config, apply patches, restart, deploy a procedure | `structs-change`, `structs-deploy` |
| Upstream merged: update downstream repos and branches, deploy (`devops pipeline`) | `structs-dev-pipeline` (fixes: `structs-dev-anchors`, `-translations`, `-merge-upstream`) |
| Database migrations, structs-pg recreate | `structs-migrations` |
| Chain upgrade (proposal, staging, window, after) | `structs-upgrade-prep`, `structs-chain-upgrade` |
| Send a transaction, create keys or players | `structs-transactions` |
| Governance proposals and votes | `structs-vote`, `structs-governance` |
| Catalogue a site, record a change, new site | `structs-inventory` |
| Secrets: where they are, audits, rotation | `structs-secrets` |
| End of session | `structs-handoff` |

## Operation tiers (enforced by `bin/devops`)

| Tier | Meaning | Examples | Behaviour |
|---|---|---|---|
| 0 | read-only | health, checks, logs, ps, debug, gov list, tx simulate | runs |
| 1 | reversible, with backup | patches apply, app.toml apply, host sync, env-restore, cron install | runs, prints backup paths |
| 2 | service-affecting | restart, recreate, deploy procedures, oidc-from-tel, rotate node key | exit 10 + Approval Block + token |
| 3 | irreversible / on-chain / keys | tx --broadcast, gov vote, create-key, create-player | same, with signer, chain id, simulate output |

When a command exits **10** it printed an Approval Block. Show the block to
the user verbatim, ask for an explicit yes, and only then re-run the exact
command with `--approve <token>` (tokens are single-use, bound to the action,
valid 10 minutes). On the public node also add `--yes-public`. Never approve on
the user's behalf, never reuse a token, never rephrase the action to dodge a
block. A procedure (`devops deploy`) is approved once for all its tier ≤ 2 steps;
tier-3 steps still stop.

## Invariants

- **Secrets are pointers.** Never read, print or copy a secret value (`cat .env`, `printenv`, `docker inspect …Env`, `userlist.txt`, `priv_validator_key.json`, keyrings). `docs/secrets.md`.
- **Simulate before broadcasting.** `devops tx` always simulates; never `structsd keys add --output json`; never capture tx stderr.
- **Votes are never automatic.** Crons remind; a person decides each vote.
- **Back up before editing** any file on a host; tools do this (`*.bak.*` next to the file).
- **Restart before recreate.** A structsd recreate resets the public node's app.toml: re-apply with `devops node <public-node> app-toml apply`.
- **structs-pg:** recreate with `--no-deps`; never run `structs-pg-init` on a live site; migrations track `structs-pg` `main`, never re-pin to a commit.
- **nginx cache:** pass `X-Forwarded-For` from Caddy (`$http_x_forwarded_for`); never `$proxy_add_x_forwarded_for` (breaks login on the `inet` column).
- **Webapp pulls blank `MATRIX_SIGNIN_CLIENT_ID` and `OIDC_ENCRYPTION_KEY`:** `devops webapp <site> env-restore`, then `oidc-from-tel`. GA4 is inserted into the current `base.html.twig`, never overlaid.
- **TSA:** stays on `structs-pg:5432` (not the bouncer); keep its accounts volume; size `TSA_WORKERS` to the cores.
- **Public node:** never `certbot renew --dry-run` (its pre_hook stops Caddy); Caddy admin is off, so restart, not reload.
- **Never copy `priv_validator_key.json` to a second running node** (double-sign, tombstone).
- **Debug read-only:** SQL through `devops debug pg` (READ ONLY, statement timeout); `EXPLAIN ANALYZE` only on plain SELECTs; snapshot (`devops debug snapshot`) before restarting anything.

## Where things are

| Path | What |
|---|---|
| `inventory/` | the operator's own repo (git-ignored here; `devops init` creates it): `network.yaml`, `sites/<id>/site.yaml` (source of truth), patches, site runbooks, `pipelines/`, `reports/` (incidents, journal, runs, tx log, audit log). Format: `docs/inventory.md` |
| `networks/` | public network presets (chain facts shared by every operator) |
| `checks/`, `crons/` | read-only health checks and hub schedules (`docs/health-checks.md`, `docs/automations.md`) |
| `tools/` | everything `bin/devops` dispatches to; `tools/host/` runs on hosts |
| `runbooks/` | network runbooks and `runbooks/deploy/` |
| `docs/debugging/` | data flows, symptom index, Postgres reference |
| `examples/inventory/` | a fictional inventory: copy it to see the format, never point real work at it |
| `.references/` | read-only clones of the Structs repos (`devops refs status`); read code here, never deploy from it |

## No shell?

If you cannot run commands, propose `bin/devops` commands one at a time, ask
the user to run them and paste the output, and reason from that. The same
tiers apply: a tier-2+ command will print an Approval Block for the user.
`devops agents bundle --site <id>` produces a single context file to paste.

## Your sites

The sites, endpoints, voters and per-site facts are in the operator's
`inventory/AGENTS.md` (its current-state block is generated by
`devops inventory render`). Read it before acting on any site; if the inventory
lives outside this folder, `devops context` prints it. No inventory yet:
`devops init`, then `structs-inventory`.
