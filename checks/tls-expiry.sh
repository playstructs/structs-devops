#!/usr/bin/env bash
# tls-expiry <site>: days left on every declared certificate, per name and port.
# Connects like a client (s_client); never touches certbot or Caddy.
. "$DEVOPS_ROOT/checks/_lib.sh"
check_site_arg "${1:-}"; site="$1"
need openssl

f="$(inv_site_file "$site")"
nt="$(yq '(.tls // []) | length' "$f")"
[ "$nt" -gt 0 ] || check_ok "no certificates declared"
warn_d="$(thr "$site" tls.days_warn 21)"; crit_d="$(thr "$site" tls.days_crit 7)"
count=0 min=""

t=0
while [ "$t" -lt "$nt" ]; do
  mgr="$(yq -r ".tls[$t].manager // \"\"" "$f")"
  resolve="$(yq -r ".tls[$t].resolve // \"\"" "$f")"
  for name in $(yq -r ".tls[$t].names[]" "$f"); do
    for port in $(yq -r ".tls[$t].ports // [443] | .[]" "$f"); do
      addr="${resolve:-$name}"
      pem="$(perl -e 'alarm 15; exec @ARGV' openssl s_client -connect "$addr:$port" -servername "$name" </dev/null 2>/dev/null |
        sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p')"
      if [ -z "$pem" ]; then bump 2 "$name:$port no certificate served (TLS handshake failed)"; continue; fi
      end="$(printf '%s\n' "$pem" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
      issuer="$(printf '%s\n' "$pem" | openssl x509 -noout -issuer 2>/dev/null | sed 's/.*O *= *\([^,]*\).*/\1/')"
      sans="$(printf '%s\n' "$pem" | openssl x509 -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ')"
      e="$(openssl_date_epoch "$end")"
      if [ -z "$e" ]; then bump 3 "$name:$port could not parse expiry '$end'"; continue; fi
      days=$(( (e - $(now_epoch)) / 86400 ))
      count=$((count + 1))
      if [ -z "$min" ] || [ "$days" -lt "$min" ]; then min="$days"; fi
      if ! printf '%s' "$sans" | tr ',' '\n' | grep -qx "DNS:$name"; then
        bump 2 "$name:$port certificate does not cover $name (SAN: $sans)"; continue
      fi
      lvl="$(level_low "$days" "$warn_d" "$crit_d")"
      hint=""; [ "$lvl" -gt 0 ] && [ "$mgr" = "certbot-standalone" ] && hint=" (certbot standalone: renewal stops Caddy; see runbooks/tls-cert-renewal.md)"
      bump "$lvl" "$name:$port expires in ${days}d ($end, $issuer, $mgr)$hint"
    done
  done
  t=$((t + 1))
done
check_finish "$count certificates valid; soonest expiry in ${min:-?} days"
