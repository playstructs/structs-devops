#!/usr/bin/env bash
# devops gov list                       [0] proposals in deposit/voting, and each inventory voter's vote
# devops gov show <id>                  [0] details: messages, upgrade plan + ETA, tally, deadline
# devops gov verify [id]                [0] exit 1 if a voter has not voted on an open proposal
# devops gov vote <id> <yes|no|abstain|no_with_veto> --as <site>.<account> [--broadcast]   [0]/[3]
# Votes are never cast automatically: crons only remind.
set -euo pipefail
. "$DEVOPS_ROOT/lib/common.sh"
. "$DEVOPS_ROOT/lib/inventory.sh"
. "$DEVOPS_ROOT/lib/chain.sh"
need yq jq curl

sub="${1:-list}"; [ $# -gt 0 ] && shift

voters() {
  # site<TAB>account<TAB>address
  local s a
  yq -r '(.gov.voters // [])[] | .site + "\t" + .account' "$(inv_network_file)" |
  while IFS="$(printf '\t')" read -r s a; do
    printf '%s\t%s\t%s\n' "$s" "$a" "$(inv_q "$s" ".onchain.accounts.\"$a\".address")"
  done
}

vote_of() { gov_vote_of "$1" "$2"; }

case "$sub" in
  list)
    listing="$(for st in 1 2; do
      lbl="$([ "$st" = 1 ] && echo DEPOSIT || echo VOTING)"
      lcd_get "/cosmos/gov/v1/proposals?proposal_status=$st&pagination.limit=100" | jq -r '.proposals[]? |
        [.id, (.title // "untitled"), (.voting_end_time // .deposit_end_time), ((.messages[0]["@type"] // "text") | split(".") | last)] | @tsv' |
      while IFS="$(printf '\t')" read -r id title end typ; do
        echo "$lbl #$id  $title  ($typ, ends $end)"
        if [ "$st" = 2 ]; then
          voters | while IFS="$(printf '\t')" read -r s a addr; do
            v="$(vote_of "$id" "$addr")"
            echo "    $s.$a: ${v:-NOT VOTED}"
          done
        fi
      done
    done)"
    if [ -n "$listing" ]; then printf '%s\n' "$listing"; else echo "no proposals in deposit or voting period"; fi
    last="$(lcd_get '/cosmos/gov/v1/proposals?pagination.reverse=true&pagination.limit=1' | jq -r '.proposals[0] | "#\(.id) \(.title) \(.status)"' 2>/dev/null || true)"
    [ -n "$last" ] && note "latest proposal: $last" ;;
  show)
    id="${1:-}"; [ -n "$id" ] || usage_die "usage: devops gov show <id>"
    p="$(lcd_get "/cosmos/gov/v1/proposals/$id")"
    printf '%s' "$p" | jq -r '.proposal | "#\(.id) \(.title)\nstatus: \(.status)\nsubmitted: \(.submit_time)\nvoting: \(.voting_start_time) -> \(.voting_end_time)\nsummary: \(.summary)\nmessages:"'
    printf '%s' "$p" | jq -r '.proposal.messages[] | "  - \(.["@type"])" + (if .plan then " plan=\(.plan.name) height=\(.plan.height) info=\(.plan.info|tostring|.[0:120])" else "" end)'
    ph="$(printf '%s' "$p" | jq -r '.proposal.messages[] | select(.plan) | .plan.height' | head -1)"
    [ -n "$ph" ] && echo "upgrade ETA: ~$(eta_hours "$ph") h (height now $(chain_height))"
    echo "tally:"; lcd_get "/cosmos/gov/v1/proposals/$id/tally" | jq -r '.tally | to_entries[] | "  \(.key)=\(.value)"'
    if [ "$(printf '%s' "$p" | jq -r '.proposal.status')" = "PROPOSAL_STATUS_VOTING_PERIOD" ]; then
      voters | while IFS="$(printf '\t')" read -r s a addr; do v="$(vote_of "$id" "$addr")"; echo "  $s.$a: ${v:-NOT VOTED}"; done
    else
      note "individual votes are pruned once a proposal is tallied"
    fi ;;
  verify)
    ids="${1:-$(gov_voting_proposals | cut -f1)}"
    missing=0
    for id in $ids; do
      while IFS="$(printf '\t')" read -r s a addr; do
        v="$(vote_of "$id" "$addr")"
        if [ -z "$v" ]; then echo "MISSING #$id $s.$a ($addr)"; missing=$((missing + 1)); else echo "ok #$id $s.$a $v"; fi
      done < <(voters)
    done
    [ -z "$ids" ] && echo "no proposals in voting period"
    [ "$missing" -eq 0 ] ;;
  vote)
    id="${1:-}"; opt="${2:-}"; shift 2 2>/dev/null || shift $#
    as="" bc=()
    while [ $# -gt 0 ]; do
      case "$1" in --as) as="$2"; shift 2 ;; --broadcast) bc=(--broadcast); shift ;; *) usage_die "unknown $1" ;; esac
    done
    [ -n "$id" ] && [ -n "$opt" ] && [ -n "$as" ] || usage_die "usage: devops gov vote <id> <yes|no|abstain|no_with_veto> --as <site>.<account> [--broadcast]"
    case "$opt" in yes|no|abstain|no_with_veto) ;; *) usage_die "option must be yes, no, abstain or no_with_veto" ;; esac
    s="${as%%.*}"; a="${as#*.}"
    yq -e "(.gov.voters // [])[] | select(.site == \"$s\" and .account == \"$a\")" "$(inv_network_file)" >/dev/null 2>&1 \
      || die "$as is not listed in network.yaml gov.voters"
    title="$(lcd_get "/cosmos/gov/v1/proposals/$id" | jq -r '.proposal.title')"
    info "proposal #$id: $title"
    exec "$DEVOPS_ROOT/tools/chain/tx.sh" "$s" "$a" ${bc[@]+"${bc[@]}"} --note "gov vote #$id $opt ($title)" -- gov vote -- "$id" "$opt" ;;
  *) usage_die "usage: devops gov list|show <id>|verify [id]|vote ..." ;;
esac
