#!/usr/bin/env bash
# patches-drift <site>: every verify pattern in the site's patch manifest still
# holds on the host (catches lost bind-mounts, overwritten overlays, a webapp
# pull that reset templates). Read-only: runs apply-patches.sh --check.
. "$DEVOPS_ROOT/checks/_lib.sh"
. "$DEVOPS_ROOT/checks/_bundle.sh"
check_site_arg "${1:-}"; site="$1"
[ -f "$(inv_site_dir "$site")/patches/manifest.tsv" ] || check_ok "site has no patch manifest"
h="$(site_stack_host "$site")"
bundle_current_or_warn "$site" "$h"
out="$(bundle_run "$site" "$h" apply-patches.sh --check 2>&1)"
sum="$(printf '%s\n' "$out" | grep '^PATCHES ' | tail -1)"
[ -n "$sum" ] || check_unknown "apply-patches.sh --check printed no summary: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
while IFS= read -r l; do [ -n "$l" ] && detail "${l#"${l%%[![:space:]]*}"}"; done <<EOF
$(printf '%s\n' "$out" | grep -E '(DRIFT|MISSING|FAIL) |anchor:')
EOF
g() { printf '%s' "$sum" | tr ' ' '\n' | sed -n "s/^$1=//p"; }
drift="$(g drift)"; missing="$(g missing)"; fails="$(g failures)"
[ "${fails:-0}" -gt 0 ] && bump 2 "$fails patch check(s) failed to run"
[ "${missing:-0}" -gt 0 ] && bump 1 "$missing patch target(s) missing on the host"
[ "${drift:-0}" -gt 0 ] && bump 1 "$drift patch(es) drifted; review with devops patches $site check, re-apply with devops patches $site apply (tier 1)"
check_finish "$(g ok) patches verified"
