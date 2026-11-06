-- pg_stat_statements (track=all on structs-pg). Totals since stats_reset.
\echo '== stats window'
SELECT stats_reset, dealloc FROM pg_stat_statements_info;

\echo '== top 20 by total execution time'
SELECT round(s.total_exec_time::numeric / 1000) AS total_s, s.calls,
       round(s.mean_exec_time::numeric, 1) AS mean_ms, round(s.max_exec_time::numeric) AS max_ms,
       s.rows, s.temp_blks_written AS temp_blks, r.rolname,
       left(regexp_replace(s.query, '\s+', ' ', 'g'), 160) AS query
FROM pg_stat_statements s LEFT JOIN pg_roles r ON r.oid = s.userid
ORDER BY s.total_exec_time DESC
LIMIT 20;

\echo '== top 15 by mean time (calls >= 20)'
SELECT round(s.mean_exec_time::numeric, 1) AS mean_ms, s.calls,
       round(s.total_exec_time::numeric / 1000) AS total_s, r.rolname,
       left(regexp_replace(s.query, '\s+', ' ', 'g'), 160) AS query
FROM pg_stat_statements s LEFT JOIN pg_roles r ON r.oid = s.userid
WHERE s.calls >= 20
ORDER BY s.mean_exec_time DESC
LIMIT 15;

\echo '== top 10 by shared blocks read from disk'
SELECT s.shared_blks_read, s.shared_blks_hit, s.calls,
       left(regexp_replace(s.query, '\s+', ' ', 'g'), 160) AS query
FROM pg_stat_statements s
ORDER BY s.shared_blks_read DESC
LIMIT 10;

\echo '== time share by role'
SELECT r.rolname, round(sum(s.total_exec_time)::numeric / 1000) AS total_s,
       round(100 * sum(s.total_exec_time) / nullif((SELECT sum(total_exec_time) FROM pg_stat_statements), 0), 1) AS pct
FROM pg_stat_statements s LEFT JOIN pg_roles r ON r.oid = s.userid
GROUP BY 1
ORDER BY 2 DESC;
