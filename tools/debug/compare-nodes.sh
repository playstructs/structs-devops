#!/usr/bin/env bash
# devops debug compare-nodes [height]     [0]
#   Block header hashes at <height> and <height>+1 on the public RPC and on every
#   structsd node in the inventory (queried on its host). The header at H+1
#   commits to H's results (last_results_hash) and state (app_hash), so a node
#   that computed H differently shows up there. Default: public tip - 2.
set -euo pipefail
. "$DEVOPS_ROOT/tools/debug/_lib.sh"
need yq jq curl

H="${1:-}"
if [ -z "$H" ]; then H=$(( $(chain_height) - 2 )); fi
case "$H" in *[!0-9]*|"") usage_die "usage: devops debug compare-nodes [height]" ;; esac
H1=$((H + 1))
JQ='.result.block.header | [.height, .app_hash, .last_results_hash, .data_hash, .validators_hash] | @tsv'

out="$(debug_out "compare-nodes-$H").txt"
rows="$(mktemp)"; trap 'rm -f "$rows"' EXIT
pub="$(chain_rpc)"
for h in "$H" "$H1"; do
  r="$(curl -s -m 10 "$pub/block?height=$h" | jq -r "$JQ" 2>/dev/null || true)"
  printf 'public\t%s\n' "${r:-$h	unavailable}" >> "$rows"
done
while IFS="$(printf '\t')" read -r s hh _ rpc role _; do
  [ -n "$s" ] || continue
  for h in "$H" "$H1"; do
    r="$(host_run "$s" "$hh" "curl -s -m 10 $(printf '%q' "$rpc/block?height=$h") | jq -r $(printf '%q' "$JQ")" 2>/dev/null || true)"
    printf '%s\t%s\n' "$s:$hh($role)" "${r:-$h	unavailable (pruned, down or ssh failed)}" >> "$rows"
  done
done < <(inv_structsd_nodes)

{
  echo "# devops debug compare-nodes $H  ($(iso_now))"
  printf '%-28s %-9s %-14s %-14s %-14s %s\n' NODE HEIGHT APP_HASH RESULTS_HASH DATA_HASH VALIDATORS
  while IFS="$(printf '\t')" read -r n h a r d v; do
    printf '%-28s %-9s %-14s %-14s %-14s %s\n' "$n" "$h" "${a:0:12}" "${r:0:12}" "${d:0:12}" "${v:0:12}"
  done < "$rows"
  echo
  for h in "$H" "$H1"; do
    want="$(awk -F'\t' -v h="$h" '$1=="public" && $2==h {print $3"|"$4"|"$5"|"$6}' "$rows")"
    awk -F'\t' -v h="$h" -v w="$want" '$1!="public" && $2==h && $3!~/^unavailable/ && w!="" && ($3"|"$4"|"$5"|"$6)!=w {print "MISMATCH at " h ": " $1 " differs from the public node"}' "$rows"
  done
} | tee "$out"
grep -q MISMATCH "$out" && warn "hash mismatch: stop and read structs-debug-chain (consensus divergence) before restarting anything" \
  || ok "all reachable nodes agree at $H and $H1"
note "saved: ${out#"$DEVOPS_ROOT"/}"
