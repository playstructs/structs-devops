# Host probe (streamed). Env: PG_CONTAINER STRUCTS_TSA_CONTAINER. Read-only.
pgq "select 'tx_' || status || '=' || count(*) from signer.tx group by status" || { echo "pg_error=1"; exit 0; }
pgq "select 'oldest_pending_min=' || coalesce((extract(epoch from now()-min(created_at))/60)::int, 0) from signer.tx where status='pending'"
pgq "select 'pending_top=' || coalesce(string_agg(command || ':' || n, ',' order by n desc), '') from (select command::text, count(*) n from signer.tx where status='pending' group by 1 order by 2 desc limit 4) t"
pgq "select 'pending_older_24h=' || count(*) from signer.tx where status='pending' and created_at < now()-interval '24 hours'"
pgq "select 'errors_1h=' || count(*) from signer.tx where status='error' and updated_at > now()-interval '1 hour'"
pgq "select 'broadcast_1h=' || count(*) from signer.tx where status='broadcast' and updated_at > now()-interval '1 hour'"
pgq "select 'acct_' || coalesce(status::text,'none') || '=' || count(*) from signer.account group by status"
pgq "select 'stuck_' || state || '=' || count(*) from signer.tx_submission where state in ('prepared','sending','unknown') and updated_at < now()-interval '10 minutes' group by state" 2>/dev/null || true
pgq "select 'last_error=' || left(regexp_replace(coalesce(output,''), '\s+', ' ', 'g'), 160) from signer.tx where status='error' order by updated_at desc limit 1"
c="${STRUCTS_TSA_CONTAINER:-}"
if [ -n "$c" ]; then
  echo "tsa_state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)"
  echo "tsa_workers=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" 2>/dev/null | sed -n 's/^TSA_WORKERS=//p' | head -1)"
  echo "tsa_image=$(docker inspect -f '{{.Image}}' "$c" 2>/dev/null | cut -c1-19)"
fi
