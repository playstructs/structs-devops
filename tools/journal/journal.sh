#!/usr/bin/env bash
# devops journal add [--site S]... [--title T] [text...]   append a hand-off entry
#     (body from the arguments, or stdin when piped; one file per day)
# devops journal show [n]                                  newest n day files (default 1)
# devops journal list                                      all day files
# Entries go to $DEVOPS_REPORTS/journal/YYYY-MM-DD.md (default inventory/reports/journal/) and are scanned for secrets first.
set -euo pipefail
. "$DEVOPS_ROOT/lib/common.sh"

J="$DEVOPS_REPORTS/journal"
mkdir -p "$J"
sub="${1:-show}"; [ $# -gt 0 ] && shift

case "$sub" in
  add)
    sites="" title="" body=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --site) sites="${sites:+$sites, }${2:?}"; shift 2 ;;
        --title) title="${2:?}"; shift 2 ;;
        --) shift; body="$*"; break ;;
        *) body="${body:+$body }$1"; shift ;;
      esac
    done
    if [ -z "$body" ] && [ ! -t 0 ]; then body="$(cat)"; fi
    [ -n "$body" ] || usage_die 'usage: devops journal add [--site S] [--title T] "what changed, what to watch, open follow-ups"  (or pipe the body)'
    title="${title:-$(printf '%s' "$body" | head -1 | cut -c1-72)}"
    who="${DEVOPS_JOURNAL_AUTHOR:-$(is_agent && echo agent || id -un)}"
    f="$J/$(date -u +%Y-%m-%d).md"
    tmp="$(mktemp "${TMPDIR:-/tmp}/devops-journal.XXXXXX")"
    {
      [ -f "$f" ] || printf '# Ops journal %s (UTC)\n' "$(date -u +%Y-%m-%d)"
      printf '\n## %s %s\n\n' "$(date -u +%H:%MZ)" "$title"
      printf -- '- **By:** %s\n' "$who"
      [ -n "$sites" ] && printf -- '- **Sites:** %s\n' "$sites"
      printf '\n%s\n' "$body"
    } > "$tmp"
    if ! python3 "$DEVOPS_ROOT/tools/secrets/scan.py" "$tmp" >&2; then
      rm -f "$tmp"
      die "journal entry looks like it contains a secret; describe it by pointer instead"
    fi
    cat "$tmp" >> "$f"; rm -f "$tmp"
    ok "journal: $f" ;;
  show)
    n="${1:-1}"
    files="$(find "$J" -maxdepth 1 -name '20*.md' | sort | tail -n "$n")"
    [ -n "$files" ] || { echo "no journal entries yet (devops journal add ...)"; exit 0; }
    for x in $files; do cat "$x"; echo; done ;;
  list)
    find "$J" -maxdepth 1 -name '20*.md' | sort | while read -r x; do
      printf '%s  %s entries\n' "$(basename "$x" .md)" "$(grep -c '^## ' "$x")"
    done ;;
  *) usage_die "usage: devops journal add|show [n]|list" ;;
esac
