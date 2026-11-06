#!/usr/bin/env bash
# Every 6 h: announce new proposals once, then remind about inventory voters
# who have not voted. Votes are always cast by a human (devops gov vote).
. "$DEVOPS_ROOT/crons/jobs/_job.sh"
job_begin gov-watch

seen_f="$(mkstate gov)/seen"
touch "$seen_f"
for st in 1 2; do
  lbl="$([ "$st" = 1 ] && echo "deposit period" || echo "voting period")"
  lcd_get "/cosmos/gov/v1/proposals?proposal_status=$st&pagination.limit=100" 2>/dev/null | jq -r '.proposals[]? |
    [.id, (.title // "untitled"), (.voting_end_time // .deposit_end_time // ""),
     ((.messages[0]["@type"] // "text") | split(".") | last)] | @tsv' 2>/dev/null |
  while IFS="$(printf '\t')" read -r id title end typ; do
    job_log "- #$id $title ($typ, $lbl, ends $end)"
    if ! grep -qx "$id:$st" "$seen_f"; then
      echo "$id:$st" >> "$seen_f"
      extra=""; [ "$typ" = "MsgSoftwareUpgrade" ] && extra=" Chain upgrade: devops gov show $id; the upgrade-watch job tracks staging."
      notify INFO "proposal #$id in $lbl" "$title ($typ), ends $end.$extra"
    fi
  done
done

rc=0
out="$(run_group any network "gov-pending")" || rc=$?
if [ "$rc" -ne 0 ]; then
  # Deliberate reminder on every run while a vote is outstanding.
  notify "$(printf '%s' "$out" | head -1 | cut -d' ' -f1)" "pending votes" "$(printf '%s\n' "$out" | head -1 | sed 's/^[A-Z]* gov-pending network: //')"
fi
job_end
exit "$rc"
