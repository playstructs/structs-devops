# Streamed by the hub after _prelude.sh. Env: KEY_NAME KEY_DIR TX_IMAGE.
# Generates a mnemonic inside an ephemeral structsd container, writes it to
# $KEY_DIR/$KEY_NAME.mnemonic (mode 600) on this host, prints the address only.
umask 077
mkdir -p "$KEY_DIR"
f="$KEY_DIR/$KEY_NAME.mnemonic"
[ -e "$f" ] && { echo "FATAL: $f already exists; refusing to overwrite a key" >&2; exit 1; }
inner="$(mktemp)"; trap 'rm -f "$inner"' EXIT
cat > "$inner" <<'INNER'
set -euo pipefail
umask 077
MN="$(structsd keys mnemonic 2>/dev/null)"
printf '%s\n' "$MN" > /keys/out.mnemonic
printf '%s\n' "$MN" | structsd keys add k --recover --keyring-backend test >/dev/null 2>&1
unset MN
structsd keys show k -a --keyring-backend test
INNER
tmpd="$(mktemp -d)"; chmod 700 "$tmpd"
addr="$(docker run --rm -v "$inner:/run/inner.sh:ro" -v "$tmpd:/keys" --entrypoint bash "${TX_IMAGE:-structs/structsd:latest}" /run/inner.sh)"
mv "$tmpd/out.mnemonic" "$f"; rmdir "$tmpd"
chmod 600 "$f"
echo "address=$addr"
echo "mnemonic_file=$f"
echo "pointer=host-file:${HOST_ID:-<host>}:$f"
