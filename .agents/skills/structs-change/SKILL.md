---
name: structs-change
description: Makes a controlled change to Structs infrastructure (plan, baseline, dry run, approval, execute, verify, record) using devops procedures, patches, restarts or one-off gated commands. Use when anything on a host must change - config, patches, restarts, image or branch updates, env settings, Caddy, Postgres, the TSA, or the node.
disable-model-invocation: true
---

# Make a change

## Procedure

1. **Plan.** Write down: site, host, exactly what changes, why, expected
   effect, rollback, how to verify. Find the existing tool:
   `devops deploy <site> list`, `devops patches <site> list`,
   `devops restart`, `devops node`, `devops webapp`. Prefer these over raw
   commands; if nothing fits, add a procedure to `site.yaml` (`structs-deploy`).
2. **Baseline.** `devops health <site>`; note anything already red.
3. **Dry run.** Add `--dry-run` and show the user the plan.
4. **Approve.** Run it. On exit 10 show the Approval Block verbatim and wait
   for an explicit yes; then re-run with `--approve <token>` (and
   `--yes-public` on the public node). Never approve on the user's behalf.
5. **Execute** and watch the output. If a step fails, stop and investigate;
   resume with `--from-step N` only after understanding why it failed.
6. **Verify** with the checks the procedure or skill lists, then
   `devops health <site>` against the baseline.
7. **Record.** Update `site.yaml` (digests, commits, settings), add a dated
   line to the site `CHANGELOG.md`, `devops inventory render`, and
   `structs-handoff`.

## Invariants to re-check before step 4

- Restart, not recreate, unless the change needs a recreate.
- structsd recreate on the public node: app.toml must be re-applied.
- structs-pg: `--no-deps`; never `structs-pg-init`; never pin migrations.
- nginx: `$http_x_forwarded_for`, never `$proxy_add_x_forwarded_for`.
- Webapp pulls: `env-restore`, then `oidc-from-tel`; GA4 inserted, not overlaid.
- TSA: keep `TSA_WORKERS` and the accounts volume.
