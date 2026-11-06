# shellcheck shell=bash
# Inventory accessors (mikefarah yq v4). Values are passed to yq through
# strenv() so site/host ids never become part of an expression.

# network.yaml may name a public preset (networks/<preset>.yaml); the merged
# result (maps merge, the inventory's lists win) is cached under state/.
inv_network_file() {
  local f="$DEVOPS_INVENTORY/network.yaml" preset pf out
  preset="$(yq -r '.preset // ""' "$f" 2>/dev/null)"
  if [ -z "$preset" ]; then printf '%s' "$f"; return 0; fi
  pf="$DEVOPS_ROOT/networks/$preset.yaml"
  [ -f "$pf" ] || die "network.yaml names preset $preset but networks/$preset.yaml does not exist"
  out="$DEVOPS_STATE/cache/network-$(printf '%s' "$f" | sha_short).yaml"
  if [ ! -s "$out" ] || [ "$f" -nt "$out" ] || [ "$pf" -nt "$out" ]; then
    mkdir -p "${out%/*}"
    yq eval-all '. as $i ireduce ({}; . * $i) | del(.preset)' "$pf" "$f" > "$out.tmp" && mv "$out.tmp" "$out"
  fi
  printf '%s' "$out"
}

inv_sites() {
  local d
  for d in "$DEVOPS_INVENTORY"/sites/*/; do
    [ -f "${d}site.yaml" ] && basename "$d"
  done
  return 0
}

inv_site_dir() { printf '%s/sites/%s' "$DEVOPS_INVENTORY" "$1"; }

inv_site_file() {
  local f
  f="$(inv_site_dir "$1")/site.yaml"
  [ -f "$f" ] || die "unknown site '$1' (known: $(inv_sites | tr '\n' ' '))"
  printf '%s' "$f"
}

inv_site_exists() { [ -f "$(inv_site_dir "$1")/site.yaml" ]; }

# inv_q SITE EXPR -> raw value, empty string for null/missing
inv_q() {
  local f
  f="$(inv_site_file "$1")" || return 1
  yq -r "($2) // \"\"" "$f"
}

# inv_net EXPR -> raw value from network.yaml
inv_net() { yq -r "($1) // \"\"" "$(inv_network_file)"; }

inv_kind() { inv_q "$1" '.kind'; }

inv_sites_of_kind() {
  local s
  for s in $(inv_sites); do
    [ "$(inv_kind "$s")" = "$1" ] && echo "$s"
  done
  return 0
}

inv_host_ids() { inv_q "$1" '.hosts[].id'; }
inv_primary_host() { inv_q "$1" '.hosts[0].id'; }

# inv_host SITE HOST FIELD
inv_host() {
  H="$2" yq -r ".hosts[] | select(.id == strenv(H)) | (.$3 // \"\")" "$(inv_site_file "$1")"
}

# Find the site that owns a host id (host ids are unique across the inventory).
inv_host_site() {
  local s
  for s in $(inv_sites); do
    if [ -n "$(H="$1" yq -r '.hosts[] | select(.id == strenv(H)) | .id' "$(inv_site_file "$s")")" ]; then
      echo "$s"; return 0
    fi
  done
  return 1
}

# Accept "site", "host", or "site:host"; sets T_SITE and T_HOST.
inv_resolve() {
  local arg="$1"
  T_SITE=""; T_HOST=""
  case "$arg" in
    *:*) T_SITE="${arg%%:*}"; T_HOST="${arg#*:}" ;;
    *)
      if inv_site_exists "$arg"; then
        T_SITE="$arg"; T_HOST="$(inv_primary_host "$arg")"
      elif T_SITE="$(inv_host_site "$arg")"; then
        T_HOST="$arg"
      else
        die "unknown site or host: $arg"
      fi
      ;;
  esac
  inv_site_exists "$T_SITE" || die "unknown site: $T_SITE"
  [ -n "$(inv_host "$T_SITE" "$T_HOST" id)" ] || die "site $T_SITE has no host $T_HOST"
}

# Stack accessors
inv_stack_ids() { inv_q "$1" '.stacks[].id'; }
inv_stack() {
  S="$2" yq -r ".stacks[] | select(.id == strenv(S)) | (.$3 // \"\")" "$(inv_site_file "$1")"
}

# Stack that declares a service (first match). Prints the stack id.
inv_service_stack() {
  SV="$2" yq -r '[.stacks[] | select(.services | has(strenv(SV)))][0].id // ""' "$(inv_site_file "$1")"
}

# Container name for a service: explicit .services.<svc>.container, else
# <compose project>-<svc>-1 where the project is the stack's project or the
# basename of its path.
inv_container() {
  local site="$1" svc="$2" st c proj path
  st="$(inv_service_stack "$site" "$svc")"
  [ -n "$st" ] || { echo ""; return 1; }
  c="$(S="$st" SV="$svc" yq -r '.stacks[] | select(.id == strenv(S)) | .services[strenv(SV)].container // ""' "$(inv_site_file "$site")")"
  if [ -n "$c" ]; then echo "$c"; return 0; fi
  proj="$(inv_stack "$site" "$st" project)"
  if [ -z "$proj" ]; then
    path="$(inv_stack "$site" "$st" path)"
    proj="$(basename "$path")"
  fi
  echo "${proj}-${svc}-1"
}

# Compose invocation prefix for a stack: cd <path> && docker compose -f a -f b
inv_compose_cmd() {
  local site="$1" st="$2" path files f cmd
  path="$(inv_stack "$site" "$st" path)"
  files="$(S="$st" yq -r '.stacks[] | select(.id == strenv(S)) | (.compose // ["compose.yaml"])[]' "$(inv_site_file "$site")")"
  cmd="cd $(printf '%q' "$path") && docker compose"
  for f in $files; do cmd="$cmd -f $(printf '%q' "$f")"; done
  printf '%s' "$cmd"
}

inv_stack_host() { inv_stack "$1" "$2" host; }

# Threshold lookup: site .checks.<path> -> network .check_defaults.<path> -> default
thr() {
  local site="$1" path="$2" def="$3" v=""
  if [ -n "$site" ] && inv_site_exists "$site"; then
    v="$(inv_q "$site" ".checks.$path")"
  fi
  [ -z "$v" ] && v="$(inv_net ".check_defaults.$path")"
  [ -z "$v" ] && v="$def"
  printf '%s' "$v"
}

# True if the site ignores a container/service in health checks.
inv_ignored_service() {
  SV="$2" yq -e '(.checks.ignore_unhealthy // []) | any_c(. == strenv(SV))' "$(inv_site_file "$1")" >/dev/null 2>&1
}

# Flat, bash-sourceable env for host-side scripts (they never parse YAML):
# host_env, site identity, patch settings, and resolved container names.
inv_site_env() {
  local site="$1" f k v svc var c
  f="$(inv_site_file "$site")"
  yq -r '(.host_env // {}) | to_entries[] | .key + "\t" + (.value | tostring)' "$f" |
    while IFS="$(printf '\t')" read -r k v; do printf '%s=%q\n' "$k" "$v"; done
  printf 'SITE_ID=%q\nSITE_KIND=%q\n' "$site" "$(inv_kind "$site")"
  printf 'PATCH_PRE_HELPERS=%q\n' "$(inv_q "$site" '(.patches.pre_helpers // []) | join(" ")')"
  printf 'GA4_ID=%q\n' "$(inv_q "$site" '.patches.ga4')"
  printf 'PATCH_AFTER_APPLY=%q\n' "$(inv_q "$site" '.patches.after_apply')"
  for svc in structs-webapp structs-webapp-cache structs-pg structs-pg-bouncer structs-tsa \
             structs-grass structs-nats structs-sync-state structs-pg-auto-migrate structsd synapse mas; do
    var="$(printf '%s' "$svc" | tr 'a-z-' 'A-Z_')_CONTAINER"
    c="$(inv_container "$site" "$svc" 2>/dev/null || true)"
    [ -n "$c" ] && printf '%s=%q\n' "$var" "$c"
  done
  c="$(inv_q "$site" '.nodes[0].container')"
  [ -n "$c" ] && printf 'NODE_CONTAINER=%q\nNODE_VOLUME=%q\n' "$c" "$(inv_q "$site" '.nodes[0].volume // "structsd-chaindata"')"
  return 0
}

# structsd nodes across the inventory, one TSV line each:
#   site  host  container  rpc(host-local)  role  volume
inv_structsd_nodes() {
  local s
  for s in $(inv_sites); do
    SITE="$s" yq -r '(.nodes // [])[] | [strenv(SITE), .host, .container,
      (.rpc // "http://127.0.0.1:26657"), (.role // "full"), (.volume // "structsd-chaindata")] | @tsv' \
      "$(inv_site_file "$s")"
  done
}
