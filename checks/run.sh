#!/usr/bin/env bash
# checks/run.sh <group> <site|all|network> [--quiet]
# Runs every catalog check in the group for the target, records state,
# notifies on status changes, writes a run report. Exit code = worst status.
# group "any" ignores the group column (use with CHECKS_ONLY).
# CHECKS_ONLY / CHECKS_SKIP: comma-separated check ids to include / exclude.
set -uo pipefail
. "$DEVOPS_ROOT/lib/common.sh"
. "$DEVOPS_ROOT/lib/inventory.sh"
. "$DEVOPS_ROOT/lib/notify.sh"
need yq jq curl

group="${1:-hourly}"; target="${2:-all}"; quiet="${3:-}"
CAT="$DEVOPS_ROOT/checks/catalog.tsv"
TIMEOUT="${DEVOPS_CHECK_TIMEOUT:-90}"

applies() {
  # applies SITE APPLIES ID
  local s="$1" a="$2" id="$3"
  SV="$id" yq -e '(.checks.skip // []) | any_c(. == strenv(SV))' "$(inv_site_file "$s")" >/dev/null 2>&1 && return 1
  case "$a" in
    all) return 0 ;;
    guild|public-node|local) [ "$(inv_kind "$s")" = "$a" ] ;;
    nodes) [ -n "$(inv_q "$s" '.nodes[0].host')" ] ;;
    manifest) [ -f "$(inv_site_dir "$s")/patches/manifest.tsv" ] ;;
    extra) SV="$id" yq -e '(.checks.extra // []) | any_c(. == strenv(SV))' "$(inv_site_file "$s")" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

sites="$target"
case "$target" in
  all|network)
    sites=""
    for s in $(inv_sites); do
      [ "$(inv_q "$s" '.checks.in_all')" = "false" ] || sites="$sites $s"
    done ;;
  *) inv_site_file "$target" >/dev/null ;;
esac

report="$(run_dir)/health-$group-${target}-$(date +%H%M).md"
{ echo "# health $group ($target) $(iso_now)"; echo; echo "| Status | Check | Scope | Summary |"; echo "|---|---|---|---|"; } > "$report"
details=""
n_ok=0 n_warn=0 n_crit=0 n_unk=0 worst=0

rank() { case "$1" in 0) echo 0 ;; 1) echo 1 ;; 3) echo 2 ;; *) echo 3 ;; esac; }

run_one() {
  local id="$1" scope="$2" out rc first status sdir
  out="$(CHECK_SCOPE="$scope" perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" bash "$DEVOPS_ROOT/checks/$id.sh" ${3:+"$3"} 2>/dev/null </dev/null)"
  rc=$?
  first="$(printf '%s\n' "$out" | head -n1)"
  case "$first" in OK\ *|WARN\ *|CRIT\ *|UNKNOWN\ *) ;; *)
    first="UNKNOWN $id $scope: check produced no status line (rc=$rc$([ "$rc" -eq 142 ] && echo ", timed out after ${TIMEOUT}s"))"
    rc=3 ;;
  esac
  [ "$rc" -gt 3 ] && rc=3
  status="${first%% *}"
  case "$status" in OK) n_ok=$((n_ok + 1)) ;; WARN) n_warn=$((n_warn + 1)) ;; CRIT) n_crit=$((n_crit + 1)) ;; *) n_unk=$((n_unk + 1)) ;; esac
  [ "$(rank "$rc")" -gt "$(rank "$worst")" ] && worst="$rc"
  sdir="$(mkstate "checks/$scope")"
  printf '%s\n' "$out" > "$sdir/$id.last"
  printf '%s %s\n' "$status" "$(now_epoch)" > "$sdir/$id.status"
  [ -z "$quiet" ] && printf '%s\n' "$first"
  printf '| %s | `%s` | %s | %s |\n' "$status" "$id" "$scope" "$(printf '%s' "${first#* * }" | sed 's/^[^:]*: //' | tr '|' '/')" >> "$report"
  if [ "$status" != "OK" ]; then
    details="$details
### $status $id ($scope)

\`\`\`
$out
\`\`\`
"
  fi
  notify_on_change "check:$scope:$id" "$status" "$scope $id" "$out"
}

while IFS="$(printf '\t')" read -r id scope grp app _ <&3; do
  case "$id" in ""|\#*) continue ;; esac
  [ "$group" = "any" ] || [ "$grp" = "$group" ] || continue
  if [ -n "${CHECKS_ONLY:-}" ]; then case ",$CHECKS_ONLY," in *",$id,"*) ;; *) continue ;; esac; fi
  if [ -n "${CHECKS_SKIP:-}" ]; then case ",$CHECKS_SKIP," in *",$id,"*) continue ;; esac; fi
  if [ "$scope" = "network" ]; then
    case "$target" in all|network) run_one "$id" network ;; esac
    continue
  fi
  [ "$target" = "network" ] && continue
  for s in $sites; do
    applies "$s" "$app" "$id" && run_one "$id" "$s" "$s"
  done
done 3< "$CAT"

[ -n "$details" ] && printf '\n## Details\n%s' "$details" >> "$report"
summary="HEALTH group=$group target=$target ok=$n_ok warn=$n_warn crit=$n_crit unknown=$n_unk report=${report#"$DEVOPS_ROOT"/}"
printf '\n%s\n' "$summary" >> "$report"
echo "$summary"
exit "$worst"
