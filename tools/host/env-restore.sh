#!/usr/bin/env bash
# env-restore.sh KEY... : after a webapp pull, copy KEY values that are now
# empty in ${WEBAPP_ENV} back from its newest .bak.* (the tracked .env blanks
# MATRIX_SIGNIN_CLIENT_ID and OIDC_ENCRYPTION_KEY). Prints key names only.
. "$(dirname "$0")/_bundle.sh"

WEB="${WEBAPP_ENV:?}"
[ $# -gt 0 ] || { echo "usage: env-restore.sh KEY..." >&2; exit 2; }
BAK="$(ls -1t "$WEB".bak.* 2>/dev/null | head -n1 || true)"
[ -n "$BAK" ] || { echo "FATAL: no backup $WEB.bak.* (take one before pulling)" >&2; exit 1; }
echo "  restoring from $BAK"

rc=0
python3 - "$WEB" "$BAK" "$@" <<'PY' || rc=$?
import re, sys
web, bak, keys = sys.argv[1], sys.argv[2], sys.argv[3:]
def val(text, k):
    m = re.search(rf"^{re.escape(k)}=(.*)$", text, re.M)
    return None if m is None else m.group(1)
cur = open(web).read()
old = open(bak).read()
rc = 0
for k in keys:
    have, prev = val(cur, k), val(old, k)
    empty = lambda v: v is None or v.strip().strip("'\"") == ""
    if not empty(have):
        print(f"  {k}: already set")
    elif empty(prev):
        print(f"  {k}: EMPTY in backup too; set it by hand")
        rc = 1
    elif have is None:
        cur = cur.rstrip("\n") + f"\n{k}={prev}\n"
        print(f"  {k}: restored (appended)")
    else:
        cur = re.sub(rf"^{re.escape(k)}=.*$", lambda _m: f"{k}={prev}", cur, count=1, flags=re.M)
        print(f"  {k}: restored")
with open(web, "w") as f:
    f.write(cur)
sys.exit(rc)
PY
[ -n "${WEBAPP_FILE_OWNER:-}" ] && chown "$WEBAPP_FILE_OWNER" "$WEB"
chmod "${WEBAPP_ENV_MODE:-664}" "$WEB"
exit "$rc"
