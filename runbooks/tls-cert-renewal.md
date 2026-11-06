# TLS certificate renewal (certbot + Caddy)

Incident fixed 2026-08-06: cert expired because auto-renew kept failing, then Caddy couldn't start after a manual renew until ACLs were restored.

## How TLS is set up

- Certbot issues Let's Encrypt ECDSA certs for `public.testnet.structs.network`
- Authenticator: **`standalone`** (binds TCP :80 during challenge)
- Caddy terminates TLS for LCD (`:443`) and RPC (`:26657`) using the live PEMs under `/etc/letsencrypt/live/...`
- `structsd` itself does **not** terminate TLS (RPC/LCD are plaintext on loopback)

## Why auto-renew failed (Aug 2026)

`certbot.timer` was enabled and running twice daily, but every attempt failed with:

```text
Could not bind TCP port 80 because it is already in use by another process
```

Caddy holds `:80` for HTTP→HTTPS redirects. Standalone authenticator cannot bind `:80` while Caddy is up.

**Permanent fix already applied** in `/etc/letsencrypt/renewal/public.testnet.structs.network.conf`:

```ini
[renewalparams]
pre_hook = systemctl stop caddy
post_hook = systemctl start caddy
authenticator = standalone
```

## Why Caddy failed after renew (second failure)

Certbot writes new archive files via rename and **drops inherited ACLs**. New `privkeyN.pem` was `root:root` mode `0640` with no `user:caddy:r--` ACL, so Caddy (runs as `caddy`) got:

```text
open .../privkey.pem: permission denied
```

**Permanent fix already applied**: deploy hook

`/etc/letsencrypt/renewal-hooks/deploy/00-fix-cert-acls.sh`

(runs before `reload-caddy.sh`, re-grants `caddy` read on the live certs).

Deploy hook order (lexical):

1. `00-fix-cert-acls.sh` — ACL restore
2. `reload-caddy.sh` — `systemctl restart caddy`
3. `sync-structsd-cert.sh` — copies PEMs into chaindata volume + restarts container (legacy; CometBFT TLS is empty now, but restart is harmless)

## Manual renew (if needed)

```bash
ssh root@<public-node-ip>

# Dry-run first (safe)
certbot renew --cert-name public.testnet.structs.network --dry-run

# Force renew
certbot renew --cert-name public.testnet.structs.network --force-renewal --no-random-sleep-on-renew

certbot certificates
systemctl is-active caddy
```

If Caddy fails with permission denied on privkey:

```bash
LIVE=/etc/letsencrypt/live/public.testnet.structs.network
for f in "$LIVE"/cert.pem "$LIVE"/chain.pem "$LIVE"/fullchain.pem "$LIVE"/privkey.pem; do
  setfacl -m u:caddy:r-- "$f"
done
systemctl start caddy
```

## Verification

```bash
certbot certificates   # should say VALID, ~90 days
systemctl is-active caddy
echo | openssl s_client -servername public.testnet.structs.network \
  -connect public.testnet.structs.network:443 2>/dev/null \
  | openssl x509 -noout -dates
curl -sS -o /dev/null -w '%{http_code}\n' \
  https://public.testnet.structs.network/cosmos/base/tendermint/v1beta1/node_info
curl -sS -o /dev/null -w '%{http_code}\n' \
  https://public.testnet.structs.network:26657/status
```

## Check timer health

```bash
systemctl status certbot.timer --no-pager
journalctl -u certbot.service --since '7 days ago' --no-pager | grep -E 'success|Failed|renew'
```
