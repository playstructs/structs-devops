#!/usr/bin/env bash
# devops context
#   Print the operator context an agent reads at session start: the
#   inventory's AGENTS.md (sites, current state) and the latest journal entry.
set -euo pipefail
. "$DEVOPS_ROOT/lib/common.sh"

f="$DEVOPS_INVENTORY/AGENTS.md"
[ -f "$f" ] || die "no inventory at $DEVOPS_INVENTORY (devops init creates one, or set DEVOPS_INVENTORY in .devops.env)"
printf '<!-- inventory: %s -->\n' "$DEVOPS_INVENTORY"
cat "$f"
jf="$(find "$DEVOPS_REPORTS/journal" -maxdepth 1 -name '20*.md' 2>/dev/null | sort | tail -1)"
if [ -n "$jf" ]; then
  printf '\n## Latest journal entry (%s)\n\n' "$(basename "$jf")"
  awk '/^## /{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' "$jf"
fi
