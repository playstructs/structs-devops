---
name: structs-deploy
description: Deploys and changes Structs services through site procedures (webapp updates, TSA updates, structs.app updates, structs-pg recreate, structsd restart or recreate, Caddy restart, quick recovery) and builds new sites (local Docker stack, a new guild, a public node). Use when updating a service, pulling a new image or branch, applying patches, running a named procedure from site.yaml, or standing up new infrastructure.
---

# Structs deployments

A deployment is a **procedure**: a named list of steps in a site's
`site.yaml`, run by `devops deploy`. Steps are `tool` (a devops command),
`ssh` (on a stack's host), `local`, `backup`, `check`, and `confirm`. The
runner computes the highest tier, asks for one approval, writes a report to
`reports/runs/<date>/`, and stops on the first failed step or CRIT check.

## When to use

- Updating the webapp, TSA, structs.app, or an image; recreating structs-pg.
- Restarting a hung service (`quick-recovery`), restarting Caddy or structsd.
- Building a new site: [runbooks/deploy/](../../../runbooks/deploy/README.md).

## Decisions

| Need | Use |
|---|---|
| A procedure exists | `devops deploy <site> <procedure>` |
| Only restart containers | `devops restart <site> <service...>` (tier 2; never recreate) |
| Only re-apply patches | `devops patches <site> apply` (tier 1), then the printed restart |
| Only config on the archive node | `devops node <public-node> app-toml apply` |
| No procedure fits | write one in site.yaml first (see below), then dry-run it |
| New site | `devops site new <id> --kind ...`, then the matching runbook |

Prefer `restart` to recreate. A structsd recreate on the public node resets
app.toml (`structsd-recreate` re-applies it). Recreate structs-pg only with
`--no-deps` and never touch `structs-pg-init`.

## Procedure

1. `devops deploy <site> list` and read the procedure's steps.
2. Baseline: `devops health <site>`. Note anything already red.
3. `devops deploy <site> <procedure> --dry-run` and read the plan: every
   step with its tier, the exact command, and the stack host.
4. Run it without `--dry-run`. For tier 2+ it exits **10** with an Approval
   Block. Show the block to the user; when they say yes, re-run with
   `--approve <token>` (add `--yes-public` on the public node).
5. If a step fails, the runner prints the resume command
   (`--from-step N`). Investigate before resuming; do not skip steps.
6. Verify with the checks the procedure ends with, then `devops health <site>`.
7. Record: update `site.yaml` (image digests, source commits, env that
   matters), add a line to the site `CHANGELOG.md`, `devops inventory render`.

### Writing a procedure

```yaml
procedures:
  tsa-update:
    description: Pull and recreate the TSA (keeps TSA_WORKERS and the accounts volume).
    steps:
      - {tool: "debug snapshot <site>", tier: 0}
      - {backup: "/root/docker-structs-guild/compose.yaml"}
      - {ssh: "docker compose pull structs-tsa && docker compose up -d --no-deps structs-tsa", stack: guild-web, tier: 2}
      - {check: tsa-queue}
```

Each ssh/local step's tier is the higher of what you declare and what
`tools/agents/classify.py` assigns; steps that would expose secrets are refused.

## Commands reference

```bash
devops deploy <guild> list
devops deploy <guild> webapp-update --dry-run
devops deploy <guild> webapp-update                    # exit 10 + Approval Block
devops deploy <guild> webapp-update --approve <token>
devops deploy <guild> webapp-update --from-step 6 --approve <token>
devops restart <guild> structs-webapp structs-webapp-cache
devops ps <guild>; devops logs <guild> structs-tsa 200
```

## Verification

- The procedure's own `check` steps pass.
- `devops health <site>` has nothing new compared with the baseline.
- Webapp updates: `devops webapp <site> status` shows the expected ref and both
  `MATRIX_SIGNIN_CLIENT_ID` and `OIDC_ENCRYPTION_KEY` present;
  `devops patches <site> check` shows no drift; GA4 is in `base.html.twig`.

## Errors

| Symptom | Cause / fix |
|---|---|
| Login broken after a webapp pull | the tracked `.env` blanked OIDC keys: `devops webapp <site> env-restore`, then `oidc-from-tel` |
| Login 500 `inet` after cache changes | `$proxy_add_x_forwarded_for` crept in; must pass `$http_x_forwarded_for` |
| `PATCHES ... DRIFT` after an upstream pull | upstream moved the anchor; update the site manifest, never force-overlay stale files |
| TSA retry loop after update | `TSA_WORKERS` lost; keep it at the inventory value (`TSA_WORKERS` in the stack's `env:`) |
| Public node gRPC at localhost:9090 after recreate | `devops node <public-node> app-toml apply` |

## See also

- [runbooks/deploy/README.md](../../../runbooks/deploy/README.md) and the per-kind runbooks
- `structs-change` (workflow), `structs-migrations`, `structs-chain-upgrade`, `structs-inventory`
