#!/usr/bin/env bash
# Watches a structsd node through a cosmovisor upgrade and writes sentinel
# lines a watcher can match:  ===(UPGRADE-FIRED|POSSIBLE-HALT|RECOVERED)===
# Started by `devops upgrade monitor install <site>` as a transient systemd
# unit (structsd-upgrade-monitor) so it survives ssh disconnects.
#   TARGET=<height> UPGRADE_NAME=<vX.Y.Z> [RPC=] [CONTAINER=] [VOLUME=]
set -uo pipefail

: "${TARGET:?}" "${UPGRADE_NAME:?}"
LOG="${LOG:-/var/log/structsd-${UPGRADE_NAME}-monitor.log}"
RPC="${RPC:-http://127.0.0.1:26657}"
CONTAINER="${CONTAINER:-docker-structs-guild-structsd-1}"
VOL="$(docker volume inspect "${VOLUME:-structsd-chaindata}" --format '{{.Mountpoint}}' 2>/dev/null || echo /var/lib/docker/volumes/structsd-chaindata/_data)"

exec >> "$LOG" 2>&1
echo "===== $(date -uIs) monitor started target=$TARGET upgrade=$UPGRADE_NAME container=$CONTAINER ====="

state="pre"; last_h=""; same=0
while true; do
  ts="$(date -uIs)"
  json="$(curl -s --max-time 5 "$RPC/status" || true)"
  height="$(printf '%s' "$json" | jq -r '.result.sync_info.latest_block_height // "NA"' 2>/dev/null || echo NA)"
  catch="$(printf '%s' "$json" | jq -r '.result.sync_info.catching_up // "NA"' 2>/dev/null || echo NA)"
  symlink="$(readlink "$VOL/cosmovisor/current" 2>/dev/null || echo NA)"
  info="$(jq -r '"\(.name // "none")@\(.height // 0)"' "$VOL/data/upgrade-info.json" 2>/dev/null || echo NA)"
  ctr="$(docker inspect --format '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$CONTAINER" 2>/dev/null || echo gone)"
  echo "STATUS $ts height=$height catching_up=$catch symlink=$symlink upgrade-info=$info container=$ctr"

  if [ "$symlink" = "upgrades/$UPGRADE_NAME" ] && [ "$state" != "fired" ] && [ "$state" != "recovered" ]; then
    echo "===UPGRADE-FIRED=== symlink moved to $UPGRADE_NAME at height=$height (info=$info)"
    state=fired
  fi
  if [ "$height" != "NA" ] && [ "$height" -ge "$TARGET" ] 2>/dev/null \
     && [ "$symlink" != "upgrades/$UPGRADE_NAME" ] && [ "$state" != "halt" ]; then
    echo "===POSSIBLE-HALT=== reached $TARGET but symlink=$symlink; cosmovisor may have raced (runbooks/cosmovisor-recovery.md)"
    timeout 60 docker logs --tail 80 "$CONTAINER" 2>&1 | sed 's/^/LOG  /'
    state=halt
  fi
  if [ "$state" = "fired" ] && [ "$height" != "NA" ] && [ "$height" -gt $((TARGET + 3)) ] 2>/dev/null; then
    echo "===RECOVERED=== producing blocks on $UPGRADE_NAME at height=$height"
    state=recovered
  fi
  if [ "$height" = "$last_h" ]; then same=$((same + 1)); else same=0; fi
  last_h="$height"
  [ "$same" -eq 20 ] && echo "===POSSIBLE-HALT=== height stuck at $height for 20 polls"

  if [ "$height" != "NA" ] && [ $((TARGET - height)) -lt 50 ] 2>/dev/null; then sleep 5
  elif [ "$height" != "NA" ] && [ $((TARGET - height)) -lt 500 ] 2>/dev/null; then sleep 15
  else sleep 60; fi
done
