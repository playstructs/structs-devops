# Streamed by the hub (after _prelude.sh). Env: NODE_CONTAINER NODE_VOLUME NODE_RPC
# Prints one key=value per line about a structsd node. Read-only.
c="${NODE_CONTAINER:-docker-structs-guild-structsd-1}"
v="${NODE_VOLUME:-structsd-chaindata}"
rpc="${NODE_RPC:-http://127.0.0.1:26657}"
mp="$(docker volume inspect "$v" --format '{{.Mountpoint}}' 2>/dev/null || true)"
s="$(curl -s -m 5 "$rpc/status" || true)"
echo "container=$(docker inspect --format '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null || echo missing)"
echo "started=$(docker inspect --format '{{.State.StartedAt}}' "$c" 2>/dev/null)"
echo "restarts=$(docker inspect --format '{{.RestartCount}}' "$c" 2>/dev/null)"
echo "image=$(docker inspect --format '{{.Config.Image}}' "$c" 2>/dev/null || echo '?')"
echo "digest=$(docker image inspect "$(docker inspect --format '{{.Image}}' "$c" 2>/dev/null)" --format '{{index .RepoDigests 0}}' 2>/dev/null | sed 's/.*@//')"
if [ -n "$s" ]; then
  printf '%s' "$s" | jq -r '.result | "height=\(.sync_info.latest_block_height)\ntime=\(.sync_info.latest_block_time)\ncatching_up=\(.sync_info.catching_up)\nnode_id=\(.node_info.id)\nmoniker=\(.node_info.moniker)\nversion=\(.node_info.version)\nnetwork=\(.node_info.network)\nvoting_power=\(.validator_info.voting_power)"'
  echo "peers=$(curl -s -m 5 "$rpc/net_info" | jq -r '.result.n_peers' 2>/dev/null || echo '?')"
else
  echo "rpc=unreachable"
fi
if [ -n "$mp" ]; then
  echo "cosmovisor_current=$(readlink "$mp/cosmovisor/current" 2>/dev/null || echo none)"
  echo "cosmovisor_upgrades=$(ls -1 "$mp/cosmovisor/upgrades" 2>/dev/null | tr '\n' ' ')"
  echo "upgrade_info=$(jq -c '{name,height}' "$mp/data/upgrade-info.json" 2>/dev/null || echo none)"
  echo "pruning=$(grep -m1 '^pruning = ' "$mp/config/app.toml" 2>/dev/null | cut -d= -f2- | tr -d ' "')"
  echo "data_size=$(du -sh "$mp/data" 2>/dev/null | cut -f1)"
  echo "disk_free=$(df -h "$mp" | awk 'NR==2{print $4" free of "$2" ("$5" used)"}')"
fi
