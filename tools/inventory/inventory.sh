#!/usr/bin/env bash
# devops inventory validate | render [--check] | show [site] | discover <site> | env <site>
set -euo pipefail
. "$DEVOPS_ROOT/lib/common.sh"
. "$DEVOPS_ROOT/lib/inventory.sh"
. "$DEVOPS_ROOT/lib/ssh.sh"
need yq python3

sub="${1:-help}"; [ $# -gt 0 ] && shift
PY="$DEVOPS_ROOT/tools/inventory"

case "$sub" in
  validate)
    python3 "$PY/validate.py" ;;
  render)
    python3 "$PY/render.py" "$@" ;;
  show)
    if [ -n "${1:-}" ]; then
      yq '.' "$(inv_site_file "$1")"
    else
      printf '%-16s %-12s %-28s %s\n' SITE KIND SSH VERIFIED
      for s in $(inv_sites); do
        printf '%-16s %-12s %-28s %s\n' "$s" "$(inv_kind "$s")" "$(inv_q "$s" '.hosts[0].ssh')" "$(inv_q "$s" '.last_verified')"
      done
    fi
    ;;
  env)
    # Flat env file for host-side scripts (they never parse YAML).
    [ -n "${1:-}" ] || usage_die "usage: devops inventory env <site>"
    inv_site_env "$1"
    ;;
  discover)
    # Read-only: what is actually running, to compare with site.yaml.
    [ -n "${1:-}" ] || usage_die "usage: devops inventory discover <site>"
    site="$1"
    for h in $(inv_host_ids "$site"); do
      echo "== $site:$h ($(ssh_target "$site" "$h"))"
      host_run "$site" "$h" '
        echo "-- compose projects"; docker compose ls 2>/dev/null || true
        echo "-- containers"; docker ps --format "{{.Names}}\t{{.Image}}\t{{.Status}}" 2>/dev/null | sort
        echo "-- listening ports"; (ss -ltnH 2>/dev/null || netstat -ltn 2>/dev/null) | awk "{print \$4}" | sort -u | tr "\n" " "; echo
        echo "-- disk"; df -h / 2>/dev/null | tail -1
        echo "-- os"; (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || uname -a
        echo "-- cpu/mem"; nproc 2>/dev/null; free -g 2>/dev/null | awk "/Mem:/{print \$2\" GB RAM\"}"
      '
    done
    echo
    echo "Compare with: devops inventory show $site   (update site.yaml, bump last_verified, then devops inventory render)"
    ;;
  help|-h|--help|*)
    cat <<'EOF'
devops inventory validate              check every site.yaml and network.yaml
devops inventory render [--check]      regenerate AGENTS.md and site README state blocks
devops inventory show [site]           list sites, or print one site.yaml
devops inventory env <site>            flat env (host_env) for host-side scripts
devops inventory discover <site>       read-only: running containers/ports vs inventory
EOF
    ;;
esac
