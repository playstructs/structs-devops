# Streamed by the hub after _prelude.sh. Env: KEY_NAME KEY_DIR GUILD_ID GUILD_API
# REACTOR_API ONBOARD_DIR [PLAYER_USERNAME PLAYER_PFP NODE_IMAGE].
# Runs structs-ai's create-player.mjs in a node container on this host. The
# mnemonic it generates goes to $KEY_DIR/$KEY_NAME.mnemonic (600); only the
# address and player id are printed.
umask 077
mkdir -p "$KEY_DIR"
f="$KEY_DIR/$KEY_NAME.mnemonic"
[ -e "$f" ] && { echo "FATAL: $f already exists; pass an existing key with the hub's --reuse" >&2; exit 1; }
[ -f "$ONBOARD_DIR/create-player.mjs" ] || { echo "FATAL: $ONBOARD_DIR/create-player.mjs missing (hub copies it)" >&2; exit 1; }
out="$(mktemp)"; trap 'rm -f "$out"' EXIT
extra=()
[ -n "${PLAYER_USERNAME:-}" ] && extra+=(--username "$PLAYER_USERNAME")
[ -n "${PLAYER_PFP:-}" ] && extra+=(--pfp "$PLAYER_PFP")
rc=0
docker run --rm -v "$ONBOARD_DIR:/app" -w /app "${NODE_IMAGE:-node:22-alpine}" sh -c \
  'npm ci --silent --no-audit --no-fund >/dev/null 2>&1 && node create-player.mjs "$@"' sh \
  --guild-id "$GUILD_ID" --guild-api "$GUILD_API" --reactor-api "$REACTOR_API" ${extra[@]+"${extra[@]}"} > "$out" || rc=$?
mn="$(jq -r '.mnemonic // empty' "$out" 2>/dev/null || true)"
if [ -n "$mn" ]; then printf '%s\n' "$mn" > "$f"; chmod 600 "$f"; echo "mnemonic_file=$f"; fi
unset mn
jq -c 'del(.mnemonic)' "$out" 2>/dev/null || echo "create-player produced no JSON (rc=$rc)"
exit "$rc"
