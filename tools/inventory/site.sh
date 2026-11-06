#!/usr/bin/env bash
# devops site list | show <site> | new <id> --kind guild|public-node|local [--fqdn F] [--ip I] [--ssh T]
set -euo pipefail
. "$DEVOPS_ROOT/lib/common.sh"
. "$DEVOPS_ROOT/lib/inventory.sh"
need yq

sub="${1:-list}"; [ $# -gt 0 ] && shift

case "$sub" in
  list) exec "$DEVOPS_ROOT/tools/inventory/inventory.sh" show ;;
  show)
    [ -n "${1:-}" ] || usage_die "usage: devops site show <site>"
    d="$(inv_site_dir "$1")"
    inv_site_file "$1" >/dev/null
    [ -f "$d/README.md" ] && cat "$d/README.md" || yq '.' "$d/site.yaml"
    ;;
  new)
    id="${1:-}"; [ -n "$id" ] || usage_die "usage: devops site new <id> --kind guild|public-node|local [--fqdn F] [--ip I] [--ssh T]"
    shift
    kind="guild"; fqdn="example.com"; ip="0.0.0.0"; target=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --kind) kind="$2"; shift 2 ;;
        --fqdn) fqdn="$2"; shift 2 ;;
        --ip) ip="$2"; shift 2 ;;
        --ssh) target="$2"; shift 2 ;;
        *) usage_die "unknown option $1" ;;
      esac
    done
    case "$id" in *[!a-z0-9-]*|"") usage_die "site id must be lowercase letters, digits, dashes" ;; esac
    tpl="$DEVOPS_ROOT/templates/site/$kind"
    [ -d "$tpl" ] || usage_die "unknown kind $kind (guild, public-node, local)"
    dst="$DEVOPS_INVENTORY/sites/$id"
    [ -e "$dst" ] && die "site $id already exists at $dst"
    [ -n "$target" ] || target="root@$fqdn"
    hostid="$(printf '%s' "$id" | cut -c1-12)"
    mkdir -p "$dst/runbooks"
    cp -R "$DEVOPS_ROOT/templates/site/_common/." "$dst/"
    cp -R "$tpl/." "$dst/"
    find "$dst" -type f \( -name '*.yaml' -o -name '*.md' -o -name '*.tsv' \) | while IFS= read -r f; do
      python3 - "$f" "$id" "$kind" "$fqdn" "$ip" "$target" "$hostid" "$(today)" <<'PY'
import sys
p, sid, kind, fqdn, ip, ssh, hid, day = sys.argv[1:]
t = open(p).read()
for k, v in {"__SITE_ID__": sid, "__KIND__": kind, "__FQDN__": fqdn, "__IPV4__": ip,
             "__SSH__": ssh, "__HOST_ID__": hid, "__TODAY__": day}.items():
    t = t.replace(k, v)
open(p, "w").write(t)
PY
    done
    ok "created $dst from templates/site/$kind"
    echo "Next:"
    echo "  1. devops inventory discover $id      # see what is really running"
    echo "  2. edit $dst/site.yaml (stacks, secrets pointers, endpoints, onchain)"
    echo "  3. devops inventory validate && devops inventory render"
    ;;
  *) usage_die "usage: devops site list | show <site> | new <id> --kind ..." ;;
esac
