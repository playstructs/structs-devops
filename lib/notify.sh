# shellcheck shell=bash
# Notifications. Channels come from DEVOPS_NOTIFY (comma list):
#   stdout  macos  ntfy  discord  matrix  webhook
# Channel credentials are local-env secrets in local/secrets.env:
#   NTFY_URL, DISCORD_WEBHOOK_URL, MATRIX_HOMESERVER, MATRIX_ROOM_ID,
#   MATRIX_ACCESS_TOKEN, NOTIFY_WEBHOOK_URL
# Everything is outbound from the hub.

_notify_secrets() {
  if [ -f "$DEVOPS_LOCAL/secrets.env" ] && [ -z "${_NOTIFY_SECRETS_LOADED:-}" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$DEVOPS_LOCAL/secrets.env"
    set +a
    _NOTIFY_SECRETS_LOADED=1
  fi
}

# notify SEVERITY TITLE BODY   (SEVERITY: OK|WARN|CRIT|UNKNOWN|INFO)
notify() {
  local sev="$1" title="$2" body="${3:-}" ch
  [ -n "${DEVOPS_NO_NOTIFY:-}" ] && return 0
  _notify_secrets
  for ch in $(printf '%s' "${DEVOPS_NOTIFY:-stdout}" | tr ',' ' '); do
    case "$ch" in
      stdout) printf '[%s] %s\n%s\n' "$sev" "$title" "$body" ;;
      macos)
        have osascript && osascript -e "display notification $(printf '%s' "$body" | head -c 200 | json_escape) with title $(printf '[%s] %s' "$sev" "$title" | json_escape)" >/dev/null 2>&1 || true
        ;;
      ntfy)
        [ -n "${NTFY_URL:-}" ] && curl -sS -m 10 -H "Title: [$sev] $title" \
          -H "Priority: $( [ "$sev" = CRIT ] && echo high || echo default)" -d "$body" "$NTFY_URL" >/dev/null 2>&1 || true
        ;;
      discord)
        [ -n "${DISCORD_WEBHOOK_URL:-}" ] && curl -sS -m 10 -H 'Content-Type: application/json' \
          -d "{\"content\": $(printf '**[%s] %s**\n%s' "$sev" "$title" "$body" | head -c 1900 | json_escape)}" \
          "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1 || true
        ;;
      matrix)
        if [ -n "${MATRIX_HOMESERVER:-}" ] && [ -n "${MATRIX_ROOM_ID:-}" ] && [ -n "${MATRIX_ACCESS_TOKEN:-}" ]; then
          curl -sS -m 10 -X PUT -H "Authorization: Bearer $MATRIX_ACCESS_TOKEN" -H 'Content-Type: application/json' \
            -d "{\"msgtype\":\"m.text\",\"body\":$(printf '[%s] %s\n%s' "$sev" "$title" "$body" | json_escape)}" \
            "$MATRIX_HOMESERVER/_matrix/client/v3/rooms/$MATRIX_ROOM_ID/send/m.room.message/devops$(now_epoch)$RANDOM" >/dev/null 2>&1 || true
        fi
        ;;
      webhook)
        [ -n "${NOTIFY_WEBHOOK_URL:-}" ] && curl -sS -m 10 -H 'Content-Type: application/json' \
          -d "{\"severity\":\"$sev\",\"title\":$(printf '%s' "$title" | json_escape),\"body\":$(printf '%s' "$body" | json_escape)}" \
          "$NOTIFY_WEBHOOK_URL" >/dev/null 2>&1 || true
        ;;
      "") ;;
      *) warn "unknown notify channel: $ch" ;;
    esac
  done
}

# notify_on_change KEY STATUS TITLE BODY
# Sends only when STATUS differs from the last one recorded for KEY, or as a
# reminder every DEVOPS_CRIT_REMIND_HOURS (default 6) while it stays CRIT.
notify_on_change() {
  local key="$1" status="$2" title="$3" body="${4:-}" d f last="" last_t=0 now remind
  d="$(mkstate alerts)"
  f="$d/$(printf '%s' "$key" | tr '/: ' '___')"
  now="$(now_epoch)"
  remind=$(( ${DEVOPS_CRIT_REMIND_HOURS:-6} * 3600 ))
  [ -f "$f" ] && read -r last last_t < "$f"
  if [ "$status" != "$last" ]; then
    if [ -n "$last" ] || [ "$status" != "OK" ]; then
      notify "$status" "$title" "${body}${last:+
(was $last)}"
    fi
    printf '%s %s\n' "$status" "$now" > "$f"
  elif [ "$status" = "CRIT" ] && [ $(( now - ${last_t:-0} )) -ge "$remind" ]; then
    notify "$status" "$title (still CRIT)" "$body"
    printf '%s %s\n' "$status" "$now" > "$f"
  fi
}
