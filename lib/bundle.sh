# shellcheck shell=bash
# Host tools bundle: tools/host (framework, then the inventory's own
# tools/host) + shared patches + one site's patches, overrides and generated
# site.env, pushed to the host's tools_path. Pushing is tier 1 (writes only
# under tools_path). Needs inventory.sh and ssh.sh.

bundle_tools_path() {
  local p
  p="$(inv_host "$1" "$2" tools_path)"
  printf '%s' "${p:-/opt/structs-devops}"
}

# bundle_stage SITE -> prints a temp dir holding the bundle tree
bundle_stage() {
  local site="$1" st sd f
  st="$(mktemp -d "${TMPDIR:-/tmp}/devops-stage.XXXXXX")"
  mkdir -p "$st/host" "$st/shared" "$st/sites/$site"
  cp "$DEVOPS_ROOT"/tools/host/*.sh "$st/host/"
  for f in "$DEVOPS_INVENTORY"/tools/host/*.sh; do
    [ -f "$f" ] || continue
    case "${f##*/}" in _*) rm -rf "$st"; die "inventory tools/host/${f##*/}: names starting with _ are reserved for the framework" ;; esac
    [ -e "$st/host/${f##*/}" ] && { rm -rf "$st"; die "inventory tools/host/${f##*/} has the same name as a framework host tool; rename it"; }
    cp "$f" "$st/host/"
  done
  [ -d "$DEVOPS_INVENTORY/shared/patches" ] && cp -R "$DEVOPS_INVENTORY/shared/patches" "$st/shared/"
  sd="$(inv_site_dir "$site")"
  [ -d "$sd/patches" ] && cp -R "$sd/patches" "$st/sites/$site/"
  for f in "$sd"/*.overrides; do [ -f "$f" ] && cp "$f" "$st/sites/$site/"; done
  inv_site_env "$site" > "$st/sites/$site/site.env"
  printf '%s\n' "$site" > "$st/SITE"
  find "$st" -name '.DS_Store' -delete
  (cd "$st" && find . -type f ! -name VERSION | LC_ALL=C sort | while IFS= read -r f; do
     printf '%s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f"; done) | sha_short > "$st/VERSION"
  printf '%s' "$st"
}

bundle_remote_version() {
  local tp
  tp="$(bundle_tools_path "$1" "$2")"
  host_run "$1" "$2" "cat $(printf '%q' "$tp")/VERSION 2>/dev/null || true" 2>/dev/null | tr -d '[:space:]'
}

# bundle_push SITE HOST STAGE
bundle_push() {
  local site="$1" host="$2" st="$3" tp target
  tp="$(bundle_tools_path "$site" "$host")"
  target="$(ssh_target "$site" "$host")"
  if [ "$target" = "local" ]; then
    case "$tp" in /*) ;; *) tp="$DEVOPS_ROOT/${tp#./}" ;; esac
    rm -rf "$tp/host" "$tp/shared" "$tp/sites/$site"
    mkdir -p "$tp" && cp -R "$st/." "$tp/"
    return 0
  fi
  local opts=() o q
  while IFS= read -r o; do opts+=("$o"); done < <(_ssh_opts)
  q="$(printf '%q' "$tp")"
  (cd "$st" && COPYFILE_DISABLE=1 tar -czf - .) | ssh "${opts[@]}" "$target" \
    "set -e; t=\$(mktemp -d); tar -xzf - -C \"\$t\" --no-same-owner;
     mkdir -p $q; rm -rf $q/host $q/shared $q/sites/$(printf '%q' "$site");
     cp -R \"\$t\"/. $q/; rm -rf \"\$t\"; chmod 700 $q; cat $q/VERSION"
}

# bundle_ensure SITE HOST: push if the host's VERSION differs from local.
bundle_ensure() {
  local site="$1" host="$2" st want have
  st="$(bundle_stage "$site")"
  want="$(cat "$st/VERSION")"
  have="$(bundle_remote_version "$site" "$host")"
  if [ "$want" != "$have" ]; then
    note "host bundle on $site:$host is ${have:-absent}; pushing $want to $(bundle_tools_path "$site" "$host") (tier 1)"
    bundle_push "$site" "$host" "$st" >/dev/null
    audit "BUNDLE site=$site host=$host version=$want previous=${have:-none}"
  fi
  rm -rf "$st"
}

# bundle_run SITE HOST SCRIPT [ARGS...]: run a synced host script
bundle_run() {
  local site="$1" host="$2" script="$3" tp; shift 3
  tp="$(bundle_tools_path "$site" "$host")"
  case "$tp" in /*) ;; *) [ "$(ssh_target "$site" "$host")" = "local" ] && tp="$DEVOPS_ROOT/${tp#./}" ;; esac
  host_run "$site" "$host" "SITE_ID=$(printf '%q' "$site") bash $(printf '%q' "$tp/host/$script") $(quote_argv "$@")"
}

# Host that carries a site's web/guild stack (else the primary host).
site_stack_host() {
  local site="$1" st="${2:-}" h=""
  [ -n "$st" ] && h="$(inv_stack_host "$site" "$st")"
  [ -z "$h" ] && h="$(inv_q "$site" '.stacks[0].host')"
  [ -z "$h" ] && h="$(inv_primary_host "$site")"
  printf '%s' "$h"
}
