#!/usr/bin/env bash
# devops logs <site> <service> [lines] [--since 30m] [--grep RE]   [0]
set -euo pipefail
. "$DEVOPS_ROOT/lib/common.sh"
. "$DEVOPS_ROOT/lib/inventory.sh"
. "$DEVOPS_ROOT/lib/ssh.sh"
need yq

site="${1:-}"; svc="${2:-}"
[ -n "$site" ] && [ -n "$svc" ] || usage_die "usage: devops logs <site> <service> [lines] [--since 30m] [--grep RE]"
shift 2
lines=200 since="" re=""
while [ $# -gt 0 ]; do
  case "$1" in
    --since) since="$2"; shift 2 ;;
    --grep) re="$2"; shift 2 ;;
    *[!0-9]*) usage_die "unknown argument $1" ;;
    *) lines="$1"; shift ;;
  esac
done
c="$(inv_container "$site" "$svc")" || die "service $svc not declared in $site stacks (devops ps $site)"
st="$(inv_service_stack "$site" "$svc")"; h="$(inv_stack_host "$site" "$st")"
case "$since" in ""|[0-9]*[smhd]) ;; *) usage_die "--since takes a duration like 30m, 2h, 1d" ;; esac
host_bundle "$site" "$h" "export LOG_CONTAINER=$(printf '%q' "$c") LOG_LINES=$(printf '%q' "$lines") LOG_SINCE=$(printf '%q' "$since") LOG_GREP=$(printf '%q' "$re")" \
  "$DEVOPS_ROOT/tools/host/logs.sh"
