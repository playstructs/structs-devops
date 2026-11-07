# Procedures (`devops deploy`)

A procedure is a named, ordered list of steps in a site's `site.yaml`: a
repeatable recipe for a change you make often. The runner shows the plan,
runs each step, writes a report, stops at the first failure and tells you how
to resume. One-off changes are fine to make by hand.

```bash
devops deploy <guild> list
devops deploy <guild> webapp-update --dry-run       # numbered plan, effective tiers, nothing runs
devops deploy <guild> webapp-update                 # runs it
devops deploy <guild> webapp-update --from-step 6   # resume after fixing a failed step
```

## Step types

```yaml
procedures:
  tsa-update:
    description: Pull and recreate the TSA (keeps TSA_WORKERS=6 and the accounts volume).
    steps:
      - {tool: "debug pg <guild> signer-queue", tier: 0}         # any devops command
      - {backup: "/root/docker-structs-guild/.env"}               # cp -a FILE FILE.bak.devops-<stamp>
      - {confirm: "Queue drained or acceptable to pause?"}        # asked at a terminal; a printed reminder for agents
      - {ssh: "docker compose pull structs-tsa && docker compose up -d --no-deps structs-tsa", stack: guild-web, tier: 2}
      - {local: "docker compose -p structs-local ps", tier: 0}    # on the hub, from the workspace root
      - {check: tsa-queue}                                        # CRIT/UNKNOWN stops, WARN continues
```

- `ssh` steps run on the stack's host, inside the stack's `path`. Without `stack:` they run on the site's primary host from `$HOME`.
- A step's **effective tier** is the higher of its declared `tier` and what `tools/agents/classify.py` says about its command; it labels the plan and the report.
- Steps that would read secret material are refused at plan time.
- Only a step that sends an on-chain transaction stops, for the user's approval; resume with `--from-step` after they approve.
- `tool` steps keep their own behaviour (backups, audits, dry runs).

## Pitfalls that apply to every procedure

- Restart before you recreate. Recreating structsd on the public node resets app.toml (`post-recreate-app-toml-fix.md`).
- Recreate structs-pg with `--no-deps` only; never touch `structs-pg-init` on a live site.
- Never re-pin migrations to a commit; the guild sites track `structs-pg` `main`.
- After a webapp pull: restore `MATRIX_SIGNIN_CLIENT_ID` and `OIDC_ENCRYPTION_KEY` (`devops webapp <site> env-restore`), re-apply patches, run `oidc-from-tel`.
- Every procedure ends with at least one `check:` step.
- Afterwards add a line to `inventory/sites/<site>/CHANGELOG.md`, and update `site.yaml` if a version, digest or commit changed.

## Writing a new procedure

1. Do it once by hand (`ssh`, or `devops ssh <site> -- <cmd>`, which logs it) and note each command.
2. Turn the commands into steps, adding a `backup` before each file edit and a `check` at the end.
3. `devops deploy <site> <name> --dry-run` and read the effective tiers.
4. `devops inventory validate`.
