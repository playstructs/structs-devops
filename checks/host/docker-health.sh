# Host probe (streamed). Env: CONTAINER. Read-only.
echo "state=$(docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${CONTAINER:?}" 2>/dev/null || echo missing)"
echo "started=$(docker inspect -f '{{.State.StartedAt}}' "$CONTAINER" 2>/dev/null)"
echo "restarts=$(docker inspect -f '{{.RestartCount}}' "$CONTAINER" 2>/dev/null)"
