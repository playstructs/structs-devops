#!/usr/bin/env bash
# bouncer <site>: PgBouncer pools have no clients queuing for a server connection.
. "$DEVOPS_ROOT/checks/_lib.sh"
check_site_arg "${1:-}"; site="$1"
st="$(inv_service_stack "$site" structs-pg-bouncer)"
[ -n "$st" ] || check_ok "no structs-pg-bouncer on this site"
h="$(stack_host "$site" "$st")"
probe "$site" "$h" "$(site_preamble "$site")" "$DEVOPS_ROOT/checks/host/bouncer.sh" || check_unknown "$h: probe failed"
e="$(pv bouncer_error)"
[ -n "$e" ] && check_crit "SHOW POOLS failed: $e"
pools=0
while IFS='|' read -r name cla clw sva svi mw mode; do
  [ -n "$name" ] || continue
  case "$name" in pgbouncer/*) continue ;; esac
  pools=$((pools + 1))
  bump "$(level_high "${clw:-0}" "$(thr "$site" bouncer.cl_waiting_warn 1)" "$(thr "$site" bouncer.cl_waiting_crit 20)")" \
    "pool $name ($mode): $cla active clients, $clw waiting, $sva/$svi server active/idle, maxwait ${mw}s"
  [ "${mw:-0}" -ge 5 ] 2>/dev/null && bump 1 "pool $name maxwait ${mw}s"
done <<EOF
$(printf '%s\n' "$PROBE" | sed -n 's/^pool=//p')
EOF
[ "$pools" -gt 0 ] || bump 1 "SHOW POOLS returned no pools"
check_finish "$pools pool(s), no clients waiting"
