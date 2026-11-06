# Streamed by the hub (after _prelude.sh). Env: WEBAPP_SRC WEBAPP_ENV. Read-only;
# secret keys are reported as set/EMPTY/absent, never their values.
repo="$(dirname "${WEBAPP_SRC:?}")"
if [ -d "$repo/.git" ]; then
  echo "branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD) commit=$(git -C "$repo" rev-parse --short HEAD) date=$(git -C "$repo" log -1 --format=%cs) dirty_files=$(git -C "$repo" status --porcelain | wc -l | tr -d ' ')"
fi
c="$(docker ps --format '{{.Names}}' | grep structs-webapp | grep -v cache | head -n1 || true)"
[ -n "$c" ] && echo "container=$c image=$(docker inspect --format '{{.Config.Image}}' "$c") started=$(docker inspect --format '{{.State.StartedAt}}' "$c")"
f="${WEBAPP_ENV:?}"
for k in OIDC_ENABLED OIDC_ISSUER; do echo "$k=$(envget "$f" "$k")"; done
for k in OIDC_MAS_CLIENT_SECRET OIDC_ENCRYPTION_KEY MATRIX_SIGNIN_CLIENT_ID GUILD_BOT_TOKEN APP_SECRET; do
  if grep -q "^$k=" "$f"; then
    [ -n "$(envget "$f" "$k")" ] && echo "$k=set" || echo "$k=EMPTY"
  else
    echo "$k=absent"
  fi
done
echo "env_mode=$(stat -c '%a %U' "$f")"
