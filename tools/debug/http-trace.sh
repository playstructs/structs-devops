#!/usr/bin/env bash
# devops debug http-trace <site> <path> [--fqdn F]     [0]
#   Same GET at every hop of the web path, outside in:
#     public (DNS)  ->  host IP (--resolve)  ->  Caddy on host loopback  ->  nginx cache :8080  ->  Apache in the container
#   Prints status, X-Cache-Status, connect and TTFB per hop, and names the first failing layer.
set -euo pipefail
. "$DEVOPS_ROOT/tools/debug/_lib.sh"
need yq curl

site="${1:-}"; path="${2:-/}"
need_site "$site" "usage: devops debug http-trace <site> <path> [--fqdn F]"
shift 2 2>/dev/null || shift $#
case "$path" in /*) ;; *) path="/$path" ;; esac
fqdn=""
while [ $# -gt 0 ]; do
  case "$1" in --fqdn) fqdn="${2:?}"; shift 2 ;; *) usage_die "unknown option $1" ;; esac
done

host="$(service_host "$site" structs-webapp-cache)"
[ -n "$host" ] || host="$(service_host "$site" structs-webapp)"
[ -n "$host" ] || host="$(inv_primary_host "$site")"
fqdn="${fqdn:-$(inv_host "$site" "$host" fqdn)}"
ip="$(inv_host "$site" "$host" ipv4)"
[ -n "$fqdn" ] || die "no fqdn for $site:$host (pass --fqdn)"

fmt='code=%{http_code} connect=%{time_connect} ttfb=%{time_starttransfer} total=%{time_total}'
hub_hop() {
  local name="$1"; shift
  local hdr res cache server
  hdr="$(mktemp)"
  res="$(curl -sS -o /dev/null -D "$hdr" -m 20 -w "$fmt" "$@" 2>&1 | tail -1)" || true
  cache="$(grep -i '^x-cache-status:' "$hdr" | tail -1 | awk '{print $2}' | tr -d '\r' || true)"
  server="$(grep -i '^server:' "$hdr" | tail -1 | cut -d' ' -f2- | tr -d '\r' | tr ' ' '_' || true)"
  rm -f "$hdr"
  case "$res" in code=*) ;; *) res="code=000 note=$(printf '%s' "$res" | tr ' ' '_' | cut -c1-120)" ;; esac
  echo "hop=$name $res cache=${cache:--} server=${server:--}"
}

out="$(debug_out "http-$site").txt"
{
  echo "# devops debug http-trace $site $path  ($(iso_now), https://$fqdn$path)"
  hub_hop public "https://$fqdn$path"
  [ -n "$ip" ] && hub_hop host-ip --resolve "$fqdn:443:$ip" "https://$fqdn$path"
  pre="$(debug_preamble "$site")
export TRACE_FQDN=$(printf '%q' "$fqdn") TRACE_PATH=$(printf '%q' "$path")"
  host_bundle "$site" "$host" "$pre" "$DEBUG_HOST/http-hops.sh" || echo "hop=host-side code=000 note=ssh_failed"
} > "$out" 2>&1

printf '%-20s %-5s %-9s %-9s %-9s %-7s %s\n' HOP CODE CONNECT TTFB TOTAL CACHE NOTE
order=""
while read -r line; do
  case "$line" in
    hop=*)
      h="$(printf '%s' "$line" | sed -n 's/.*hop=\([^ ]*\).*/\1/p')"
      v() { printf '%s' "$line" | sed -n "s/.* $1=\([^ ]*\).*/\1/p"; }
      code="$(v code)"; [ -n "$code" ] || code="$(printf '%s' "$line" | sed -n 's/.*code=\([^ ]*\).*/\1/p')"
      printf '%-20s %-5s %-9s %-9s %-9s %-7s %s\n' "$h" "$code" "$(v connect)" "$(v ttfb)" "$(v total)" "$(v cache)" "$(v note)$(v server | sed 's/^-$//; s/^/ /')"
      order="$order $h:$code" ;;
    apache_procs=*) note "${line/=/: }" ;;
  esac
done < "$out"

# Walk inside out: the failing layer is the innermost hop that fails (every hop inside it answered).
verdict="" inner_ok=1
# shellcheck disable=SC2086
for item in $(printf '%s\n' $order | awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}'); do
  h="${item%%:*}"; c="${item##*:}"
  case "$c" in skip) continue ;; 000|5??) ok_hop="" ;; *) ok_hop=1 ;; esac
  if [ -z "$ok_hop" ] && [ "$inner_ok" = 1 ]; then verdict="$h"; fi
  [ -n "$ok_hop" ] || inner_ok=0
done
first_fail=""
for item in $order; do case "${item##*:}" in 000|5??) first_fail="${item%%:*}"; break ;; esac; done
echo
if [ -z "$first_fail" ]; then
  ok "every hop answered (no 5xx/timeouts). Compare codes and TTFB between hops for slowness."
else
  case "$verdict" in
    apache-in-container) msg="the webapp itself (PHP/Symfony, its DB via the bouncer, or worker saturation): structs-debug-http, then structs-debug-postgres" ;;
    nginx-8080) msg="nginx cache (structs-webapp-cache) or its upstream to structs-webapp:80" ;;
    caddy-loopback) msg="Caddy on the host (config, cert, upstream 127.0.0.1:8080)" ;;
    host-ip) msg="between the internet and the host: firewall, provider, Caddy bind address" ;;
    public) msg="DNS or the path to the host (host-ip worked)" ;;
    *) msg="see the hops above" ;;
  esac
  warn "first failing layer: ${verdict:-$first_fail} -> $msg"
fi
note "saved: ${out#"$DEVOPS_ROOT"/}"
