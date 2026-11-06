# shellcheck shell=bash
# Shared by tools/debug/*. Everything here is read-only.
. "$DEVOPS_ROOT/lib/common.sh"
. "$DEVOPS_ROOT/lib/inventory.sh"
. "$DEVOPS_ROOT/lib/ssh.sh"
. "$DEVOPS_ROOT/lib/chain.sh"
. "$DEVOPS_ROOT/lib/bundle.sh"

# shellcheck disable=SC2034
DEBUG_SQL="$DEVOPS_ROOT/tools/debug/sql"
# shellcheck disable=SC2034
DEBUG_HOST="$DEVOPS_ROOT/tools/host"

need_site() {
  [ -n "${1:-}" ] || usage_die "$2"
  inv_site_exists "$1" || die "unknown site $1 (devops site list)"
}

# Exported site env (container names, host_env) for streamed host scripts.
debug_preamble() {
  inv_site_env "$1" | sed 's/^/export /'
  printf 'export PG_CONTAINER="${STRUCTS_PG_CONTAINER:-}"\n'
}

# Host running a service's stack, or empty when the site has no such service.
service_host() {
  local st
  st="$(inv_service_stack "$1" "$2")"
  [ -n "$st" ] || return 0
  site_stack_host "$1" "$st"
}

# sql_var NAME FILE -> shell lines that set NAME to the file's contents (quoted heredoc).
sql_var() {
  grep -q '^__DEVOPS_SQL__$' "$2" && die "$2 contains the heredoc marker"
  printf '%s=$(cat <<'"'"'__DEVOPS_SQL__'"'"'\n' "$1"
  cat "$2"
  printf '\n__DEVOPS_SQL__\n)\n'
}

# debug_out NAME -> path under $DEVOPS_REPORTS/runs/<date>/debug/ (created)
debug_out() {
  local d
  d="$(run_dir)/debug"
  mkdir -p "$d"
  printf '%s/%s-%s' "$d" "$1" "$(date +%H%M%S)"
}
