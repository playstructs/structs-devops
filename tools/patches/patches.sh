#!/usr/bin/env bash
# devops patches <site> list|check           [0]
# devops patches <site> apply [--only ID]    [1] backups on the host
#                       apply --restart      [2] then run patches.after_apply
set -euo pipefail
. "$DEVOPS_ROOT/lib/common.sh"
. "$DEVOPS_ROOT/lib/inventory.sh"
. "$DEVOPS_ROOT/lib/ssh.sh"
. "$DEVOPS_ROOT/lib/gate.sh"
. "$DEVOPS_ROOT/lib/bundle.sh"
need yq

site="${1:-}"; sub="${2:-check}"
[ -n "$site" ] || usage_die "usage: devops patches <site> list|check|apply [--only ID] [--restart]"
inv_site_file "$site" >/dev/null
[ -f "$(inv_site_dir "$site")/patches/manifest.tsv" ] || die "site $site has no patches/manifest.tsv"
shift 2 2>/dev/null || shift $#
only=() restart=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only) only=(--only "$2"); shift 2 ;;
    --restart) restart=1; shift ;;
    *) usage_die "unknown option $1" ;;
  esac
done
host="$(site_stack_host "$site" guild-web)"
gate_site "$site"; GATE_HOST="$host"

case "$sub" in
  list|check)
    bundle_ensure "$site" "$host"
    bundle_run "$site" "$host" apply-patches.sh "--$sub" ${only[@]+"${only[@]}"} ;;
  apply)
    bundle_ensure "$site" "$host"
    if [ -n "${DEVOPS_DRY_RUN:-}" ]; then
      note "dry-run: showing current state; apply would fix DRIFT rows and run pre_helpers ($(inv_q "$site" '(.patches.pre_helpers // []) | join(", ")'))"
      bundle_run "$site" "$host" apply-patches.sh --check ${only[@]+"${only[@]}"} || true
      exit 0
    fi
    audit "TIER1 patches apply site=$site host=$host"
    rc=0
    bundle_run "$site" "$host" apply-patches.sh --apply ${only[@]+"${only[@]}"} || rc=$?
    [ "$rc" -eq 0 ] || die "patch apply reported failures (backups are next to each changed file)"
    after="$(inv_q "$site" '.patches.after_apply')"
    if [ -n "$restart" ] && [ -n "$after" ]; then
      groot="$(inv_q "$site" '.host_env.GUILD_ROOT')"
      cmd="cd $(printf '%q' "$groot") && $after"
      GATE_EFFECT="Recreates/restarts the containers named in patches.after_apply; brief webapp blip."
      GATE_ROLLBACK="Restore the .bak.<stamp> files printed above, then re-run the same command."
      GATE_VERIFY="devops check endpoints $site && devops patches $site check"
      gate 2 "Apply patched config on $site" "$cmd"
      host_run "$site" "$host" "$cmd"
      ok "after_apply done; verify with: devops check endpoints $site"
    elif [ -n "$after" ]; then
      note "files patched. To load them (tier 2): devops patches $site apply --restart"
    fi ;;
  *) usage_die "usage: devops patches <site> list|check|apply" ;;
esac
