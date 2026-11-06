# Prepended to every script the hub streams to a host (bash 5 on Ubuntu).
# Host-side code never parses YAML and never prints secret values.
set -euo pipefail

log() { printf '%s\n' "$*" >&2; }

# envget FILE KEY -> value of KEY in a dotenv file, surrounding quotes removed
envget() {
  local v
  v="$(grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2-)" || true
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  printf '%s' "$v"
}

# volcat VOLUME PATH -> contents of a file inside a docker volume
volcat() {
  local mp
  mp="$(docker volume inspect "$1" --format '{{.Mountpoint}}')"
  cat "$mp/$2"
}

need_secret() {
  [ -n "${!1:-}" ] || { echo "secret $1 is empty or missing" >&2; exit 1; }
}

backup_file() {
  local f="$1" b
  b="${f}.bak.$(date +%Y%m%dT%H%M%S)"
  cp -a "$f" "$b"
  echo "backup -> $b"
}

# pgq "SQL" -> tab-separated rows from structs-pg, as the postgres superuser
# over the local socket, inside a READ ONLY transaction with a statement timeout.
pgq() {
  docker exec -u postgres -e PGUSER=postgres -e PGHOST=/var/run/postgresql \
    -e PGOPTIONS="-c default_transaction_read_only=on -c statement_timeout=${PG_TIMEOUT_MS:-15000}" \
    "${PG_CONTAINER:?PG_CONTAINER not set}" psql -X -q -v ON_ERROR_STOP=1 -d "${PG_DB:-structs}" -At -F "$(printf '\t')" -c "$1"
}

# bouncer_q "SHOW POOLS" -> PgBouncer admin console (read-only SHOW commands)
bouncer_q() {
  docker exec "${PG_CONTAINER:?PG_CONTAINER not set}" psql -X -q \
    "postgres://${BOUNCER_USER:-structs_webapp}@${BOUNCER_HOST:-structs-pg-bouncer}:6432/pgbouncer?sslmode=disable" \
    -At -F "$(printf '\t')" -c "$1"
}

# redact: mask credential-looking values in log text before it leaves the host.
redact() {
  sed -E \
    -e 's/((password|passwd|secret|token|mnemonic|api[_-]?key|authorization|cookie|private[_-]?key)[A-Za-z0-9_]*["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?)[^"'"'"'[:space:],&;]+/\1<redacted>/Ig' \
    -e 's/(Bearer|Basic) [A-Za-z0-9._~+\/=-]+/\1 <redacted>/g' \
    -e 's/\b(syt|mat|mct)_[A-Za-z0-9_]+/\1_<redacted>/g' \
    -e 's/([?&](access_token|refresh_token|code|client_secret|state)=)[^&[:space:]"]+/\1<redacted>/g'
}

# clog CONTAINER [--tail N | --since 1h|30m|2d] [ts] -> container log lines
# (with "ts": prefixed by the UTC timestamp). Reads the json-file log directly:
# `docker logs` can take minutes or hang on multi-GB logs without rotation.
# --since reads at most CLOG_MAX_BYTES (200 MB) from the end of the file.
clog() {
  local c="$1" mode="${2:---tail}" arg="${3:-200}" ts="${4:-}" drv lp secs cutoff fmt n
  drv="$(docker inspect -f '{{.HostConfig.LogConfig.Type}}' "$c" 2>/dev/null)" || return 0
  lp="$(docker inspect -f '{{.LogPath}}' "$c" 2>/dev/null)"
  if [ "$ts" = ts ]; then fmt='"\(.time[0:19])Z \(.log)"'; else fmt='.log'; fi
  if [ "$drv" != json-file ] || [ ! -r "$lp" ]; then
    timeout 60 docker logs "$mode" "$arg" ${ts:+--timestamps} "$c" 2>&1 || true
    return 0
  fi
  if [ "$mode" = --since ]; then
    n="${arg%[smhd]}"
    case "$arg" in
      *s) secs="$n" ;; *m) secs=$((n * 60)) ;; *h) secs=$((n * 3600)) ;; *d) secs=$((n * 86400)) ;; *) secs="$arg" ;;
    esac
    cutoff="$(date -u -d "-${secs} seconds" +%Y-%m-%dT%H:%M:%S)"
    tail -c "${CLOG_MAX_BYTES:-200000000}" "$lp" |
      jq -Rrj --arg c "$cutoff" "fromjson? | select(.time[0:19] >= \$c) | $fmt"
  else
    tail -n "$arg" "$lp" | jq -Rrj "fromjson? | $fmt"
  fi
}

compose_container() {
  # compose_container NAME_FRAGMENT -> first running container whose name matches
  docker ps --format '{{.Names}}' | grep -E "$1" | head -n1
}
