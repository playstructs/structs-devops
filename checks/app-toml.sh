#!/usr/bin/env bash
# app-toml <site>: the node's app.toml carries every key in the site's
# app-toml.overrides (structsd recreates and upgrades reset it).
. "$DEVOPS_ROOT/checks/_lib.sh"
. "$DEVOPS_ROOT/checks/_bundle.sh"
check_site_arg "${1:-}"; site="$1"
[ -f "$(inv_site_dir "$site")/app-toml.overrides" ] || check_ok "site has no app-toml.overrides"
h="$(inv_q "$site" '.nodes[0].host')"
[ -n "$h" ] || check_ok "site has no structsd node"
bundle_current_or_warn "$site" "$h"
out="$(bundle_run "$site" "$h" app-toml-overrides.sh --check 2>&1)"
sum="$(printf '%s\n' "$out" | grep '^APPTOML ' | tail -1)"
[ -n "$sum" ] || check_unknown "app-toml-overrides.sh printed no summary: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
d="$(printf '%s' "$sum" | sed -n 's/.*drift=\([0-9]*\).*/\1/p')"
while IFS= read -r l; do [ -n "$l" ] && detail "${l#"${l%%[![:space:]]*}"}"; done <<EOF
$(printf '%s\n' "$out" | grep ' DRIFT ')
EOF
[ "${d:-0}" -gt 0 ] && bump 1 "$d app.toml key(s) differ from overrides; fix: devops node $site app-toml apply (tier 1) then restart structsd (tier 2)"
check_finish "app.toml matches overrides"
