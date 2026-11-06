#!/usr/bin/env bash
# devops refs sync [--all] [repo...]   clone or fast-forward .references/<repo>
# devops refs status [repo...]         checked-out ref, behind/ahead of remote, site pins
# devops refs path <repo>              print the clone path
set -euo pipefail
. "$DEVOPS_ROOT/lib/common.sh"
need git

TSV="$DEVOPS_REFS/repos.tsv"
[ -f "$TSV" ] || die "missing $TSV"
sub="${1:-status}"; [ $# -gt 0 ] && shift
all=""
names=()
for a in "$@"; do
  case "$a" in --all) all=1 ;; *) names+=("$a") ;; esac
done

rows() {
  # rows -> name url ref group depth (tab-separated), filtered by args/group
  local name url ref group depth n want
  while IFS="$(printf '\t')" read -r name url ref group depth _; do
    case "$name" in ""|\#*) continue ;; esac
    if [ ${#names[@]} -gt 0 ]; then
      want=""
      for n in "${names[@]}"; do [ "$n" = "$name" ] && want=1; done
      [ -n "$want" ] || continue
    elif [ "$sub" = "sync" ] && [ -z "$all" ] && [ "$group" != "core" ]; then
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$url" "$ref" "$group" "$depth"
  done < "$TSV"
}

case "$sub" in
  path)
    [ ${#names[@]} -eq 1 ] || usage_die "usage: devops refs path <repo>"
    printf '%s/%s\n' "$DEVOPS_REFS" "${names[0]}" ;;
  sync)
    fails=0
    while IFS="$(printf '\t')" read -r name url ref group depth; do
      d="$DEVOPS_REFS/$name"
      if [ ! -d "$d/.git" ]; then
        info "clone $name ($ref${depth:+, depth $depth})"
        dflag=()
        [ "${depth:-0}" != "0" ] && dflag=(--depth "$depth" --no-single-branch)
        git clone --quiet ${dflag[@]+"${dflag[@]}"} --branch "$ref" "$url" "$d" || { warn "clone failed: $name"; fails=$((fails + 1)); }
        continue
      fi
      if [ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]; then
        warn "skip $name: local changes in $d"; continue
      fi
      if git -C "$d" fetch --quiet --prune origin; then
        cur="$(git -C "$d" rev-parse --abbrev-ref HEAD)"
        if [ "$cur" = "$ref" ]; then
          git -C "$d" merge --quiet --ff-only "origin/$ref" 2>/dev/null || warn "$name: cannot fast-forward $ref"
        else
          note "$name is on $cur (not $ref); fetched only"
        fi
        info "ok $name $(git -C "$d" rev-parse --short HEAD)"
      else
        warn "fetch failed: $name"; fails=$((fails + 1))
      fi
    done < <(rows)
    [ "$fails" -eq 0 ] || die "$fails repo(s) failed"
    ;;
  status)
    printf '%-26s %-12s %-10s %-10s %s\n' REPO REF LOCAL REMOTE NOTE
    while IFS="$(printf '\t')" read -r name url ref group depth; do
      d="$DEVOPS_REFS/$name"
      if [ ! -d "$d/.git" ]; then printf '%-26s %-12s %-10s %-10s %s\n' "$name" "$ref" "-" "-" "not cloned ($group)"; continue; fi
      cur="$(git -C "$d" rev-parse --abbrev-ref HEAD)"
      loc="$(git -C "$d" rev-parse --short HEAD)"
      rem="$(git -C "$d" rev-parse --short "origin/$ref" 2>/dev/null || echo '?')"
      n=""
      [ "$loc" != "$rem" ] && n="behind/ahead of origin/$ref (devops refs sync $name)"
      [ -n "$(git -C "$d" status --porcelain)" ] && n="$n local changes"
      printf '%-26s %-12s %-10s %-10s %s\n' "$name" "$cur" "$loc" "$rem" "$n"
    done < <(rows)
    if command -v yq >/dev/null 2>&1; then
      echo
      echo "Site pins (site.yaml sources):"
      for f in "$DEVOPS_INVENTORY"/sites/*/site.yaml; do
        s="$(basename "$(dirname "$f")")"
        SITE="$s" yq -r '(.sources // [])[] | "  " + strenv(SITE) + ": " + .repo + " " + .ref + "@" + (.commit // "-")' "$f"
      done
    fi
    ;;
  *) usage_die "usage: devops refs sync [--all] [repo...] | status [repo...] | path <repo>" ;;
esac
