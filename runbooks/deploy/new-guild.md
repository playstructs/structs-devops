# New guild site

Stand up a guild site: web stack, Postgres, indexer, TSA, GRASS, optional
validator and Matrix, on-chain guild with an entry substation, and the guild
manifest. `examples/inventory/sites/example-guild/` shows the finished
inventory entry.

Tiers below are the devops tiers of each action.

## 0. Catalogue first

```bash
devops site new my-guild --kind guild --fqdn guild.example.com --ip 203.0.113.10 --ssh root@guild.example.com
$EDITOR inventory/sites/my-guild/site.yaml     # hosts, stacks, endpoints, tls, secrets pointers
devops inventory validate
```

Fill in what you know; mark guesses in `unverified:`. Every secret is a
pointer (`docs/secrets.md`); decide now where the guild mnemonic's off-host
backup will live.

## 1. Host prep

Ubuntu 24.04, Docker Engine + compose plugin, Caddy, `git curl jq ufw`.
Firewall: 22, 80, 443, 1443 (GRASS wss), 26656 only if this host runs structsd.
Add the hub's ssh key; confirm with `devops doctor`.

## 2. Guild stack

```bash
devops ssh my-guild -- 'git clone https://github.com/playstructs/docker-structs-guild.git /root/docker-structs-guild'
devops ssh my-guild -- 'git clone https://github.com/playstructs/structs-webapp.git /root/structs-webapp'
```

Create `/root/docker-structs-guild/.env` on the host (by hand over ssh; values
never come through the hub): chain id `structstestnet-111`, RPC/LCD seeds on
`public.testnet.structs.network`, `WEBAPP_SOURCE=/root/structs-webapp/src`,
`WEBAPP_APP_ENV=prod`, fresh `WEBAPP_APP_SECRET` and NATS passwords,
`STRUCTS_PG_BRANCH=main`. Quote values with spaces.

Web stack points sync-state and the webapp at the **public node**; a local
structsd (if any) is only for validator block production.

## 3. Guild key

```bash
devops account create-key my-guild guild_admin
```

The mnemonic is generated on the host into a `600` file; the hub sees the
address and a pointer. Add the printed snippet to `site.yaml` under
`secrets:` and `onchain.accounts:`. Fund the address.

## 4. Bring up the stack

Start Postgres first, let auto-migrate finish, then the rest. Use `--no-deps`
for later Postgres recreates. Check:

```bash
devops ps my-guild
devops health my-guild
```

## 5. Web edge

Caddyfile: `guild.example.com` → nginx cache `:8080` → webapp. Copy the shared
overlays from another guild's `patches/manifest.tsv` (nginx 5 s `/api/*`
microcache with `X-Forwarded-For` passed through, Apache `MaxRequestWorkers`,
PgBouncer for the webapp only), then:

```bash
devops host sync my-guild
devops patches my-guild check
devops patches my-guild apply --restart
```

## 6. On-chain guild (transactions: simulate, then the user approves)

The guild needs a reactor and an entry substation (power for new members);
the messages and their arguments are in `.references/structs-ai/reference/action-quick-reference.md`.
Each transaction simulates first, then needs the user's approval to broadcast:

```bash
# guild-create [reactor id] [endpoint] [substation id]: costs two Alpha
# (one burned, one collateralizes the guild token); the reactor must exist.
devops tx my-guild guild_admin -- structs guild-create -- <reactor-id> https://guild.example.com/guild.json <substation-id>
devops onchain my-guild guild-endpoint https://guild.example.com/guild.json   # later endpoint changes
devops onchain my-guild show          # compare chain vs inventory, then record ids in site.yaml onchain:
```

Write `guild.json` (see `examples/inventory/sites/example-guild/patches/overlay/guild.json`)
with `guild.id`, `services.guild_api`, `reactor_api`, `client_websocket`,
`grass_nats_websocket`, and serve it at `/guild.json`.

## 7. TSA

Start `structs-tsa` with `TSA_WORKERS` sized to the host (6 on 4 cores; the
default 30 outlasts a block and every signature is rejected). Keep the
`/var/structs/accounts` volume. `devops check tsa-queue my-guild`.

## 8. Optional: validator, Matrix, structs.app

- Validator: `compose-reactor.yaml`; the consensus key is a critical secret with an off-host backup. Never run the same `priv_validator_key.json` on two nodes.
- Matrix: `structs-tel` (Synapse + MAS); `devops webapp my-guild oidc-from-tel` wires the webapp's OIDC client.

## 9. Finish

```bash
devops inventory render
devops health my-guild && devops health my-guild daily
devops cron status
```

Add `checks.extra` (tsa-queue, sync-lag, bouncer, apache-workers, validator),
procedures (`quick-recovery`, `webapp-update`, `pg-recreate`), a README and a
CHANGELOG entry.
