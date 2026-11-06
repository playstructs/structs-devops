# Post-recreate app.toml reset — fix

## Symptom

After `docker compose up -d --force-recreate structsd` (especially with a new image), one or more of these regress to template defaults:

| Setting | Working value | Template default |
|---|---|---|
| `pruning` | `"nothing"` (full archive) | `"default"` (prunes after 362880 blocks) |
| `query-gas-limit` | `"25000000"` | unset |
| `[api] swagger` | `true` | `false` |
| `[api] enabled-unsafe-cors` | `true` | `false` |
| `[grpc] address` | `"0.0.0.0:9090"` | `"localhost:9090"` ← **breaks external gRPC** |
| `[state-sync] snapshot-interval` | `1000` | `0` |
| `[state-sync] snapshot-keep-recent` | `5` | `2` |
| `[telemetry] enabled` | `true` | `false` |
| `[telemetry] prometheus-retention-time` | `60` | `0` |

`config.toml` is **not** affected (`network-config.sh` only edits `laddr` in it). `client.toml` is only re-seeded if missing.

External observable: `nc -zv <public-node-ip> 9090` → `Connection refused`, and `https://public.testnet.structs.network/swagger/` → `501`.

## Root cause

`/root/scripts/network-config.sh` in the structsd image runs on every container start. It contains:

```bash
DOCKER_CONFIG_MARKER="$STRUCTS_PATH/status/docker-config-v1"
...
if [ ! -f "$CONFIG_DIR/app.toml" ] || [ ! -f "$DOCKER_CONFIG_MARKER" ]; then
  cp -f "$DEFAULTS_DIR/app.toml" "$CONFIG_DIR/app.toml"
  ...
fi
# Then re-applies a SMALL set of overrides via sed:
#   - minimum-gas-prices
#   - [api] enable + address
#   - [rpc] laddr in config.toml
touch "$DOCKER_CONFIG_MARKER"
```

This means:

1. When the marker file `/var/lib/docker/volumes/structsd-chaindata/_data/status/docker-config-v1` is missing, `app.toml` gets overwritten with the image's template.
2. **A new image that bumps the marker name** (`docker-config-v2`, `v3`, …) triggers the overwrite even though `v1` exists on disk — the new condition is `! -f .../docker-config-v2` and that's missing.
3. Only the small handful of sed-applied overrides survive the overwrite.

Verified during v0.17.0 → v0.18.0 upgrade prep on 2026-06-14: the previous image (May-24) didn't have this marker mechanism at all, so the new image (Jun-14) found no marker and re-templated `app.toml`. All our customizations beyond gas+api had to be re-applied.

## Detection

After ANY recreate:

```bash
ssh root@<public-node-ip>
APP=/var/lib/docker/volumes/structsd-chaindata/_data/config/app.toml
grep -E '^pruning|^query-gas|^minimum-gas' "$APP"
sed -n '/^\[api\]/,/^\[/p' "$APP" | grep -E '^(swagger|enabled-unsafe-cors)'
sed -n '/^\[grpc\]/,/^\[/p' "$APP" | grep -E '^address'
sed -n '/^\[state-sync\]/,/^\[/p' "$APP" | grep -E '^snapshot'
sed -n '/^\[telemetry\]/,/^\[/p' "$APP" | grep -E '^(enabled|prometheus-retention)'
```

External test:

```bash
nc -zv <public-node-ip> 9090    # MUST succeed; if "Connection refused" → grpc bound to localhost
curl -sS -o /dev/null -w '%{http_code}\n' https://public.testnet.structs.network/swagger/  # MUST be 200
```

## Fix

Run the idempotent patcher (`devops node <public-node> app-toml apply` does the same through the bundle):

```bash
scp scripts/apply-app-toml-overrides.sh root@<public-node-ip>:/root/
ssh root@<public-node-ip> 'bash /root/apply-app-toml-overrides.sh && docker compose -f /home/docker/docker-structs-guild/compose.yaml restart structsd'
```

The script:

1. Backs up `app.toml` to `app.toml.bak.<stamp>`.
2. Applies each customization via section-anchored sed (idempotent — re-running is safe).
3. Inserts `query-gas-limit` if it's missing, replaces if present.

After restart, re-run the detection checks above. All should pass within ~30 seconds of healthy.

## Prevention

Two options if you want this to stop happening:

### A. Apply post-start overrides automatically

Add a sidecar service or `command:` wrapper in `compose.yaml` that runs `apply-app-toml-overrides.sh` after start.sh but before launching cosmovisor. This is invasive — easier to just keep the script handy and run it post-recreate.

### B. Use `STRUCTS_*` env vars where they exist

`network-config.sh` honours these envs (the only ones it consults):

- `STRUCTS_MIN_GAS_PRICES` → `minimum-gas-prices` (default `0ualpha`)
- `STRUCTS_API_ADDRESS` → `[api] address` (default `tcp://0.0.0.0:1317`)

There's no env for any of the other customized settings. Until upstream adds them, the patch script is the answer.

### C. Watch for marker bumps

Whenever pulling a new image:

```bash
docker run --rm --entrypoint sh structs/structsd:latest -c \
  'grep DOCKER_CONFIG_MARKER /root/scripts/network-config.sh'
```

If the marker name has incremented, expect `app.toml` to be re-templated on the next recreate. Plan for the patch run.

## Current customizations on prod (snapshot from 2026-06-14)

Captured from `app.toml.bak.20260614T041826` (the pre-patch state showed defaults; this lists the desired state after patching):

```toml
minimum-gas-prices = "0ualpha"
pruning = "nothing"
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
address = "0.0.0.0:9090"

[state-sync]
snapshot-interval = 1000
snapshot-keep-recent = 5
```
