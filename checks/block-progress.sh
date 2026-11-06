#!/usr/bin/env bash
# block-progress (network): the public RPC tip advances at the expected rate.
. "$DEVOPS_ROOT/checks/_lib.sh"
need curl jq

s="$(rpc_status 2>/dev/null || true)"
[ -n "$s" ] || check_crit "public RPC $(chain_rpc) not answering /status"
h="$(printf '%s' "$s" | jq -r .height)"
case "$h" in ''|*[!0-9]*) check_unknown "public RPC $(chain_rpc) /status has no numeric height (got '${h:0:40}')" ;; esac
t="$(printf '%s' "$s" | jq -r .time)"
net="$(printf '%s' "$s" | jq -r .network)"
[ "$net" = "$(chain_id)" ] || bump 2 "RPC reports network $net, inventory chain_id is $(chain_id)"
age="$(iso_age_seconds "$t" || true)"
if [ -n "$age" ]; then
  bump "$(level_high "$age" "$(thr "" chain.stall_seconds_warn 60)" "$(thr "" chain.stall_seconds_crit 180)")" "height $h, last block ${age}s ago"
fi
[ "$(printf '%s' "$s" | jq -r .catching_up)" = "true" ] && bump 1 "public node reports catching_up=true"

now="$(now_epoch)"
prev="$(cstate_get last)"; cstate_set last "$h $now"
case "$prev" in *[!0-9\ ]*|*" "*" "*) prev="" ;; *" "*) ;; *) prev="" ;; esac
if [ -n "$prev" ]; then
  ph="${prev% *}"; pt="${prev#* }"; dt=$((now - pt))
  if [ "$dt" -ge 600 ] && [ "$dt" -le 86400 ]; then
    bph="$(py "int(($h - $ph) * 3600.0 / $dt)")"
    min="$(thr "" chain.blocks_per_hour_min 400)"
    if [ "$h" -le "$ph" ]; then bump 2 "no new blocks in $((dt / 60)) min (height $ph -> $h)"
    elif [ "$bph" -lt "$min" ]; then bump 1 "$bph blocks/hour over the last $((dt / 60)) min (< $min)"
    else detail "ok: $bph blocks/hour over the last $((dt / 60)) min"; fi
  fi
fi
check_finish "height $h, last block ${age:-?}s ago"
