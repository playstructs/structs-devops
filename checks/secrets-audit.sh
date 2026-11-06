#!/usr/bin/env bash
# secrets-audit <site>: every secret pointer resolves to something present and
# non-empty with the expected mode/owner. Uses test/stat/grep -c only; no value
# is ever read, printed or copied.
. "$DEVOPS_ROOT/checks/_lib.sh"
. "$DEVOPS_ROOT/lib/secrets.sh"
check_site_arg "${1:-}"; site="$1"
f="$(inv_site_file "$site")"
names="$(yq -r '(.secrets // {}) | keys | .[]' "$f")"
[ -n "$names" ] || check_ok "no secrets declared"

sev_missing() {
  case "$(inv_q "$site" ".secrets.\"$1\".criticality")" in critical|high) echo 2 ;; *) echo 1 ;; esac
}
mode_ok() {
  # mode_ok ACTUAL WANT   WANT is "600" (exact) or "<=640" (no bits beyond)
  case "$2" in
    "<="*) python3 -c "import sys; a,m=int(sys.argv[1],8),int(sys.argv[2],8); sys.exit(0 if a & ~m == 0 else 1)" "$1" "${2#<=}" ;;
    *) [ "$1" = "$2" ] ;;
  esac
}

total=0 nobackup=""
for h in $(inv_host_ids "$site"); do
  script=""
  for n in $names; do
    ref="$(inv_q "$site" ".secrets.\"$n\".ref")"
    secret_parse "$ref" || continue
    [ "$S_SCHEME" = "local-env" ] && continue
    [ "$S_HOST" = "$h" ] || continue
    script="${script}printf '%s ' $(printf '%q' "$n"); $(secret_probe_cmd)
"
    el="$(inv_q "$site" ".secrets.\"$n\".expect_line")"
    if [ -n "$el" ]; then
      script="${script}printf 'line %s ' $(printf '%q' "$n"); grep -cF -- $(printf '%q' "$el") $(printf '%q' "$S_PATH") 2>/dev/null || true
"
    fi
  done
  [ -n "$script" ] || continue
  out="$(host_run "$site" "$h" "$script" 2>/dev/null)" || { bump 3 "$h unreachable; secrets not audited"; continue; }
  while read -r a b c d; do
    [ -n "$a" ] || continue
    if [ "$a" = "line" ]; then
      [ "${c:-0}" -gt 0 ] 2>/dev/null || bump "$(sev_missing "$b")" "$b: expected line $(inv_q "$site" ".secrets.\"$b\".expect_line") is gone"
      continue
    fi
    n="$a"; state="$b"; mode="$c"; owner="$d"; total=$((total + 1))
    case "$state" in
      present)
        em="$(inv_q "$site" ".secrets.\"$n\".expect_mode")"
        eo="$(inv_q "$site" ".secrets.\"$n\".expect_owner")"
        if [ -n "$em" ] && ! mode_ok "$mode" "$em"; then bump 1 "$n: mode $mode (expected $em)"
        elif [ -n "$eo" ] && [ "${owner%%:*}" != "$eo" ] && [ "${owner#*:}" != "$eo" ]; then bump 1 "$n: owner $owner (expected $eo)"
        else detail "ok: $n present (mode $mode, $owner)"; fi ;;
      empty)    bump "$(sev_missing "$n")" "$n: key/file exists but is EMPTY (a pull or overwrite blanked it?)" ;;
      missing)  bump "$(sev_missing "$n")" "$n: key not in the file" ;;
      nofile)   bump "$(sev_missing "$n")" "$n: file not found" ;;
      novolume) bump "$(sev_missing "$n")" "$n: docker volume not found" ;;
      *)        bump 3 "$n: unexpected probe output '$state'" ;;
    esac
  done <<EOF
$out
EOF
done

for n in $names; do
  ref="$(inv_q "$site" ".secrets.\"$n\".ref")"
  if ! secret_parse "$ref"; then bump 1 "$n: unparseable ref '$ref'"; continue; fi
  if [ "$S_SCHEME" = "local-env" ]; then
    total=$((total + 1))
    if secret_local_present "$S_KEY"; then detail "ok: $n present in local/secrets.env"
    else bump 1 "$n: $S_KEY not set in local/secrets.env"; fi
  elif [ -z "$(inv_host "$site" "$S_HOST" id)" ]; then
    bump 1 "$n: pointer names host '$S_HOST', which is not a host of $site"
  fi
  if [ "$(inv_q "$site" ".secrets.\"$n\".criticality")" = "critical" ] && [ "$(inv_q "$site" ".secrets.\"$n\".backup")" = "none" ]; then
    nobackup="$nobackup $n"
  fi
done
[ -n "$nobackup" ] && detail "policy: critical secrets with no off-host backup:$nobackup (docs/secrets.md#backups)"
check_finish "$total secret pointers resolve"
