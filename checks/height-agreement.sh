#!/usr/bin/env bash
# height-agreement (network): the public RPC and every inventory structsd node
# report heights within a few blocks of each other.
. "$DEVOPS_ROOT/checks/_lib.sh"
need curl jq

pub="$(chain_height 2>/dev/null || true)"
[ -n "$pub" ] || check_unknown "public RPC not answering"
max="$pub"; min="$pub"; list="public=$pub"
while IFS="$(printf '\t')" read -r s h c rpc _ vol; do
  [ -n "$s" ] || continue
  pre="NODE_CONTAINER=$(printf '%q' "$c")
NODE_VOLUME=$(printf '%q' "$vol")
NODE_RPC=$(printf '%q' "$rpc")"
  if ! probe "$s" "$h" "$pre" "$DEVOPS_ROOT/tools/host/node-status.sh"; then bump 3 "$s:$h unreachable"; continue; fi
  nh="$(pv height)"
  case "$nh" in ''|*[!0-9]*) bump 2 "$s:$h reports no height ($(pv rpc container))"; continue ;; esac
  list="$list $s:$h=$nh"
  [ "$nh" -gt "$max" ] && max="$nh"
  [ "$nh" -lt "$min" ] && min="$nh"
done <<EOF
$(inv_structsd_nodes)
EOF
spread=$((max - min))
detail "$list"
bump "$(level_high "$spread" "$(thr "" heights.disagree_blocks_warn 5)" "$(thr "" heights.disagree_blocks_crit 50)")" "spread $spread blocks ($list)"
check_finish "all nodes within $spread blocks of each other (tip $max)"
