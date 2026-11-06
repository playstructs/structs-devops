#!/usr/bin/env bash
# devops host sync <site> [host]     [1] push the tools bundle to tools_path
# devops host status <site> [host]   [0] local vs host bundle version
# devops host files <site>           [0] list what the bundle contains
set -euo pipefail
. "$DEVOPS_ROOT/lib/common.sh"
. "$DEVOPS_ROOT/lib/inventory.sh"
. "$DEVOPS_ROOT/lib/ssh.sh"
. "$DEVOPS_ROOT/lib/gate.sh"
. "$DEVOPS_ROOT/lib/bundle.sh"
need yq

sub="${1:-}"; site="${2:-}"
[ -n "$sub" ] && [ -n "$site" ] || usage_die "usage: devops host sync|status|files <site> [host]"
inv_site_file "$site" >/dev/null
host="${3:-$(site_stack_host "$site")}"

case "$sub" in
  files)
    st="$(bundle_stage "$site")"
    (cd "$st" && find . -type f | LC_ALL=C sort)
    echo "VERSION $(cat "$st/VERSION")"
    rm -rf "$st" ;;
  status)
    st="$(bundle_stage "$site")"
    want="$(cat "$st/VERSION")"; rm -rf "$st"
    have="$(bundle_remote_version "$site" "$host")"
    echo "local  $want"
    echo "host   ${have:-absent} ($site:$host $(bundle_tools_path "$site" "$host"))"
    [ "$want" = "$have" ] ;;
  sync)
    st="$(bundle_stage "$site")"
    want="$(cat "$st/VERSION")"
    if [ -n "${DEVOPS_DRY_RUN:-}" ]; then
      echo "dry-run: would push bundle $want to $site:$host:$(bundle_tools_path "$site" "$host")"
      (cd "$st" && find . -type f | LC_ALL=C sort | sed 's/^/  /')
      rm -rf "$st"; exit 0
    fi
    have="$(bundle_remote_version "$site" "$host")"
    got="$(bundle_push "$site" "$host" "$st")"
    rm -rf "$st"
    audit "BUNDLE site=$site host=$host version=$want previous=${have:-none}"
    [ "$got" = "$want" ] || die "push reported VERSION '$got', expected $want"
    ok "bundle $want on $site:$host (was ${have:-absent})" ;;
  *) usage_die "usage: devops host sync|status|files <site> [host]" ;;
esac
