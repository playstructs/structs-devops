#!/usr/bin/env bash
# Build / update structs.app (share-link site) on the host.
#   structs-app-update.sh            pull both repos, sync assets, build, up, verify
#   structs-app-update.sh --no-pull  rebuild from the checkouts as they are
#   structs-app-update.sh --status   versions + health only, change nothing
# The image is built from $STRUCTS_APP_DIR plus game assets synced from
# $STRUCTS_UNIVERSE_DIR (a structs-desktop checkout: its structs-webapp
# submodule + frontend/ components). Both come from the site's host_env.
. "$(dirname "$0")/_bundle.sh"

APP_DIR="${STRUCTS_APP_DIR:?set host_env.STRUCTS_APP_DIR in site.yaml (sites that run structs.app only)}"
UNIVERSE_DIR="${STRUCTS_UNIVERSE_DIR:?set host_env.STRUCTS_UNIVERSE_DIR in site.yaml}"
LOCAL_URL="${STRUCTS_APP_LOCAL_URL:-http://127.0.0.1:8437/healthz}"
PUBLIC_URL="${STRUCTS_APP_PUBLIC_URL:?set host_env.STRUCTS_APP_PUBLIC_URL in site.yaml}"
CONTAINER="${STRUCTS_APP_CONTAINER:-$(basename "$APP_DIR")-structs-app-1}"
MODE="${1:-}"

status() {
  echo "structs-app      $(git -C "$APP_DIR" rev-parse --short HEAD 2>/dev/null || echo '?') ($(git -C "$APP_DIR" log -1 --format=%cs 2>/dev/null || echo '?'))"
  echo "structs-desktop  $(git -C "$UNIVERSE_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')"
  echo "webapp submodule $(git -C "$UNIVERSE_DIR/structs-webapp" rev-parse --short HEAD 2>/dev/null || echo '?')"
  [ -f "$APP_DIR/public/shared/SOURCE" ] && echo "assets built from $(tr '\n' ' ' < "$APP_DIR/public/shared/SOURCE")"
  docker image ls structs/structs-app --format 'image            {{.Repository}}:{{.Tag}} {{.ID}} ({{.CreatedSince}})' || true
  (cd "$APP_DIR" && docker compose ps --format 'container        {{.Name}} {{.Status}} {{.Ports}}') || true
  printf 'local healthz    '; curl -sS -m 10 "$LOCAL_URL" || echo "FAIL"; echo
  printf 'public healthz   '; curl -sS -m 10 -o /dev/null -w '%{http_code}\n' "$PUBLIC_URL" || echo "FAIL"
}

for d in "$APP_DIR" "$UNIVERSE_DIR"; do
  [ -d "$d/.git" ] || { echo "FATAL: missing checkout $d (see runbooks/structs-app.md one-time bring-up)" >&2; exit 1; }
done
[ -f "$APP_DIR/.env" ] || { echo "FATAL: $APP_DIR/.env missing (loopback port + PgBouncer DSN)" >&2; exit 1; }

case "$MODE" in
  --status) status; exit 0 ;;
  --no-pull) ;;
  "")
    echo "== pull"
    git -C "$APP_DIR" pull --ff-only
    git -C "$UNIVERSE_DIR" pull --ff-only
    git -C "$UNIVERSE_DIR" submodule update --init --depth 1 structs-webapp \
      || git -C "$UNIVERSE_DIR" submodule update --init structs-webapp
    ;;
  *) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

echo "== sync game assets into public/"
STRUCTS_UNIVERSE="$UNIVERSE_DIR" bash "$APP_DIR/scripts/sync.sh"
echo "== build + (re)create"
cd "$APP_DIR" || exit 1
docker compose build --pull
docker compose up -d
echo "== wait for healthy"
h=starting
for _ in $(seq 1 30); do
  h="$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo starting)"
  [ "$h" = "healthy" ] && break
  sleep 2
done
echo "health: $h"
[ "$h" = "healthy" ] || { docker compose logs --tail 40; exit 1; }
status
if ss -ltn | grep -qE '(^|[^0-9.])0\.0\.0\.0:8437|\*:8437'; then
  echo "FATAL: 8437 is published on all interfaces; set STRUCTS_APP_PORT=127.0.0.1:8437 in $APP_DIR/.env (Docker ports bypass UFW)" >&2
  exit 1
fi
echo "OK: structs.app updated"
