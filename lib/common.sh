# shellcheck shell=bash
# Shared helpers for hub-side scripts.
# Hub scripts must run on stock macOS bash 3.2: no associative arrays, no
# ${var,,}, no mapfile/readarray, no `declare -n`, and empty arrays must be
# expanded as ${arr[@]+"${arr[@]}"} under `set -u`.

if [ -z "${DEVOPS_ROOT:-}" ]; then
  DEVOPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
export DEVOPS_ROOT

# .devops.env fills in defaults; anything already exported (e.g.
# DEVOPS_INVENTORY=... devops ...) wins over it.
if [ -f "$DEVOPS_ROOT/.devops.env" ] && [ -z "${DEVOPS_ENV_LOADED:-}" ]; then
  _devops_env_before="$(export -p)"
  set -a
  # shellcheck disable=SC1091
  . "$DEVOPS_ROOT/.devops.env"
  set +a
  eval "$_devops_env_before" 2>/dev/null || true
  unset _devops_env_before
  DEVOPS_ENV_LOADED=1
  export DEVOPS_ENV_LOADED
fi

_abs() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$DEVOPS_ROOT" "$1" ;;
  esac
}

# The inventory is the operator's own (usually private) repo: sites, network
# overlay, pipelines, reports. The framework never tracks it.
DEVOPS_INVENTORY="$(_abs "${DEVOPS_INVENTORY:-inventory}")"
DEVOPS_STATE="$(_abs "${DEVOPS_STATE:-state}")"
DEVOPS_REPORTS="$(_abs "${DEVOPS_REPORTS:-$DEVOPS_INVENTORY/reports}")"
DEVOPS_PIPELINES="$(_abs "${DEVOPS_PIPELINES:-$DEVOPS_INVENTORY/pipelines}")"
DEVOPS_REFS="$(_abs "${DEVOPS_REFS:-.references}")"
DEVOPS_LOCAL="$(_abs "${DEVOPS_LOCAL:-local}")"
export DEVOPS_INVENTORY DEVOPS_STATE DEVOPS_REPORTS DEVOPS_PIPELINES DEVOPS_REFS DEVOPS_LOCAL

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  _C_RED=$'\033[31m'; _C_YEL=$'\033[33m'; _C_GRN=$'\033[32m'; _C_DIM=$'\033[2m'; _C_OFF=$'\033[0m'
else
  _C_RED=''; _C_YEL=''; _C_GRN=''; _C_DIM=''; _C_OFF=''
fi

info() { printf '%s\n' "$*" >&2; }
note() { printf '%s%s%s\n' "$_C_DIM" "$*" "$_C_OFF" >&2; }
ok()   { printf '%sOK%s %s\n' "$_C_GRN" "$_C_OFF" "$*" >&2; }
warn() { printf '%sWARN%s %s\n' "$_C_YEL" "$_C_OFF" "$*" >&2; }
err()  { printf '%sERROR%s %s\n' "$_C_RED" "$_C_OFF" "$*" >&2; }
die()  { err "$*"; exit 1; }
usage_die() { err "$*"; exit 2; }

have() { command -v "$1" >/dev/null 2>&1; }

need() {
  local c
  for c in "$@"; do
    have "$c" || die "missing required command: $c (run ./setup.sh)"
  done
  case " $* " in
    *" yq "*) yq_is_mikefarah || die "yq must be mikefarah/yq v4 (brew install yq); found: $(yq --version 2>&1 | head -1)" ;;
  esac
}

yq_is_mikefarah() {
  yq --version 2>&1 | grep -q 'mikefarah' && yq --version 2>&1 | grep -Eq 'version v?4\.'
}

now_epoch() { date +%s; }
iso_now()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
stamp()     { date +%Y%m%dT%H%M%S; }
today()     { date +%Y-%m-%d; }

# Seconds since an ISO-8601 UTC timestamp (works with BSD and GNU date).
iso_age_seconds() {
  local ts="$1" e
  ts="${ts%%.*}"; ts="${ts%Z}"
  if e=$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "$ts" +%s 2>/dev/null); then :
  elif e=$(date -u -d "${ts}Z" +%s 2>/dev/null); then :
  else echo ""; return 1
  fi
  echo $(( $(now_epoch) - e ))
}

# Epoch for a date like "Feb  2 12:00:00 2027 GMT" (openssl enddate format).
openssl_date_epoch() {
  local d="$1"
  date -j -f '%b %e %T %Y %Z' "$d" +%s 2>/dev/null || date -d "$d" +%s 2>/dev/null
}

mkstate() { mkdir -p "$DEVOPS_STATE/$1"; printf '%s/%s' "$DEVOPS_STATE" "$1"; }

# Quote an argv for display / re-run (bash 3.2 supports printf %q).
quote_argv() {
  local out="" a
  for a in "$@"; do out="$out $(printf '%q' "$a")"; done
  printf '%s' "${out# }"
}

# True when an LLM harness is driving this shell. Agents never get an
# interactive prompt; they get an Approval Block and a token instead.
is_agent() {
  [ -n "${DEVOPS_AGENT:-}${CURSOR_AGENT:-}${CLAUDECODE:-}${CLAUDE_CODE_ENTRYPOINT:-}${CODEX_SANDBOX:-}${CODEX_SANDBOX_NETWORK_DISABLED:-}${CODEX_THREAD_ID:-}" ]
}

has_tty() {
  [ -z "${DEVOPS_NONINTERACTIVE:-}" ] && ( exec </dev/tty ) 2>/dev/null
}

# Ask a yes/no question on the controlling terminal (never stdin, so it
# cannot be answered by a pipe). Returns 1 when there is no terminal.
tty_confirm() {
  local prompt="$1" ans=""
  has_tty || return 1
  printf '%s [type yes]: ' "$prompt" >/dev/tty
  read -r -t 300 ans </dev/tty || return 1
  [ "$ans" = "yes" ]
}

sha_short() { shasum -a 256 | cut -c1-16; }

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

# Run-report directory for today: $DEVOPS_REPORTS/runs/YYYY-MM-DD
run_dir() {
  local d
  d="$DEVOPS_REPORTS/runs/$(today)"
  mkdir -p "$d"
  printf '%s' "$d"
}
