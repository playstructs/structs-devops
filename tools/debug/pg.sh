#!/usr/bin/env bash
# devops debug pg <site> list                       packs and what they show
# devops debug pg <site> <pack> [--timeout-ms N]    run tools/debug/sql/<pack>.sql
# devops debug pg <site> sql "<SELECT ...>"         one ad-hoc read-only statement
# devops debug pg <site> explain "<SELECT ...>"     EXPLAIN (ANALYZE, BUFFERS) for plain SELECTs, plain EXPLAIN otherwise
# Runs as postgres over the container socket (never through the bouncer, except
# the bouncer pack) in a READ ONLY session with statement_timeout and lock_timeout.
set -euo pipefail
. "$DEVOPS_ROOT/tools/debug/_lib.sh"
need yq

site="${1:-}"; sub="${2:-list}"
need_site "$site" 'usage: devops debug pg <site> list|<pack>|sql "<SELECT>"|explain "<SELECT>"'
shift 2 2>/dev/null || shift $#

if [ "$sub" = list ]; then
  for f in "$DEBUG_SQL"/*.sql; do
    printf '%-16s %s\n' "$(basename "$f" .sql)" "$(grep -m1 -E '^(--|\\echo)' "$f" | sed -E "s/^-- ?//; s/^\\\\echo '== ?//; s/'$//" | cut -c1-90)"
  done
  exit 0
fi

timeout_ms=30000 stmt=""
case "$sub" in sql|explain) stmt="${1:-}"; [ -n "$stmt" ] || usage_die "usage: devops debug pg $site $sub \"<SELECT ...>\""; shift ;; esac
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout-ms) timeout_ms="${2:?}"; shift 2 ;;
    *) usage_die "unknown option $1" ;;
  esac
done

host="$(service_host "$site" structs-pg)"
[ -n "$host" ] || die "$site has no structs-pg service in the inventory"
mode=pg
tmp="$(mktemp "${TMPDIR:-/tmp}/devops-sql.XXXXXX")"; trap 'rm -f "$tmp"' EXIT

writes='\b(insert|update|delete|merge|drop|truncate|alter|create|grant|revoke|vacuum|reindex|cluster|copy|call|do|lock|refresh|comment|security|nextval|setval|pg_terminate_backend|pg_cancel_backend|pg_reload_conf|pg_rotate_logfile|lo_import|lo_export|dblink)\b'
case "$sub" in
  sql)
    printf '%s' "$stmt" | grep -Eiq '^[[:space:]]*(select|with|show|table|values|explain)\b' || die "only SELECT/WITH/SHOW/TABLE/VALUES/EXPLAIN statements"
    printf '%s' "$stmt" | grep -Eiq "$writes" && die "statement contains a write or admin keyword; debug SQL is read-only"
    printf '%s;\n' "${stmt%;}" > "$tmp"; name=sql ;;
  explain)
    printf '%s' "$stmt" | grep -Eiq "$writes" && die "statement contains a write or admin keyword; debug SQL is read-only"
    if printf '%s' "$stmt" | grep -Eiq '^[[:space:]]*(select|with)\b'; then
      printf 'EXPLAIN (ANALYZE, BUFFERS, SETTINGS) %s;\n' "${stmt%;}" > "$tmp"
    else
      printf 'EXPLAIN %s;\n' "${stmt%;}" > "$tmp"
    fi
    name=explain ;;
  *)
    f="$DEBUG_SQL/$sub.sql"
    [ -f "$f" ] || usage_die "unknown pack $sub (devops debug pg $site list)"
    cp "$f" "$tmp"; name="$sub"
    [ "$sub" = bouncer ] && mode=bouncer ;;
esac
if [ "$mode" = bouncer ] && [ -z "$(inv_service_stack "$site" structs-pg-bouncer)" ]; then
  die "$site has no structs-pg-bouncer in the inventory"
fi

pre="$(debug_preamble "$site")
export PACK_MODE=$mode PACK_NAME=$(printf '%q' "$name") PG_TIMEOUT_MS=$(printf '%q' "$timeout_ms")
$(sql_var PACK_SQL "$tmp")"

out="$(debug_out "pg-$site-$name").txt"
{
  printf '# devops debug pg %s %s  (%s, host %s, %s)\n' "$site" "$name" "$(iso_now)" "$host" "$mode"
  [ -n "$stmt" ] && printf '# %s\n' "$stmt"
  host_bundle "$site" "$host" "$pre" "$DEBUG_HOST/debug-pg.sh"
} 2>&1 | tee "$out"
rc="${PIPESTATUS[0]}"

if [ "$name" = migrations ] && [ -f "$DEVOPS_REFS/structs-pg/sqitch.plan" ]; then
  plan="$DEVOPS_REFS/structs-pg/sqitch.plan"
  last="$(grep -Ev '^(%|#|@|[[:space:]]*$)' "$plan" | tail -1 | awk '{print $1}')"
  n="$(grep -Evc '^(%|#|@|[[:space:]]*$)' "$plan")"
  printf '\n== upstream plan in .references/structs-pg (%s): %s changes, last %s\n' \
    "$(git -C "$DEVOPS_REFS/structs-pg" rev-parse --short HEAD 2>/dev/null || echo '?')" "$n" "$last" | tee -a "$out"
  note "refresh with: devops refs sync structs-pg"
fi
note "saved: ${out#"$DEVOPS_ROOT"/}"
exit "$rc"
