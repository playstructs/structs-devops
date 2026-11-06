#!/usr/bin/env bash
# devops debug snapshot <site> [--lines N]     [0] read-only evidence bundle, taken BEFORE restarting anything
#   -> inventory/reports/runs/<date>/debug/<site>-snapshot-<time>/<host>/{host,containers,stats,compose,node,caddy,firewall}.txt,
#      logs/<container>.log (redacted on the host), pg-<pack>.txt; README.md summarizes.
set -euo pipefail
. "$DEVOPS_ROOT/tools/debug/_lib.sh"
need yq

site="${1:-}"
need_site "$site" "usage: devops debug snapshot <site> [--lines N]"
shift
lines=300
while [ $# -gt 0 ]; do
  case "$1" in --lines) lines="${2:?}"; shift 2 ;; *) usage_die "unknown option $1" ;; esac
done

PACKS="activity connections locks signer-queue sync-state"
out="$(debug_out "$site-snapshot")"
mkdir -p "$out"
pg_host="$(service_host "$site" structs-pg)"
sf="$(inv_site_file "$site")"

summary=""
for h in $(inv_host_ids "$site"); do
  containers="" n=0 compose_lines=""
  for st in $(inv_stack_ids "$site"); do
    [ "$(site_stack_host "$site" "$st")" = "$h" ] || continue
    compose_lines="${compose_lines}export SNAP_COMPOSE_$n=$(printf '%q' "$(inv_compose_cmd "$site" "$st")")
"
    n=$((n + 1))
    for svc in $(S="$st" yq -r '.stacks[] | select(.id == strenv(S)) | (.services // {}) | keys | .[]' "$sf"); do
      c="$(inv_container "$site" "$svc" 2>/dev/null || true)"
      case " $containers " in *" $c "*) ;; *) [ -n "$c" ] && containers="$containers $c" ;; esac
    done
  done
  node_c="$(H="$h" yq -r '[(.nodes // [])[] | select(.host == strenv(H))][0] | .container // ""' "$sf")"
  node_rpc="$(H="$h" yq -r '[(.nodes // [])[] | select(.host == strenv(H))][0] | .rpc // ""' "$sf")"
  node_vol="$(H="$h" yq -r '[(.nodes // [])[] | select(.host == strenv(H))][0] | .volume // ""' "$sf")"
  if [ -n "$node_c" ]; then
    case " $containers " in *" $node_c "*) ;; *) containers="$containers $node_c" ;; esac
  fi
  pre="$(debug_preamble "$site")
export SNAP_CONTAINERS=$(printf '%q' "${containers# }") SNAP_LOG_LINES=$(printf '%q' "$lines") SNAP_N_COMPOSE=$n
${compose_lines}export SNAP_NODE_CONTAINER=$(printf '%q' "$node_c") SNAP_NODE_RPC=$(printf '%q' "$node_rpc") SNAP_NODE_VOLUME=$(printf '%q' "$node_vol")"
  if [ "$h" = "$pg_host" ]; then
    pre="$pre
export SNAP_PG=1 SNAP_PACKS=$(printf '%q' "$PACKS")"
    for p in $PACKS; do pre="$pre
$(sql_var "PACK_$(printf '%s' "$p" | tr '-' '_')" "$DEBUG_SQL/$p.sql")"; done
  fi
  info "collecting $site:$h ($(ssh_target "$site" "$h"))"
  mkdir -p "$out/$h"
  if host_bundle "$site" "$h" "$pre" "$DEBUG_HOST/debug-snapshot.sh" > "$out/$h.tgz" 2> "$out/$h.stderr"; then
    if tar -xzf "$out/$h.tgz" -C "$out/$h" 2>> "$out/$h.stderr"; then rm -f "$out/$h.tgz"; else warn "$site:$h: returned data is not a tar stream (kept $h.tgz)"; fi
    [ -s "$out/$h.stderr" ] || rm -f "$out/$h.stderr"
    bad="$(grep -E 'status=(restarting|dead|created)|status=exited.* exit=[1-9]|health=unhealthy|MISSING|oom=true' "$out/$h/containers.txt" 2>/dev/null | sed 's/ started=.*//; s/^/    /' || true)"
    rst="$(sed -n 's/^\/\([^ ]*\) .*restarts=\([1-9][0-9]*\).*/\1=\2/p' "$out/$h/containers.txt" 2>/dev/null | tr '\n' ' ' || true)"
    up="$(sed -n '2p' "$out/$h/host.txt" 2>/dev/null | sed 's/^ *//' || true)"
    [ -n "$up" ] || up="no host.txt returned (see $h.stderr)"
    summary="$summary
- **$h**: $up
  - restarts: ${rst:-none}"
    [ -n "$bad" ] && summary="$summary
  - not healthy:
$bad"
  else
    rm -f "$out/$h.tgz"
    warn "$site:$h: collection failed (see $out/$h.stderr)"
    summary="$summary
- **$h**: collection FAILED ($(head -c 200 "$out/$h.stderr" | tr '\n' ' '))"
  fi
done

{
  printf '# Snapshot %s (%s)\n\n' "$site" "$(iso_now)"
  printf 'Chain: %s height %s (public RPC)\n\n' "$(chain_id)" "$(chain_height 2>/dev/null || echo '?')"
  printf '## Hosts\n%s\n\n' "$summary"
  printf '## Files\n\n'
  (cd "$out" && find . -type f ! -name README.md | LC_ALL=C sort | sed 's/^\.\//- /')
  printf '\nLogs are redacted on the host. Before sharing anything from here, run: devops secrets scan %s\n' "${out#"$DEVOPS_ROOT"/}"
} > "$out/README.md"

if ! python3 "$DEVOPS_ROOT/tools/secrets/scan.py" "$out" >/dev/null 2>&1; then
  warn "the secret scanner matched something in the snapshot; review before sharing: devops secrets scan ${out#"$DEVOPS_ROOT"/}"
fi
ok "snapshot: ${out#"$DEVOPS_ROOT"/}"
sed -n '/^## Hosts/,/^## Files/p' "$out/README.md" | sed '$d'
