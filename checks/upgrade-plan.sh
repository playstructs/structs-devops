#!/usr/bin/env bash
# upgrade-plan (network): a scheduled software upgrade, its ETA, and whether
# every inventory node has upgrades/<name> staged in its cosmovisor volume.
# Also flags inventory that still names an older binary than the chain runs.
. "$DEVOPS_ROOT/checks/_lib.sh"
need curl jq

inv_ver="$(inv_net '.binary.version')"
applied="$(lcd_get "/cosmos/upgrade/v1beta1/applied_plan/$inv_ver" 2>/dev/null | jq -r '.height // "0"' 2>/dev/null)"
if [ -n "$inv_ver" ] && [ "${applied:-0}" = "0" ]; then
  bump 1 "binary.version $inv_ver (network preset or your network.yaml) has no applied upgrade plan on chain (typo, or inventory ahead of chain?)"
fi
plan="$(chain_upgrade_plan 2>/dev/null || true)"
if [ -z "$plan" ]; then
  check_finish "no upgrade scheduled; chain runs $inv_ver (applied at ${applied:-?})"
fi
name="${plan% *}"; ph="${plan#* }"
h="$(chain_height)"; eta="$(eta_hours "$ph")"
detail "plan $name at height $ph, current $h, ETA ~${eta}h"
cstate_set plan "$name $ph"

staged=0 total=0
while IFS="$(printf '\t')" read -r s hh c rpc _ vol; do
  [ -n "$s" ] || continue
  total=$((total + 1))
  pre="NODE_CONTAINER=$(printf '%q' "$c")
NODE_VOLUME=$(printf '%q' "$vol")
NODE_RPC=$(printf '%q' "$rpc")"
  if ! probe "$s" "$hh" "$pre" "$DEVOPS_ROOT/tools/host/node-status.sh"; then bump 3 "$s:$hh unreachable"; continue; fi
  case " $(pv cosmovisor_upgrades) " in
    *" $name "*) staged=$((staged + 1)); detail "ok: $s:$hh has upgrades/$name" ;;
    *)
      lvl="$(level_low "$eta" 48 6)"; [ "$lvl" -eq 0 ] && lvl=1
      bump "$lvl" "$s:$hh has NOT staged upgrades/$name (ETA ${eta}h): devops upgrade preflight $s; runbooks/chain-upgrade.md" ;;
  esac
done <<EOF
$(inv_structsd_nodes)
EOF
if python3 -c "import sys; sys.exit(0 if float('$eta') <= 3 else 1)" 2>/dev/null; then
  bump 1 "upgrade $name in ~${eta}h: start monitors now (devops upgrade monitor install <site>, tier 1)"
fi
check_finish "upgrade $name at $ph (~${eta}h); staged on $staged/$total nodes"
