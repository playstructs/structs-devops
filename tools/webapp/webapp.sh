#!/usr/bin/env bash
# devops webapp <site> status                       [0] branch, commit, image, OIDC flags (no values)
# devops webapp <site> env-restore KEY...           [1] refill keys a pull blanked, from the newest .env backup
# devops webapp <site> ga4                          [1] insert the site's GA4 tag into the current template
# devops webapp <site> oidc-from-tel                [2] restore OIDC from structs-tel, clear cache, seed client
# devops webapp <site> structs-app-update [--no-pull|--status]   [2]/[0]
set -euo pipefail
. "$DEVOPS_ROOT/lib/common.sh"
. "$DEVOPS_ROOT/lib/inventory.sh"
. "$DEVOPS_ROOT/lib/ssh.sh"
. "$DEVOPS_ROOT/lib/gate.sh"
. "$DEVOPS_ROOT/lib/bundle.sh"
need yq

site="${1:-}"; sub="${2:-status}"
[ -n "$site" ] || usage_die "usage: devops webapp <site> status|env-restore|ga4|oidc-from-tel|structs-app-update"
inv_site_file "$site" >/dev/null
shift 2 2>/dev/null || shift $#
host="$(site_stack_host "$site" guild-web)"
gate_site "$site"; GATE_HOST="$host"
src="$(inv_q "$site" '.host_env.WEBAPP_SRC')"
envf="$(inv_q "$site" '.host_env.WEBAPP_ENV')"

case "$sub" in
  status)
    host_bundle "$site" "$host" "WEBAPP_SRC=$(printf '%q' "$src")
WEBAPP_ENV=$(printf '%q' "$envf")" "$DEVOPS_ROOT/tools/host/webapp-status.sh"
    want="$(inv_q "$site" '(.sources // [])[] | select(.repo == "structs-webapp") | .ref + "@" + (.commit // "")')"
    [ -n "$want" ] && echo "inventory pin=$want" ;;
  env-restore)
    [ $# -gt 0 ] || set -- MATRIX_SIGNIN_CLIENT_ID OIDC_ENCRYPTION_KEY
    bundle_ensure "$site" "$host"
    if [ -n "${DEVOPS_DRY_RUN:-}" ]; then echo "dry-run: env-restore $* on $envf from its newest .bak.*"; exit 0; fi
    audit "TIER1 webapp env-restore site=$site keys=$*"
    bundle_run "$site" "$host" env-restore.sh "$@" ;;
  ga4)
    bundle_ensure "$site" "$host"
    [ -n "${DEVOPS_DRY_RUN:-}" ] && { echo "dry-run: insert GA4 $(inv_q "$site" '.patches.ga4') into $src/templates/base.html.twig"; exit 0; }
    audit "TIER1 webapp ga4 site=$site"
    bundle_run "$site" "$host" insert-ga4.sh ;;
  oidc-from-tel)
    bundle_ensure "$site" "$host"
    GATE_EFFECT="Writes OIDC_* (and chat keys) into $envf from structs-tel/.env, clears the Symfony prod cache, seeds the MAS client. Logins blip during cache clear."
    GATE_ROLLBACK="Restore the newest $envf.bak.* and run cache:clear."
    GATE_VERIFY="devops debug oidc-probe $site"
    [ -n "${DEVOPS_DRY_RUN:-}" ] && { echo "dry-run: oidc-from-tel on $site:$host"; exit 0; }
    gate 2 "Restore webapp OIDC from structs-tel on $site" "SITE_ID=$site bash <tools_path>/host/oidc-from-tel.sh"
    bundle_run "$site" "$host" oidc-from-tel.sh ;;
  structs-app-update)
    appdir="$(inv_q "$site" '.host_env.STRUCTS_APP_DIR')"
    [ -n "$appdir" ] || die "$site has no host_env.STRUCTS_APP_DIR; structs-app-update is only for sites that run structs.app"
    bundle_ensure "$site" "$host"
    if [ "${1:-}" = "--status" ]; then bundle_run "$site" "$host" structs-app-update.sh --status; exit $?; fi
    GATE_EFFECT="Pulls structs-app and structs-desktop, syncs assets, rebuilds the image, recreates the structs.app container (a few seconds of 502)."
    GATE_ROLLBACK="git -C $appdir checkout <previous sha> and re-run with --no-pull."
    GATE_VERIFY="curl -s $(inv_q "$site" '.host_env.STRUCTS_APP_PUBLIC_URL'); devops check endpoints $site"
    [ -n "${DEVOPS_DRY_RUN:-}" ] && { echo "dry-run: structs-app-update $* on $site:$host"; exit 0; }
    gate 2 "Update structs.app on $site" "SITE_ID=$site bash <tools_path>/host/structs-app-update.sh $*"
    bundle_run "$site" "$host" structs-app-update.sh "$@" ;;
  *) usage_die "usage: devops webapp <site> status|env-restore|ga4|oidc-from-tel|structs-app-update" ;;
esac
