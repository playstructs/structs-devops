#!/usr/bin/env bash
# devops node <site> status                  [0] structsd on each node of the site
# devops node <site> app-toml check|apply    [0]/[1] re-apply app.toml overrides (restart is separate, tier 2)
# devops node <site> rotate-node-key         [2] new P2P identity (after cloning chaindata)
set -euo pipefail
. "$DEVOPS_ROOT/lib/common.sh"
. "$DEVOPS_ROOT/lib/inventory.sh"
. "$DEVOPS_ROOT/lib/ssh.sh"
. "$DEVOPS_ROOT/lib/gate.sh"
. "$DEVOPS_ROOT/lib/bundle.sh"
need yq jq

site="${1:-}"; sub="${2:-status}"
[ -n "$site" ] || usage_die "usage: devops node <site> status|app-toml check|apply|rotate-node-key"
inv_site_file "$site" >/dev/null
[ -n "$(inv_q "$site" '.nodes[0].host')" ] || die "site $site declares no structsd nodes"
host="$(inv_q "$site" '.nodes[0].host')"
container="$(inv_q "$site" '.nodes[0].container')"
volume="$(inv_q "$site" '.nodes[0].volume // "structsd-chaindata"')"
rpc="$(inv_q "$site" '.nodes[0].rpc // "http://127.0.0.1:26657"')"
gate_site "$site"; GATE_HOST="$host"

case "$sub" in
  status)
    for i in $(seq 0 $(( $(inv_q "$site" '.nodes | length') - 1 ))); do
      h="$(inv_q "$site" ".nodes[$i].host")"
      echo "== $site:$h ($(inv_q "$site" ".nodes[$i].role // \"full\""))"
      pre="NODE_CONTAINER=$(printf '%q' "$(inv_q "$site" ".nodes[$i].container")")
NODE_VOLUME=$(printf '%q' "$(inv_q "$site" ".nodes[$i].volume // \"structsd-chaindata\"")")
NODE_RPC=$(printf '%q' "$(inv_q "$site" ".nodes[$i].rpc // \"http://127.0.0.1:26657\"")")"
      host_bundle "$site" "$h" "$pre" "$DEVOPS_ROOT/tools/host/node-status.sh" | sed 's/^/  /'
    done
    want_id="$(inv_q "$site" '.nodes[0].node_id')"
    [ -n "$want_id" ] && echo "inventory node_id=$want_id"
    ;;
  app-toml)
    mode="${3:-check}"
    [ -f "$(inv_site_dir "$site")/app-toml.overrides" ] || die "site $site has no app-toml.overrides"
    bundle_ensure "$site" "$host"
    case "$mode" in
      check) bundle_run "$site" "$host" app-toml-overrides.sh --check ;;
      apply)
        if [ -n "${DEVOPS_DRY_RUN:-}" ]; then bundle_run "$site" "$host" app-toml-overrides.sh --check || true; exit 0; fi
        audit "TIER1 app-toml apply site=$site host=$host"
        bundle_run "$site" "$host" app-toml-overrides.sh --apply
        note "takes effect after a restart (tier 2): devops restart $site structsd" ;;
      *) usage_die "usage: devops node <site> app-toml check|apply" ;;
    esac ;;
  rotate-node-key)
    st="$(inv_service_stack "$site" structsd)"; [ -n "$st" ] || st="$(inv_q "$site" '.stacks[0].id')"
    compose="$(inv_compose_cmd "$site" "$st")"
    cmd="set -e
mp=\$(docker volume inspect $(printf '%q' "$volume") --format '{{.Mountpoint}}')
$compose stop structsd
cp -a \"\$mp/config/node_key.json\" \"\$mp/config/node_key.json.bak.\$(date +%Y%m%dT%H%M%S)\"
rm \"\$mp/config/node_key.json\"
$compose start structsd
for i in \$(seq 1 30); do id=\$(curl -s -m 3 $rpc/status | jq -r '.result.node_info.id' 2>/dev/null || true); [ -n \"\$id\" ] && [ \"\$id\" != null ] && break; sleep 2; done
echo \"new node_id=\$id\""
    GATE_EFFECT="Stops structsd, moves node_key.json aside, starts structsd (CometBFT generates a new key). Peers that pinned the old id ($(inv_q "$site" '.nodes[0].node_id')) must update persistent_peers."
    GATE_ROLLBACK="Stop structsd, restore node_key.json.bak.<stamp>, start structsd."
    GATE_VERIFY="devops node $site status; then update node_id in site.yaml and network.yaml persistent_peers, and tell peers"
    gate 2 "Rotate P2P node key on $site ($container)" "$cmd"
    host_run "$site" "$host" "$cmd"
    warn "update inventory: sites/$site/site.yaml nodes[0].node_id and network.yaml persistent_peers, then devops inventory render"
    ;;
  *) usage_die "usage: devops node <site> status|app-toml check|apply|rotate-node-key" ;;
esac
