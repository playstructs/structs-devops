# shellcheck shell=bash
# Operation tiers. Every action carries one so the operator and the audit log
# know what kind of change it was. Only on-chain transactions stop for approval.
#
#   0 read-only                       runs
#   1 changes files or config         runs; callers print where backups went
#   2 affects running services        runs; logged
#   3 on-chain transaction            Approval Block + single-use token (exit 10);
#                                     the block includes signer, chain id, simulate output
#
# Callers set optional context before calling gate:
#   GATE_SITE GATE_HOST GATE_EFFECT GATE_ROLLBACK GATE_VERIFY GATE_EXTRA
# and then:  gate <tier> "<title>" "<exact action>"
# gate returns 0 when the action may run; for tier 3 without an approval it
# prints the block and exits 10.

GATE_EXIT_APPROVAL=10
APPROVAL_TTL_SECONDS="${APPROVAL_TTL_SECONDS:-600}"

_tier_name() {
  case "$1" in
    0) echo "read-only" ;;
    1) echo "changes files or config" ;;
    2) echo "affects running services" ;;
    3) echo "on-chain transaction" ;;
    *) echo "unknown" ;;
  esac
}

audit() {
  mkdir -p "$DEVOPS_REPORTS"
  printf '%s\t%s\n' "$(iso_now)" "$*" >> "$DEVOPS_REPORTS/audit.log"
}

_gate_key() {
  printf '%s\n%s\n%s\n%s\n' "$1" "${GATE_SITE:-}" "${GATE_HOST:-}" "$2" | sha_short
}

_gate_block() {
  local tier="$1" title="$2" action="$3" token="${4:-}" expires="${5:-}"
  local rerun="devops ${DEVOPS_RERUN:-${DEVOPS_ARGV:-<same command>}}"
  echo "==================== APPROVAL REQUIRED: $(_tier_name "$tier") ===================="
  echo "Action:   $title"
  [ -n "${GATE_SITE:-}" ] && echo "Site:     $GATE_SITE${GATE_SITE_KIND:+ (kind: $GATE_SITE_KIND)}"
  [ -n "${GATE_HOST:-}" ] && echo "Host:     $GATE_HOST"
  echo "Command:"
  printf '%s\n' "$action" | sed 's/^/  /'
  [ -n "${GATE_EFFECT:-}" ]   && echo "Effect:   $GATE_EFFECT"
  [ -n "${GATE_ROLLBACK:-}" ] && echo "Rollback: $GATE_ROLLBACK"
  [ -n "${GATE_VERIFY:-}" ]   && echo "Verify:   $GATE_VERIFY"
  if [ -n "${GATE_EXTRA:-}" ]; then
    echo "Details:"
    printf '%s\n' "$GATE_EXTRA" | sed 's/^/  /'
  fi
  if [ -n "$token" ]; then
    echo "Token:    $token (single use, expires $expires)"
    echo "Ask the user to approve this exact transaction. Only after they say yes, re-run:"
    echo "  $rerun --approve $token"
  fi
  echo "==================================================================================="
}

gate() {
  local tier="$1" title="$2" action="$3"
  if [ "$tier" -le 2 ]; then
    [ "$tier" -ge 1 ] && audit "RAN tier=$tier site=${GATE_SITE:-} host=${GATE_HOST:-} action=$(printf '%s' "$title" | tr '\n\t' '  ')"
    return 0
  fi

  local key adir now
  key="$(_gate_key "$tier" "$action")"
  adir="$(mkstate approvals)"
  now="$(now_epoch)"

  if [ -n "${DEVOPS_APPROVE:-}" ]; then
    local f="$adir/$DEVOPS_APPROVE" created="" fkey=""
    if [ -f "$f" ]; then
      read -r created fkey < "$f" || true
      if [ "$fkey" != "$key" ]; then
        err "approval token $DEVOPS_APPROVE was issued for a different transaction; issuing a new block"
      elif [ $(( now - created )) -gt "$APPROVAL_TTL_SECONDS" ]; then
        rm -f "$f"
        err "approval token $DEVOPS_APPROVE expired; issuing a new block"
      else
        rm -f "$f"
        audit "APPROVED tier=$tier via=token token=$DEVOPS_APPROVE site=${GATE_SITE:-} host=${GATE_HOST:-} key=$key action=$(printf '%s' "$title" | tr '\n\t' '  ')"
        return 0
      fi
    else
      err "unknown or already-used approval token: $DEVOPS_APPROVE"
    fi
  fi

  if ! is_agent && has_tty; then
    _gate_block "$tier" "$title" "$action" >/dev/tty
    if tty_confirm "Proceed?"; then
      audit "APPROVED tier=$tier via=tty site=${GATE_SITE:-} host=${GATE_HOST:-} key=$key action=$(printf '%s' "$title" | tr '\n\t' '  ')"
      return 0
    fi
    die "not approved"
  fi

  local token expires
  token="$(openssl rand -hex 4 2>/dev/null || printf '%04x%04x' "$RANDOM" "$RANDOM")"
  printf '%s %s\n' "$now" "$key" > "$adir/$token"
  expires="$(date -r $(( now + APPROVAL_TTL_SECONDS )) +%H:%M 2>/dev/null || date -d "@$(( now + APPROVAL_TTL_SECONDS ))" +%H:%M)"
  audit "REQUESTED tier=$tier token=$token site=${GATE_SITE:-} host=${GATE_HOST:-} key=$key action=$(printf '%s' "$title" | tr '\n\t' '  ')"
  _gate_block "$tier" "$title" "$action" "$token" "$expires"
  exit "$GATE_EXIT_APPROVAL"
}

# Load the site and its kind into the gate context.
gate_site() {
  GATE_SITE="$1"
  GATE_SITE_KIND="$(inv_kind "$1" 2>/dev/null || true)"
}
