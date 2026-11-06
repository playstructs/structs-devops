#!/usr/bin/env bash
# Every 30 min: chain upgrade lifecycle.
#   voting     a MsgSoftwareUpgrade proposal is open      -> gov-watch reminds
#   preparing  plan on chain, ETA > 2 h                    -> milestones 48/24/6 h with staging status
#   window     ETA <= 2 h                                  -> start monitors (human, tier 1)
#   post       plan gone and applied                       -> system checks + inventory bump reminder
# Never stages binaries, recreates containers or installs monitors itself.
. "$DEVOPS_ROOT/crons/jobs/_job.sh"
job_begin upgrade-watch
sd="$(mkstate upgrade)"
rc=0

plan="$(chain_upgrade_plan 2>/dev/null || true)"
if [ -n "$plan" ]; then
  name="${plan% *}"; ph="${plan#* }"
  printf '%s %s\n' "$name" "$ph" > "$sd/current"
  eta="$(eta_hours "$ph")"
  job_log "plan $name at $ph, ETA ~${eta}h"
  out="$(run_group any network "upgrade-plan")" || rc=$?
  for m in 48 24 6 2 0.5; do
    python3 -c "import sys; sys.exit(0 if float('$eta') <= $m else 1)" || continue
    [ -f "$sd/$name.m$m" ] && continue
    touch "$sd/$name.m$m"
    case "$m" in
      2|0.5)
        sites="$(inv_structsd_nodes | cut -f1 | sort -u | tr '\n' ' ')"
        notify WARN "upgrade $name in ~${eta}h (window)" "Start a monitor per node site (tier 1): $(for s in $sites; do printf 'devops upgrade monitor install %s; ' "$s"; done)
$(printf '%s' "$out" | head -1)" ;;
      *)
        notify INFO "upgrade $name in ~${eta}h" "$(printf '%s\n' "$out" | head -12)" ;;
    esac
    break
  done
elif [ -f "$sd/current" ]; then
  read -r name ph < "$sd/current"
  h="$(chain_height 2>/dev/null || echo 0)"
  applied="$(lcd_get "/cosmos/upgrade/v1beta1/applied_plan/$name" 2>/dev/null | jq -r '.height // "0"' 2>/dev/null)"
  if [ "${applied:-0}" != "0" ] && [ "$h" -gt "$ph" ]; then
    job_log "upgrade $name applied at $applied; running post-upgrade system checks"
    out="$(run_group any all "block-progress,height-agreement,node-health,app-toml,containers,sync-lag,tsa-queue")" || rc=$?
    pub="$(inv_net '.public_node_site')"
    notify "$( [ "$rc" -eq 0 ] && echo OK || echo WARN)" "upgrade $name applied at $applied" \
"Post-upgrade checks: $(printf '%s\n' "$out" | tail -1)
Next: update binary (version $name, since_height $applied, cosmovisor_current upgrades/$name, git_commit) in networks/<preset>.yaml or as an override in your network.yaml, and images.structsd there, then devops inventory render.${pub:+ Public node: devops check app-toml $pub.}"
    [ "$rc" -eq 0 ] && mv "$sd/current" "$sd/$name.done"
  else
    job_log "plan $name no longer on chain and not applied (cancelled?)"
    notify WARN "upgrade plan $name disappeared" "No current plan and applied_plan($name) is ${applied:-0}. Cancelled by governance? devops gov list"
    mv "$sd/current" "$sd/$name.gone"
  fi
else
  job_log "no upgrade plan"
fi
job_end
exit "$rc"
