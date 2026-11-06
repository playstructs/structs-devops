#!/usr/bin/env bash
# validator <site>: the site's validator is bonded, not jailed or tombstoned,
# and misses few blocks in the slashing window. Public LCD only.
. "$DEVOPS_ROOT/checks/_lib.sh"
check_site_arg "${1:-}"; site="$1"
need curl jq

op="$(inv_q "$site" '.onchain.validator.operator')"
[ -n "$op" ] || check_ok "site has no validator in onchain.validator"
v="$(lcd_get "/cosmos/staking/v1beta1/validators/$op" 2>/dev/null)" || check_unknown "LCD not answering"
status="$(printf '%s' "$v" | jq -r '.validator.status // empty')"
[ -n "$status" ] || check_crit "validator $op not found on chain"
jailed="$(printf '%s' "$v" | jq -r '.validator.jailed')"
moniker="$(printf '%s' "$v" | jq -r '.validator.description.moniker')"
tokens="$(printf '%s' "$v" | jq -r '.validator.tokens')"
[ "$status" = "BOND_STATUS_BONDED" ] || bump 2 "$moniker status $status"
[ "$jailed" = "true" ] && bump 2 "$moniker is JAILED (unjail is tier 3: devops tx $site validator -- slashing unjail)"

pk="$(printf '%s' "$v" | jq -r '.validator.consensus_pubkey.key // empty')"
if [ -n "$pk" ]; then
  prefix="$(inv_net '.bech32_prefix // "structs"')valcons"
  cons="$(python3 - "$pk" "$prefix" <<'PY'
import base64, hashlib, sys
CH = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
def polymod(v):
    g = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
    c = 1
    for x in v:
        b = c >> 25
        c = ((c & 0x1ffffff) << 5) ^ x
        for i in range(5):
            c ^= g[i] if ((b >> i) & 1) else 0
    return c
def hrp_exp(h): return [ord(x) >> 5 for x in h] + [0] + [ord(x) & 31 for x in h]
def bits(data):
    acc = n = 0; out = []
    for b in data:
        acc = (acc << 8) | b; n += 8
        while n >= 5:
            n -= 5; out.append((acc >> n) & 31)
    if n: out.append((acc << (5 - n)) & 31)
    return out
hrp = sys.argv[2]
d = bits(hashlib.sha256(base64.b64decode(sys.argv[1])).digest()[:20])
pm = polymod(hrp_exp(hrp) + d + [0] * 6) ^ 1
print(hrp + "1" + "".join(CH[x] for x in d + [(pm >> 5 * (5 - i)) & 31 for i in range(6)]))
PY
)"
  si="$(lcd_get "/cosmos/slashing/v1beta1/signing_infos/$cons" 2>/dev/null || true)"
  win="$(lcd_get /cosmos/slashing/v1beta1/params 2>/dev/null | jq -r '.params.signed_blocks_window // empty')"
  missed="$(printf '%s' "$si" | jq -r '.val_signing_info.missed_blocks_counter // empty' 2>/dev/null)"
  tomb="$(printf '%s' "$si" | jq -r '.val_signing_info.tombstoned // false' 2>/dev/null)"
  [ "$tomb" = "true" ] && bump 2 "$moniker is TOMBSTONED (double-sign); it can never rejoin with this key"
  if [ -n "$missed" ] && [ -n "$win" ]; then
    mp="$(py "round(100.0*$missed/$win, 1)")"
    bump "$(level_high "$mp" 5 30)" "missed $missed of the last $win blocks (${mp}%)"
  else
    detail "signing info unavailable for $cons"
  fi
fi
check_finish "$moniker bonded, $(py "round($tokens/1e6, 1)")M tokens, missed ${missed:-?}/${win:-?}"
