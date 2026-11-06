# Streamed by the hub after _prelude.sh and a preamble that loads MN from the
# host (never printed) and sets TX_MODE (simulate|broadcast) TX_NAME TX_EXPECT
# TX_CHAIN_ID TX_NODE TX_IMAGE TX_GAS_ADJ.
# Args: <module> <msg> [flags...] [-- positionals...]
# Signing happens in an ephemeral structsd container with a throwaway test
# keyring; the mnemonic only exists in this process and that container.
inner="$(mktemp)"
trap 'rm -f "$inner"' EXIT
cat > "$inner" <<'INNER'
set -euo pipefail
module="$1"; msg="$2"; shift 2
flags=(); pos=()
seen=""
for a in "$@"; do
  if [ -z "$seen" ] && [ "$a" = "--" ]; then seen=1; continue; fi
  if [ -n "$seen" ]; then pos+=("$a"); else flags+=("$a"); fi
done
if [ -z "$seen" ]; then pos=(${flags[@]+"${flags[@]}"}); flags=(); fi

printf '%s\n' "$MN" | structsd keys add "$TX_NAME" --recover --keyring-backend test >/dev/null 2>&1 || true
unset MN
ADDR="$(structsd keys show "$TX_NAME" -a --keyring-backend test)"
echo "signer=$ADDR"
if [ -n "${TX_EXPECT:-}" ] && [ "$ADDR" != "$TX_EXPECT" ]; then
  echo "FATAL: recovered $ADDR but the inventory expects $TX_EXPECT; refusing to sign" >&2
  exit 1
fi
catching="$(structsd status --node "$TX_NODE" 2>/dev/null | jq -r '(.sync_info // .SyncInfo).catching_up' 2>/dev/null || echo unknown)"
echo "node=$TX_NODE catching_up=$catching"
common=(--chain-id "$TX_CHAIN_ID" --node "$TX_NODE" --keyring-backend test --gas auto --gas-adjustment "$TX_GAS_ADJ")
echo "msg=$module $msg ${flags[*]-} -- ${pos[*]-}"
echo "=== simulate ==="
structsd tx "$module" "$msg" ${flags[@]+"${flags[@]}"} --from "$ADDR" "${common[@]}" --dry-run -- ${pos[@]+"${pos[@]}"}
echo "SIMULATE_OK"
[ "$TX_MODE" = "broadcast" ] || exit 0
if [ "$catching" != "false" ]; then echo "FATAL: node catching_up=$catching; refusing to broadcast" >&2; exit 1; fi
echo "=== broadcast ==="
out="$(structsd tx "$module" "$msg" ${flags[@]+"${flags[@]}"} --from "$TX_NAME" "${common[@]}" -y --output json -- ${pos[@]+"${pos[@]}"})"
hash="$(printf '%s' "$out" | jq -r '.txhash')"
code="$(printf '%s' "$out" | jq -r '.code')"
echo "txhash=$hash checktx_code=$code"
if [ "$code" != "0" ]; then printf '%s' "$out" | jq -r '.raw_log' >&2; echo "RESULT txhash=$hash code=$code height=0"; exit 1; fi
for _ in $(seq 1 30); do
  sleep 3
  if res="$(structsd query tx "$hash" --node "$TX_NODE" --output json 2>/dev/null)"; then
    code="$(printf '%s' "$res" | jq -r '.code')"
    height="$(printf '%s' "$res" | jq -r '.height')"
    [ "$code" != "0" ] && printf '%s' "$res" | jq -r '.raw_log' >&2
    echo "RESULT txhash=$hash code=$code height=$height"
    [ "$code" = "0" ]; exit $?
  fi
done
echo "RESULT txhash=$hash code=unknown height=0 (not found after 90 s; check: structsd query tx $hash)"
exit 1
INNER

docker run --rm -e MN -e TX_MODE -e TX_NAME -e TX_EXPECT -e TX_CHAIN_ID -e TX_NODE -e TX_GAS_ADJ \
  -v "$inner:/run/inner.sh:ro" --entrypoint bash "${TX_IMAGE:-structs/structsd:latest}" /run/inner.sh "$@"
