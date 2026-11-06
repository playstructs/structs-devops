# Cosmovisor recovery runbook

When the daemon enters a crash-loop, fails to switch binaries at an upgrade height, or restarts repeatedly with `UPGRADE NEEDED` / AppHash mismatch errors — use this.

## How to recognise the failure mode

```bash
docker logs --tail 100 docker-structs-guild-structsd-1 2>&1 | grep -Ei "panic|UPGRADE|AppHash|FATAL"
```

| Log signature | Likely cause |
|---|---|
| `UPGRADE "v0.X.0" NEEDED` | Daemon is on v0.X-1.0 binary but chain state has crossed the v0.X.0 upgrade height. `cosmovisor/current` symlink is wrong. |
| `wrong Block.Header.AppHash` | Same root cause — running the wrong binary version against state from a different version. |
| `cannot find binary at /root/.structs/cosmovisor/upgrades/v0.X.0/bin/structsd` | The v0.X.0 binary was never staged into the volume. Need a fresh image with that binary, or `install` from `/opt/structs/cosmovisor/upgrades/v0.X.0/bin/structsd` if present in the container. |
| `Error reading upgrade-info.json` / corrupt JSON | Manually written or partially-flushed. Restore from backup or delete. |

## Quick diagnostics

```bash
ssh root@<public-node-ip>
VOL=/var/lib/docker/volumes/structsd-chaindata/_data

echo '--- current symlink ---'
readlink "$VOL/cosmovisor/current"

echo '--- staged upgrade binaries ---'
ls "$VOL/cosmovisor/upgrades/"
for u in $(ls "$VOL/cosmovisor/upgrades/"); do
  "$VOL/cosmovisor/upgrades/$u/bin/structsd" version 2>&1 | head -1 | sed "s|^|$u: |"
done

echo '--- data/upgrade-info.json (authoritative current upgrade) ---'
cat "$VOL/data/upgrade-info.json" | jq '{name, height}' 2>/dev/null

echo '--- batch ---'
cat "$VOL/data/upgrade-info.json.batch" | jq '.[] | {name, height}' 2>/dev/null

echo '--- chain height from last priv_validator_state.json ---'
jq '{height, round}' "$VOL/data/priv_validator_state.json"
```

The `cosmovisor/current` symlink should be the upgrade whose height is the **highest** entry in the batch whose `height ≤` the chain's current height. If it's pointing at something older, you've hit the symlink race.

## Fix path 1 — daemon panicking with UPGRADE NEEDED (symlink race)

This happened during the v0.17.0 upgrade. Cosmovisor swapped the symlink, then a container restart raced and left `current` pointing at the old binary while `data/upgrade-info.json` already said the new version had fired.

The image **`structs/structsd:latest` ≥ digest `d0d574ff`** ships `/root/scripts/reconcile-cosmovisor-current.sh` which self-heals on every container start. If you're on that image or newer, the fix is:

```bash
docker compose -f /home/docker/docker-structs-guild/compose.yaml restart structsd
docker logs --tail 30 docker-structs-guild-structsd-1 2>&1 | grep -E 'Reconciled|cosmovisor'
# expected: 'Reconciled cosmovisor/current -> upgrades/v0.X.0 (was: upgrades/v0.X-1.0, source: data/upgrade-info.json)'
```

If you're on an **older image** (no reconcile script), point the symlink manually:

```bash
ssh root@<public-node-ip>
VOL=/var/lib/docker/volumes/structsd-chaindata/_data

# what does the chain say the active upgrade should be?
ACTIVE=$(jq -r '.name' "$VOL/data/upgrade-info.json")
echo "active per chain state: $ACTIVE"

# verify binary exists for that version
ls -la "$VOL/cosmovisor/upgrades/$ACTIVE/bin/structsd"

# stop, re-point, restart
docker compose -f /home/docker/docker-structs-guild/compose.yaml stop structsd
ln -sfn "upgrades/$ACTIVE" "$VOL/cosmovisor/current"
readlink "$VOL/cosmovisor/current"   # confirm
docker compose -f /home/docker/docker-structs-guild/compose.yaml up -d structsd

# watch it come up
docker logs -f --tail 0 docker-structs-guild-structsd-1
```

## Fix path 2 — binary missing for an upgrade name

If `data/upgrade-info.json` references e.g. `v0.X.0` but `cosmovisor/upgrades/v0.X.0/bin/structsd` doesn't exist, the image you're running pre-dates that upgrade. Pull the newer image.

```bash
docker pull structs/structsd:latest
# verify it has the missing binary
docker run --rm --entrypoint sh structs/structsd:latest -c 'ls /opt/structs/cosmovisor/upgrades/'
# if yes, recreate (start.sh will install it into the volume)
cd /home/docker/docker-structs-guild
docker compose up -d --force-recreate --no-deps structsd
```

This is the same flow as a normal upgrade — see [chain-upgrade.md](chain-upgrade.md).

## Fix path 3 — corrupt or hand-edited upgrade-info.json

`data/upgrade-info.json` is written by the daemon's `x/upgrade` BeginBlocker. If it gets corrupted (interrupted write, manual edit gone wrong) the `reconcile-cosmovisor-current.sh` script will WARN and exit without fixing the symlink.

```bash
# inspect
cat /var/lib/docker/volumes/structsd-chaindata/_data/data/upgrade-info.json

# if it's invalid JSON or the .name is wrong, restore from backup
ls /var/lib/docker/volumes/structsd-chaindata/_data/data/upgrade-info.json.bak.*

# alternatively, regenerate from chain state by running the previous binary briefly,
# letting it re-fire the upgrade — this is safe because x/upgrade is idempotent at the height.
```

## Fix path 4 — node syncing too slow because it can't find peers

Not strictly a cosmovisor issue but related. If logs show `dial tcp ...` errors trying to reach `persistent_peers`, edit `config.toml`:

```bash
sed -i 's|^persistent_peers = .*|persistent_peers = "<id>@<ip>:26656,<id>@<ip>:26656,..."|' \
  /var/lib/docker/volumes/structsd-chaindata/_data/config/config.toml
docker compose restart structsd
```

The peer IDs must be **40 hex chars exactly** — a typo (e.g. odd-length hex) causes a crash-loop with `encoding/hex: odd length hex string`. Validate them with:

```bash
echo -n "<peer-id-from-someone>" | wc -c   # must be 40
```

## When in doubt

The `reconcile-cosmovisor-current.sh` script bundled in current images is the most reliable fix for symlink/upgrade-info disagreements. Read it before improvising — it explains the priority order:

```bash
docker exec docker-structs-guild-structsd-1 cat /root/scripts/reconcile-cosmovisor-current.sh
```
