#!/usr/bin/env bash
# devops secrets list [site]           [0] pointers, criticality, backup, rotation (no values)
# devops secrets audit [site|all]      [0] resolve every pointer on its host (test/stat/grep -c only)
# devops secrets scan [--staged [--repo D]] [path...]  [0] look for secret material in the workspace and inventory
# devops secrets hook install|remove [framework|inventory|all]   [1] pre-commit hook (scan --staged); default all
set -euo pipefail
. "$DEVOPS_ROOT/lib/common.sh"
. "$DEVOPS_ROOT/lib/inventory.sh"
. "$DEVOPS_ROOT/lib/gate.sh"
need yq

sub="${1:-list}"; [ $# -gt 0 ] && shift
case "$sub" in
  list)
    sites="${1:-$(inv_sites)}"
    printf '%-16s %-34s %-9s %-11s %s\n' SITE SECRET CRIT BACKUP POINTER
    for s in $sites; do
      yq -r '(.secrets // {}) | to_entries[] | [.key, (.value.criticality // "?"), (.value.backup // "?"), .value.ref] | @tsv' "$(inv_site_file "$s")" |
      while IFS="$(printf '\t')" read -r n c b r; do
        printf '%-16s %-34s %-9s %-11s %s\n' "$s" "$n" "$c" "$(printf '%s' "$b" | cut -c1-11)" "$r"
      done
    done
    note "values never leave their hosts; docs/secrets.md" ;;
  audit)
    target="${1:-all}"
    rc=0
    if [ "$target" = all ]; then
      for s in $(inv_sites); do
        [ "$(inv_q "$s" '.checks.in_all')" = "false" ] && continue
        "$DEVOPS_ROOT/checks/run-one.sh" secrets-audit "$s" || rc=$?
      done
    else
      "$DEVOPS_ROOT/checks/run-one.sh" secrets-audit "$target" || rc=$?
    fi
    exit "$rc" ;;
  scan)
    exec python3 "$DEVOPS_ROOT/tools/secrets/scan.py" "$@" ;;
  hook)
    act="${1:-install}" which="${2:-all}"
    case "$act" in install|remove) ;; *) usage_die "usage: devops secrets hook install|remove [framework|inventory|all]" ;; esac
    case "$which" in
      framework) repos=("$DEVOPS_ROOT") ;;
      inventory) repos=("$DEVOPS_INVENTORY") ;;
      all) repos=("$DEVOPS_ROOT" "$DEVOPS_INVENTORY") ;;
      *) usage_die "usage: devops secrets hook install|remove [framework|inventory|all]" ;;
    esac
    done_any="" rc=0
    for repo in "${repos[@]}"; do
      # Only a repo rooted at this directory; never a hook in an enclosing repo.
      top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || continue
      [ "$(cd "$top" && pwd -P)" = "$(cd "$repo" && pwd -P)" ] || continue
      done_any=1
      hook="$(git -C "$repo" rev-parse --git-path hooks)/pre-commit"
      case "$hook" in /*) ;; *) hook="$top/$hook" ;; esac
      if [ "$act" = remove ]; then
        if [ -f "$hook" ] && grep -q 'structs-devops secrets scan' "$hook"; then rm -f "$hook"; audit "TIER1 secrets hook remove $hook"; ok "removed $hook"
        else note "no structs-devops hook at $hook"; fi
        continue
      fi
      if [ -f "$hook" ] && ! grep -q 'structs-devops secrets scan' "$hook"; then
        err "$hook exists and is not ours; add this line to it: python3 \"$DEVOPS_ROOT/tools/secrets/scan.py\" --staged --repo \"$top\""
        rc=1; continue
      fi
      [ -n "${DEVOPS_DRY_RUN:-}" ] && { echo "would write $hook"; continue; }
      if [ "$repo" = "$DEVOPS_ROOT" ]; then
        extra="\"$DEVOPS_ROOT/bin/devops\" agents sync --check >/dev/null 2>&1 || {
  echo \"structs-devops: generated files are stale; run: devops agents sync\" >&2
  exit 1
}"
      else
        extra="DEVOPS_INVENTORY=\"$top\" \"$DEVOPS_ROOT/bin/devops\" inventory validate >/dev/null 2>&1 || {
  echo \"structs-devops: inventory has errors; run: devops inventory validate\" >&2
  exit 1
}"
      fi
      mkdir -p "$(dirname "$hook")"
      cat > "$hook" <<EOF
#!/bin/sh
# structs-devops secrets scan (installed by: devops secrets hook install)
python3 "$DEVOPS_ROOT/tools/secrets/scan.py" --staged --repo "$top" || exit 1
$extra
EOF
      chmod +x "$hook"
      audit "TIER1 secrets hook install $hook"
      ok "pre-commit hook installed: $hook"
    done
    [ -n "$done_any" ] || die "no git repository rooted at ${repos[*]} (git init first, or run devops secrets scan by hand)"
    exit "$rc" ;;
  *) usage_die "usage: devops secrets list|audit|scan|hook" ;;
esac
