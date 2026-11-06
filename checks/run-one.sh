#!/usr/bin/env bash
# devops check <id> [site]    run one check and print its full output (no notifications)
# devops checks               list the catalog
set -uo pipefail
. "$DEVOPS_ROOT/lib/common.sh"

CAT="$DEVOPS_ROOT/checks/catalog.tsv"
if [ "${1:-}" = "--list" ] || [ -z "${1:-}" ]; then
  printf '%-20s %-8s %-7s %-12s %s\n' ID SCOPE GROUP APPLIES DESCRIPTION
  grep -v '^#' "$CAT" | awk -F'\t' 'NF>=5 {printf "%-20s %-8s %-7s %-12s %s\n", $1, $2, $3, $4, $5}'
  exit 0
fi
id="$1"; site="${2:-}"
row="$(awk -F'\t' -v id="$id" '$1 == id' "$CAT")"
[ -n "$row" ] || usage_die "unknown check $id (devops checks)"
scope="$(printf '%s' "$row" | cut -f2)"
[ -f "$DEVOPS_ROOT/checks/$id.sh" ] || die "checks/$id.sh is missing"
if [ "$scope" = "site" ]; then
  [ -n "$site" ] || usage_die "check $id needs a site: devops check $id <site>"
  CHECK_SCOPE="$site" exec bash "$DEVOPS_ROOT/checks/$id.sh" "$site"
fi
CHECK_SCOPE=network exec bash "$DEVOPS_ROOT/checks/$id.sh"
