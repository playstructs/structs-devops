# shellcheck shell=bash
# Shared by Postgres-backed checks: find the structs-pg host and run a probe there.
# pg_probe SITE SCRIPT -> PROBE; exits UNKNOWN on failure.
pg_probe() {
  local site="$1" script="$2" st h
  st="$(inv_service_stack "$site" structs-pg)"
  [ -n "$st" ] || check_ok "no structs-pg on this site"
  h="$(stack_host "$site" "$st")"
  probe "$site" "$h" "$(site_preamble "$site")" "$script" || check_unknown "$h: probe failed (ssh unreachable?)"
  [ -n "$(pv pg_error)" ] && check_crit "$h: psql into $(inv_container "$site" structs-pg) failed (container down or not ready?)"
  return 0
}
