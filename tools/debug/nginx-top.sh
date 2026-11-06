#!/usr/bin/env bash
# devops debug nginx-top <site> [--since 1h] [--top N]     [0]
#   Summarizes the nginx cache (structs-webapp-cache) access log: paths with ids
#   collapsed, status codes, user agents, bytes, peak rate, and scraper loops
#   (one agent walking /page/N or ?offset= of the same listing).
set -euo pipefail
. "$DEVOPS_ROOT/tools/debug/_lib.sh"
need yq

site="${1:-}"
need_site "$site" "usage: devops debug nginx-top <site> [--since 1h] [--top N]"
shift
since=1h topn=15
while [ $# -gt 0 ]; do
  case "$1" in
    --since) since="${2:?}"; shift 2 ;;
    --top) topn="${2:?}"; shift 2 ;;
    *) usage_die "unknown option $1" ;;
  esac
done
case "$since" in *[!0-9smhd]*|"") usage_die "--since takes a docker duration like 30m, 1h, 6h" ;; esac
host="$(service_host "$site" structs-webapp-cache)"
[ -n "$host" ] || die "$site has no structs-webapp-cache in the inventory"

out="$(debug_out "nginx-top-$site").txt"
pre="$(debug_preamble "$site")
export TOP_SINCE=$(printf '%q' "$since") TOP_N=$(printf '%q' "$topn")"
{
  echo "# devops debug nginx-top $site --since $since  ($(iso_now))"
  host_bundle "$site" "$host" "$pre" "$DEBUG_HOST/nginx-top.sh"
} 2>&1 | tee "$out"
note "saved: ${out#"$DEVOPS_ROOT"/}"
