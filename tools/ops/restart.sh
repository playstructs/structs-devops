#!/usr/bin/env bash
# devops restart <site> <service...>   [2] docker compose restart (never recreate)
set -euo pipefail
. "$DEVOPS_ROOT/lib/common.sh"
. "$DEVOPS_ROOT/lib/inventory.sh"
. "$DEVOPS_ROOT/lib/ssh.sh"
. "$DEVOPS_ROOT/lib/gate.sh"
need yq

site="${1:-}"; [ $# -ge 2 ] || usage_die "usage: devops restart <site> <service...>"
shift
inv_site_file "$site" >/dev/null
st=""
for svc in "$@"; do
  case "$svc" in structs-pg-init) die "never restart structs-pg-init on a live site" ;; esac
  s="$(inv_service_stack "$site" "$svc")"
  [ -n "$s" ] || die "service $svc not declared in $site (devops ps $site)"
  [ -z "$st" ] && st="$s"
  [ "$s" = "$st" ] || die "services span stacks ($st, $s); restart them separately"
done
h="$(inv_stack_host "$site" "$st")"
cmd="$(inv_compose_cmd "$site" "$st") restart $(quote_argv "$@")"

gate_site "$site"; GATE_HOST="$h"
GATE_EFFECT="Restarts $* on $site ($st). Users of these services see a brief interruption."
case " $* " in
  *" structs-pg "*) GATE_EFFECT="$GATE_EFFECT Every service on this host loses the database for the restart." ;;
  *" structsd "*) GATE_EFFECT="$GATE_EFFECT structsd restart: RPC/LCD down until it rejoins; app.toml is kept (restart, not recreate)." ;;
esac
GATE_ROLLBACK="None needed; if a service does not come back: devops logs $site <service> 200"
GATE_VERIFY="devops health $site"
if [ -n "${DEVOPS_DRY_RUN:-}" ]; then echo "dry-run: $cmd"; exit 0; fi
gate 2 "Restart $* on $site" "$cmd"
host_run "$site" "$h" "$cmd"
ok "restarted $*; verify: devops health $site"
