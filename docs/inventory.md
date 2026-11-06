# Inventory format (`structs-devops/site/v1`)

The inventory is the source of truth for what one operator runs and where.
Tools read it; people and agents keep it current. It is the operator's own
repo, separate from the framework: by default it sits in `inventory/` (which
the framework git-ignores), or anywhere `DEVOPS_INVENTORY` in `.devops.env`
points. `devops init` creates one from `templates/inventory/`;
`examples/inventory/` is a filled-in fictional one.

`devops inventory validate` checks it. `devops inventory render` regenerates
the state blocks in the inventory's `AGENTS.md` and in each site `README.md`.

```
inventory/
  AGENTS.md                     agent notes + generated current-state block (read at session start)
  network.yaml                  preset name + your network additions
  publish-markers.txt           extra names devops publish-check keeps out of the framework
  shared/patches/{overlay,snippets}/   files any site manifest can reference as @shared/<file>
  sites/<site-id>/
    site.yaml                   machine-readable source of truth
    README.md                   narrative + generated site-state block
    CHANGELOG.md                dated changes, newest first
    patches/manifest.tsv        anchored patches (+ overlay/, snippets/)
    app-toml.overrides          optional, for nodes whose app.toml must be re-applied
    runbooks/  reference/       site-specific docs
  tools/host/                   your host helpers (bundled with the framework's tools/host)
  pipelines/                    dev pipelines (docs/pipelines.md)
  runbooks/  docs/              anything else that is about your sites
  reports/                      incidents/, journal/ (tracked); runs/, tx-log/, audit.log (ignored)
```

Use `devops site new <id> --kind guild|public-node|local` to start a site from
`templates/site/`. Keep values that would be secrets out of every file here:
only pointers, under `secrets:`.

## network.yaml

Public chain facts live in the framework, in `networks/<preset>.yaml`. Your
`network.yaml` names the preset and adds what is yours. Maps merge (your keys
win), lists in your file replace the preset's, and every tool sees the merged
result. Without `preset:` the file must carry everything itself.

| Key | Usually in | Meaning |
|---|---|---|
| `preset` | inventory | Preset file name in `networks/`, e.g. `structstestnet-111`. |
| `id`, `chain_id`, `bech32_prefix`, `denom`, `block_time_seconds` | preset | Chain identity. `id` is what sites name in `network:`. |
| `network_version` | preset | `structs-networks` branch used by `network-config.sh` on a fresh init. |
| `binary` | preset | `version`, `since_height`, `cosmovisor_current`, `cosmovisor_version`, `git_commit`, `cometbft`: what the chain runs now. Bump after every upgrade (in the preset, or override it here until the preset catches up). |
| `upgrades[]` | preset | `{name, height, date?, proposal?}` history (seeded from `docker-structsd/scripts/upgrades.conf.sh`). |
| `endpoints.{rpc,lcd,websocket,grpc,p2p}` | preset | Public endpoints every client can use. |
| `check_defaults` | preset | Thresholds for every check (`docs/health-checks.md`); override any of them here, and per site under `checks:`. |
| `public_node_site` | inventory | The site that serves the public endpoints, if one of yours does. |
| `images.<name>` | inventory | `{repo, tag, digest, date}` pins you expect on your hosts; `digest` may be a short prefix. |
| `persistent_peers[]` | inventory | `id@ip:port` peers your nodes keep. |
| `gov.voters[]` | inventory | `{site, account}` accounts expected to vote; votes are never automatic. |
| `last_verified` | both | Date the facts were last confirmed against the chain. |

## site.yaml

```yaml
schema: structs-devops/site/v1
id: example-guild                   # must equal the directory name
kind: guild                         # guild | public-node | local
name: Example guild (guild.example.org)
network: structstestnet-111         # network id
owner: {team: ..., contact: ...}
last_verified: 2026-11-05           # bump whenever you confirm the file against the hosts
unverified: [stacks.matrix.path]    # dotted paths that were inferred, not confirmed
```

### hosts

```yaml
hosts:
  - id: web1                        # unique across the whole inventory
    fqdn: guild.example.org
    ipv4: 203.0.113.10
    ssh: root@guild.example.org     # or "local" for the hub itself
    os: ubuntu-24.04
    tools_path: /opt/structs-devops # where `devops host sync` puts the host bundle
    key_dir: /root/.structs-devops/keys   # optional; where create-key writes mnemonic files
    specs: {vcpu: 4, ram_gb: 31}
    firewall: {tool: ufw, open: [22, 80, 443, 1443, 26656]}
    dns: [guild.example.org, ...]
retired_hosts: [{ipv4: ..., retired: 2026-09, note: "..."}]   # keep for history (old node keys!)
dependents: [example-guild, desktop-clients]                  # public-node only: who breaks if it does
```

### host_env

Flat `KEY: value` pairs exported to host scripts as `site.env` (they never parse
YAML). Patch targets use them as `${KEY}`. Common keys: `GUILD_ROOT`,
`WEBAPP_SRC`, `WEBAPP_ENV`, `TEL_ENV`, `CADDYFILE`, `OIDC_ISSUER`,
`MAS_AUTH_HOST`, `WEBAPP_FILE_OWNER`, `WEBAPP_ENV_MODE`. Optional modules read
their own: `structs-app-update` needs `STRUCTS_APP_DIR`, `STRUCTS_UNIVERSE_DIR`
and `STRUCTS_APP_PUBLIC_URL`.

### stacks and nodes

```yaml
stacks:
  - id: guild-web
    host: web1
    path: /root/docker-structs-guild
    compose: [compose.yaml]         # -f files, relative to path
    project: structs-local          # optional; default is basename(path)
    services:
      structs-tsa:
        image: structs/structs-tsa:latest
        digest: "sha256:6dea64286fae"
        env: {TSA_WORKERS: 6}       # only the settings that matter operationally
        container: ...              # optional; default <project>-<service>-1
        one_shot: true              # optional; exited(0) is healthy
        note: "..."
nodes:                              # structsd instances on this site
  - host: web1
    container: docker-structs-guild-structsd-1
    role: validator                 # validator | archive | full
    rpc: http://127.0.0.1:26657     # as seen from the host
    volume: structsd-chaindata
    node_id: 8d45...                # optional; node-health compares it
    app_toml_overrides: app-toml.overrides
```

Stacks may share a compose project (same `path`, different `compose:` files).

### sources

Checkouts on hosts that are built or bind-mounted:

```yaml
sources:
  - {repo: structs-webapp, host: web1, path: /root/structs-webapp, ref: guild-custom, commit: 6cb5ae17,
     pin_reason: "main plus this guild's changes"}
```

`repo` is a name from `.references/repos.tsv`. A `pin_reason` makes
`new-releases` report when the pinned commit lands on the default branch. A
deploy stage in a pipeline rolls out to every site whose sources track its
`repo@ref`.

### patches

```yaml
patches:
  manifest: patches/manifest.tsv
  pre_helpers: [my-apache-tuning]   # tools/host/<name>.sh (framework or inventory), run before the manifest
  ga4: G-XXXXXXX                    # optional; inserted into the current base.html.twig
  after_apply: "docker compose up -d structs-webapp"   # tier 2; printed, or run with --restart
```

`manifest.tsv` columns (tab-separated, `-` for empty):
`id  kind  target  overlay_or_snippet  anchor  verify`, where kind is
`overlay` (copy a file), `transform` (replace the anchor once), `transform_all`,
`snippet` (insert a file after the anchor) or `verify` (assert only). `verify`
is a fixed string or `re:<regex>` that must be present after applying.

A pre-helper is a host script you write for changes a manifest cannot express
(e.g. adding a sidecar to `compose.yaml`). Put it in the inventory's
`tools/host/`: it is bundled next to the framework's host tools, must source
`_bundle.sh`, must be idempotent, and may not reuse a framework tool's name.

### endpoints and tls

```yaml
endpoints:
  - {id: guild-manifest, url: "https://guild.example.org/guild.json", expect: 200, content_type: application/json}
  - {id: grass-wss, url: "https://guild.example.org:1443/", resolve: "guild.example.org:1443:203.0.113.10", expect: 400}
  - {id: rpc-status, url: "...", json: '.result.sync_info.catching_up == false'}
  - {id: cors-preflight, url: "...", method: OPTIONS, origin: "https://example.com", expect_header: access-control-allow-origin}
  - {id: structs-app-healthz, url: "...", json: '.ok == true', lag_json: '.block.lag_blocks'}
  - {id: p2p, tcp: "203.0.113.20:26656"}
  - {id: webapp, url: "...", optional: true}      # failures are WARN, not CRIT
tls:
  - {names: [guild.example.org], ports: [443], manager: caddy-acme}
  - names: [node.example.org]
    ports: [443, 26657]
    manager: certbot-standalone
    cert_name: node.example.org
    hooks: {pre: systemctl stop caddy, post: systemctl start caddy, deploy: [00-fix-cert-acls.sh, reload-caddy.sh]}
    acl: "setfacl -m u:caddy:r-- on live PEMs"
caddy: {config: /etc/caddy/Caddyfile, admin: off, binds: {"1443": 203.0.113.10}}
```

### onchain

```yaml
onchain:
  guild: {id: 0-0, name: Example Guild, endpoint: "https://guild.example.org/guild.json", entry_substation: 4-9, primary_reactor: 3-15}
  player: 1-100
  validator: {operator: structsvaloper1..., moniker: example-guild, self_stake_ualpha: 50000000}
  accounts:
    guild_admin: {address: structs1..., secret: guild_admin_mnemonic, gov_voter: true}
```

`devops onchain <site> show` compares these with the chain. `secret` names an
entry under `secrets:`.

### secrets

Pointers only; see `docs/secrets.md` for schemes and rules.

```yaml
secrets:
  guild_admin_mnemonic:
    ref: "host-env:web1:/root/docker-structs-guild/.env#GUILD_MNEMONIC"
    criticality: critical           # critical | high | medium | low
    backup: none                    # where the off-host copy is, never the value
    rotation: "not-rotatable (address-bound)"
    used_by: [tx, gov-vote]
    expect_mode: "600"              # optional: exact, or "<=640"
    expect_owner: "991"             # optional: uid or name
    expect_line: '"structs_app"'    # optional: fixed string the file must contain
    kind: config                    # optional: not secret, but must not go missing
```

### procedures

Named step lists run by `devops deploy <site> <name>`; see
`runbooks/deploy/README.md`. Step types: `tool`, `ssh` (+ `stack`), `local`,
`backup`, `check`, `confirm`; optional `tier`.

### checks

```yaml
checks:
  extra: [tsa-queue, sync-lag, bouncer, apache-workers, validator]   # opt-in checks
  skip: [host-resources]            # opt-out checks
  in_all: false                     # keep the site out of runs over "all"
  ignore_unhealthy: [structs-grass] # containers whose unhealthy state is known
  tsa: {workers: 6, pending_warn: 50}   # overrides check_defaults.tsa
  disk: {paths: [/, /var/lib/docker/volumes/structsd-chaindata/_data], project_growth_path: ...}
auto_remediate: []                  # reserved; nothing remediates automatically today
```

### known_issues

```yaml
known_issues:
  - id: login-500-xff
    symptom: "Login 500; Postgres error invalid input syntax for type inet."
    cause: "nginx appended its own address to X-Forwarded-For."
    fix: "pass $http_x_forwarded_for through; never $proxy_add_x_forwarded_for."
```

The generated README and current-state blocks list these ids; the debugging
skills and `docs/debugging/symptom-index.md` describe the general symptoms.

## Keeping it true

- Change the host, then the inventory, in the same session. `devops deploy` reminds you at the end.
- `devops inventory discover <site>` prints what is actually running (compose projects, containers, ports, disk, OS) to compare against.
- `inventory-freshness` (daily) warns when `last_verified` is older than `check_defaults.inventory.stale_days` or `unverified:` is not empty.
- Record what changed and why in the site `CHANGELOG.md`.

## Public framework, private inventory

The framework holds nothing about any one operator. Before you publish changes
to it, `devops publish-check` collects every site id, host id, hostname, IP,
address, GA id, contact email and non-default source ref from your inventory
(plus `publish-markers.txt`) and fails if a publishable framework file
contains one. Values in `networks/*.yaml` count as public. A rare legitimate
hit goes in `.publish-allow`.
