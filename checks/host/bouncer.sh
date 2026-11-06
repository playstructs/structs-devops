# Host probe (streamed). Env: PG_CONTAINER. Read-only SHOW POOLS, one line per pool:
# pool=<db>/<user>|cl_active|cl_waiting|sv_active|sv_idle|maxwait|pool_mode
out="$(docker exec "${PG_CONTAINER:?}" psql -X -q \
  "postgres://${BOUNCER_USER:-structs_webapp}@${BOUNCER_HOST:-structs-pg-bouncer}:6432/pgbouncer?sslmode=disable" \
  -A -F "$(printf '\t')" -c 'SHOW POOLS' 2>&1)" || { echo "bouncer_error=$(printf '%s' "$out" | head -1 | cut -c1-160)"; exit 0; }
printf '%s\n' "$out" | awk -F'\t' '
  NR==1 { for (i=1;i<=NF;i++) h[$i]=i; next }
  /^\(/ { next }
  NF>3 { printf "pool=%s/%s|%s|%s|%s|%s|%s|%s\n", $h["database"], $h["user"], $h["cl_active"], $h["cl_waiting"], $h["sv_active"], $h["sv_idle"], $h["maxwait"], $h["pool_mode"] }'
