# structs-devops

Operations framework for Structs infrastructure: guild stacks, public archive
nodes, validators, local Docker stacks, in whatever mix the operator's
inventory describes. This machine is the **hub**: it reaches hosts over
outbound ssh and the chain over public HTTPS; hosts never call back.
`bin/devops` (`devops help`) has helpers for the common jobs: health checks,
deploy procedures, patches, debugging, transactions. Use them when they fit;
plain `ssh`, `docker`, `git`, `psql` or anything else is fine when it gets
the job done better.

These instructions apply in any harness (Cursor, Claude Code, Codex, or a chat
with no shell). Skills live in `.agents/skills/<name>/SKILL.md`.

## Session protocol

1. **Orient.** Identify the site(s) and the intent. Read the operator's `inventory/AGENTS.md` (sites and current state; `devops context` prints it wherever the inventory lives) and the newest `inventory/reports/journal/*.md`.
2. **Route.** The skill for the intent (table below) has the context, known causes and commands that usually work. Use it as a guide, not a script.
3. **Do the work** however suits the task: `devops` helpers, `ssh <host> '<cmd>'`, `devops ssh <site> -- <cmd>`, editing files, SQL. A quick look (`devops health <site>`, `devops ps`, `devops logs`, `devops debug …`) before changing things usually saves time.
4. **Transactions are the exception:** anything that signs and broadcasts on chain (transfers, votes, guild and player actions, allocations) needs the user's explicit yes first. See below.
5. **Verify** the result (`devops health <site>`, the checks the skill names).
6. **Record.** Update `site.yaml` (versions, digests, commits), the site `CHANGELOG.md`, `known_issues`, or an incident report; then `devops inventory render`.
7. **Hand off.** `devops journal add` with what changed, what to watch, and open follow-ups.

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

## Transactions: the one thing that needs approval

Restarts, recreates, deploys, config edits, pushes and database writes need no
permission; tell the user what you did. On-chain transactions are different:
they are signed with the operator's keys and cannot be undone.

- Simulate first: `devops tx <site> <account> -- <module> <msg> …` (and
  `devops gov vote`, `devops onchain`, `devops account create-player`) simulates
  by default and prints signer, chain id, message and the simulation result.
- Broadcasting (`--broadcast`) exits **10** with an Approval Block. Show it to
  the user, get an explicit yes for that transaction, then re-run the same
  command with `--approve <token>` (single use, bound to that transaction,
  valid 10 minutes). Never approve on the user's behalf or reuse a token.
- The same applies to transactions sent any other way (`structsd tx` on a
  host, the REST or RPC broadcast endpoints): ask first.
- Governance votes are always the user's decision, one vote at a time.

Every command still carries a tier in `devops help` and the audit log
(0 read-only, 1 changes files with a backup, 2 affects running services,
3 on-chain transaction). Only tier 3 asks.

## Secrets

Secrets are pointers. Do not print or copy secret values into chat, files or
the hub (`cat .env`, `printenv`, `docker inspect …Env`, `userlist.txt`,
`priv_validator_key.json`, keyrings); check them with `devops secrets audit`
and change them on the host. Never `structsd keys add --output json` (prints the
mnemonic). `docs/secrets.md`.

## Known pitfalls

Hard-won facts about this stack. They explain what breaks, not how you must work.

- **Keep a copy before editing** a file on a host; the tools leave `*.bak.*` next to the file.
- **A structsd recreate resets the public node's app.toml:** re-apply with `devops node <public-node> app-toml apply`. A restart keeps it.
- **structs-pg:** recreate with `--no-deps`; never run `structs-pg-init` on a live site; migrations track `structs-pg` `main`, never re-pin to a commit.
- **nginx cache:** pass `X-Forwarded-For` from Caddy (`$http_x_forwarded_for`); never `$proxy_add_x_forwarded_for` (breaks login on the `inet` column).
- **Webapp pulls blank `MATRIX_SIGNIN_CLIENT_ID` and `OIDC_ENCRYPTION_KEY`:** `devops webapp <site> env-restore`, then `oidc-from-tel`. GA4 is inserted into the current `base.html.twig`, never overlaid.
- **TSA:** stays on `structs-pg:5432` (not the bouncer); keep its accounts volume; size `TSA_WORKERS` to the cores.
- **Public node:** `certbot renew --dry-run` runs its pre_hook, which stops Caddy; Caddy admin is off, so restart, not reload.
- **Never copy `priv_validator_key.json` to a second running node** (double-sign, tombstone).
- **SQL:** `devops debug pg` is a handy read-only session with a statement timeout; for writes use `psql` on the host and keep a copy of the rows you change. `EXPLAIN ANALYZE` executes the statement, so only on plain SELECTs. `devops debug snapshot` before a restart keeps evidence the restart would clear.

## Where things are

| Path | What |
|---|---|
| `inventory/` | the operator's own repo (git-ignored here; `devops init` creates it): `network.yaml`, `sites/<id>/site.yaml` (source of truth), patches, site runbooks, `pipelines/`, `reports/` (incidents, journal, runs, tx log, audit log). Format: `docs/inventory.md` |
| `networks/` | public network presets (chain facts shared by every operator) |
| `checks/`, `crons/` | read-only health checks and hub schedules (`docs/health-checks.md`, `docs/automations.md`) |
| `tools/` | everything `bin/devops` dispatches to; `tools/host/` runs on hosts (you can run those scripts directly too) |
| `runbooks/` | network runbooks and `runbooks/deploy/` |
| `docs/debugging/` | data flows, symptom index, Postgres reference |
| `examples/inventory/` | a fictional inventory: copy it to see the format, never point real work at it |
| `.references/` | read-only clones of the Structs repos (`devops refs status`); read code here, never deploy from it |

## No shell?

If you cannot run commands, propose commands one at a time, ask the user to
run them and paste the output, and reason from that. A transaction broadcast
prints an Approval Block for the user.
`devops agents bundle --site <id>` produces a single context file to paste.

## Your sites

The sites, endpoints, voters and per-site facts are in the operator's
`inventory/AGENTS.md` (its current-state block is generated by
`devops inventory render`). Read it before acting on any site; if the inventory
lives outside this folder, `devops context` prints it. No inventory yet:
`devops init`, then `structs-inventory`.
