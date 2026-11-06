# shellcheck shell=bash
# Remote execution. The hub always connects outbound with BatchMode; hosts
# never call back. A host whose ssh field is "local" runs on the hub itself.

_ssh_opts() {
  printf '%s\n' -o BatchMode=yes -o "ConnectTimeout=${DEVOPS_SSH_TIMEOUT:-10}" \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3
  # One multiplexed connection per host for a whole health run. The socket
  # lives in /tmp because the workspace path may contain spaces.
  if [ -z "${DEVOPS_SSH_NOMUX:-}" ]; then
    printf '%s\n' -o ControlMaster=auto -o "ControlPath=/tmp/devops-ssh-$(id -u)-%C" -o ControlPersist=120
  fi
  if [ -n "${DEVOPS_SSH_OPTS:-}" ]; then
    # shellcheck disable=SC2086
    printf '%s\n' $DEVOPS_SSH_OPTS
  fi
}

ssh_target() { inv_host "$1" "$2" ssh; }

# host_run SITE HOST "command string"
# Never reads the caller's stdin, so it is safe inside `while read` loops.
host_run() {
  local site="$1" host="$2" cmd="$3" target
  target="$(ssh_target "$site" "$host")"
  [ -n "$target" ] || die "no ssh target for $site:$host"
  if [ "$target" = "local" ]; then
    (cd "$DEVOPS_ROOT" && bash -c "$cmd" </dev/null)
  else
    local opts=() o
    while IFS= read -r o; do opts+=("$o"); done < <(_ssh_opts)
    ssh -n "${opts[@]}" "$target" "$cmd"
  fi
}

# host_script SITE HOST SCRIPT [ARGS...]
# Streams a local script to `bash -s` on the host. Extra environment for the
# remote script goes in HOST_ENV as "K=V" lines (values are %q-quoted).
host_script() {
  local site="$1" host="$2" script="$3"; shift 3
  local target prefix="" line k v args=""
  target="$(ssh_target "$site" "$host")"
  [ -n "$target" ] || die "no ssh target for $site:$host"
  [ -f "$script" ] || die "missing script: $script"
  if [ -n "${HOST_ENV:-}" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      k="${line%%=*}"; v="${line#*=}"
      prefix="$prefix $k=$(printf '%q' "$v")"
    done <<EOF
$HOST_ENV
EOF
  fi
  [ $# -gt 0 ] && args="$(quote_argv "$@")"
  if [ "$target" = "local" ]; then
    eval "env $prefix bash -s -- $args" < "$script"
  else
    local opts=() o
    while IFS= read -r o; do opts+=("$o"); done < <(_ssh_opts)
    ssh "${opts[@]}" "$target" "env $prefix bash -s -- $args" < "$script"
  fi
}

# host_bundle SITE HOST PREAMBLE SCRIPT [ARGS...]
# Streams tools/host/_prelude.sh + PREAMBLE lines + SCRIPT as one script.
# Use PREAMBLE for generated lines such as secret_load_snippet output.
host_bundle() {
  local site="$1" host="$2" pre="$3" script="$4"; shift 4
  local tmp rc=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/devops-bundle.XXXXXX")"
  # Wrapped in a function so bash parses the whole script before running it;
  # otherwise any command that reads stdin would swallow the rest of the script.
  {
    echo '__devops_main() {'
    cat "$DEVOPS_ROOT/tools/host/_prelude.sh"
    printf '%s\n' "$pre"
    cat "$script"
    echo '}'
    echo '__devops_main "$@" </dev/null'
  } > "$tmp"
  host_script "$site" "$host" "$tmp" "$@" || rc=$?
  rm -f "$tmp"
  return "$rc"
}

# host_copy SITE HOST LOCAL_PATH REMOTE_PATH (single file, via ssh cat)
host_copy() {
  local site="$1" host="$2" src="$3" dst="$4" target
  target="$(ssh_target "$site" "$host")"
  if [ "$target" = "local" ]; then
    mkdir -p "$(dirname "$dst")" && cp "$src" "$dst"
  else
    local opts=() o
    while IFS= read -r o; do opts+=("$o"); done < <(_ssh_opts)
    ssh "${opts[@]}" "$target" "mkdir -p $(printf '%q' "$(dirname "$dst")") && cat > $(printf '%q' "$dst")" < "$src"
  fi
}

# Can we reach the host non-interactively?
host_ping() {
  local site="$1" host="$2"
  host_run "$site" "$host" 'echo ok' 2>/dev/null | grep -q '^ok$'
}
