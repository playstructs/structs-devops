-- Temp files come from sorts/hashes larger than work_mem. On our guilds they
-- were all deep OFFSET paging (/api/*/all/page/N with LIMIT 10000 OFFSET n).
\echo '== temp files for this database since stats reset'
SELECT datname, temp_files, pg_size_pretty(temp_bytes) AS temp_bytes, stats_reset
FROM pg_stat_database WHERE datname = current_database();

\echo '== statements writing temp blocks'
SELECT s.temp_blks_written, s.calls, round(s.mean_exec_time::numeric, 1) AS mean_ms,
       left(regexp_replace(s.query, '\s+', ' ', 'g'), 180) AS query
FROM pg_stat_statements s
WHERE s.temp_blks_written > 0
ORDER BY s.temp_blks_written DESC
LIMIT 15;

\echo '== OFFSET-paged statements (look for LIMIT/OFFSET on large views)'
SELECT s.calls, round(s.mean_exec_time::numeric, 1) AS mean_ms, s.temp_blks_written,
       left(regexp_replace(s.query, '\s+', ' ', 'g'), 180) AS query
FROM pg_stat_statements s
WHERE s.query ILIKE '%offset%'
ORDER BY s.total_exec_time DESC
LIMIT 10;

\echo '== memory settings'
SELECT name, setting, unit FROM pg_settings
WHERE name IN ('work_mem', 'hash_mem_multiplier', 'maintenance_work_mem', 'temp_file_limit', 'log_temp_files', 'shared_buffers')
ORDER BY name;
