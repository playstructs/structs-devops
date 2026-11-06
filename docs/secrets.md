# Secrets

The workspace stores **where** each secret lives, never its value. Values stay
on the host that uses them. Tools that need a value (signing a transaction,
creating a key) load it **on that host**, use it inside a container, and
print only the result.

## Pointers

Every secret is declared in its site's `site.yaml` under `secrets:`:

```yaml
secrets:
  guild_admin_mnemonic:
    ref: "host-env:web1:/root/docker-structs-guild/.env#GUILD_MNEMONIC"
    criticality: critical        # critical | high | medium | low
    backup: none                 # where an off-host copy lives, or "none" / "regenerable"
    rotation: not-rotatable (address-bound)
    used_by: [guild-onchain, gov-vote, tx]
    expect_mode: "600"           # optional: exact mode, or "<=640" for "no bits beyond"
    expect_owner: "991"          # optional: uid or user name
    expect_line: '"structs_app"' # optional: a fixed string the file must still contain
    kind: config                 # optional: not secret, but must not go missing
    note: "..."
```

| Scheme | Form | Points at |
|---|---|---|
| `host-env` | `host-env:<host>:<file>#<KEY>` | one key in a dotenv file on a host |
| `host-file` | `host-file:<host>:<path>` | a whole file on a host |
| `host-volume` | `host-volume:<host>:<volume>/<path>` | a file inside a docker volume on a host |
| `local-env` | `local-env:<KEY>` | a key in the hub's git-ignored `local/secrets.env` (notification webhooks and similar) |

`<host>` is a host id from the same site's `hosts:` list.

## What reads what

| Action | How the value is touched |
|---|---|
| `devops secrets audit` / the `secrets-audit` check | `test -s`, `stat -c '%a %u:%U'`, `grep -c`. A value is never read. Reports present / EMPTY / missing / nofile / novolume plus mode and owner. |
| `devops tx … --broadcast`, `devops gov vote` | On the host, `envget`/`volcat` load the mnemonic into an environment variable that is handed to an ephemeral `structs/structsd` container (`-e MN`). The container recovers the key into a throwaway test keyring, checks the address matches the inventory, unsets the variable, signs, and exits. Only `RESULT txhash=… code=… height=…` comes back. |
| `devops account create-key` | Generated inside a container on the host, written to a `600` file on the host. Only the address and a pointer line come back. |
| `devops account create-player` | Same, with the structs-ai `create-player.mjs` signup flow; the mnemonic is moved out of the JSON into a `600` file before anything is printed. |
| `devops webapp <site> env-restore` | Copies empty keys back from the newest `.env.bak.*` on the host. Prints key names only. |

## Rules for people and agents

- Never `cat`, `grep`, `head`, `less`, `docker exec … env`, `printenv` or `docker inspect … .Config.Env` on files or containers that hold secrets. The agent command guard (`tools/agents/policy.tsv`, class `S`) refuses these outright.
- Never paste a value into chat, a commit, a report, the journal or an issue. Reports quote pointers and states, not values.
- Never pass `--output json` to `structsd keys add` (it prints the mnemonic), and never capture stderr from `structsd tx` commands that recover keys.
- Prefer the workflow tools (`devops tx`, `devops account`) to ad-hoc ssh. If you must work by hand on a host, load the value into a variable with `envget` from `tools/host/_prelude.sh` and do not echo it.
- `local/secrets.env` is for hub-side credentials only (notifier webhooks, Matrix bot token). It is git-ignored; `devops doctor` warns if its mode is wider than `600`.

## Backups

`backup: none` on a `critical` secret is a finding, not a configuration. The
validator warns about it, the `secrets-audit` check lists it as a policy note,
and the generated site README shows it. Mnemonics and validator keys need an
off-host copy that the workspace does **not** hold (a password manager, a
hardware wallet, sealed paper). Record where it is in `backup:` (for example
`backup: "1Password vault Ops, item guild admin"`); never record
the value.

A second copy on the same host (for example the `structsd-chainbackup`
volume) is not a backup: one disk failure or one compromised root account
loses both.

## Rotation

`rotation:` says what rotating costs. Common cases on a Structs guild:

| Secret | Rotation |
|---|---|
| Guild/admin mnemonic | Not rotatable without moving guild ownership on chain (new key, transfer, update every pointer). |
| `priv_validator_key.json` | Not rotatable; it is the validator's consensus identity. Copying it to a second running node double-signs and gets the validator tombstoned. |
| `node_key.json` | Rotatable: `devops node <site> rotate-node-key` (tier 2). Update `node_id` in the inventory and any persistent_peers that name it. |
| OIDC client secret (MAS ↔ webapp) | Rotate together on both sides; hex only (base64 breaks RFC 6749 Basic auth). |
| `OIDC_ENCRYPTION_KEY`, `MATRIX_SIGNIN_CLIENT_ID` | Keep across webapp pulls; the tracked `.env` blanks them. Restore with `devops webapp <site> env-restore`. |
| PgBouncer `userlist.txt` rows | Server-local; the bouncer helper preserves extra rows. After editing, `docker kill -s HUP` the bouncer. |

## Scanning

`devops secrets scan` looks for private-key PEM blocks, Cosmos `priv_key`
JSON, provider tokens (GitHub, Matrix `syt_`, MAS, Docker Hub, Slack, Discord
webhooks), literal assignments to `*PASSWORD*`/`*SECRET*`/`*TOKEN*`/`*MNEMONIC*`
keys, and 12–24-word mnemonic phrases on lines that mention a mnemonic or seed.
It covers the framework and the inventory, even when `DEVOPS_INVENTORY`
points outside the workspace. Findings print redacted.
`devops secrets hook install` adds it as a pre-commit hook to each of the two
that is its own git repo (`devops init` does this for a new inventory).
Narrow false positives go in `tools/secrets/scan-allow.txt`, or for your own
files in `<inventory>/scan-allow.txt`.

## If a value leaks

1. Treat it as compromised. For a mnemonic, move funds and guild ownership to a new key **before** cleaning history; for an OIDC or bot secret, rotate it.
2. Remove it from wherever it landed (chat export, commit history with `git filter-repo`, reports).
3. Record what happened with `templates/incident-report.md` in `inventory/reports/incidents/`.
