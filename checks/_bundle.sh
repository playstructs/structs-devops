# shellcheck shell=bash
# Checks that run a synced host tool (patch manifest, app.toml overrides).
# A check never pushes the bundle (that is tier 1); it reports a stale
# bundle instead and tells the operator to sync.
. "$DEVOPS_ROOT/lib/bundle.sh"

# bundle_current_or_warn SITE HOST -> returns 0 when the host has this exact bundle
bundle_current_or_warn() {
  local site="$1" host="$2" st want have
  st="$(bundle_stage "$site")"; want="$(cat "$st/VERSION")"; rm -rf "$st"
  have="$(bundle_remote_version "$site" "$host")"
  [ "$want" = "$have" ] && return 0
  check_warn "host bundle on $host is ${have:-absent} (hub has $want); run: devops host sync $site   (tier 1), then devops check $CHECK_ID $site"
}
