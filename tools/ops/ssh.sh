#!/usr/bin/env bash
# devops ssh <site|host|site:host>             interactive shell (humans only)
# devops ssh <site|host|site:host> -- <cmd>    one command, tier from policy.tsv
set -euo pipefail
. "$DEVOPS_ROOT/lib/common.sh"
. "$DEVOPS_ROOT/lib/inventory.sh"
. "$DEVOPS_ROOT/lib/ssh.sh"
. "$DEVOPS_ROOT/lib/gate.sh"
need yq python3

[ $# -ge 1 ] || usage_die "usage: devops ssh <site|host> [-- cmd]"
inv_resolve "$1"; shift
target="$(ssh_target "$T_SITE" "$T_HOST")"

if [ $# -eq 0 ] || { [ "$1" = "--" ] && [ $# -eq 1 ]; }; then
  is_agent && die "interactive ssh is for humans; agents pass a command: devops ssh $T_SITE -- '<cmd>'"
  [ "$target" = "local" ] && exec "${SHELL:-bash}"
  exec ssh "$target"
fi
[ "$1" = "--" ] && shift
cmd="$*"

cls="$(python3 "$DEVOPS_ROOT/tools/agents/classify.py" -- "$cmd" || true)"
tier="${cls%% *}"; reason="${cls#* }"
case "$tier" in
  S) die "refused: $reason. Secrets never leave the host; use devops secrets audit $T_SITE" ;;
  0|1) ;;
  *)
    gate_site "$T_SITE"; GATE_HOST="$T_HOST"
    GATE_EFFECT="Raw command classified tier $tier: $reason"
    GATE_ROLLBACK="Prefer a devops subcommand with a defined rollback if one exists (devops help)."
    gate "$tier" "Raw command on $T_SITE:$T_HOST" "$cmd"
    audit "SSH tier=$tier site=$T_SITE host=$T_HOST cmd=$(printf '%s' "$cmd" | tr '\n\t' '  ')"
    ;;
esac
host_run "$T_SITE" "$T_HOST" "$cmd"
