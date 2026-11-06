#!/usr/bin/env bash
# gov-pending (network): proposals in voting period and which inventory voters
# (network.yaml gov.voters) have not voted. Never votes: it only reminds.
. "$DEVOPS_ROOT/checks/_lib.sh"
need curl jq

props="$(gov_voting_proposals 2>/dev/null)" || check_unknown "LCD not answering"
[ -n "$props" ] || check_ok "no proposals in voting period"
count=0
while IFS="$(printf '\t')" read -r id title end typ; do
  [ -n "$id" ] || continue
  count=$((count + 1))
  left_s="$(iso_age_seconds "$end" || echo 0)"; left_h=$(( -left_s / 3600 ))
  missing=""
  while IFS="$(printf '\t')" read -r s a; do
    [ -n "$s" ] || continue
    addr="$(inv_q "$s" ".onchain.accounts.\"$a\".address")"
    v="$(gov_vote_of "$id" "$addr")"
    if [ -n "$v" ]; then detail "#$id $s.$a voted ${v#VOTE_OPTION_}"; else missing="$missing $s.$a"; fi
  done <<EOF
$(yq -r '(.gov.voters // [])[] | .site + "\t" + .account' "$(inv_network_file)")
EOF
  if [ -n "$missing" ]; then
    lvl=1; [ "$left_h" -lt 24 ] && lvl=2
    bump "$lvl" "#$id \"$title\" ($typ) ends in ${left_h}h; not voted:$missing (devops gov show $id; devops gov vote $id <option> --as <site>.<account>)"
  else
    detail "ok: #$id \"$title\" all inventory voters voted (ends in ${left_h}h)"
  fi
done <<EOF
$props
EOF
check_finish "$count proposal(s) in voting; all inventory voters voted"
