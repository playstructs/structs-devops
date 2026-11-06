# shellcheck shell=bash
# Operation tiers, enforced here so they apply no matter which harness (or
# human) is driving.
#
#   0 read-only            runs freely
#   1 reversible + backup  runs; callers print where backups went
#   2 service-affecting    Approval Block + single-use token (exit 10)
#   3 irreversible         same as 2; block must include signer, chain-id, simulate output
#
# Callers set optional context before calling gate:
#   GATE_SITE GATE_HOST GATE_EFFECT GATE_ROLLBACK GATE_VERIFY GATE_EXTRA
# and then:  gate <tier> "<title>" "<exact action>"
# gate returns 0 when approved; otherwise it prints the block and exits 10.

GATE_EXIT_APPROVAL=10
APPROVAL_TTL_SECONDS="${APPROVAL_TTL_SECONDS:-600}"

_tier_name() {
  case "$1" in
    0) echo "read-only" ;;
    1) echo "reversible with backup" ;;
    2) echo "service-affecting" ;;
    3) echo "irreversible / on-chain / keys" ;;
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
  echo "==================== APPROVAL REQUIRED: tier $tier ($(_tier_name "$tier")) ===================="
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
  if [ "${GATE_SITE_KIND:-}" = "public-node" ]; then
    echo "PUBLIC NODE: other sites and external users depend on it (${GATE_DEPENDENTS:-see site.yaml dependents})."
    echo "            Announce first; the re-run also needs --yes-public."
  fi
  if [ -n "$token" ]; then
    echo "Token:    $token (single use, expires $expires)"
    echo "Ask the user to approve this exact action. Only after they say yes, re-run:"
    echo "  $rerun --approve $token${GATE_NEEDS_PUBLIC:+ --yes-public}"
  fi
  echo "=========================================================================================="
}

gate() {
  local tier="$1" title="$2" action="$3"
  [ "$tier" -le 1 ] && return 0

  # Inside an approved `devops deploy` run: the procedure was approved as a
  # whole (site + max tier), so its steps do not re-prompt.
  if [ -n "${DEVOPS_PROCEDURE_TOKEN:-}" ]; then
    local pf pcreated="" pmax="" psite=""
    pf="$(mkstate approvals)/procedure-$DEVOPS_PROCEDURE_TOKEN"
    if [ -f "$pf" ]; then
      read -r pcreated pmax psite < "$pf" || true
      if [ "$tier" -le "${pmax:-0}" ] && [ "$psite" = "${GATE_SITE:-}" ] \
         && [ $(( $(now_epoch) - ${pcreated:-0} )) -le 7200 ]; then
        audit "APPROVED tier=$tier via=procedure token=$DEVOPS_PROCEDURE_TOKEN site=${GATE_SITE:-} host=${GATE_HOST:-} action=$(printf '%s' "$title" | tr '\n\t' '  ')"
        return 0
      fi
    fi
  fi

  GATE_NEEDS_PUBLIC=""
  if [ "${GATE_SITE_KIND:-}" = "public-node" ] && [ "${DEVOPS_YES_PUBLIC:-}" != "1" ]; then
    GATE_NEEDS_PUBLIC=1
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
        err "approval token $DEVOPS_APPROVE was issued for a different action; issuing a new block"
      elif [ $(( now - created )) -gt "$APPROVAL_TTL_SECONDS" ]; then
        rm -f "$f"
        err "approval token $DEVOPS_APPROVE expired; issuing a new block"
      elif [ -n "$GATE_NEEDS_PUBLIC" ]; then
        err "public-node action also needs --yes-public"
      else
        rm -f "$f"
        audit "APPROVED tier=$tier via=token token=$DEVOPS_APPROVE site=${GATE_SITE:-} host=${GATE_HOST:-} key=$key action=$(printf '%s' "$title" | tr '\n\t' '  ')"
        return 0
      fi
    else
      err "unknown or already-used approval token: $DEVOPS_APPROVE"
    fi
  fi

  if ! is_agent && has_tty && [ -z "$GATE_NEEDS_PUBLIC" ]; then
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

# Load site kind/dependents into the gate context.
gate_site() {
  GATE_SITE="$1"
  GATE_SITE_KIND="$(inv_kind "$1" 2>/dev/null || true)"
  GATE_DEPENDENTS="$(inv_q "$1" '.dependents // [] | join(", ")' 2>/dev/null || true)"
}
