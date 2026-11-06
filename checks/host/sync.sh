# Host probe (streamed). Env: PG_CONTAINER. Read-only.
pgq "select 'cursor=' || chain_id || '|' || last_height || '|' || coalesce(tip_height::text,'') || '|' || coalesce(lag_blocks::text,'') || '|' || coalesce(status,'') || '|' || extract(epoch from now()-updated_at)::int || '|' || coalesce(extract(epoch from now()-last_block_time)::int::text,'') from sync_state.sync_cursor" || { echo "pg_error=1"; exit 0; }
pgq "select 'handler_errors_1h=' || coalesce(sum(num_handler_errors),0) from sync_state.block_log where ingested_at > now()-interval '1 hour'"
pgq "select 'blocks_1h=' || count(*) from sync_state.block_log where ingested_at > now()-interval '1 hour'"
pgq "select 'proj_' || model || '=' || extract(epoch from now()-refreshed_at)::int || '|' || coalesce(source_height::text,'') from structs.api_refresh_state" 2>/dev/null || true
pgq "select 'ready=' || coalesce(data_ready::text,'null') || '|' || coalesce(transaction_ready::text,'null') || '|' || coalesce(indexed_height,'') || '|' || coalesce(observed_tip,'') from structs.api_readiness(ARRAY['inventory','work']::text[])" 2>/dev/null | head -1 || true
