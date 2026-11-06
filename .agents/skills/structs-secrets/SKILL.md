---
name: structs-secrets
description: Manages Structs infrastructure secrets as pointers only (where each mnemonic, validator key, OIDC secret, bouncer userlist and env key lives), audits presence, modes and owners without reading values, scans the workspace for leaks, and guides rotation and leak response. Use when asked where a secret is, when secrets-audit warns, before rotating a key or password, when a value may have leaked, or when adding a new secret to the inventory.
---

# Structs secrets

The workspace stores **where** a secret lives, never its value. Values stay
on the host that uses them; tools that need one load it on that host and
return only results. Full rules: [docs/secrets.md](../../../docs/secrets.md).

## When to use

- "Where is the guild mnemonic / validator key / OIDC secret?"
- `secrets-audit` reports missing, empty, or wrong mode/owner.
- Rotation, a suspected leak, or adding a new secret.

## Decisions

| Need | Command |
|---|---|
| List pointers | `devops secrets list [site]` |
| Audit (presence, mode, owner, expected line) | `devops secrets audit <site|all>` |
| Scan the workspace | `devops secrets scan` (and `--staged` in the pre-commit hook) |
| Pre-commit hook | `devops secrets hook install` (tier 1) |
| Webapp keys blanked by a pull | `devops webapp <site> env-restore` (tier 1) |
| P2P node key | `devops node <site> rotate-node-key` (tier 2) |
| Bouncer `structs_app` row lost (structs.app 503) | rotate per the site's structs-app runbook (`inventory/sites/<site>/runbooks/`), then HUP the bouncer |

Never read a secret to "check" it. `cat .env`, `printenv`, `docker exec … env`,
`docker inspect … .Config.Env`, reading `userlist.txt`,
`priv_validator_key.json` or keyring folders are refused by the command
guard and by `devops ssh`; the audit answers the same questions safely.

## Procedure

1. `devops secrets list <site>` to find the pointer, criticality, backup and
   rotation notes.
2. `devops secrets audit <site>`: each pointer is `present`, `EMPTY`,
   `missing`, `nofile` or `novolume`, with mode and owner.
3. Missing or empty critical/high secrets are CRIT: find out what changed
   (a pull, a recreate, a restore) before restoring anything.
4. Rotation: follow the table in [docs/secrets.md](../../../docs/secrets.md#rotation).
   Rotations that touch services are tier 2 and need a procedure or an
   Approval Block. Update the pointer and `rotation:` notes afterwards.
5. Policy gaps: `backup: none` on a critical secret is a finding. Tell the
   user; record where the offline copy is once they have made one (the
   location, never the value).

## Commands reference

```bash
devops secrets list <guild>
devops secrets audit all
devops check secrets-audit <guild>
devops secrets scan
devops secrets hook install
devops webapp <guild> env-restore MATRIX_SIGNIN_CLIENT_ID OIDC_ENCRYPTION_KEY
```

## Verification

`devops secrets audit <site>` is OK; `devops secrets scan` finds nothing.

## Errors

| Finding | Meaning / fix |
|---|---|
| `EMPTY OIDC_ENCRYPTION_KEY` after a webapp pull | tracked `.env` blanked it: `env-restore`, then `oidc-from-tel` |
| `mode 644` on a key file | `chmod 600` on the host (tier 1 by hand: `devops ssh <site> -- chmod 600 <path>`) |
| `missing "structs_app"` in userlist | structs.app 503 with bouncer auth failures; follow the runbook |
| scan hit in a commit | stop, rotate the value, remove it from history, add to `known_issues` |

## If a value leaked

Treat it as compromised: rotate first (or move funds for a mnemonic), then
clean up the copy. Write an incident report. Never paste the leaked value
anywhere while doing so.

## See also

- [docs/secrets.md](../../../docs/secrets.md), `structs-inventory`, `structs-transactions`
