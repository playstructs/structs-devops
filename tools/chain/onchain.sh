#!/usr/bin/env bash
# devops onchain <site> show                                    [0] guild, substation, reactor, player, validator, balances vs inventory
# devops onchain <site> guild-endpoint [URL] [--broadcast]      [0]/[3] MsgGuildUpdateEndpoint (default: inventory endpoint)
# devops onchain <site> agreement-open <provider> <duration> <capacity> [--broadcast]   [0]/[3] cost/balance check first
# devops onchain <site> allocation-create <source> <power> [--broadcast]                [0]/[3] dynamic allocation
# devops onchain <site> allocation-connect <allocation> <substation> [--broadcast]      [0]/[3]
# Transactions are signed by the site's guild_admin account (override with --as <account>).
set -euo pipefail
. "$DEVOPS_ROOT/lib/common.sh"
. "$DEVOPS_ROOT/lib/inventory.sh"
. "$DEVOPS_ROOT/lib/chain.sh"
need yq jq curl

site="${1:-}"; sub="${2:-show}"
[ -n "$site" ] || usage_die "usage: devops onchain <site> show|guild-endpoint|agreement-open|allocation-create|allocation-connect"
inv_site_file "$site" >/dev/null
shift 2 2>/dev/null || shift $#
acct="guild_admin" bc=() args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --broadcast) bc=(--broadcast); shift ;;
    --as) acct="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- ${args[@]+"${args[@]}"}
tx() { exec "$DEVOPS_ROOT/tools/chain/tx.sh" "$site" "$acct" ${bc[@]+"${bc[@]}"} --note "onchain $sub" -- "$@"; }
gid="$(inv_q "$site" '.onchain.guild.id')"

case "$sub" in
  show)
    rc=0
    if [ -n "$gid" ]; then
      g="$(lcd_get "/structs/guild/$gid" | jq '.Guild // .guild')"
      echo "guild $gid: endpoint=$(printf '%s' "$g" | jq -r .endpoint) owner=$(printf '%s' "$g" | jq -r .owner) reactor=$(printf '%s' "$g" | jq -r .primaryReactorId) entry_substation=$(printf '%s' "$g" | jq -r .entrySubstationId)"
      want="$(inv_q "$site" '.onchain.guild.endpoint')"
      have="$(printf '%s' "$g" | jq -r .endpoint)"
      if [ -n "$want" ] && [ "$want" != "$have" ]; then warn "endpoint differs from inventory ($want); fix: devops onchain $site guild-endpoint"; rc=1; fi
      for k in entry_substation:entrySubstationId primary_reactor:primaryReactorId; do
        w="$(inv_q "$site" ".onchain.guild.${k%%:*}")"; h="$(printf '%s' "$g" | jq -r ".${k#*:}")"
        [ -n "$w" ] && [ "$w" != "$h" ] && { warn "${k%%:*} on chain is $h, inventory says $w"; rc=1; }
      done
      sub_id="$(printf '%s' "$g" | jq -r .entrySubstationId)"
      [ -n "$sub_id" ] && [ "$sub_id" != null ] && lcd_get "/structs/substation/$sub_id" | jq -c '.Substation // .substation | {id, owner, connectedPlayerCount: (.connectedPlayerCount // null)}' | sed 's/^/substation /'
    fi
    pid="$(inv_q "$site" '.onchain.player')"
    if [ -n "$pid" ]; then
      lcd_get "/structs/player/$pid" | jq -c '(.Player // .player) as $p | {player: $p.id, guild: $p.guildId, primaryAddress: $p.primaryAddress, substation: $p.substationId}'
      lcd_get "/structs/vault/$pid" | jq -c '{vault: .}' 2>/dev/null | cut -c1-300 || true
    fi
    vop="$(inv_q "$site" '.onchain.validator.operator')"
    if [ -n "$vop" ]; then
      lcd_get "/cosmos/staking/v1beta1/validators/$vop" | jq -r '.validator | "validator \(.description.moniker): \(.status) jailed=\(.jailed) tokens=\(.tokens)"'
    fi
    yq -r '(.onchain.accounts // {}) | to_entries[] | .key + "\t" + .value.address' "$(inv_site_file "$site")" |
    while IFS="$(printf '\t')" read -r a addr; do
      bal="$(lcd_get "/cosmos/bank/v1beta1/balances/$addr" | jq -r '[.balances[] | "\(.amount)\(.denom)"] | join(", ")')"
      echo "account $a $addr: ${bal:-0}"
    done
    exit "$rc" ;;
  guild-endpoint)
    [ -n "$gid" ] || die "$site has no onchain.guild.id"
    url="${1:-$(inv_q "$site" '.onchain.guild.endpoint')}"
    [ -n "$url" ] || usage_die "usage: devops onchain $site guild-endpoint <url>"
    info "current: $(lcd_get "/structs/guild/$gid" | jq -r '(.Guild // .guild).endpoint')"
    curl -fsS -m 10 -o /dev/null "$url" || warn "$url is not reachable right now; the crawler will fail until it is"
    tx structs guild-update-endpoint -- "$gid" "$url" ;;
  agreement-open)
    [ $# -eq 3 ] || usage_die "usage: devops onchain $site agreement-open <provider> <duration> <capacity>"
    prov="$(lcd_get "/structs/provider/$1" | jq '.Provider // .provider')"
    denom="$(printf '%s' "$prov" | jq -r .rate.denom)"; rate="$(printf '%s' "$prov" | jq -r .rate.amount)"
    addr="$(inv_q "$site" ".onchain.accounts.\"$acct\".address")"
    bal="$(lcd_get "/cosmos/bank/v1beta1/balances/$addr" | jq -r --arg d "$denom" '[.balances[] | select(.denom==$d) | .amount][0] // "0"')"
    cost="$(python3 -c "print(int('$rate')*int('$2')*int('$3'))")"
    echo "provider $1 rate=${rate}${denom} duration=$2 capacity=$3 cost=$cost$denom balance=$bal$denom"
    python3 -c "import sys; sys.exit(0 if int('$cost') <= int('$bal') else 1)" || die "cost exceeds balance"
    tx structs agreement-open -- "$1" "$2" "$3" ;;
  allocation-create)
    [ $# -eq 2 ] || usage_die "usage: devops onchain $site allocation-create <source> <power>"
    tx structs allocation-create --allocation-type dynamic -- "$1" "$2" ;;
  allocation-connect)
    [ $# -eq 2 ] || usage_die "usage: devops onchain $site allocation-connect <allocation> <substation>"
    lcd_get "/structs/allocation/$1" | jq -c '.Allocation // .allocation'
    tx structs substation-allocation-connect -- "$1" "$2" ;;
  *) usage_die "usage: devops onchain <site> show|guild-endpoint|agreement-open|allocation-create|allocation-connect" ;;
esac
