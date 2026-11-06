# Public node — canonical configuration reference

Working configuration of a public archive node, taken from `public.testnet.structs.network` on 2026-06-14. Replace `<public-node-ip>` with your host's public IPv4.

Use this as the source of truth when verifying after recreates, upgrades, or disaster recovery.

## Host

| Item | Value |
|---|---|
| OS | Ubuntu (apt-based, systemd) |
| Public IPv4 | <public-node-ip> |
| Hostname (DNS) | `public.testnet.structs.network` |
| SSH | `root@<public-node-ip>` (port 22) |
| Firewall | UFW (allows 22, 80, 443, 26656, 26657, 9090) — historically blocked all else |

## TLS

| Item | Value |
|---|---|
| Provider | Let's Encrypt via certbot |
| Cert files | `/etc/letsencrypt/live/public.testnet.structs.network/{cert,chain,fullchain,privkey}.pem` (symlinks to `archive/`) |
| Key type | ECDSA |
| Authenticator | `standalone` (needs :80 free) |
| Renewal pre/post hooks | `pre_hook = systemctl stop caddy` / `post_hook = systemctl start caddy` in renewal conf (required — Caddy owns :80) |
| Deploy hooks | `00-fix-cert-acls.sh` (re-grant `caddy` ACL on new PEMs), `reload-caddy.sh` (`systemctl restart caddy`), `sync-structsd-cert.sh` (legacy volume copy) |
| ACL | `setfacl -m u:caddy:r--` on live PEMs — certbot rename drops inherited ACLs |
| Termination | Caddy on host (NOT in `structsd` — internal cometbft TLS was disabled to avoid handshake spam) |

Full renewal incident notes: [runbooks/tls-cert-renewal.md](../../runbooks/tls-cert-renewal.md)

## Caddy

Config at `/etc/caddy/Caddyfile`:

```caddyfile
{
    admin off
    email admin@public.testnet.structs.network
}

public.testnet.structs.network {
    tls /etc/letsencrypt/live/public.testnet.structs.network/fullchain.pem /etc/letsencrypt/live/public.testnet.structs.network/privkey.pem
    encode zstd gzip
    @nobody { path /debug/* /admin/* }
    respond @nobody 404
    reverse_proxy 127.0.0.1:1317 {
        header_up X-Real-IP {remote_host}
    }
    log {
        output file /var/log/caddy/access.log { roll_size 100mb roll_keep 5 }
        format json
    }
}

public.testnet.structs.network:26657 {
    bind <public-node-ip>   # required — host's docker-proxy already owns 0.0.0.0:26657 mapping
    tls /etc/letsencrypt/live/public.testnet.structs.network/fullchain.pem /etc/letsencrypt/live/public.testnet.structs.network/privkey.pem
    reverse_proxy 127.0.0.1:26657
    log {
        output file /var/log/caddy/rpc.log { roll_size 100mb roll_keep 5 }
        format json
    }
}
```

Why `bind <public-node-ip>` on the :26657 block: the structsd container's RPC port 26657 is bound on the host to `127.0.0.1:26657` (loopback only), and Caddy needs to take the public-IP side of port 26657. Without the explicit bind, Caddy tries `0.0.0.0:26657` and collides with anything else on loopback.

Log file ownership matters: `caddy:caddy` on `/var/log/caddy/`. A `chown root:` here will break reloads.

## Docker

| Item | Value |
|---|---|
| Compose project | `/home/docker/docker-structs-guild/` |
| Container name | `docker-structs-guild-structsd-1` |
| Image | `structs/structsd:latest` (Docker Hub) |
| Current digest (2026-06-14) | `sha256:d0d574ffc8a28eed6506bb877223d9ea415efa1fc76243a30ece32a4bf1974ad` |
| Previous digest (May-24) | `sha256:4f83292b2cdf74b361565744e42f289fda7b21fda0999842ab77333a1e0d4a59` |
| Volume | `structsd-chaindata` → `/var/lib/docker/volumes/structsd-chaindata/_data` |
| Network | bridge, container IP `172.18.0.2` |
| Restart policy | `unless-stopped` |
| Logging driver | `json-file`, `max-size: 50m`, `max-file: 5` |

### Compose port bindings (the ones that matter)

```yaml
ports:
  - 26656:26656                # P2P, public
  - 127.0.0.1:26657:26657      # RPC, loopback only — Caddy terminates TLS on public
  - 127.0.0.1:1317:1317        # LCD, loopback only — Caddy terminates TLS on public
  - 9090:9090                  # gRPC, public
```

Container internal listeners (validate with `ss -tlnp` inside container, or by external port test):

| Port | Inside-container bind | Reason for the choice |
|---|---|---|
| 1317 | `0.0.0.0:1317` | LCD must accept the docker-proxy connection from the bridge |
| 26657 | `0.0.0.0:26657` | Same — for the docker-proxy |
| 9090 | `0.0.0.0:9090` | **Critical** — template default is `localhost:9090`, which makes the host docker-proxy unable to forward |
| 26656 | `0.0.0.0:26656` | P2P public |
| 26660 | `0.0.0.0:26660` (CometBFT prometheus) | not exposed to host |

## Environment (`.env`)

```bash
MONIKER=structs-public-rpc
NETWORK_VERSION=112b                    # branch of playstructs/structs-networks
NETWORK_CHAIN_ID=structstestnet-111
# ...validator-related vars are populated by the network-config-init service
```

## Container envs (`compose.yaml` `x-common-env`)

```yaml
STRUCTS_MONIKER: "${MONIKER}"
STRUCTS_NETWORK_VERSION: "${NETWORK_VERSION}"
STRUCTS_CHAIN_ID: "${NETWORK_CHAIN_ID}"
STRUCTS_UPGRADE_NAME: "v0.17.0"   # NOTE: not actually read by current start.sh
                                   # (reconcile-cosmovisor-current.sh derives from chain state).
                                   # Leave it set to the current chain-state upgrade; bumping does no harm.
```

## `config.toml` customizations (CometBFT)

These are preserved across recreates — `network-config.sh` only edits `[rpc] laddr` in this file.

```toml
[rpc]
laddr = "tcp://0.0.0.0:26657"
cors_allowed_origins = ["*"]
cors_allowed_methods = ["HEAD", "GET", "POST"]
cors_allowed_headers = ["Origin", "Accept", "Content-Type", "X-Requested-With", "X-Server-Time"]
max_open_connections = 1000
max_subscription_clients = 1000
max_subscriptions_per_client = 10
tls_cert_file = ""               # explicitly empty — Caddy terminates TLS, not cometbft
tls_key_file = ""

[p2p]
external_address = "<public-node-ip>:26656"
persistent_peers = "<node_id>@<ip>:26656,..."   # your network.yaml persistent_peers, or structs-networks addrbook.json
max_num_inbound_peers = 240
max_num_outbound_peers = 30
allow_duplicate_ip = true
persistent_peers_max_dial_period = "0s"

[statesync]
enable = false                    # consuming side off; we full-sync from genesis
rpc_servers = ""

[instrumentation]
prometheus = true
prometheus_listen_addr = ":26660"

moniker = "structs-public-rpc"
```

## `app.toml` customizations (Cosmos SDK app)

**These get reset to template defaults whenever `network-config.sh` re-runs against a missing/bumped `status/docker-config-vN` marker.** See [runbooks/post-recreate-app-toml-fix.md](../../runbooks/post-recreate-app-toml-fix.md).

```toml
minimum-gas-prices = "0ualpha"
pruning = "nothing"                    # full archive (forward from this restart)
pruning-keep-recent = "0"
pruning-interval = "0"
min-retain-blocks = 0
query-gas-limit = "25000000"

[telemetry]
enabled = true
prometheus-retention-time = 60

[api]
enable = true
swagger = true
address = "tcp://0.0.0.0:1317"
enabled-unsafe-cors = true

[grpc]
enable = true
address = "0.0.0.0:9090"               # NOT "localhost:9090"

[state-sync]
snapshot-interval = 1000               # we produce snapshots for other nodes to consume
snapshot-keep-recent = 5
```

`devops node <public-node> app-toml apply` (host script `tools/host/app-toml-overrides.sh`) applies all of these idempotently.

## Cosmovisor

| Item | Value |
|---|---|
| Version | v1.7.0 (bundled in image) |
| `DAEMON_NAME` | `structsd` |
| `DAEMON_HOME` | `/root/.structs` |
| `DAEMON_RESTART_AFTER_UPGRADE` | `true` |
| `DAEMON_ALLOW_DOWNLOAD_BINARIES` | `false` (binaries MUST come from the image) |
| `UNSAFE_SKIP_BACKUP` | `true` |

Known upgrades (from `/root/scripts/upgrades.conf.sh` in the current image):

```bash
UPGRADES=(
  "v0.16.0:385730"
  "v0.17.0:867678"
  "v0.18.0:1173255"
)
```

## Health endpoints (external)

| Test | Command | Expected |
|---|---|---|
| LCD | `curl -sS https://public.testnet.structs.network/cosmos/base/tendermint/v1beta1/node_info` | HTTP 200, JSON with `network: structstestnet-111` |
| RPC | `curl -sS https://public.testnet.structs.network:26657/status` | HTTP 200, JSON-RPC |
| Swagger | `curl -sS -o /dev/null -w '%{http_code}\n' https://public.testnet.structs.network/swagger/` | 200 (trailing slash required) |
| P2P | `nc -zv <public-node-ip> 26656` | open |
| gRPC | `nc -zv <public-node-ip> 9090` | open |
| CORS | `curl -X OPTIONS -H 'Origin: https://x.com' -H 'Access-Control-Request-Method: GET' https://public.testnet.structs.network/...` | 200 with `Access-Control-Allow-Origin: *` |

## Healthcheck

`compose.yaml` runs:

```
CMD-SHELL bash /root/scripts/health-check-sync-state.sh
```

Which internally calls `structsd status --home /root/.structs -o json | jq -e '.sync_info.catching_up == false'`. The client.toml `node` URL must be `tcp://localhost:26657` (plain HTTP, loopback) for this to work — Caddy is what speaks TLS on the outside.

## Monitoring

| Item | Location |
|---|---|
| CometBFT Prometheus | `localhost:26660/metrics` (inside container; not exposed) |
| App Prometheus | `localhost:1317/metrics` (when `[telemetry] enabled = true`) |
| Caddy logs | `/var/log/caddy/access.log`, `/var/log/caddy/rpc.log` |
| Docker logs | `docker logs docker-structs-guild-structsd-1` (json-file, 50m × 5) |
| Upgrade monitor | `systemctl status structsd-upgrade-monitor.service`, `/var/log/structsd-vX.Y.Z-monitor.log` |
