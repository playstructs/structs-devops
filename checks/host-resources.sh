#!/usr/bin/env bash
# host-resources <site>: load per core, memory, swap, disk %, inodes, days until full.
. "$DEVOPS_ROOT/checks/_lib.sh"
check_site_arg "${1:-}"; site="$1"

paths="$(inv_q "$site" '(.checks.disk.paths // ["/"]) | join(" ")')"
hosts="$(remote_hosts "$site")"
[ -n "$hosts" ] || check_ok "no remote hosts (hub-local site)"

for h in $hosts; do
  if ! probe "$site" "$h" "DISK_PATHS=$(printf '%q' "$paths")" "$DEVOPS_ROOT/checks/host/resources.sh" || [ -z "$(pv nproc)" ]; then
    bump 3 "$h: probe failed (ssh unreachable?)"; continue
  fi
  n="$(pv nproc 1)"; l5="$(pv load5 0)"
  per="$(py "round($l5/$n, 2)")"
  bump "$(level_high "$per" "$(thr "$site" host.load_per_core_warn 1.5)" "$(thr "$site" host.load_per_core_crit 3.0)")" \
    "$h load5 $l5 on $n cores ($per/core); top: $(pv top_cpu)"

  mt="$(pv mem_total_kb 1)"; ma="$(pv mem_avail_kb 0)"
  mp="$(py "round(100.0*$ma/$mt, 1)")"
  bump "$(level_low "$mp" "$(thr "$site" host.mem_avail_pct_warn 15)" "$(thr "$site" host.mem_avail_pct_crit 5)")" \
    "$h memory available ${mp}% of $(py "round($mt/1048576.0, 1)") GiB"

  st="$(pv swap_total_kb 0)"; su="$(pv swap_used_kb 0)"
  if [ "$st" -gt 0 ]; then
    sp="$(py "round(100.0*$su/$st, 1)")"
    bump "$(level_high "$sp" "$(thr "$site" host.swap_used_pct_warn 50)" 101)" "$h swap used ${sp}%"
  fi
  oom="$(pv oom_1h 0)"
  [ "$oom" -gt 0 ] && bump 1 "$h kernel OOM kills in the last hour: $oom"
  [ "$(pv docker)" = "down" ] && bump 2 "$h docker daemon not answering"

  i=0; nd="$(pv disks 0)"
  while [ "$i" -lt "$nd" ]; do
    p="$(pv "disk${i}_path")"
    if [ -n "$(pv "disk${i}_missing")" ]; then
      detail "$h $p: not present on this host"; i=$((i + 1)); continue
    fi
    up="$(pv "disk${i}_used_pct" 0)"; used="$(pv "disk${i}_used" 0)"; avail="$(pv "disk${i}_avail" 0)"
    bump "$(level_high "$up" "$(thr "$site" host.disk_used_pct_warn 85)" "$(thr "$site" host.disk_used_pct_crit 93)")" \
      "$h $p ${up}% used, $(py "round($avail/1073741824.0, 1)") GiB free"
    ip="$(pv "disk${i}_inode_pct" 0)"
    [ "${ip:-0}" -ge 85 ] 2>/dev/null && bump 1 "$h $p inodes ${ip}% used"

    hist="$(cstate_dir)/$CHECK_ID.hist.$h.$(printf '%s' "$p" | tr '/' '_')"
    printf '%s %s %s\n' "$(now_epoch)" "$used" "$avail" >> "$hist"
    tail -n 400 "$hist" > "$hist.tmp" && mv "$hist.tmp" "$hist"
    days="$(python3 - "$hist" <<'PY'
import sys
rows = [tuple(map(int, l.split())) for l in open(sys.argv[1]) if len(l.split()) == 3]
now, used, avail = rows[-1]
old = [r for r in rows if now - r[0] <= 7 * 86400 and now - r[0] >= 6 * 3600]
if not old:
    print("")
else:
    t0, u0, _ = old[0]
    rate = (used - u0) / float(now - t0)
    print("" if rate <= 0 else round(avail / rate / 86400.0, 1))
PY
)"
    if [ -n "$days" ]; then
      bump "$(level_low "$days" "$(thr "$site" host.disk_days_left_warn 30)" "$(thr "$site" host.disk_days_left_crit 10)")" \
        "$h $p full in ~$days days at the current growth rate"
    fi
    i=$((i + 1))
  done
done
check_finish "$(printf '%s' "$hosts" | wc -w | tr -d ' ') host(s) within limits"
