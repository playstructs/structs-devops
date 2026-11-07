---
name: structs-change
description: Makes a change to Structs infrastructure and keeps the record straight (plan, baseline, do it, verify, record), using devops procedures, patches and restarts where they fit or direct commands on the host where they do not. Use when anything on a host must change - config, patches, restarts, image or branch updates, env settings, Caddy, Postgres, the TSA, or the node.
disable-model-invocation: true
---

# Make a change

## Procedure

1. **Plan.** Know the site, host, what changes, why, how you will tell it
   worked and how you would undo it. Helpers that may already do it:
   `devops deploy <site> list`, `devops patches <site> list`,
   `devops restart`, `devops node`, `devops webapp`. Use them when they fit;
   otherwise work on the host directly (`ssh`, `docker compose`, editing
   files). A change you will repeat is worth a procedure in `site.yaml`
   (`structs-deploy`).
2. **Baseline.** `devops health <site>`; note anything already red.
3. **Do it.** `--dry-run` shows what a helper would run. Keep a copy of any
   file you edit by hand. If something fails, find out why before retrying;
   procedures resume with `--from-step N`.
4. **Verify** with the checks the procedure or skill lists, then
   `devops health <site>` against the baseline.
5. **Record.** Update `site.yaml` (digests, commits, settings), add a dated
   line to the site `CHANGELOG.md`, `devops inventory render`, and
   `structs-handoff`. Tell the user what you changed.

If the change includes an on-chain transaction, that one step needs the
user's approval (`structs-transactions`); everything else does not.

## Pitfalls worth a glance

- Restart, not recreate, unless the change needs a recreate.
- structsd recreate on the public node: app.toml must be re-applied.
- structs-pg: `--no-deps`; never `structs-pg-init`; never pin migrations.
- nginx: `$http_x_forwarded_for`, never `$proxy_add_x_forwarded_for`.
- Webapp pulls: `env-restore`, then `oidc-from-tel`; GA4 inserted, not overlaid.
- TSA: keep `TSA_WORKERS` and the accounts volume.
