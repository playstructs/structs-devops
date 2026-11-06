# Host evidence collector (streamed). Writes a tar.gz of the snapshot to stdout;
# everything else goes to stderr. Read-only. Log tails are redacted on the host.
# Env: SNAP_CONTAINERS (space-separated), SNAP_N_COMPOSE + SNAP_COMPOSE_<i>,
#      SNAP_LOG_LINES, SNAP_NODE_CONTAINER, SNAP_NODE_RPC, SNAP_NODE_VOLUME,
#      SNAP_PG (1 when structs-pg runs here), SNAP_PACKS + PACK_<name> SQL, PG_CONTAINER.
# A missing piece of evidence is not a failure: collect what is there.
set +e
d="$(mktemp -d /tmp/devops-snapshot.XXXXXX)"
trap 'rm -rf "$d"' EXIT
mkdir -p "$d/logs"

{
  echo "== $(hostname) $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  uptime; echo "nproc $(nproc)"
  echo; free -m
  echo; df -h -x tmpfs -x overlay 2>/dev/null || df -h
  echo; top -b -n1 | head -30
  echo; echo "== OOM / killed (kernel, last 50)"
  dmesg -T 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process' | tail -50 || true
  echo; echo "== listening sockets"
  ss -ltnp 2>/dev/null | head -60 || true
  echo; echo "== docker $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  docker system df 2>/dev/null || true
} > "$d/host.txt" 2>&1

{
  docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
  echo
  echo "== inventory containers: restarts, state, image"
  for c in ${SNAP_CONTAINERS:-}; do
    docker inspect -f '{{.Name}} status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}} restarts={{.RestartCount}} started={{.State.StartedAt}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} image={{.Config.Image}} id={{.Image}}' "$c" 2>/dev/null \
      || echo "/$c MISSING"
  done
} > "$d/containers.txt" 2>&1

docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}' > "$d/stats.txt" 2>&1 || true

i=0
while [ "$i" -lt "${SNAP_N_COMPOSE:-0}" ]; do
  v="SNAP_COMPOSE_$i"
  { echo "== ${!v}"; eval "${!v} ps -a" 2>&1; echo; } >> "$d/compose.txt"
  i=$((i + 1))
done

for c in ${SNAP_CONTAINERS:-}; do
  clog "$c" --tail "${SNAP_LOG_LINES:-300}" ts | redact > "$d/logs/$c.log"
  lp="$(docker inspect -f '{{.LogPath}}' "$c" 2>/dev/null)"
  [ -n "$lp" ] && echo "$c log_size=$(du -h "$lp" 2>/dev/null | cut -f1) rotation=$(docker inspect -f '{{index .HostConfig.LogConfig.Config "max-size"}}' "$c" 2>/dev/null | sed 's/^$/none/')" >> "$d/logs/_sizes.txt"
done

if [ -n "${SNAP_NODE_CONTAINER:-}" ]; then
  rpc="${SNAP_NODE_RPC:-http://127.0.0.1:26657}"
  {
    echo "== status"
    curl -s -m 8 "$rpc/status" | jq '.result | {node_info: {id: .node_info.id, moniker: .node_info.moniker, version: .node_info.version, network: .node_info.network}, sync_info, voting_power: .validator_info.voting_power}' 2>&1
    echo "== peers"
    curl -s -m 8 "$rpc/net_info" | jq -r '.result.n_peers as $n | "n_peers=\($n)", (.result.peers[] | "\(.node_info.id) \(.node_info.moniker) \(.remote_ip) outbound=\(.is_outbound)")' 2>&1
    mp="$(docker volume inspect "${SNAP_NODE_VOLUME:-structsd-chaindata}" -f '{{.Mountpoint}}' 2>/dev/null || true)"
    if [ -n "$mp" ]; then
      echo "== cosmovisor"
      echo "current -> $(readlink "$mp/cosmovisor/current" 2>/dev/null)"
      echo "upgrades: $(ls "$mp/cosmovisor/upgrades" 2>/dev/null | tr '\n' ' ')"
      echo "upgrade-info.json: $(cat "$mp/data/upgrade-info.json" 2>/dev/null)"
      echo "data size: $(du -sh "$mp/data" 2>/dev/null | cut -f1)"
    fi
    echo "== consensus signatures in the last 2000 log lines"
    clog "$SNAP_NODE_CONTAINER" --tail 2000 | grep -E 'CONSENSUS FAILURE|LastResultsHash|AppHash|wrong Block\.Header|UPGRADE .* NEEDED|panic|odd length hex|pong timeout|Stopping peer' | tail -40
  } > "$d/node.txt" 2>&1
fi

if [ "${SNAP_PG:-}" = 1 ] && [ -n "${PG_CONTAINER:-}" ]; then
  for p in ${SNAP_PACKS:-}; do
    v="PACK_$(printf '%s' "$p" | tr '-' '_')"
    printf '%s\n' "${!v}" | docker exec -i -u postgres -e PGUSER=postgres -e PGHOST=/var/run/postgresql \
      -e PGOPTIONS="-c default_transaction_read_only=on -c statement_timeout=20000 -c lock_timeout=2000 -c application_name=structs-devops-snapshot" \
      "$PG_CONTAINER" psql -X -P pager=off -v ON_ERROR_STOP=0 -d structs -f - > "$d/pg-$p.txt" 2>&1 || true
  done
  docker top "$PG_CONTAINER" -eo pid,pcpu,etime,time,args 2>/dev/null | { read -r h; echo "$h"; sort -k2 -nr | head -15; } > "$d/pg-processes.txt" 2>&1 || true
fi

if systemctl list-unit-files caddy.service >/dev/null 2>&1; then
  { echo "caddy $(systemctl is-active caddy 2>/dev/null)"; journalctl -u caddy --since '-2h' --no-pager 2>/dev/null | tail -300 | redact; } > "$d/caddy.log" 2>&1
fi
{ ufw status verbose 2>/dev/null || echo "ufw not available"; } > "$d/firewall.txt" 2>&1

tar -C "$d" -czf - .
