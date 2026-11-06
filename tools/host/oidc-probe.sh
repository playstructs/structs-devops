# Host side of devops debug oidc-probe (streamed). Prints booleans, lengths and
# HTTP codes only; never a secret value.
# Env: WEBAPP_ENV TEL_ENV OIDC_ISSUER MAS_AUTH_HOST MATRIX_HOST
set +e
python3 - <<'PY'
import base64, json, os, re, urllib.error, urllib.parse, urllib.request
from pathlib import Path

web = Path(os.environ.get("WEBAPP_ENV", ""))
tel = Path(os.environ.get("TEL_ENV", ""))
issuer = os.environ.get("OIDC_ISSUER", "").rstrip("/")
mas = os.environ.get("MAS_AUTH_HOST", "")
matrix = os.environ.get("MATRIX_HOST") or ("matrix." + urllib.parse.urlparse(issuer).hostname if issuer else "")

def env(path, key):
    try:
        m = re.search(rf"^{re.escape(key)}=(.*)$", path.read_text(), re.M)
    except OSError:
        return None
    return m.group(1).strip().strip("'\"") if m else ""

def http(url, data=None, headers=None):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method="POST" if data else "GET")
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, r.read(400).decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read(400).decode(errors="replace")
    except Exception as e:
        return 0, str(e)[:120]

print(f"webapp_env={'present' if web.is_file() else 'MISSING'} tel_env={'present' if tel.is_file() else 'MISSING'}")
for k in ("OIDC_ENABLED", "OIDC_ISSUER", "OIDC_MAS_REDIRECT_URI"):
    print(f"web.{k}={env(web, k)!r}")
for k in ("OIDC_ENCRYPTION_KEY", "MATRIX_SIGNIN_CLIENT_ID", "OIDC_MAS_CLIENT_SECRET"):
    v = env(web, k)
    print(f"web.{k}={'set' if v else 'EMPTY' if v == '' else 'absent'} len={len(v or '')}")
cid_w, cid_t = env(web, "OIDC_MAS_CLIENT_ID"), env(tel, "OIDC_MAS_CLIENT_ID")
sec_w, sec_t = env(web, "OIDC_MAS_CLIENT_SECRET"), env(tel, "OIDC_MAS_CLIENT_SECRET")
print(f"client_id_match={cid_w == cid_t and bool(cid_w)}")
print(f"client_secret_match={sec_w == sec_t and bool(sec_w)} hex={bool(sec_w) and all(c in '0123456789abcdef' for c in sec_w)}")

for name, url in [
    ("webapp_discovery", f"{issuer}/.well-known/openid-configuration"),
    ("webapp_jwks", f"{issuer}/oauth/jwks"),
    ("mas_discovery", f"https://{mas}/.well-known/openid-configuration" if mas else ""),
    ("matrix_versions", f"https://{matrix}/_matrix/client/versions" if matrix else ""),
]:
    if url:
        code, _ = http(url)
        print(f"{name}={code} {url}")

if issuer and sec_t:
    user = urllib.parse.quote(cid_t or "matrix-auth-service", safe="")
    pw = urllib.parse.quote(sec_t, safe="")
    basic = base64.b64encode(f"{user}:{pw}".encode()).decode()
    body = urllib.parse.urlencode({"grant_type": "authorization_code", "code": "devops-probe",
                                   "redirect_uri": env(web, "OIDC_MAS_REDIRECT_URI") or ""}).encode()
    code, text = http(f"{issuer}/oauth/token", body,
                      {"Authorization": f"Basic {basic}", "Content-Type": "application/x-www-form-urlencoded"})
    try:
        err = json.loads(text).get("error", "")
    except ValueError:
        err = text[:80].replace("\n", " ")
    verdict = ("PASS client auth ok" if (code, err) == (400, "invalid_grant") else
               "FAIL client auth rejected (secret mismatch or base64 instead of hex)" if code == 401 else "UNEXPECTED")
    print(f"token_probe={code} error={err!r} -> {verdict}")
else:
    print("token_probe=skipped (no issuer or no MAS client secret in TEL_ENV)")
PY
