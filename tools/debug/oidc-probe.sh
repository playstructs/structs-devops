#!/usr/bin/env bash
# devops debug oidc-probe <site>     [0]
#   Webapp <-> MAS OIDC wiring without printing secrets: env keys set or empty,
#   client id/secret match between the webapp and structs-tel, hex secret,
#   discovery/JWKS/MAS/Matrix HTTP codes, and a token-endpoint client-auth probe
#   (400 invalid_grant = healthy; 401 = secret mismatch or base64-encoded secret).
set -euo pipefail
. "$DEVOPS_ROOT/tools/debug/_lib.sh"
need yq

site="${1:-}"
need_site "$site" "usage: devops debug oidc-probe <site>"
[ -n "$(inv_q "$site" '.host_env.OIDC_ISSUER')" ] || die "$site has no host_env.OIDC_ISSUER (no webapp OIDC here)"
host="$(service_host "$site" structs-webapp)"
[ -n "$host" ] || host="$(inv_primary_host "$site")"

out="$(debug_out "oidc-$site").txt"
{
  echo "# devops debug oidc-probe $site ($(iso_now), host $host)"
  host_bundle "$site" "$host" "$(debug_preamble "$site")" "$DEBUG_HOST/oidc-probe.sh"
} 2>&1 | tee "$out"
grep -q 'token_probe=.*PASS' "$out" || warn "OIDC not healthy: see structs-debug-http (OIDC and MAS) and devops webapp $site env-restore / oidc-from-tel"
note "saved: ${out#"$DEVOPS_ROOT"/}"
