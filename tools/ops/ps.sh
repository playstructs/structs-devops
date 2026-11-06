#!/usr/bin/env bash
# devops ps <site>   [0] containers per stack with health, image digest, uptime
set -euo pipefail
. "$DEVOPS_ROOT/lib/common.sh"
. "$DEVOPS_ROOT/lib/inventory.sh"
. "$DEVOPS_ROOT/lib/ssh.sh"
need yq

site="${1:-}"; [ -n "$site" ] || usage_die "usage: devops ps <site>"
inv_site_file "$site" >/dev/null
for st in $(inv_stack_ids "$site"); do
  h="$(inv_stack_host "$site" "$st")"
  echo "== $site/$st on $h ($(inv_stack "$site" "$st" path))"
  host_run "$site" "$h" "$(inv_compose_cmd "$site" "$st") ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}\t{{.Image}}' 2>&1" || warn "compose ps failed for $st"
done
