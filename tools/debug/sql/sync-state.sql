-- The indexer (structs-sync-state) writes from structsd RPC into structs-pg.
\echo '== cursor'
SELECT chain_id, last_height, tip_height, lag_blocks, status,
       now() - updated_at AS updated_ago, now() - last_block_time AS block_age
FROM sync_state.sync_cursor;

\echo '== ingestion per 10 minutes, last 2 h'
SELECT date_trunc('hour', ingested_at) + floor(extract(minute FROM ingested_at) / 10) * interval '10 minutes' AS bucket,
       count(*) AS blocks, min(height), max(height), sum(num_handler_errors) AS handler_errors
FROM sync_state.block_log
WHERE ingested_at > now() - interval '2 hours'
GROUP BY 1 ORDER BY 1;

\echo '== unresolved handler errors by key'
SELECT composite_key, severity, count(*) AS n, min(height), max(height), max(created_at) AS latest
FROM sync_state.handler_error_log
WHERE resolved_at IS NULL
GROUP BY 1, 2 ORDER BY n DESC LIMIT 15;

\echo '== latest 15 unresolved handler errors'
SELECT height, composite_key, severity, left(regexp_replace(error, '\s+', ' ', 'g'), 160) AS error, created_at
FROM sync_state.handler_error_log
WHERE resolved_at IS NULL
ORDER BY id DESC LIMIT 15;

\echo '== unknown events (no handler for this event type)'
SELECT composite_key, count, first_seen_height, last_seen_height, last_seen_at
FROM sync_state.unknown_event_log
ORDER BY count DESC LIMIT 15;

\echo '== API projections: refresh age'
SELECT model, source_height, now() - refreshed_at AS age
FROM structs.api_refresh_state ORDER BY refreshed_at;

\echo '== readiness (what the webapp and TSA gate on)'
SELECT * FROM structs.api_readiness(ARRAY['inventory', 'work']::text[]);
