#!/usr/bin/env bash
# archive-growth <site>: chain data growth per day on an archive node and the
# projected days until the volume is full.
. "$DEVOPS_ROOT/checks/_lib.sh"
check_site_arg "${1:-}"; site="$1"
p="$(inv_q "$site" '.checks.disk.project_growth_path')"
[ -n "$p" ] || check_ok "no checks.disk.project_growth_path set"
h="$(inv_q "$site" '.nodes[0].host')"; h="${h:-$(inv_primary_host "$site")}"
probe "$site" "$h" "GROWTH_PATH=$(printf '%q' "$p")" "$DEVOPS_ROOT/checks/host/archive.sh" || check_unknown "$h unreachable"
b="$(pv data_bytes)"; avail="$(pv avail)"
[ -n "$b" ] || check_unknown "could not size $p/data"
hist="$(cstate_dir)/$CHECK_ID.hist"
printf '%s %s %s\n' "$(now_epoch)" "$b" "$avail" >> "$hist"
tail -n 120 "$hist" > "$hist.tmp" && mv "$hist.tmp" "$hist"
res="$(python3 - "$hist" <<'PY'
import sys
rows = [tuple(map(int, l.split())) for l in open(sys.argv[1]) if len(l.split()) == 3]
now, size, avail = rows[-1]
old = [r for r in rows if 20 * 3600 <= now - r[0] <= 30 * 86400]
if not old:
    print("%.1f - -" % (size / 1e9))
else:
    t0, s0, _ = old[0]
    per_day = (size - s0) / ((now - t0) / 86400.0)
    days = "-" if per_day <= 0 else "%.0f" % (avail / per_day)
    print("%.1f %.2f %s" % (size / 1e9, per_day / 1e9, days))
PY
)"
read -r gb gbday days <<EOF
$res
EOF
if [ "$days" = "-" ]; then
  check_ok "data ${gb} GB; growth rate needs a day of history${gbday:+ ($gbday GB/day)}"
fi
bump "$(level_low "$days" "$(thr "$site" host.disk_days_left_warn 30)" "$(thr "$site" host.disk_days_left_crit 10)")" \
  "data ${gb} GB growing ${gbday} GB/day; ~$days days until the volume is full (docs/reference/pruning-and-archive.md)"
check_finish "data ${gb} GB, +${gbday} GB/day, ~$days days of headroom"
