#!/usr/bin/env bash
# inventory-freshness (network): the inventory validates, generated docs are
# current, no site has gone unverified for too long, and unverified fields
# are listed so someone confirms them.
. "$DEVOPS_ROOT/checks/_lib.sh"

out="$(python3 "$DEVOPS_ROOT/tools/inventory/validate.py" 2>&1)"; rc=$?
errs="$(printf '%s\n' "$out" | grep -c '^ERROR' || true)"
[ "$rc" -ne 0 ] && bump 2 "inventory validation failed with $errs error(s): devops inventory validate"
while IFS= read -r l; do [ -n "$l" ] && detail "$l"; done <<EOF
$(printf '%s\n' "$out" | grep -E '^(ERROR|WARN)')
EOF
python3 "$DEVOPS_ROOT/tools/inventory/render.py" --check >/dev/null 2>&1 ||
  bump 1 "generated inventory docs are stale: devops inventory render"

stale="$(thr "" inventory.stale_days 30)"
for s in $(inv_sites); do
  lv="$(inv_q "$s" '.last_verified')"
  if [ -z "$lv" ]; then bump 1 "$s has no last_verified date"; continue; fi
  age="$(iso_age_seconds "${lv}T00:00:00Z" || echo 0)"; d=$((age / 86400))
  if [ "$d" -gt "$stale" ]; then bump 1 "$s last verified $lv ($d days ago): devops inventory discover $s, then update site.yaml"
  else detail "ok: $s verified $lv"; fi
  uv="$(inv_q "$s" '(.unverified // []) | join(", ")')"
  [ -n "$uv" ] && bump 1 "$s unverified fields: $uv (confirm on the host, then drop them from site.yaml unverified:)"
done
check_finish "inventory valid and verified within $stale days"
