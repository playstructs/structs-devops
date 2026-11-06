#!/usr/bin/env bash
# Restore webapp OIDC (and guild chat) settings from structs-tel/.env so MAS
# can use the webapp as its upstream IdP. Run after every structs-webapp pull:
# the tracked src/.env defaults OIDC_ENABLED=false. Never prints secret values.
. "$(dirname "$0")/_bundle.sh"

WEB="${WEBAPP_ENV:?}"
TEL="${TEL_ENV:?}"
ISSUER="${OIDC_ISSUER:?}"
AUTH_HOST="${MAS_AUTH_HOST:?}"
[ -f "$WEB" ] && [ -f "$TEL" ] || { echo "FATAL: need $WEB and $TEL" >&2; exit 1; }

python3 - "$WEB" "$TEL" "$ISSUER" "$AUTH_HOST" <<'PY'
from pathlib import Path
import re, secrets, sys
web, tel = Path(sys.argv[1]), Path(sys.argv[2])
issuer, auth_host = sys.argv[3], sys.argv[4]

def envmap(path):
    out = {}
    for line in path.read_text().splitlines():
        if not line.strip() or line.strip().startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k] = v.strip().strip("'").strip('"')
    return out

t = envmap(tel)
secret = t.get("OIDC_MAS_CLIENT_SECRET", "")
pid = t.get("MAS_UPSTREAM_PROVIDER_ID", "")
if not secret or not pid:
    raise SystemExit("structs-tel .env missing OIDC_MAS_CLIENT_SECRET or MAS_UPSTREAM_PROVIDER_ID")

def setkv(text, key, value, quote=True):
    val = f"'{value}'" if quote else value
    pat = re.compile(rf"^{re.escape(key)}=.*$", re.M)
    if not pat.search(text):
        raise SystemExit(f"missing {key} in webapp .env")
    return pat.sub(lambda _m: f"{key}={val}", text, count=1)

w = web.read_text()
w = setkv(w, "OIDC_ENABLED", "true", quote=False)
w = setkv(w, "OIDC_ISSUER", issuer)
w = setkv(w, "OIDC_MAS_CLIENT_ID", t.get("OIDC_MAS_CLIENT_ID") or "matrix-auth-service")
w = setkv(w, "OIDC_MAS_CLIENT_SECRET", secret)
w = setkv(w, "OIDC_MAS_REDIRECT_URI", f"https://{auth_host}/upstream/callback/{pid}")
if not envmap(web).get("OIDC_ENCRYPTION_KEY", ""):
    w = setkv(w, "OIDC_ENCRYPTION_KEY", secrets.token_hex(32))
    print("  generated OIDC_ENCRYPTION_KEY (was empty: existing OIDC sessions are invalidated)")
if re.search(r"^GUILD_BOT_TOKEN=", w, re.M):
    bot = tel.parent / "config/secrets/guild-bot.compatibility-token"
    if not bot.is_file() or not t.get("MATRIX_SERVER_NAME"):
        raise SystemExit(f"chat rooms need MATRIX_SERVER_NAME in {tel} and {bot}")
    w = setkv(w, "MATRIX_SERVER_NAME", t["MATRIX_SERVER_NAME"])
    w = setkv(w, "GUILD_BOT_TOKEN", bot.read_text().strip())
    print(f"  chat rooms restored from structs-tel ({t['MATRIX_SERVER_NAME']})")
with open(web, "w") as f:
    f.write(w)
print(f"  OIDC restored from structs-tel (issuer {issuer})")
PY

[ -n "${WEBAPP_FILE_OWNER:-}" ] && chown "$WEBAPP_FILE_OWNER" "$WEB"
chmod "${WEBAPP_ENV_MODE:-664}" "$WEB"

C="$(webapp_container)"
docker exec "$C" bash -lc 'cd /src && php bin/console cache:clear --env=prod'
docker exec "$C" bash -lc 'cd /src && php bin/console app:oidc:seed-client -n'
curl -sS -o /dev/null -w '  discovery %{http_code} %{content_type}\n' --max-time 8 \
  -H 'Accept: application/json' "${ISSUER}/.well-known/openid-configuration"
