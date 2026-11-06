# shellcheck shell=bash
# Chain queries over public HTTP endpoints (no keys, no hosts).

chain_rpc() { printf '%s' "${DEVOPS_RPC:-$(inv_net '.endpoints.rpc')}"; }
chain_lcd() { printf '%s' "${DEVOPS_LCD:-$(inv_net '.endpoints.lcd')}"; }
chain_id()  { inv_net '.chain_id'; }

lcd_get() {
  curl -sS -m "${DEVOPS_HTTP_TIMEOUT:-15}" -H 'Accept: application/json' "$(chain_lcd)$1"
}

rpc_get() {
  local base="${2:-$(chain_rpc)}"
  curl -sS -m "${DEVOPS_HTTP_TIMEOUT:-15}" "$base$1"
}

# rpc_status [RPC_BASE] -> compact JSON {height,time,catching_up,network,version,moniker,peers?}
rpc_status() {
  rpc_get /status "${1:-}" | jq -c '.result | {height: (.sync_info.latest_block_height|tonumber),
    time: .sync_info.latest_block_time, catching_up: .sync_info.catching_up,
    network: .node_info.network, moniker: .node_info.moniker, node_id: .node_info.id}'
}

chain_height() { rpc_status "${1:-}" | jq -r '.height'; }

# Current on-chain upgrade plan: "name height" or empty
chain_upgrade_plan() {
  lcd_get /cosmos/upgrade/v1beta1/current_plan | jq -r 'if .plan then "\(.plan.name) \(.plan.height)" else "" end'
}

# Proposals in voting period: TSV id, title, voting_end_time, type
gov_voting_proposals() {
  lcd_get '/cosmos/gov/v1/proposals?proposal_status=2&pagination.limit=100' | jq -r '
    .proposals[]? | [.id, (.title // .metadata // "untitled"), .voting_end_time,
      ((.messages[0]["@type"] // "text") | split(".") | last)] | @tsv'
}

# gov_vote_of ID ADDRESS -> option string or empty
gov_vote_of() {
  lcd_get "/cosmos/gov/v1/proposals/$1/votes/$2" 2>/dev/null \
    | jq -r '.vote.options[0].option // empty' 2>/dev/null || true
}

seconds_per_block() { inv_net '.block_time_seconds // 6'; }

# ETA in hours for a height, using the configured block time
eta_hours() {
  local target="$1" h spb
  h="$(chain_height)"; spb="$(seconds_per_block)"
  [ -n "$h" ] || { echo "?"; return; }
  python3 -c "print(round(max(0, ($target - $h)) * $spb / 3600, 1))"
}
