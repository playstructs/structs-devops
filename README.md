# structs-devops

A framework for running Structs infrastructure: guild stacks, public archive
nodes, validators, and local Docker stacks, in whatever mix you run. One
machine (the **hub**, usually your laptop) holds your inventory, the tools and
the schedules, and reaches every host over outbound ssh. Hosts never call
back, so a hub on a home network works.

The framework knows nothing about any one operator. What you run lives in your
**inventory**, a separate repo you keep private or not: sites, hosts, secret
pointers, patches, pipelines, incidents and run reports. By default it is
`inventory/` (git-ignored here); `DEVOPS_INVENTORY` can point anywhere.
`examples/inventory/` is a fictional one (a guild, a public node, a local
stack) to read before writing your own.

## Quick start

```bash
./setup.sh                       # tools, .devops.env, .references, harness adapters, doctor
devops init                      # your inventory repo, from templates/inventory (once)
devops site new <id> --kind guild --fqdn <host> --ssh root@<host>
devops doctor                    # hub tools + BatchMode ssh to every host
devops health all                # hourly checks across every site
devops checks                    # the check catalog
devops deploy <guild> list       # site procedures
```

`setup.sh` links `bin/devops` into `~/.local/bin` (add it to `PATH`) or run
`./bin/devops` directly. Options: `--refs core|all|none`,
`--harness auto|cursor,claude,codex|all|none`, `--non-interactive`.

Requirements on the hub: bash (macOS 3.2 is fine), `git`, `curl`, `jq`,
`yq` (mikefarah v4), `python3` (standard library only), `perl`, `openssl`,
`ssh`. Optional: `shellcheck`, `nc`. On hosts: bash 5, Docker with the compose plugin, `jq`,
`python3`, `curl`.

## What is in here

| Area | What it gives you |
|---|---|
| **Inventory** (your repo) | A YAML cataloguing format for sites, hosts, stacks, services, image digests, source pins, endpoints, TLS, on-chain ids, secret pointers, procedures, thresholds and known issues; validated and rendered into READMEs and the inventory's `AGENTS.md`. Public chain facts come from a preset in `networks/`. Spec: `docs/inventory.md`. |
| **Secrets** | Pointers only (`host-env`, `host-file`, `host-volume`, `local-env`). Audits use `test`/`stat`/`grep -c`. Signing happens on the host. `docs/secrets.md`. |
| **Checks** (`checks/`) | 23 read-only checks: host resources, block progression, height agreement, containers, endpoints, TLS expiry, Postgres, TSA queue, sync lag, PgBouncer, Apache, validator, patch drift, app.toml, certbot, archive growth, governance, upgrades, new releases, inventory freshness. `docs/health-checks.md`. |
| **Crons** (`crons/`) | Hub schedules (launchd or crontab): hourly health, daily network, TLS, new updates, governance reminders, the chain-upgrade lifecycle, a weekly digest. Gaps while the hub sleeps are reported, not hidden. `docs/automations.md`. |
| **Change tools** | Anchored patch engine with backups and drift checks, app.toml overrides, webapp helpers (env restore, OIDC, GA4), restarts, procedures (`devops deploy`). |
| **Chain tools** | `devops tx` (simulate, then broadcast after the user approves, with on-host signing), `devops gov` (list, show, verify, vote), `devops onchain`, `devops account` (create keys and players on the host). |
| **Debugging** | `devops debug snapshot|pg|http-trace|nginx-top|compare-nodes|grass-tap|oidc-probe`, SQL packs for structs-pg, and `docs/debugging/` (data flows, symptom index). |
| **Dev pipelines** (`inventory/pipelines/`) | When an upstream branch moves, prepare every consumer in hub-local clones (submodule bumps, sed-anchor and translation checks, merges, builds), let an agent fix what fails, then push, tag and deploy one approval at a time. `docs/pipelines.md`. |
| **Agents** | `AGENTS.md` + `.agents/skills/` work in Cursor, Claude Code and Codex; a command guard and the transaction gate give every harness the same two rules: transactions ask first, secret values are never printed. |
| **Publishing** | `devops publish-check` fails if a framework file names anything from your inventory (site and host ids, hostnames, IPs, addresses, branches), so fixes can go upstream without leaking your setup. |
| **References** (`.references/`) | Read-only clones of the Structs repos for reading code and diffing upstream (`devops refs sync|status`). |

## Safety model

The `devops` commands are helpers, not the only way in: people and agents can
also work on hosts directly with ssh, docker, git or psql. One thing always
asks first: an on-chain transaction (sends, votes, guild and player actions).
`devops tx` and the commands built on it simulate, then stop with an Approval
Block and a single-use token (or a prompt at a terminal), and the agent hooks
ask before any raw broadcast. Every command carries a tier for the record
(0 read-only, 1 changes files with a backup, 2 affects running services,
3 transaction), and tier 1+ actions are logged to `inventory/reports/audit.log`.
Secrets stay pointers: their values are never printed or copied to the hub.

## Your inventory

`devops init` creates `inventory/` from `templates/inventory/` and runs
`git init` there (no commit, no remote): push it wherever you keep private
repos. To keep it outside this folder, `devops init /path/to/inventory` and set
`DEVOPS_INVENTORY=/path/to/inventory` in `.devops.env`. Add sites with
`devops site new`, then `devops inventory validate` and `render`.
`devops context` prints what an agent reads first. Before you push a change to
the framework itself, run `devops publish-check`.

## Layout

```
bin/devops            CLI dispatcher (devops help)
lib/                  hub libraries (bash 3.2)
tools/                command implementations; tools/host/ runs on hosts (bash 5)
checks/  crons/       health checks and schedules
networks/             public network presets (chain facts shared by every operator)
inventory/            YOUR repo (git-ignored): network.yaml, sites/, pipelines/, reports/, tools/host/
examples/inventory/   a fictional inventory to copy from
runbooks/  docs/      procedures, references, debugging guides
templates/            inventory and site skeletons, runbook and incident templates
.agents/skills/       operations, debugging and workflow skills
.references/          upstream clones (git-ignored)
state/  local/        hub-local state and secrets (git-ignored)
```

## License

Apache License 2.0, the same as structsd and the other Structs repositories.
See [LICENSE](LICENSE). Your inventory is your own and is not covered by it.
