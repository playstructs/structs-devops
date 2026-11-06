#!/usr/bin/env bash
# Idempotent, anchored patch engine for a site's customizations of upstream
# docker-structs-guild / structs-webapp / package defaults.
#
#   apply-patches.sh --list
#   apply-patches.sh --check [--only ID]     verify only; exit 1 on drift
#   apply-patches.sh --apply [--only ID]     pre_helpers, manifest, GA4; backups first
#
# Manifest: sites/<site>/patches/manifest.tsv, six tab-separated columns
#   id  kind  target  overlay_or_snippet  anchor  verify      ("-" = empty)
# kinds: overlay | transform | transform_all | snippet | verify
# ${VAR} in target expands from site.env; verify "re:<ERE>" is a regex.
# File changes only: restarting containers is the caller's job (tier 2).
. "$(dirname "$0")/_bundle.sh"

MODE="${1:-}"; [ $# -gt 0 ] && shift
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in --only) ONLY="$2"; shift 2 ;; *) echo "unknown arg $1" >&2; exit 2 ;; esac
done
MANIFEST="$SITE_PATCHES/manifest.tsv"
[ -f "$MANIFEST" ] || { echo "no manifest for $SITE_ID ($MANIFEST)" >&2; exit 2; }

APPLIED=0 OK=0 DRIFT=0 MISSING=0 SKIPPED=0 FAILURES=0

expand_path() {
  local s="$1" var val
  while [[ "$s" =~ \$\{([A-Z_][A-Z0-9_]*)\} ]]; do
    var="${BASH_REMATCH[1]}"
    val="${!var:-}"
    [ -n "$val" ] || { echo "UNSET:$var"; return 1; }
    s="${s//\$\{$var\}/$val}"
  done
  printf '%s' "$s"
}

field() { [ "$1" = "-" ] && printf '' || printf '%s' "$1"; }

file_contains() {
  if [[ "$2" == re:* ]]; then grep -qE -- "${2#re:}" "$1"; else grep -Fq -- "$2" "$1"; fi
}

verify_patch() {
  local id="$1" target="$2" verify="$3"
  [ -z "$verify" ] && { echo "  [$id] verify SKIP (no pattern)"; return 0; }
  [ -f "$target" ] || { echo "  [$id] MISSING file $target"; return 1; }
  if file_contains "$target" "$verify"; then echo "  [$id] OK"; return 0; fi
  echo "  [$id] DRIFT pattern not found in $target"
  echo "         expected: $verify"
  return 1
}

py_replace() {
  # py_replace MODE FILE ANCHOR REPLACEMENT|SNIPPET_FILE ; MODE once|all|snippet
  python3 - "$@" <<'PY'
import sys
mode, path, anchor, arg = sys.argv[1:5]
repl = open(arg, encoding="utf-8").read() if mode == "snippet" else arg
text = open(path, encoding="utf-8", errors="replace").read()
if mode == "once" and repl in text:
    sys.exit(2)
if anchor not in text:
    sys.exit(3)
new = text.replace(anchor, repl) if mode == "all" else text.replace(anchor, repl, 1)
with open(path, "w", encoding="utf-8") as f:   # in place: keeps owner and mode
    f.write(new)
print(text.count(anchor) if mode == "all" else 1)
PY
}

check_only() {
  local id="$1" target="$2" verify="$3"
  if [ ! -f "$target" ]; then echo "  [$id] MISSING file $target"; MISSING=$((MISSING + 1)); return 1; fi
  if verify_patch "$id" "$target" "$verify"; then OK=$((OK + 1)); return 0; fi
  DRIFT=$((DRIFT + 1)); return 1
}

apply_overlay() {
  local id="$1" target="$2" rel="$3" verify="$4" src
  src="$(patch_src overlay "$rel")"
  [ -f "$src" ] || { echo "  [$id] FAIL overlay source missing: $src"; return 1; }
  if [ -f "$target" ] && cmp -s "$src" "$target"; then
    echo "  [$id] already applied (identical)"; SKIPPED=$((SKIPPED + 1)); return 0
  fi
  [ -f "$target" ] && backup_file "$target"
  install_file "$src" "$target"
  echo "  [$id] APPLIED overlay -> $target"; APPLIED=$((APPLIED + 1))
  verify_patch "$id" "$target" "$verify"
}

apply_transform() {
  local id="$1" target="$2" anchor="$3" expected="$4" mode="$5" rc=0 n
  [ -f "$target" ] || { echo "  [$id] FAIL missing file $target"; return 1; }
  if [ -n "$expected" ] && file_contains "$target" "$expected" \
     && { [ "$mode" != "all" ] || ! grep -Fq -- "$anchor" "$target"; }; then
    echo "  [$id] already applied"; SKIPPED=$((SKIPPED + 1)); return 0
  fi
  if [ -z "$anchor" ] || ! grep -Fq -- "$anchor" "$target"; then
    echo "  [$id] DRIFT anchor not found (upstream changed?)"
    echo "         anchor: $anchor"
    DRIFT=$((DRIFT + 1)); return 1
  fi
  backup_file "$target"
  n="$(py_replace "$mode" "$target" "$anchor" "$expected")" || rc=$?
  [ "$rc" -eq 2 ] && { echo "  [$id] already applied"; SKIPPED=$((SKIPPED + 1)); return 0; }
  [ "$rc" -ne 0 ] && { echo "  [$id] FAIL transform rc=$rc"; return 1; }
  echo "  [$id] APPLIED $mode ($n) -> $target"; APPLIED=$((APPLIED + 1))
  verify_patch "$id" "$target" "$expected"
}

apply_snippet() {
  local id="$1" target="$2" rel="$3" anchor="$4" verify="$5" snip rc=0
  snip="$(patch_src snippets "$rel")"
  [ -f "$snip" ] || { echo "  [$id] FAIL snippet missing: $snip"; return 1; }
  [ -f "$target" ] || { echo "  [$id] FAIL missing file $target"; return 1; }
  if [ -n "$verify" ] && file_contains "$target" "$verify"; then
    echo "  [$id] already applied"; SKIPPED=$((SKIPPED + 1)); return 0
  fi
  grep -Fq -- "$anchor" "$target" || { echo "  [$id] DRIFT anchor not found"; echo "         anchor: $anchor"; DRIFT=$((DRIFT + 1)); return 1; }
  backup_file "$target"
  py_replace snippet "$target" "$anchor" "$snip" >/dev/null || rc=$?
  [ "$rc" -ne 0 ] && { echo "  [$id] FAIL snippet rc=$rc"; return 1; }
  echo "  [$id] APPLIED snippet -> $target"; APPLIED=$((APPLIED + 1))
  verify_patch "$id" "$target" "$verify"
}

run_pre_helpers() {
  local h
  for h in ${PATCH_PRE_HELPERS:-}; do
    [ -f "$TOOLS_ROOT/host/$h.sh" ] || { echo "FAIL missing helper $h.sh"; FAILURES=$((FAILURES + 1)); continue; }
    echo "== helper $h =="
    bash "$TOOLS_ROOT/host/$h.sh" || FAILURES=$((FAILURES + 1))
    echo
  done
}

process() {
  local do_apply="$1" id kind target src anchor verify t
  echo "site: $SITE_ID  manifest: $MANIFEST"
  while IFS=$'\t' read -r id kind target src anchor verify || [ -n "${id:-}" ]; do
    [ -z "${id:-}" ] || [[ "$id" == \#* ]] && continue
    [ -n "$ONLY" ] && [ "$id" != "$ONLY" ] && continue
    if ! t="$(expand_path "$target")"; then
      echo "== $id ($kind) ==";  echo "  [$id] FAIL ${t#UNSET:} is not set in site.env"; FAILURES=$((FAILURES + 1)); continue
    fi
    src="$(field "$src")"; anchor="$(field "$anchor")"; verify="$(field "$verify")"
    echo "== $id ($kind) =="
    if [ "$do_apply" = 1 ]; then
      case "$kind" in
        overlay)       apply_overlay "$id" "$t" "$src" "$verify" || FAILURES=$((FAILURES + 1)) ;;
        transform)     apply_transform "$id" "$t" "$anchor" "$verify" once || FAILURES=$((FAILURES + 1)) ;;
        transform_all) apply_transform "$id" "$t" "$anchor" "$verify" all || FAILURES=$((FAILURES + 1)) ;;
        snippet)       apply_snippet "$id" "$t" "$src" "$anchor" "$verify" || FAILURES=$((FAILURES + 1)) ;;
        verify)        check_only "$id" "$t" "$verify" || FAILURES=$((FAILURES + 1)) ;;
        *) echo "  [$id] FAIL unknown kind $kind"; FAILURES=$((FAILURES + 1)) ;;
      esac
    else
      case "$kind" in
        overlay|transform|transform_all|snippet|verify) check_only "$id" "$t" "$verify" || FAILURES=$((FAILURES + 1)) ;;
        *) echo "  [$id] FAIL unknown kind $kind"; FAILURES=$((FAILURES + 1)) ;;
      esac
    fi
  done < "$MANIFEST"
}

case "$MODE" in
  --list)
    printf '%-30s %-14s %s\n' ID KIND TARGET
    while IFS=$'\t' read -r id kind target _rest || [ -n "${id:-}" ]; do
      [ -z "${id:-}" ] || [[ "$id" == \#* ]] && continue
      printf '%-30s %-14s %s\n' "$id" "$kind" "$(expand_path "$target" || true)"
    done < "$MANIFEST"
    exit 0 ;;
  --check) process 0 ;;
  --apply)
    if [ -z "$ONLY" ]; then
      run_pre_helpers
      if [ -n "${GA4_ID:-}" ]; then
        echo "== helper insert-ga4 =="; bash "$TOOLS_ROOT/host/insert-ga4.sh" || FAILURES=$((FAILURES + 1)); echo
      fi
    fi
    process 1
    ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

echo
echo "PATCHES site=$SITE_ID mode=${MODE#--} ok=$OK applied=$APPLIED skipped=$SKIPPED drift=$DRIFT missing=$MISSING failures=$FAILURES"
if [ "$MODE" = "--apply" ] && [ "$APPLIED" -gt 0 ] && [ -n "${PATCH_AFTER_APPLY:-}" ]; then
  echo "NEXT (tier 2, not run here): cd ${GUILD_ROOT:-.} && $PATCH_AFTER_APPLY"
fi
[ "$FAILURES" -eq 0 ]
