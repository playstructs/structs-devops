#!/usr/bin/env bash
# certbot <site>: for certbot-managed certificates, the timer is active, the
# renewal conf still has its stop/start hooks, deploy hooks exist and Caddy
# can read the key. Never runs certbot (on the public node, the pre_hook
# stops Caddy, so even `renew --dry-run` takes the public node down).
. "$DEVOPS_ROOT/checks/_lib.sh"
check_site_arg "${1:-}"; site="$1"
f="$(inv_site_file "$site")"
idx="$(yq -r '(.tls // []) | to_entries | map(select(.value.manager | test("^certbot"))) | .[].key' "$f")"
[ -n "$idx" ] || check_ok "no certbot-managed certificates"
h="$(inv_primary_host "$site")"
for t in $idx; do
  name="$(yq -r ".tls[$t].cert_name // .tls[$t].names[0]" "$f")"
  if ! probe "$site" "$h" "CERT_NAME=$(printf '%q' "$name")" "$DEVOPS_ROOT/checks/host/certbot.sh"; then bump 3 "$h unreachable"; continue; fi
  [ "$(pv timer)" = "active" ] || bump 2 "$name: certbot.timer is $(pv timer); renewals will not run"
  detail "next timer run: $(pv next)"
  [ "$(pv renewal_conf)" = "missing" ] && { bump 2 "$name: /etc/letsencrypt/renewal/$name.conf missing"; continue; }
  if [ -n "$(yq -r ".tls[$t].hooks.pre // \"\"" "$f")" ]; then
    [ "$(pv pre_hook 0)" -gt 0 ] || bump 2 "$name: renewal conf lost its pre_hook (standalone renewal will fail on :80)"
    [ "$(pv post_hook 0)" -gt 0 ] || bump 2 "$name: renewal conf lost its post_hook (Caddy would stay stopped after renewal)"
  fi
  for dh in $(yq -r ".tls[$t].hooks.deploy // [] | .[]" "$f"); do
    case " $(pv deploy_hooks) " in *" $dh "*) ;; *) bump 1 "$name: deploy hook $dh missing from renewal-hooks/deploy" ;; esac
  done
  acl="$(pv caddy_acl)"
  if [ -n "$(yq -r ".tls[$t].acl // \"\"" "$f")" ] && [ "${acl:-0}" -eq 0 ]; then
    bump 2 "$name: caddy has no read ACL on the live private key (Caddy TLS breaks at next reload; runbooks/tls-cert-renewal.md)"
  fi
  le="$(pv le_errors_recent 0)"
  [ "$le" -gt 0 ] && bump 1 "$name: $le ERROR lines in the recent letsencrypt.log"
done
check_finish "certbot renewal path intact"
