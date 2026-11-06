# shellcheck shell=bash
# Sourced by every check. Checks are read-only and never use set -e: a failed
# probe is a finding (UNKNOWN/CRIT), not a crash.
set -uo pipefail
. "$DEVOPS_ROOT/lib/common.sh"
. "$DEVOPS_ROOT/lib/inventory.sh"
. "$DEVOPS_ROOT/lib/ssh.sh"
. "$DEVOPS_ROOT/lib/chain.sh"
. "$DEVOPS_ROOT/lib/check.sh"

# Hosts of a site that are real Linux hosts (not the hub itself).
remote_hosts() {
  local h
  for h in $(inv_host_ids "$1"); do
    [ "$(ssh_target "$1" "$h")" = "local" ] || echo "$h"
  done
}

# Host that runs a stack (stack.host, else the site's primary host).
stack_host() {
  local h
  h="$(inv_stack "$1" "$2" host)"
  printf '%s' "${h:-$(inv_primary_host "$1")}"
}

# py EXPR -> python3 evaluation of a numeric expression
py() { python3 -c "print($1)"; }
