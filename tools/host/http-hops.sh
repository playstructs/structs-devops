# Host side of devops debug http-trace (streamed). Read-only GETs.
# Env: TRACE_FQDN TRACE_PATH STRUCTS_WEBAPP_CONTAINER STRUCTS_WEBAPP_CACHE_CONTAINER
# Prints one line per hop: hop=<name> code= connect= ttfb= total= cache= server= note=
set +e
fmt='code=%{http_code} connect=%{time_connect} ttfb=%{time_starttransfer} total=%{time_total}'
hdr="$(mktemp)"; trap 'rm -f "$hdr"' EXIT

hop() {
  local name="$1"; shift
  local res cache server
  : > "$hdr"
  res="$(curl -sS -o /dev/null -D "$hdr" -m 20 -w "$fmt" "$@" 2>&1 | tail -1)"
  cache="$(grep -i '^x-cache-status:' "$hdr" | tail -1 | awk '{print $2}' | tr -d '\r')"
  server="$(grep -i '^server:' "$hdr" | tail -1 | cut -d' ' -f2- | tr -d '\r' | tr ' ' '_')"
  case "$res" in code=*) ;; *) res="code=000 note=$(printf '%s' "$res" | tr ' ' '_' | cut -c1-120)" ;; esac
  echo "hop=$name $res cache=${cache:--} server=${server:--}"
}

hop caddy-loopback -k --resolve "$TRACE_FQDN:443:127.0.0.1" "https://$TRACE_FQDN$TRACE_PATH"

if [ -n "${STRUCTS_WEBAPP_CACHE_CONTAINER:-}" ]; then
  hop nginx-8080 -H "Host: $TRACE_FQDN" -H "X-Forwarded-For: 203.0.113.7" -H "X-Forwarded-Proto: https" \
    "http://127.0.0.1:8080$TRACE_PATH"
fi

if [ -n "${STRUCTS_WEBAPP_CONTAINER:-}" ]; then
  if docker exec "$STRUCTS_WEBAPP_CONTAINER" sh -c 'command -v curl' >/dev/null 2>&1; then
    res="$(docker exec "$STRUCTS_WEBAPP_CONTAINER" curl -sS -o /dev/null -m 20 -w "$fmt" \
      -H "Host: $TRACE_FQDN" -H "X-Forwarded-For: 203.0.113.7" -H "X-Forwarded-Proto: https" \
      "http://127.0.0.1:80$TRACE_PATH" 2>&1 | tail -1)"
    case "$res" in code=*) ;; *) res="code=000 note=$(printf '%s' "$res" | tr ' ' '_' | cut -c1-120)" ;; esac
    echo "hop=apache-in-container $res cache=- server=apache"
  else
    echo "hop=apache-in-container code=skip note=no_curl_in_container"
  fi
  busy="$(docker top "$STRUCTS_WEBAPP_CONTAINER" -eo pid,comm 2>/dev/null | awk 'NR > 1 && ($2 == "apache2" || $2 == "httpd")' | wc -l | tr -d ' ')"
  echo "apache_procs=$busy"
fi
