-- Write amplification and vacuum health. Known: delete-and-reinsert on
-- api_leaderboard_player / api_inventory, and indexes on updated_at/val that
-- block HOT updates on grid, struct_attribute, planet_attribute.
\echo '== most-updated tables: HOT ratio, dead tuples, last vacuum'
SELECT schemaname || '.' || relname AS tbl, n_tup_ins, n_tup_upd, n_tup_del,
       round(100.0 * n_tup_hot_upd / nullif(n_tup_upd, 0), 1) AS hot_pct,
       n_live_tup, n_dead_tup,
       round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
       last_autovacuum, autovacuum_count, last_autoanalyze
FROM pg_stat_user_tables
ORDER BY n_tup_upd + n_tup_del DESC
LIMIT 20;

\echo '== most dead tuples'
SELECT schemaname || '.' || relname AS tbl, n_dead_tup, n_live_tup, last_autovacuum, last_vacuum
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC
LIMIT 15;

\echo '== autovacuum workers running'
SELECT pid, now() - xact_start AS running_for, left(query, 120) AS query
FROM pg_stat_activity WHERE backend_type = 'autovacuum worker';

\echo '== table storage options (fillfactor, autovacuum overrides)'
SELECT n.nspname || '.' || c.relname AS tbl, c.reloptions
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.reloptions IS NOT NULL AND n.nspname IN ('structs', 'signer', 'sync_state', 'view')
ORDER BY 1;

\echo '== oldest transaction ids (wraparound margin)'
SELECT datname, age(datfrozenxid) AS xid_age FROM pg_database ORDER BY 2 DESC;
