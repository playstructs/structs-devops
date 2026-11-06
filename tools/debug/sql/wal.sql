\echo '== WAL volume since stats reset'
SELECT wal_records, wal_fpi, pg_size_pretty(wal_bytes) AS wal_bytes, wal_buffers_full, stats_reset
FROM pg_stat_wal;

\echo '== checkpoints (PostgreSQL 17+)'
SELECT * FROM pg_stat_checkpointer;

\echo '== WAL settings'
SELECT name, setting, unit FROM pg_settings
WHERE name IN ('wal_level', 'max_wal_size', 'min_wal_size', 'checkpoint_timeout', 'checkpoint_completion_target',
               'wal_compression', 'full_page_writes', 'synchronous_commit', 'archive_mode', 'wal_keep_size')
ORDER BY name;

\echo '== pg_wal directory'
SELECT count(*) AS segments, pg_size_pretty(sum(size)) AS total FROM pg_ls_waldir();

\echo '== replication slots (an inactive slot retains WAL forever)'
SELECT slot_name, slot_type, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots;
