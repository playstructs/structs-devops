# shellcheck shell=bash
# Sourced by host-side scripts that run from the synced bundle
# (`devops host sync <site>` -> <tools_path>, default /opt/structs-devops):
#
#   <tools_path>/host/*.sh                    these scripts
#   <tools_path>/shared/patches/{overlay,snippets}/
#   <tools_path>/sites/<site>/patches/        manifest.tsv, overlay/, snippets/
#   <tools_path>/sites/<site>/site.env        generated from site.yaml (host_env + containers)
#   <tools_path>/sites/<site>/*.overrides     e.g. app-toml.overrides
#   <tools_path>/SITE, VERSION
set -euo pipefail

TOOLS_ROOT="${TOOLS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SITE_ID="${SITE_ID:-$(cat "$TOOLS_ROOT/SITE" 2>/dev/null || true)}"
[ -n "$SITE_ID" ] || { echo "SITE_ID not set and $TOOLS_ROOT/SITE missing; run devops host sync <site>" >&2; exit 2; }
SITE_DIR="$TOOLS_ROOT/sites/$SITE_ID"
[ -f "$SITE_DIR/site.env" ] || { echo "missing $SITE_DIR/site.env; run devops host sync $SITE_ID" >&2; exit 2; }
# shellcheck disable=SC1091
. "$SITE_DIR/site.env"
SHARED_PATCHES="$TOOLS_ROOT/shared/patches"
SITE_PATCHES="$SITE_DIR/patches"

log() { printf '%s\n' "$*" >&2; }

# patch_src overlay|snippets REL -> source file. "@shared/x" is always the
# shared copy; a bare path prefers the site copy and falls back to shared.
patch_src() {
  local kind="$1" rel="$2"
  case "$rel" in
    @shared/*) printf '%s/%s/%s' "$SHARED_PATCHES" "$kind" "${rel#@shared/}" ;;
    *)
      if [ -f "$SITE_PATCHES/$kind/$rel" ]; then printf '%s/%s/%s' "$SITE_PATCHES" "$kind" "$rel"
      else printf '%s/%s/%s' "$SHARED_PATCHES" "$kind" "$rel"; fi ;;
  esac
}

backup_file() {
  local f="$1" b
  b="${f}.bak.$(date +%Y%m%dT%H%M%S)"
  cp -a "$f" "$b"
  echo "  backup -> $b"
}

# install_file SRC DST: keeps owner and mode of an existing DST (writes in
# place); a new DST takes the owner of its directory.
install_file() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [ -f "$dst" ]; then
    cat "$src" > "$dst"
  else
    cp "$src" "$dst"
    chown --reference="$(dirname "$dst")" "$dst" 2>/dev/null || true
  fi
}

webapp_container() {
  local c="${STRUCTS_WEBAPP_CONTAINER:-}"
  if [ -z "$c" ] || ! docker inspect "$c" >/dev/null 2>&1; then
    c="$(docker ps --format '{{.Names}}' | grep structs-webapp | grep -v cache | head -n1 || true)"
  fi
  [ -n "$c" ] || { echo "structs-webapp container not running" >&2; return 1; }
  printf '%s' "$c"
}
