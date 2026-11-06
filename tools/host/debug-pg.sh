# Host debug SQL runner (streamed). Env: PG_CONTAINER PACK_MODE PACK_NAME PACK_SQL PG_TIMEOUT_MS.
# READ ONLY session as postgres over the socket; the bouncer pack uses the admin console.
[ -n "${PG_CONTAINER:-}" ] || { echo "no structs-pg container in the inventory for this site" >&2; exit 1; }
docker inspect -f '{{.State.Status}}' "$PG_CONTAINER" >/dev/null 2>&1 || { echo "container $PG_CONTAINER not found on $(hostname)" >&2; exit 1; }

if [ "${PACK_MODE:-pg}" = bouncer ]; then
  printf '%s\n' "$PACK_SQL" | docker exec -i "$PG_CONTAINER" psql -X -P pager=off \
    "postgres://${BOUNCER_USER:-structs_webapp}@${BOUNCER_HOST:-structs-pg-bouncer}:6432/pgbouncer?sslmode=disable" -f - 2>&1
else
  printf '%s\n' "$PACK_SQL" | docker exec -i -u postgres -e PGUSER=postgres -e PGHOST=/var/run/postgresql \
    -e PGOPTIONS="-c default_transaction_read_only=on -c statement_timeout=${PG_TIMEOUT_MS:-30000} -c lock_timeout=2000 -c application_name=structs-devops-debug" \
    "$PG_CONTAINER" psql -X -P pager=off -v ON_ERROR_STOP=0 -d "${PG_DB:-structs}" -f - 2>&1
fi

if [ "${PACK_NAME:-}" = activity ]; then
  echo
  echo "== processes in $PG_CONTAINER by CPU (args show user, database, client and current command)"
  docker top "$PG_CONTAINER" -eo pid,pcpu,etime,time,args 2>/dev/null | { read -r h; echo "$h"; sort -k2 -nr | head -15; } || true
fi
