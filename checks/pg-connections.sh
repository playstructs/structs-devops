#!/usr/bin/env bash
# pg-connections <site>: structs-pg connection headroom, idle-in-transaction,
# long-running queries, lock waits, transaction-id age, pg_cron failures.
. "$DEVOPS_ROOT/checks/_lib.sh"
. "$DEVOPS_ROOT/checks/_pg.sh"
check_site_arg "${1:-}"; site="$1"
pg_probe "$site" "$DEVOPS_ROOT/checks/host/pg.sh"

conn="$(pv conn 0)"; max="$(pv max_conn 100)"; res="$(pv reserved 3)"
pct="$(py "round(100.0*$conn/($max-$res), 1)")"
bump "$(level_high "$pct" "$(thr "$site" pg.conn_pct_warn 70)" "$(thr "$site" pg.conn_pct_crit 90)")" \
  "$conn/$max connections (${pct}% of usable); by user: $(printf '%s\n' "$PROBE" | sed -n 's/^user_//p' | tr '\n' ' ')"
detail "states: $(printf '%s\n' "$PROBE" | sed -n 's/^state_//p' | tr '\n' ' ')"
iit="$(pv idle_in_tx_5m 0)"
[ "$iit" -gt 0 ] && bump 1 "$iit session(s) idle in transaction for > 5 min (they hold locks and block vacuum)"
la="$(pv longest_active_s 0)"
bump "$(level_high "$la" 300 1800)" "longest active query ${la}s: $(pv longest_active_q)"
bl="$(pv blocked 0)"
[ "$bl" -gt 5 ] && bump 1 "$bl lock requests waiting (devops debug pg $site locks)"
xa="$(pv xid_age 0)"
bump "$(level_high "$xa" 1000000000 1500000000)" "max datfrozenxid age $xa"
cf="$(pv cron_failed_1h)"
[ -n "$cf" ] && [ "$cf" -gt 0 ] && bump 1 "$cf pg_cron job run(s) failed in the last hour (devops debug pg $site pg-cron)"
check_finish "$conn/$max connections; db $(pv db_size)"
