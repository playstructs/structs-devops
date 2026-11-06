# Host side of devops logs (streamed). Read-only; output is redacted.
# Env: LOG_CONTAINER LOG_LINES LOG_SINCE LOG_GREP
docker inspect "$LOG_CONTAINER" >/dev/null 2>&1 || { echo "no container $LOG_CONTAINER on $(hostname)" >&2; exit 1; }
if [ -n "${LOG_SINCE:-}" ]; then
  clog "$LOG_CONTAINER" --since "$LOG_SINCE" ts
else
  clog "$LOG_CONTAINER" --tail "${LOG_LINES:-200}" ts
fi | { if [ -n "${LOG_GREP:-}" ]; then grep -E -- "$LOG_GREP" || true; else cat; fi; } |
  tail -n "${LOG_LINES:-200}" | redact
