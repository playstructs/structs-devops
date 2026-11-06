#!/usr/bin/env bash
# devops debug grass-tap <site> [--seconds 15] [--subject '>'] [--pull]     [0]
#   Confirms GRASS events reach NATS: subscribes as the anonymous read-only
#   websocket user for a few seconds and counts messages per subject. Also
#   reports GRASS's dropped-notification and LISTEN log counts for the last hour.
#   The subscriber runs in a throwaway natsio/nats-box container; if the image
#   is not on the host, only the log counts run unless --pull is given.
set -euo pipefail
. "$DEVOPS_ROOT/tools/debug/_lib.sh"
need yq

site="${1:-}"
need_site "$site" "usage: devops debug grass-tap <site> [--seconds N] [--subject S] [--pull]"
shift
secs=15 subj='>' pull=0
while [ $# -gt 0 ]; do
  case "$1" in
    --seconds) secs="${2:?}"; shift 2 ;;
    --subject) subj="${2:?}"; shift 2 ;;
    --pull) pull=1; shift ;;
    *) usage_die "unknown option $1" ;;
  esac
done
case "$secs" in *[!0-9]*|"") usage_die "--seconds must be a number" ;; esac
[ "$secs" -le 120 ] || usage_die "--seconds is capped at 120"
host="$(service_host "$site" structs-nats)"
[ -n "$host" ] || die "$site has no structs-nats in the inventory"

out="$(debug_out "grass-tap-$site").txt"
pre="$(debug_preamble "$site")
export TAP_SECONDS=$(printf '%q' "$secs") TAP_SUBJECT=$(printf '%q' "$subj") TAP_PULL=$pull"
{
  echo "# devops debug grass-tap $site ($(iso_now))"
  host_bundle "$site" "$host" "$pre" "$DEBUG_HOST/grass-tap.sh"
} 2>&1 | tee "$out"
if grep -q '^subscriber=skipped' "$out"; then
  warn "natsio/nats-box is not on $host; re-run with --pull to fetch it (one image pull on the host)"
elif grep -q '^messages=0 ' "$out"; then
  warn "no events in ${secs}s: check structs-grass (LISTEN loop, pg_notify), NATS grass_pub auth, and that blocks are being indexed (devops check sync-lag $site)"
fi
note "saved: ${out#"$DEVOPS_ROOT"/}"
