#!/usr/bin/env bash
# apache-workers <site>: Apache prefork processes vs MaxRequestWorkers.
# Saturation shows up as intermittent timeouts long before 5xx.
. "$DEVOPS_ROOT/checks/_lib.sh"
check_site_arg "${1:-}"; site="$1"
st="$(inv_service_stack "$site" structs-webapp)"
[ -n "$st" ] || check_ok "no structs-webapp on this site"
h="$(stack_host "$site" "$st")"
probe "$site" "$h" "$(site_preamble "$site")" "$DEVOPS_ROOT/checks/host/apache.sh" || check_unknown "$h: probe failed"
[ "$(pv webapp)" = "missing" ] && check_crit "webapp container not found"
procs="$(pv apache_procs 0)"
conf="$(pv max_workers_conf)"
want="$(thr "$site" apache.max_workers 150)"
busy=$(( procs > 0 ? procs - 1 : 0 ))
max="${conf:-$want}"
pct="$(py "round(100.0*$busy/$max, 1)")"
bump "$(level_high "$pct" "$(thr "$site" apache.busy_pct_warn 70)" "$(thr "$site" apache.busy_pct_crit 90)")" \
  "$busy apache children of MaxRequestWorkers $max (${pct}%); host load1 $(pv load1)"
if [ -n "$conf" ] && [ "$conf" != "$want" ]; then
  bump 1 "MaxRequestWorkers in the container is $conf, inventory expects $want (bind-mount lost? devops patches $site check)"
fi
[ "$procs" -eq 0 ] && bump 2 "no apache2 processes in $(pv webapp)"
check_finish "$busy/$max apache workers busy"
