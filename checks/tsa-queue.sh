#!/usr/bin/env bash
# tsa-queue <site>: the signer queue drains. Pending count and age, errors,
# broadcasts in the last hour, available signer accounts, stuck submissions,
# and the TSA worker count against the inventory.
. "$DEVOPS_ROOT/checks/_lib.sh"
. "$DEVOPS_ROOT/checks/_pg.sh"
check_site_arg "${1:-}"; site="$1"
pg_probe "$site" "$DEVOPS_ROOT/checks/host/tsa.sh"

pend="$(pv tx_pending 0)"; claimed="$(pv tx_claimed 0)"
oldest="$(pv oldest_pending_min 0)"
b1h="$(pv broadcast_1h 0)"; e1h="$(pv errors_1h 0)"
avail="$(pv acct_available 0)"; signing="$(pv acct_signing 0)"

bump "$(level_high "$pend" "$(thr "$site" tsa.pending_warn 50)" "$(thr "$site" tsa.pending_crit 500)")" \
  "$pend pending, $claimed claimed; top: $(pv pending_top)"
bump "$(level_high "$oldest" "$(thr "$site" tsa.oldest_pending_warn_min 30)" "$(thr "$site" tsa.oldest_pending_crit_min 120)")" \
  "oldest pending tx is $oldest min old"
o24="$(pv pending_older_24h 0)"
[ "$o24" -gt 0 ] && bump 1 "$o24 pending rows older than 24 h (never-claimable rows? see skill structs-debug-tsa)"
if [ "$pend" -gt 0 ] && [ "$b1h" -eq 0 ]; then
  bump 2 "queue not draining: $pend pending and 0 broadcasts in the last hour"
else
  detail "ok: $b1h broadcast in the last hour"
fi
[ "$e1h" -gt 10 ] && bump 1 "$e1h tx errors in the last hour; latest: $(pv last_error)"
amin="$(thr "$site" tsa.available_accounts_min 2)"
if [ "$avail" -lt "$amin" ]; then
  lvl=1; [ "$avail" -eq 0 ] && [ "$pend" -gt 0 ] && lvl=2
  bump "$lvl" "$avail signer accounts available, $signing signing (< $amin); accounts: $(printf '%s\n' "$PROBE" | sed -n 's/^acct_//p' | tr '\n' ' ')"
fi
stuck="$(printf '%s\n' "$PROBE" | sed -n 's/^stuck_//p' | tr '\n' ' ')"
[ -n "$stuck" ] && bump 1 "tx_submission rows stuck > 10 min: $stuck"

ts="$(pv tsa_state)"
[ -n "$ts" ] && [ "$ts" != "running" ] && bump 2 "TSA container is $ts"
want="$(inv_q "$site" '.checks.tsa.workers // ([.stacks[].services["structs-tsa"].env.TSA_WORKERS | select(. != null)][0])')"
have="$(pv tsa_workers)"
if [ -n "$want" ] && [ "${have:-30}" != "$want" ]; then
  bump 1 "TSA_WORKERS is ${have:-unset (default 30)}, inventory expects $want (too many workers outlast a block: saves are rejected and the TSA retries in a loop)"
fi
check_finish "$pend pending (oldest ${oldest}m), $b1h broadcast/h, $avail accounts available"
