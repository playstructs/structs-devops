#!/usr/bin/env bash
# devops tx <site> <account> [--broadcast] [--note TEXT] -- <module> <msg> [flags...] [-- positionals...]
#
# Always simulates first (tier 0). --broadcast is tier 3: Approval Block with
# signer, chain id, message and the simulation printed above it. The key is
# loaded on the host that holds it and never reaches the hub.
#   devops tx <guild> guild_admin -- structs guild-update-endpoint -- <guild-id> https://<guild-host>/guild.json
#   devops tx <guild> guild_admin -- structs allocation-create --allocation-type dynamic -- <source-id> 1000
set -euo pipefail
. "$DEVOPS_ROOT/lib/common.sh"
. "$DEVOPS_ROOT/lib/inventory.sh"
. "$DEVOPS_ROOT/lib/ssh.sh"
. "$DEVOPS_ROOT/lib/gate.sh"
. "$DEVOPS_ROOT/lib/secrets.sh"
. "$DEVOPS_ROOT/lib/chain.sh"
need yq jq

site="${1:-}"; acct="${2:-}"
[ -n "$site" ] && [ -n "$acct" ] || usage_die "usage: devops tx <site> <account> [--broadcast] [--note TEXT] -- <module> <msg> [flags] [-- positionals]"
shift 2
broadcast="" txnote=""
while [ $# -gt 0 ] && [ "$1" != "--" ]; do
  case "$1" in
    --broadcast) broadcast=1; shift ;;
    --note) txnote="$2"; shift 2 ;;
    *) usage_die "unknown option $1 (tx arguments go after --)" ;;
  esac
done
[ "${1:-}" = "--" ] || usage_die "tx arguments must follow --"
shift
[ $# -ge 2 ] || usage_die "need at least <module> <msg> after --"
[ -n "${DEVOPS_DRY_RUN:-}" ] && broadcast=""

inv_site_file "$site" >/dev/null
addr="$(inv_q "$site" ".onchain.accounts.\"$acct\".address")"
sname="$(inv_q "$site" ".onchain.accounts.\"$acct\".secret")"
[ -n "$addr" ] && [ -n "$sname" ] || die "$site has no onchain.accounts.$acct with address and secret"
secret_ref_of "$site" "$sname" >/dev/null
[ -n "$S_HOST" ] || die "secret $sname is not on a host (scheme $S_SCHEME); hub-side signing is not supported"
host="$S_HOST"
chain="$(chain_id)"; node="$(chain_rpc)"
image="$(inv_net '.images.structsd.repo // "structs/structsd"'):$(inv_net '.images.structsd.tag // "latest"')"

preamble() {
  secret_load_snippet MN
  printf 'export TX_MODE=%q TX_NAME=%q TX_EXPECT=%q TX_CHAIN_ID=%q TX_NODE=%q TX_IMAGE=%q TX_GAS_ADJ=%q\n' \
    "$1" "$acct" "$addr" "$chain" "$node" "$image" "${DEVOPS_GAS_ADJ:-1.5}"
}

logdir="$DEVOPS_REPORTS/tx-log"; mkdir -p "$logdir"
out="$(mktemp)"; trap 'rm -f "$out"' EXIT

info "simulating as $site.$acct ($addr) on $chain via $node"
if ! host_bundle "$site" "$host" "$(preamble simulate)" "$DEVOPS_ROOT/tools/host/tx-run.sh" "$@" | tee "$out"; then
  die "simulation failed; nothing was broadcast"
fi
grep -q '^SIMULATE_OK' "$out" || die "simulation did not complete"
[ -n "$broadcast" ] || { note "simulate only. To broadcast (tier 3), re-run with --broadcast"; exit 0; }

gate_site "$site"; GATE_HOST="$host"
GATE_EFFECT="Signs and broadcasts an on-chain transaction. This cannot be undone."
GATE_ROLLBACK="None on-chain. A follow-up transaction may be able to reverse its effect."
GATE_VERIFY="txhash and code are printed; the result is logged in $logdir/"
GATE_EXTRA="Signer:   $site.$acct = $addr (key loaded on $host from $sname)
Chain:    $chain via $node
Message:  structsd tx $(quote_argv "$@")
Note:     ${txnote:-(none)}
Simulation output is printed above this block."
gate 3 "Broadcast $1 $2 as $site.$acct" "structsd tx $(quote_argv "$@") --from $addr --chain-id $chain"

rc=0
host_bundle "$site" "$host" "$(preamble broadcast)" "$DEVOPS_ROOT/tools/host/tx-run.sh" "$@" | tee "$out" || rc=$?
res="$(grep '^RESULT ' "$out" | tail -1 || true)"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(iso_now)" "$site" "$acct" "$addr" "$(quote_argv "$@")" "${res#RESULT }" "${txnote:-}" >> "$logdir/$(today).tsv"
audit "TX site=$site acct=$acct addr=$addr msg=$1.$2 ${res#RESULT }"
[ "$rc" -eq 0 ] || die "broadcast failed or tx not committed (${res:-no result}); see $logdir/$(today).tsv"
ok "${res#RESULT }"
