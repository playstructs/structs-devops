# shellcheck shell=bash
# Secret pointers. The inventory stores where a secret lives, never its value.
#
#   host-env:<host>:<file>#<KEY>      key in a dotenv file on a host
#   host-file:<host>:<path>           whole file on a host
#   host-volume:<host>:<volume>/<p>   file inside a docker volume on a host
#   local-env:<KEY>                   key in the hub's ignored local/secrets.env
#
# Nothing here reads a value. Presence checks use test/stat/grep -c only.

# secret_parse REF -> sets S_SCHEME S_HOST S_PATH S_KEY
# shellcheck disable=SC2034
secret_parse() {
  local ref="$1" rest
  S_SCHEME="${ref%%:*}"; rest="${ref#*:}"
  S_HOST=""; S_PATH=""; S_KEY=""
  case "$S_SCHEME" in
    host-env)
      S_HOST="${rest%%:*}"; rest="${rest#*:}"
      S_PATH="${rest%%#*}"; S_KEY="${rest#*#}"
      [ "$S_KEY" = "$rest" ] && return 1
      ;;
    host-file)   S_HOST="${rest%%:*}"; S_PATH="${rest#*:}" ;;
    host-volume) S_HOST="${rest%%:*}"; S_PATH="${rest#*:}" ;;
    local-env)   S_KEY="$rest" ;;
    *) return 1 ;;
  esac
  return 0
}

# Remote probe for one pointer. Prints "<state> <mode> <uid>:<user>" where
# state is present|empty|missing|nofile|novolume. Never prints the value.
secret_probe_cmd() {
  case "$S_SCHEME" in
    host-env)
      printf 'f=%q; k=%q; if [ -f "$f" ]; then m=$(stat -c "%%a %%u:%%U" "$f"); if ! grep -q "^${k}=" "$f"; then echo "missing $m"; elif [ -n "$(grep -m1 "^${k}=" "$f" | cut -d= -f2- | tr -d "\\"'"'"' \\t\\r")" ]; then echo "present $m"; else echo "empty $m"; fi; else echo "nofile - -"; fi' "$S_PATH" "$S_KEY"
      ;;
    host-file)
      printf 'f=%q; if [ -s "$f" ]; then echo "present $(stat -c "%%a %%u:%%U" "$f")"; elif [ -e "$f" ]; then echo "empty $(stat -c "%%a %%u:%%U" "$f")"; else echo "nofile - -"; fi' "$S_PATH"
      ;;
    host-volume)
      local vol="${S_PATH%%/*}" p="${S_PATH#*/}"
      printf 'mp=$(docker volume inspect %q --format "{{.Mountpoint}}" 2>/dev/null); f="$mp/%s"; if [ -n "$mp" ] && [ -s "$f" ]; then echo "present $(stat -c "%%a %%u:%%U" "$f")"; elif [ -n "$mp" ]; then echo "nofile - -"; else echo "novolume - -"; fi' "$vol" "$p"
      ;;
  esac
}

# Local presence for local-env refs
secret_local_present() {
  [ -f "$DEVOPS_LOCAL/secrets.env" ] && grep -q "^$1=..*" "$DEVOPS_LOCAL/secrets.env"
}

# Line for a host-side script (after tools/host/_prelude.sh) that loads the
# parsed pointer into an exported variable without echoing it.
#   secret_load_snippet VAR
secret_load_snippet() {
  local var="$1"
  case "$S_SCHEME" in
    host-env)
      printf '%s="$(envget %q %q)"; export %s; need_secret %s\n' "$var" "$S_PATH" "$S_KEY" "$var" "$var" ;;
    host-file)
      printf '%s="$(cat %q)"; export %s; need_secret %s\n' "$var" "$S_PATH" "$var" "$var" ;;
    host-volume)
      printf '%s="$(volcat %q %q)"; export %s; need_secret %s\n' "$var" "${S_PATH%%/*}" "${S_PATH#*/}" "$var" "$var" ;;
    *) die "secret scheme $S_SCHEME cannot be loaded on a host" ;;
  esac
}

# Resolve a site's named secret (site.yaml .secrets.<name>.ref) and parse it.
secret_ref_of() {
  local site="$1" name="$2" ref
  ref="$(inv_q "$site" ".secrets.\"$name\".ref")"
  [ -n "$ref" ] || die "site $site has no secret named $name"
  secret_parse "$ref" || die "bad secret ref for $site.$name: $ref"
  printf '%s' "$ref"
}
