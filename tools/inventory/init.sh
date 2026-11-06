#!/usr/bin/env bash
# devops init [--example] [--no-git] [DIR]
#   Create your inventory repo at DIR (default: $DEVOPS_INVENTORY) from
#   templates/inventory, or from the fictional examples/inventory with
#   --example. Runs `git init` there (no commit, no remote) unless --no-git.
#   Local files only.
set -euo pipefail
. "$DEVOPS_ROOT/lib/common.sh"

src="$DEVOPS_ROOT/templates/inventory" dst="" gitinit=1
while [ $# -gt 0 ]; do
  case "$1" in
    --example) src="$DEVOPS_ROOT/examples/inventory"; shift ;;
    --no-git) gitinit=""; shift ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) usage_die "usage: devops init [--example] [--no-git] [DIR]" ;;
    *) dst="$1"; shift ;;
  esac
done
dst="$(_abs "${dst:-$DEVOPS_INVENTORY}")"
[ -f "$dst/network.yaml" ] && die "$dst already has a network.yaml; nothing to do"
[ -d "$src" ] || die "missing $src"

mkdir -p "$dst"
cp -R "$src/." "$dst/"
d="$(today)"
find "$dst" -type f \( -name '*.yaml' -o -name '*.md' \) | while IFS= read -r f; do perl -pi -e "s/__TODAY__/$d/g" "$f"; done
ok "created $dst from ${src#"$DEVOPS_ROOT"/}"
if [ -n "$gitinit" ] && have git && [ ! -e "$dst/.git" ]; then
  git -C "$dst" init -q && ok "git init $dst (no commit, no remote)"
  DEVOPS_INVENTORY="$dst" "$DEVOPS_ROOT/bin/devops" secrets hook install inventory || true
fi

if [ "$dst" != "$DEVOPS_INVENTORY" ]; then
  note "point the framework at it: DEVOPS_INVENTORY=$dst in .devops.env"
fi
DEVOPS_INVENTORY="$dst" DEVOPS_REPORTS="$dst/reports" python3 "$DEVOPS_ROOT/tools/inventory/validate.py" | tail -1
DEVOPS_INVENTORY="$dst" python3 "$DEVOPS_ROOT/tools/inventory/render.py" >/dev/null
echo "Next:"
echo "  1. devops site new <id> --kind guild|public-node|local --fqdn <host> --ssh root@<host>"
echo "  2. devops inventory discover <id>, then fill in site.yaml (skill: structs-inventory)"
echo "  3. devops inventory validate && devops inventory render"
