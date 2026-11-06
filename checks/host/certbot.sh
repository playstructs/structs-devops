# Host probe (streamed). Env: CERT_NAME. Read-only: never runs certbot itself.
n="${CERT_NAME:?}"
echo "timer=$(systemctl is-active certbot.timer 2>/dev/null || echo inactive)"
echo "next=$(systemctl list-timers certbot.timer --no-pager 2>/dev/null | awk 'NR==2 {print $1, $2, $3}')"
conf="/etc/letsencrypt/renewal/$n.conf"
if [ -f "$conf" ]; then
  echo "authenticator=$(sed -n 's/^authenticator *= *//p' "$conf")"
  echo "pre_hook=$(grep -c '^pre_hook' "$conf")"
  echo "post_hook=$(grep -c '^post_hook' "$conf")"
else
  echo "renewal_conf=missing"
fi
echo "deploy_hooks=$(ls -1 /etc/letsencrypt/renewal-hooks/deploy 2>/dev/null | tr '\n' ' ')"
key="$(readlink -f "/etc/letsencrypt/live/$n/privkey.pem" 2>/dev/null || true)"
if [ -n "$key" ] && command -v getfacl >/dev/null 2>&1; then
  echo "caddy_acl=$(getfacl -p "$key" 2>/dev/null | grep -c '^user:caddy:r' || true)"
fi
echo "le_errors_recent=$(tail -n 400 /var/log/letsencrypt/letsencrypt.log 2>/dev/null | grep -c ' ERROR ' || true)"
