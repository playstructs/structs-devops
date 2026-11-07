#!/usr/bin/env bash
# devops deploy <site> list                         [0] procedures declared in site.yaml
# devops deploy <site> <procedure> --dry-run        [0] numbered plan with effective tiers
# devops deploy <site> <procedure> [--from-step N]  [max step tier] run it
#
# Procedures run straight through. Only a step that sends an on-chain
# transaction (tier 3) stops for approval; resume with --from-step.
# A step's effective tier is max(declared, classify.py of its command).
# The plan, every step's output and the result go to a run report.
# Steps:
#   tool: "<devops args>"            a devops command (it enforces its own tier)
#   ssh: "<cmd>"  [stack: <id>]      on the stack's host, cd'd into the stack path
#   local: "<cmd>"                   on the hub, from the workspace root
#   backup: "<remote path>"          cp -a <path> <path>.bak.devops-<stamp> on the host (tier 1)
#   check: <check-id>                stop on CRIT/UNKNOWN, continue on WARN
#   confirm: "<reminder>"            asked when a person runs it at a terminal; otherwise
#                                    printed as a reminder and the procedure continues
set -uo pipefail
. "$DEVOPS_ROOT/lib/common.sh"
. "$DEVOPS_ROOT/lib/inventory.sh"
. "$DEVOPS_ROOT/lib/ssh.sh"
. "$DEVOPS_ROOT/lib/gate.sh"
need yq jq python3

site="${1:-}"; proc="${2:-}"
[ -n "$site" ] || usage_die "usage: devops deploy <site> list | <procedure> [--dry-run] [--from-step N]"
f="$(inv_site_file "$site")"
shift; [ $# -gt 0 ] && shift
from=1
while [ $# -gt 0 ]; do
  case "$1" in
    --from-step) from="$2"; shift 2 ;;
    *) usage_die "unknown argument $1" ;;
  esac
done

if [ -z "$proc" ] || [ "$proc" = list ]; then
  yq -r '(.procedures // {}) | to_entries[] | .key + "\t" + (.value.description // "")' "$f" |
    while IFS="$(printf '\t')" read -r k d; do printf '%-22s %s\n' "$k" "$d"; done
  exit 0
fi
P="$(P="$proc" yq -o=json -I=0 '.procedures[strenv(P)] // null' "$f")"
[ "$P" != "null" ] || die "site $site has no procedure '$proc' (devops deploy $site list)"
n="$(printf '%s' "$P" | jq '.steps | length')"
[ "$from" -ge 1 ] && [ "$from" -le "$n" ] || usage_die "--from-step must be 1..$n"

step() { printf '%s' "$P" | jq -c ".steps[$(( $1 - 1 ))]"; }
sf() { printf '%s' "$1" | jq -r ".$2 // empty"; }
stype() {
  local s="$1" t
  for t in tool ssh local backup check confirm; do
    [ -n "$(sf "$s" "$t")" ] && { echo "$t"; return; }
  done
  echo unknown
}
classify() { python3 "$DEVOPS_ROOT/tools/agents/classify.py" -- "$1" | cut -d' ' -f1; }
default_tier() { case "$1" in check|confirm) echo 0 ;; tool|local|backup) echo 1 ;; *) echo 2 ;; esac; }
step_host() {
  local st; st="$(sf "$1" stack)"
  if [ -n "$st" ]; then inv_stack_host "$site" "$st"; else inv_primary_host "$site"; fi
}
step_cmd() {
  # step_cmd STEP [STAMP]: without STAMP (plan/approval text) backups show <stamp>
  local s="$1" ts="${2:-<stamp>}" t st path b
  t="$(stype "$s")"
  case "$t" in
    ssh)
      st="$(sf "$s" stack)"
      if [ -n "$st" ]; then
        path="$(inv_stack "$site" "$st" path)"
        printf 'cd %q && %s' "$path" "$(sf "$s" ssh)"
      else
        sf "$s" ssh
      fi ;;
    backup) b="$(sf "$s" backup)"; printf 'cp -a %q %q.bak.devops-%s' "$b" "$b" "$ts" ;;
    *) sf "$s" "$t" ;;
  esac
}
eff_tier() {
  local s="$1" t d c
  t="$(stype "$s")"; d="$(sf "$s" tier)"; d="${d:-$(default_tier "$t")}"
  case "$t" in
    ssh|local)
      c="$(classify "$(sf "$s" "$t")")"
      [ "$c" = "S" ] && { echo S; return; }
      [ "$c" -gt "$d" ] && d="$c" ;;
  esac
  echo "$d"
}

# Build the plan.
plan="procedure $proc on $site: $(printf '%s' "$P" | jq -r '.description // ""')"
max=0 confirms="" i="$from"
while [ "$i" -le "$n" ]; do
  s="$(step "$i")"; t="$(stype "$s")"; et="$(eff_tier "$s")"
  [ "$et" = "S" ] && die "step $i reads secret material ($(sf "$s" "$t")); procedures may not do that"
  [ "$t" = unknown ] && die "step $i has no known type: $s"
  [ "$et" -gt "$max" ] && max="$et"
  where=""; case "$t" in ssh|backup) where=" @$(step_host "$s")" ;; local) where=" @hub" ;; esac
  plan="$plan
  $i. [$t tier $et$where] $(step_cmd "$s")"
  [ "$t" = confirm ] && confirms="$confirms
  - $(sf "$s" confirm)"
  i=$((i + 1))
done
echo "$plan"
[ -n "$confirms" ] && printf 'Confirmations:%s\n' "$confirms"
[ -n "${DEVOPS_DRY_RUN:-}" ] && { note "dry run: nothing executed"; exit 0; }

gate_site "$site"
GATE_HOST="$(inv_primary_host "$site")"
ask_confirms=""; ! is_agent && has_tty && ask_confirms=1

report="$(run_dir)/deploy-$site-$proc-$(date +%H%M).md"
{ echo "# deploy $site $proc $(iso_now)"; echo; echo '```'; echo "$plan"; echo '```'; echo; } > "$report"
audit "DEPLOY start site=$site procedure=$proc steps=$from-$n max_tier=$max"

fail() {
  echo "FAILED at step $1: $2" | tee -a "$report" >&2
  echo "resume: devops deploy $site $proc --from-step $1    report: ${report#"$DEVOPS_ROOT"/}" >&2
  audit "DEPLOY failed site=$site procedure=$proc step=$1"
  exit 1
}

run_stamp="$(stamp)"
i="$from"
while [ "$i" -le "$n" ]; do
  s="$(step "$i")"; t="$(stype "$s")"; et="$(eff_tier "$s")"; cmd="$(step_cmd "$s" "$run_stamp")"
  printf '\n== step %s/%s [%s tier %s] %s\n' "$i" "$n" "$t" "$et" "$cmd" | tee -a "$report"
  rc=0
  case "$t" in
    confirm)
      if [ -z "$ask_confirms" ]; then echo "reminder: $(sf "$s" confirm)" | tee -a "$report"
      elif tty_confirm "$(sf "$s" confirm)"; then echo "confirmed on the terminal" >> "$report"
      else fail "$i" "not confirmed"; fi ;;
    tool)
      # shellcheck disable=SC2086
      out="$("$DEVOPS_ROOT/bin/devops" $cmd 2>&1)" || rc=$?
      printf '%s\n' "$out" | tee -a "$report"
      [ "$rc" -eq 10 ] && fail "$i" "this step sends a transaction and needs the user's approval; after they approve, resume from this step"
      [ "$rc" -eq 0 ] || fail "$i" "exit $rc" ;;
    ssh|backup)
      h="$(step_host "$s")"
      GATE_HOST="$h"; DEVOPS_RERUN="deploy $site $proc --from-step $i" gate "$et" "deploy step $i: $cmd" "$cmd"
      out="$(host_run "$site" "$h" "$cmd" 2>&1)" || rc=$?
      printf '%s\n' "$out" | tee -a "$report"
      [ "$rc" -eq 0 ] || fail "$i" "exit $rc on $h" ;;
    local)
      DEVOPS_RERUN="deploy $site $proc --from-step $i" gate "$et" "deploy step $i: $cmd" "$cmd"
      out="$(cd "$DEVOPS_ROOT" && bash -c "$cmd" 2>&1)" || rc=$?
      printf '%s\n' "$out" | tee -a "$report"
      [ "$rc" -eq 0 ] || fail "$i" "exit $rc" ;;
    check)
      out="$("$DEVOPS_ROOT/checks/run-one.sh" "$cmd" "$site" 2>&1)" || rc=$?
      printf '%s\n' "$out" | tee -a "$report"
      case "$rc" in 0) ;; 1) warn "check $cmd is WARN; continuing" ;; *) fail "$i" "check $cmd is $(printf '%s' "$out" | head -1 | cut -d' ' -f1)" ;; esac ;;
  esac
  i=$((i + 1))
done
audit "DEPLOY done site=$site procedure=$proc"
echo
ok "procedure $proc finished on $site (report: ${report#"$DEVOPS_ROOT"/})"
echo "Record it: inventory/sites/$site/CHANGELOG.md (and update site.yaml if versions or digests changed)"
