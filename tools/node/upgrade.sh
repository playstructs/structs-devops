#!/usr/bin/env bash
# devops upgrade status                         [0] on-chain plan, ETA, every node's cosmovisor state
# devops upgrade preflight <site>               [0] readiness for the pending plan on one site
# devops upgrade monitor install <site> [--target H --name vX]  [1] transient systemd watcher
# devops upgrade monitor tail <site> [n]        [0]
# devops upgrade monitor stop <site>            [1]
set -euo pipefail
. "$DEVOPS_ROOT/lib/common.sh"
. "$DEVOPS_ROOT/lib/inventory.sh"
. "$DEVOPS_ROOT/lib/ssh.sh"
. "$DEVOPS_ROOT/lib/gate.sh"
. "$DEVOPS_ROOT/lib/chain.sh"
. "$DEVOPS_ROOT/lib/bundle.sh"
need yq jq curl

sub="${1:-status}"; [ $# -gt 0 ] && shift

node_probe() {
  # node_probe SITE HOST CONTAINER VOLUME RPC -> node-status key=value lines
  local pre
  pre="NODE_CONTAINER=$(printf '%q' "$3")
NODE_VOLUME=$(printf '%q' "$4")
NODE_RPC=$(printf '%q' "$5")"
  host_bundle "$1" "$2" "$pre" "$DEVOPS_ROOT/tools/host/node-status.sh" 2>/dev/null || echo "rpc=unreachable (ssh failed)"
}

case "$sub" in
  status)
    plan="$(chain_upgrade_plan || true)"
    h="$(chain_height || echo '?')"
    echo "chain $(chain_id) height $h; inventory binary $(inv_net '.binary.version') since $(inv_net '.binary.since_height')"
    if [ -n "$plan" ]; then
      name="${plan% *}"; ph="${plan#* }"
      echo "PLAN $name at height $ph (in $(( ph - h )) blocks, ~$(eta_hours "$ph") h at $(seconds_per_block) s/block)"
    else
      echo "no upgrade plan scheduled"
    fi
    inv_structsd_nodes | while IFS="$(printf '\t')" read -r s hh c rpc role vol; do
      echo "== $s:$hh ($role)"
      out="$(node_probe "$s" "$hh" "$c" "$vol" "$rpc")"
      printf '%s\n' "$out" | grep -E '^(height|cosmovisor_current|cosmovisor_upgrades|upgrade_info|image|rpc)=' | sed 's/^/  /'
      if [ -n "$plan" ]; then
        if printf '%s' "$out" | grep -q "cosmovisor_upgrades=.*\b${plan% *}\b"; then echo "  staged: upgrades/${plan% *} present"
        else echo "  NOT STAGED: upgrades/${plan% *} missing (image-based nodes stage it on pull; check runbooks/chain-upgrade.md)"; fi
      fi
    done ;;
  preflight)
    site="${1:-}"; [ -n "$site" ] || usage_die "usage: devops upgrade preflight <site>"
    host="$(inv_q "$site" '.nodes[0].host')"; [ -n "$host" ] || die "$site has no structsd node"
    out="$(node_probe "$site" "$host" "$(inv_q "$site" '.nodes[0].container')" "$(inv_q "$site" '.nodes[0].volume // "structsd-chaindata"')" "$(inv_q "$site" '.nodes[0].rpc // "http://127.0.0.1:26657"')")"
    printf '%s\n' "$out" | sed 's/^/  /'
    plan="$(chain_upgrade_plan || true)"
    rc=0
    [ -n "$plan" ] && { printf '%s' "$out" | grep -q "cosmovisor_upgrades=.*${plan% *}" && ok "binary for ${plan% *} staged" || { warn "upgrades/${plan% *} not staged"; rc=1; }; }
    printf '%s' "$out" | grep -q 'catching_up=false' && ok "in sync" || { warn "node is catching up or unreachable"; rc=1; }
    free_pct="$(printf '%s' "$out" | sed -n 's/^disk_free=.*(\([0-9]*\)% used)/\1/p')"
    [ -n "$free_pct" ] && [ "$free_pct" -ge 85 ] && { warn "disk ${free_pct}% used; upgrades can need room for a backup"; rc=1; }
    [ -f "$(inv_site_dir "$site")/app-toml.overrides" ] && echo "after the upgrade: devops node $site app-toml check"
    echo "runbook: runbooks/chain-upgrade.md"
    exit "$rc" ;;
  monitor)
    act="${1:-}"; site="${2:-}"
    [ -n "$act" ] && [ -n "$site" ] || usage_die "usage: devops upgrade monitor install|tail|stop <site>"
    shift 2
    host="$(inv_q "$site" '.nodes[0].host')"; [ -n "$host" ] || die "$site has no structsd node"
    case "$act" in
      install)
        target="" name=""
        while [ $# -gt 0 ]; do case "$1" in --target) target="$2"; shift 2 ;; --name) name="$2"; shift 2 ;; *) usage_die "unknown $1" ;; esac; done
        if [ -z "$target" ]; then plan="$(chain_upgrade_plan || true)"; [ -n "$plan" ] || die "no on-chain plan; pass --target and --name"; name="${plan% *}"; target="${plan#* }"; fi
        bundle_ensure "$site" "$host"
        tp="$(bundle_tools_path "$site" "$host")"
        cmd="systemctl stop structsd-upgrade-monitor.service 2>/dev/null || true; systemctl reset-failed structsd-upgrade-monitor.service 2>/dev/null || true
systemd-run --unit=structsd-upgrade-monitor --no-block --description='watch $name cosmovisor swap' \
  --setenv=TARGET=$target --setenv=UPGRADE_NAME=$name \
  --setenv=CONTAINER=$(inv_q "$site" '.nodes[0].container') --setenv=VOLUME=$(inv_q "$site" '.nodes[0].volume // "structsd-chaindata"') \
  /bin/bash $tp/host/upgrade-monitor.sh
sleep 2; systemctl status structsd-upgrade-monitor.service --no-pager -n 3 || true"
        if [ -n "${DEVOPS_DRY_RUN:-}" ]; then echo "$cmd"; exit 0; fi
        audit "TIER1 upgrade monitor install site=$site target=$target name=$name"
        host_run "$site" "$host" "$cmd"
        echo "tail: devops upgrade monitor tail $site   sentinels: ===UPGRADE-FIRED=== ===POSSIBLE-HALT=== ===RECOVERED===" ;;
      tail)
        n="${1:-40}"
        host_run "$site" "$host" "ls -1t /var/log/structsd-*-monitor.log 2>/dev/null | head -1 | xargs -r tail -n $n" ;;
      stop)
        audit "TIER1 upgrade monitor stop site=$site"
        host_run "$site" "$host" "systemctl stop structsd-upgrade-monitor.service; systemctl reset-failed structsd-upgrade-monitor.service 2>/dev/null || true; echo stopped" ;;
      *) usage_die "usage: devops upgrade monitor install|tail|stop <site>" ;;
    esac ;;
  *) usage_die "usage: devops upgrade status|preflight <site>|monitor ..." ;;
esac
