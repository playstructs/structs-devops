#!/usr/bin/env bash
# sync-lag <site>: the sync-state indexer follows the chain tip, writes every
# block, and the API projections it feeds are fresh.
. "$DEVOPS_ROOT/checks/_lib.sh"
. "$DEVOPS_ROOT/checks/_pg.sh"
check_site_arg "${1:-}"; site="$1"
pg_probe "$site" "$DEVOPS_ROOT/checks/host/sync.sh"

cur="$(pv cursor)"
[ -n "$cur" ] || check_crit "sync_state.sync_cursor is empty (sync-state never ran?)"
IFS='|' read -r cid last _ lagdb status upd_age _ <<EOF
$cur
EOF
[ "$cid" = "$(chain_id)" ] || bump 2 "cursor chain_id $cid, inventory chain_id $(chain_id)"
pub="$(chain_height 2>/dev/null || true)"
if [ -n "$pub" ]; then
  lag=$((pub - last))
  bump "$(level_high "$lag" "$(thr "$site" sync.lag_blocks_warn 20)" "$(thr "$site" sync.lag_blocks_crit 200)")" \
    "indexed $last, chain $pub (lag $lag; cursor says ${lagdb:-?}, status ${status:-?})"
else
  bump 3 "public RPC not answering; cursor at $last (lag ${lagdb:-?})"
fi
bump "$(level_high "${upd_age:-0}" 120 600)" "cursor last updated ${upd_age}s ago"
he="$(pv handler_errors_1h 0)"
[ "$he" -gt 0 ] && bump 1 "$he handler errors in the last hour (devops debug pg $site sync-state)"
b1h="$(pv blocks_1h 0)"
detail "blocks ingested in the last hour: $b1h"
for p in $(printf '%s\n' "$PROBE" | sed -n 's/^proj_//p'); do
  m="${p%%=*}"; v="${p#*=}"; age="${v%%|*}"
  bump "$(level_high "$age" 600 3600)" "projection $m refreshed ${age}s ago"
done
rd="$(pv ready)"
if [ -n "$rd" ]; then
  IFS='|' read -r data_ready tx_ready ih ot <<EOF
$rd
EOF
  [ "$data_ready" = "true" ] || bump 1 "api_readiness data_ready=$data_ready (indexed $ih, observed tip $ot)"
  [ "$tx_ready" = "true" ] || bump 1 "api_readiness transaction_ready=$tx_ready (the webapp will refuse to queue transactions)"
fi
check_finish "indexed $last, lag ${lag:-?} blocks"
