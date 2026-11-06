# Host probe (streamed). Env: STRUCTS_WEBAPP_CONTAINER. Read-only.
c="${STRUCTS_WEBAPP_CONTAINER:-$(docker ps --format '{{.Names}}' | grep structs-webapp | grep -v cache | head -n1)}"
[ -n "$c" ] || { echo "webapp=missing"; exit 0; }
echo "webapp=$c"
echo "apache_procs=$(docker top "$c" -eo pid,comm 2>/dev/null | awk 'NR > 1 && $2 == "apache2"' | wc -l | tr -d ' ')"
echo "max_workers_conf=$(docker exec "$c" sh -c 'grep -h "^[[:space:]]*MaxRequestWorkers" /etc/apache2/mods-enabled/mpm_prefork.conf /etc/apache2/mods-available/mpm_prefork.conf 2>/dev/null' | awk '{print $2}' | head -1)"
echo "load1=$(cut -d' ' -f1 /proc/loadavg)"
