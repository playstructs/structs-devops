#!/usr/bin/env bash
# structs-app <site>: structs.app answers /healthz ok with a small block lag,
# and its container is healthy. 503 + bouncer auth errors usually means the
# structs_app row vanished from pgbouncer userlist.txt (see secrets-audit).
. "$DEVOPS_ROOT/checks/_lib.sh"
check_site_arg "${1:-}"; site="$1"
st="$(inv_service_stack "$site" structs-app)"
[ -n "$st" ] || check_ok "no structs-app on this site"
url="$(inv_q "$site" '[.endpoints[] | select(.id == "structs-app-healthz")][0].url')"
url="${url:-https://structs.app/healthz}"
body="$(curl -sS -m 15 -w '\n%{http_code}' "$url" 2>&1)"
code="$(printf '%s' "$body" | tail -n1)"; json="$(printf '%s' "$body" | sed '$d')"
if [ "$code" != "200" ]; then
  bump 2 "$url HTTP $code; if 503 check bouncer auth: devops logs $site structs-pg-bouncer 50 --grep 'password authentication'"
else
  lag="$(printf '%s' "$json" | jq -r '.block.lag_blocks // empty' 2>/dev/null)"
  okv="$(printf '%s' "$json" | jq -r '.ok // empty' 2>/dev/null)"
  [ "$okv" = "true" ] || bump 2 "healthz ok=$okv"
  [ -n "$lag" ] && bump "$(level_high "$lag" "$(thr "$site" sync.lag_blocks_warn 20)" "$(thr "$site" sync.lag_blocks_crit 200)")" "healthz lag $lag blocks"
fi
h="$(stack_host "$site" "$st")"
c="$(inv_container "$site" structs-app)"
if probe "$site" "$h" "CONTAINER=$(printf '%q' "$c")" "$DEVOPS_ROOT/checks/host/docker-health.sh"; then
  case "$(pv state)" in running/healthy|running/none) detail "ok: $c $(pv state)" ;; *) bump 1 "$c is $(pv state)" ;; esac
else
  bump 3 "$h unreachable"
fi
check_finish "structs.app healthy, lag ${lag:-?} blocks"
