# Public archive node

A public node (`kind: public-node`) serves RPC, LCD and gRPC for every guild's
indexer, webapp and players. Treat changes to it like changes to all sites at
once: announce blips to guild operators first, and check the dependents
after every change.

Reference: `docs/reference/public-node-config.md`, `docs/reference/pruning-and-archive.md`.

## Shape

| Piece | Setting |
|---|---|
| structsd | `docker-structs-guild` compose, `structsd` only; volume `structsd-chaindata` |
| Pruning | `pruning = "nothing"` (archive). sync-state backfills need history. |
| app.toml | `inventory/sites/<public-node>/app-toml.overrides`: API enabled on `127.0.0.1:1317`, CORS, gRPC `0.0.0.0:9090`, `iavl-cache-size`, … |
| TLS | certbot **standalone** for `public.testnet.structs.network`; renewal pre/post hooks stop and start Caddy; deploy hooks fix ACLs, reload Caddy, sync the cert into structsd |
| Edge | Caddy :443 → LCD 127.0.0.1:1317; :26657 TLS → RPC 127.0.0.1:26657; p2p 26656 and gRPC 9090 open |

## Build

1. Host prep (Ubuntu 24.04, Docker, Caddy, certbot, `acl`). Disk: archive grows; `archive-growth` projects days left.
2. Clone `docker-structs-guild` to `/home/docker/docker-structs-guild`; `.env` with the chain id and seeds.
3. Restore chain data from a snapshot or another archive node (copy the `structsd-chaindata` volume with structsd stopped on both sides); a state-synced node is not an archive. Never run the old and new node with the same `node_key.json`.
4. `docker compose up -d structsd`, then catch up: `devops node <public-node> status`.
5. Apply app.toml overrides and restart:

   ```bash
   devops host sync <public-node>
   devops node <public-node> app-toml check
   devops node <public-node> app-toml apply
   devops restart <public-node> structsd
   ```

6. certbot standalone + Caddy (`../tls-cert-renewal.md`). Do not run `certbot renew --dry-run` on a live public node: the pre_hook stops Caddy.
7. Verify from the hub: `devops health <public-node>`, `devops check tls-expiry <public-node>`, `devops check height-agreement`.

## Day 2

| Task | Command |
|---|---|
| Restart structsd | `devops deploy <public-node> structsd-restart` |
| Image bump | `devops deploy <public-node> structsd-recreate` (re-applies app.toml) |
| After any recreate or upgrade | `devops check app-toml <public-node>` |
| Rotate the p2p identity | `devops node <public-node> rotate-node-key` (tier 2; update `node_id` and peers) |
| Caddy changes | `devops deploy <public-node> caddy-restart` (admin API is off; reload does not work) |
