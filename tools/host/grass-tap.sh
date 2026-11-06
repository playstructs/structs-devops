# Host side of devops debug grass-tap (streamed). Subscribes to NATS over the
# websocket listener as the anonymous read-only user (no_auth_user reader),
# from a throwaway nats-box container sharing the NATS container's network.
# Env: STRUCTS_NATS_CONTAINER STRUCTS_GRASS_CONTAINER TAP_SECONDS TAP_SUBJECT TAP_PULL
set +e
n="${STRUCTS_NATS_CONTAINER:-}"
[ -n "$n" ] || { echo "no structs-nats container for this site" >&2; exit 1; }
echo "nats_state=$(docker inspect -f '{{.State.Status}}' "$n" 2>/dev/null || echo missing)"
if [ -n "${STRUCTS_GRASS_CONTAINER:-}" ]; then
  g="$STRUCTS_GRASS_CONTAINER"
  echo "grass_state=$(docker inspect -f '{{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}} restarts={{.RestartCount}}' "$g" 2>/dev/null || echo missing)"
  gl="$(mktemp)"; clog "$g" --since 1h > "$gl"
  echo "grass_dropped_full_buffer_1h=$(grep -c 'dropped notification due to full buffer' "$gl")"
  echo "grass_listen_lines_1h=$(grep -ci 'listen' "$gl")"
  echo "grass_errors_1h=$(grep -ciE 'error|authorization violation' "$gl")"
  rm -f "$gl"
fi
if [ "${TAP_PULL:-0}" != 1 ] && ! docker image inspect natsio/nats-box:latest >/dev/null 2>&1; then
  echo "subscriber=skipped (natsio/nats-box:latest not present)"
  exit 0
fi
echo "== subscribing to '${TAP_SUBJECT:->}' for ${TAP_SECONDS:-15}s via ws://127.0.0.1:1443 as reader"
docker run --rm --network "container:$n" natsio/nats-box:latest \
  timeout "${TAP_SECONDS:-15}" nats sub "${TAP_SUBJECT:->}" --server ws://127.0.0.1:1443 2>&1 |
  awk '
    /Received on/ { match($0, /"[^"]*"/); s = substr($0, RSTART + 1, RLENGTH - 2); cnt[s]++; total++; want = (cnt[s] == 1); next }
    want && NF { sample[s] = substr($0, 1, 160); want = 0; next }
    /nats: error|Authorization|connection refused|i\/o timeout/ { print "error: " $0 }
    END {
      printf "messages=%d subjects=%d\n", total, length(cnt)
      for (k in cnt) printf "%7d  %s  sample: %s\n", cnt[k], k, sample[k]
    }'
