#!/usr/bin/env bash
# node-health <site>: each structsd node on the site is current, peered, and
# runs the image, node key and cosmovisor binary the inventory says it does.
. "$DEVOPS_ROOT/checks/_lib.sh"
check_site_arg "${1:-}"; site="$1"
f="$(inv_site_file "$site")"

nn="$(yq '(.nodes // []) | length' "$f")"
[ "$nn" -gt 0 ] || check_ok "no structsd nodes on this site"
want_digest="$(inv_net '.images.structsd.digest')"
want_cv="$(inv_net '.binary.cosmovisor_current')"
peers_min="$(thr "$site" chain.peers_min 3)"

k=0
while [ "$k" -lt "$nn" ]; do
  q() { yq -r ".nodes[$k].$1 // \"\"" "$f"; }
  h="$(q host)"; c="$(q container)"; role="$(q role)"
  pre="NODE_CONTAINER=$(printf '%q' "$c")
NODE_VOLUME=$(printf '%q' "$(q volume)")
NODE_RPC=$(printf '%q' "$(q rpc)")"
  k=$((k + 1))
  if ! probe "$site" "$h" "$pre" "$DEVOPS_ROOT/tools/host/node-status.sh"; then bump 3 "$h: probe failed (ssh unreachable?)"; continue; fi
  st="$(pv container missing)"
  case "$st" in running/*) ;; *) bump 2 "$h structsd container $c is $st"; continue ;; esac
  if [ "$(pv rpc)" = "unreachable" ]; then bump 2 "$h structsd RPC not answering on $(q rpc)"; continue; fi
  height="$(pv height)"; age="$(iso_age_seconds "$(pv time)" || true)"
  if [ -n "$age" ]; then
    bump "$(level_high "$age" "$(thr "$site" chain.stall_seconds_warn 60)" "$(thr "$site" chain.stall_seconds_crit 180)")" \
      "$h height $height, last block ${age}s ago"
  fi
  [ "$(pv catching_up)" = "true" ] && bump 1 "$h is catching up"
  peers="$(pv peers 0)"
  if [ "$peers" = "0" ]; then bump 2 "$h has 0 peers"
  elif [ "$peers" -lt "$peers_min" ] 2>/dev/null; then bump 1 "$h has $peers peers (< $peers_min)"
  else detail "ok: $h $peers peers"; fi
  inv_id="$(q node_id)"
  if [ -n "$inv_id" ] && [ "$(pv node_id)" != "$inv_id" ]; then
    bump 2 "$h node_id $(pv node_id) differs from inventory $inv_id (copied node_key? update inventory and peers)"
  fi
  d="$(pv digest)"
  if [ -n "$want_digest" ] && [ -n "$d" ] && [ "$d" != "$want_digest" ]; then
    bump 1 "$h runs structsd image ${d:0:19} but network.yaml pins ${want_digest:0:19}"
  fi
  cv="$(pv cosmovisor_current)"
  if [ -n "$want_cv" ] && [ -n "$cv" ] && [ "$cv" != "none" ] && [ "${cv%/}" != "$want_cv" ] && [ "$(basename "$cv")" != "$(basename "$want_cv")" ]; then
    bump 1 "$h cosmovisor current -> $cv (inventory expects $want_cv)"
  fi
  if [ "$role" = "validator" ] && [ "$(pv voting_power 0)" = "0" ]; then
    bump 1 "$h role validator but this node reports voting_power 0"
  fi
done
check_finish "$nn node(s) current"
