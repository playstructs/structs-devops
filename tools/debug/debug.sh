#!/usr/bin/env bash
# devops debug <tool> ...                     [0] read-only debugging tools
#   snapshot <site>                     evidence bundle -> inventory/reports/runs/<date>/debug/<site>-snapshot-*/
#   pg <site> list|<pack>|sql "<SELECT>"|explain "<SELECT>"   SQL packs, READ ONLY + statement timeout
#   http-trace <site> <path>            public -> host IP -> Caddy -> nginx :8080 -> Apache; names the failing hop
#   nginx-top <site> [--since 1h]       nginx cache access-log summary; flags scraper loops and heavy pollers
#   compare-nodes [height]              block header hashes across every node and the public RPC
#   grass-tap <site> [--seconds N] [--subject S] [--pull]   GRASS events through NATS as the anonymous reader
#   oidc-probe <site>                   webapp <-> MAS OIDC wiring and token endpoint client auth
# Output is also saved under inventory/reports/runs/<date>/debug/.
set -euo pipefail
. "$DEVOPS_ROOT/lib/common.sh"

tool="${1:-help}"; [ $# -gt 0 ] && shift
case "$tool" in
  snapshot|pg|http-trace|nginx-top|compare-nodes|grass-tap|oidc-probe)
    exec "$DEVOPS_ROOT/tools/debug/$tool.sh" "$@" ;;
  help|-h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) usage_die "unknown debug tool $tool (devops debug help)" ;;
esac
