#!/usr/bin/env bash
# devops account list [site]                              [0] inventory accounts with addresses and balances
# devops account create-key <site> <name> [--host H]      [3] mnemonic generated and kept on the host
# devops account create-player <site> <name> [--guild-id ID] [--username U] [--pfp URL]   [3]
#     signs up a new player through the guild API (structs-ai create-player.mjs)
# Neither command prints a mnemonic. Each prints the address and the secret
# pointer to add to site.yaml (secrets + onchain.accounts).
set -euo pipefail
. "$DEVOPS_ROOT/lib/common.sh"
. "$DEVOPS_ROOT/lib/inventory.sh"
. "$DEVOPS_ROOT/lib/ssh.sh"
. "$DEVOPS_ROOT/lib/gate.sh"
. "$DEVOPS_ROOT/lib/chain.sh"
need yq jq

sub="${1:-list}"; [ $# -gt 0 ] && shift
KEY_DIR_DEFAULT="/root/.structs-devops/keys"
image="$(inv_net '.images.structsd.repo // "structs/structsd"'):$(inv_net '.images.structsd.tag // "latest"')"

case "$sub" in
  list)
    for s in ${1:-$(inv_sites)}; do
      yq -r '(.onchain.accounts // {}) | to_entries[] | .key + "\t" + .value.address + "\t" + (.value.secret // "")' "$(inv_site_file "$s")" |
      while IFS="$(printf '\t')" read -r a addr sec; do
        bal="$(lcd_get "/cosmos/bank/v1beta1/balances/$addr" 2>/dev/null | jq -r '[.balances[]? | "\(.amount)\(.denom)"] | join(",")' 2>/dev/null || echo '?')"
        printf '%-16s %-14s %-48s %-24s %s\n' "$s" "$a" "$addr" "${sec:--}" "${bal:-0}"
      done
    done ;;
  create-key|create-player)
    site="${1:-}"; name="${2:-}"
    [ -n "$site" ] && [ -n "$name" ] || usage_die "usage: devops account $sub <site> <name> [...]"
    shift 2
    case "$name" in *[!a-z0-9_-]*) usage_die "name: lowercase letters, digits, _ and -" ;; esac
    inv_site_file "$site" >/dev/null
    host="$(inv_primary_host "$site")" guild="" uname="" pfp=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --host) host="$2"; shift 2 ;;
        --guild-id) guild="$2"; shift 2 ;;
        --username) uname="$2"; shift 2 ;;
        --pfp) pfp="$2"; shift 2 ;;
        *) usage_die "unknown option $1" ;;
      esac
    done
    keydir="$(inv_host "$site" "$host" key_dir)"; keydir="${keydir:-$KEY_DIR_DEFAULT}"
    gate_site "$site"; GATE_HOST="$host"
    if [ "$sub" = "create-key" ]; then
      GATE_EFFECT="Generates a new mnemonic on $host and stores it at $keydir/$name.mnemonic (600). Nothing is broadcast."
      GATE_ROLLBACK="Delete the file on the host (the key has no on-chain footprint until it is used)."
      GATE_VERIFY="The address is printed; add the pointer to sites/$site/site.yaml"
      [ -n "${DEVOPS_DRY_RUN:-}" ] && { echo "dry-run: create key $name on $site:$host in $keydir"; exit 0; }
      gate 3 "Create key $name on $site" "create-key $name on $host ($keydir)"
      pre="export KEY_NAME=$(printf '%q' "$name") KEY_DIR=$(printf '%q' "$keydir") TX_IMAGE=$(printf '%q' "$image") HOST_ID=$(printf '%q' "$host")"
      host_bundle "$site" "$host" "$pre" "$DEVOPS_ROOT/tools/host/create-key.sh"
    else
      guild="${guild:-$(inv_q "$site" '.onchain.guild.id')}"
      [ -n "$guild" ] || usage_die "--guild-id needed (site has no onchain.guild.id)"
      api="$(lcd_get "/structs/guild/$guild" | jq -r '(.Guild // .guild).endpoint' | xargs -I{} curl -fsS -m 10 {} 2>/dev/null | jq -r '.guild.services.guild_api // .services.guild_api // empty' 2>/dev/null || true)"
      [ -n "$api" ] || api="$(inv_q "$site" '.onchain.guild.api')"
      [ -n "$api" ] || api="https://$(inv_host "$site" "$host" fqdn)/api/"
      onboard="$DEVOPS_REFS/structs-ai/.cursor/skills/structs-onboarding/scripts"
      [ -f "$onboard/create-player.mjs" ] || die "missing $onboard/create-player.mjs (devops refs sync structs-ai)"
      GATE_EFFECT="Generates a mnemonic on $host, signs a guild-join proxy message and POSTs it to $api; the guild then creates player on chain in guild $guild."
      GATE_ROLLBACK="None on-chain; the player persists. The mnemonic file stays on the host."
      GATE_VERIFY="player_id is printed; devops onchain $site show"
      [ -n "${DEVOPS_DRY_RUN:-}" ] && { echo "dry-run: create-player $name in guild $guild via $api on $site:$host"; exit 0; }
      gate 3 "Create player $name in guild $guild" "create-player.mjs --guild-id $guild --guild-api $api --reactor-api $(chain_lcd)"
      tp="$(inv_host "$site" "$host" tools_path)"; tp="${tp:-/opt/structs-devops}"
      for f in create-player.mjs package.json package-lock.json; do host_copy "$site" "$host" "$onboard/$f" "$tp/vendor/structs-onboarding/$f"; done
      pre="export KEY_NAME=$(printf '%q' "$name") KEY_DIR=$(printf '%q' "$keydir") GUILD_ID=$(printf '%q' "$guild") GUILD_API=$(printf '%q' "$api") REACTOR_API=$(printf '%q' "$(chain_lcd)") ONBOARD_DIR=$(printf '%q' "$tp/vendor/structs-onboarding") PLAYER_USERNAME=$(printf '%q' "$uname") PLAYER_PFP=$(printf '%q' "$pfp")"
      host_bundle "$site" "$host" "$pre" "$DEVOPS_ROOT/tools/host/create-player.sh"
    fi
    audit "ACCOUNT $sub site=$site host=$host name=$name"
    cat <<EOF

Add to inventory/sites/$site/site.yaml:
  secrets:
    $name:
      ref: "host-file:$host:$keydir/$name.mnemonic"
      criticality: high
      backup: none        # decide where the off-host backup lives
      rotation: not-rotatable (address-bound)
      used_by: [tx]
  onchain.accounts.$name: { address: <address above>, secret: $name }
EOF
    ;;
  *) usage_die "usage: devops account list|create-key|create-player ..." ;;
esac
