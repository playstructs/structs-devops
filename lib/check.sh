# shellcheck shell=bash
# Check contract (see checks/AGENTS.md and docs/health-checks.md):
#   - first stdout line: "<STATUS> <check-id> <scope>: <summary>"
#   - optional detail lines after it
#   - exit 0 OK, 1 WARN, 2 CRIT, 3 UNKNOWN
#   - deltas between runs live in state/checks/<scope>/<check-id>.*
# Checks are read-only. They never restart, edit, or broadcast anything.

CHECK_ID="${CHECK_ID:-$(basename "${0%.sh}")}"
CHECK_SCOPE="${CHECK_SCOPE:-network}"
CHECK_DETAILS=""

detail() { CHECK_DETAILS="${CHECK_DETAILS}$*
"; }

_check_emit() {
  local status="$1" code="$2"; shift 2
  printf '%s %s %s: %s\n' "$status" "$CHECK_ID" "$CHECK_SCOPE" "$*"
  [ -n "$CHECK_DETAILS" ] && printf '%s' "$CHECK_DETAILS" | sed 's/^/  /'
  exit "$code"
}
check_ok()      { _check_emit OK 0 "$@"; }
check_warn()    { _check_emit WARN 1 "$@"; }
check_crit()    { _check_emit CRIT 2 "$@"; }
check_unknown() { _check_emit UNKNOWN 3 "$@"; }

# Worst-of accumulator for checks that evaluate several things.
CHECK_WORST=0
CHECK_MSGS=""
# Severity rank for aggregation: OK < WARN < UNKNOWN < CRIT
_rank() { case "$1" in 0) echo 0 ;; 1) echo 1 ;; 3) echo 2 ;; *) echo 3 ;; esac; }
_lvl_label() { case "$1" in 0) echo ok ;; 1) echo WARN ;; 2) echo CRIT ;; *) echo UNKNOWN ;; esac; }
bump() {
  # bump LEVEL MESSAGE   (LEVEL: 0 ok, 1 warn, 2 crit, 3 unknown)
  local lvl="$1"; shift
  detail "$(_lvl_label "$lvl"): $*"
  if [ "$(_rank "$lvl")" -gt "$(_rank "$CHECK_WORST")" ]; then CHECK_WORST="$lvl"; fi
  if [ "$lvl" -gt 0 ]; then CHECK_MSGS="${CHECK_MSGS:+$CHECK_MSGS; }$*"; fi
  return 0
}
check_finish() {
  local okmsg="$1"
  case "$CHECK_WORST" in
    0) check_ok "$okmsg" ;;
    1) check_warn "$CHECK_MSGS" ;;
    2) check_crit "$CHECK_MSGS" ;;
    *) check_unknown "$CHECK_MSGS" ;;
  esac
}

cstate_dir() { mkstate "checks/$CHECK_SCOPE"; }
cstate_get() { local f; f="$(cstate_dir)/$CHECK_ID.$1"; [ -f "$f" ] && cat "$f"; return 0; }
cstate_set() { printf '%s\n' "$2" > "$(cstate_dir)/$CHECK_ID.$1"; }

# Level for a numeric value against warn/crit thresholds (higher is worse).
level_high() {
  python3 -c "import sys; v,w,c=map(float,sys.argv[1:4]); print(2 if v>=c else 1 if v>=w else 0)" "$1" "$2" "$3"
}
# Lower is worse (e.g. days left, free MB).
level_low() {
  python3 -c "import sys; v,w,c=map(float,sys.argv[1:4]); print(2 if v<=c else 1 if v<=w else 0)" "$1" "$2" "$3"
}

# probe SITE HOST PREAMBLE SCRIPT: run a read-only host script, keep its
# key=value output in PROBE. Returns the ssh/script exit code.
PROBE=""
probe() {
  local rc=0
  PROBE="$(host_bundle "$1" "$2" "$3" "$4" 2>/dev/null)" || rc=$?
  return "$rc"
}
# pv KEY [DEFAULT] -> value of KEY in PROBE
pv() {
  local v
  v="$(printf '%s\n' "$PROBE" | sed -n "s/^$1=//p" | head -n1)"
  printf '%s' "${v:-${2:-}}"
}
# Preamble lines exporting container names etc. for host check scripts.
site_preamble() {
  inv_site_env "$1" | sed 's/^/export /'
  printf 'export PG_CONTAINER="${STRUCTS_PG_CONTAINER:-}"\n'
}

# Site checks take the site as $1.
check_site_arg() {
  [ -n "${1:-}" ] || { echo "UNKNOWN $CHECK_ID -: usage: $0 <site>"; exit 3; }
  CHECK_SCOPE="$1"
  inv_site_exists "$1" || check_unknown "unknown site"
}
