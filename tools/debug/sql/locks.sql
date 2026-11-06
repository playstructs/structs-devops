\echo '== blocked backends and who blocks them'
SELECT a.pid, pg_blocking_pids(a.pid) AS blocked_by, a.usename, a.application_name,
       now() - a.query_start AS waiting_for, a.wait_event_type, a.wait_event,
       left(regexp_replace(a.query, '\s+', ' ', 'g'), 160) AS query
FROM pg_stat_activity a
WHERE cardinality(pg_blocking_pids(a.pid)) > 0
ORDER BY a.query_start;

\echo '== blockers (sessions that others wait on)'
SELECT b.pid, b.usename, b.application_name, b.state, now() - b.xact_start AS xact_age,
       left(regexp_replace(b.query, '\s+', ' ', 'g'), 160) AS query
FROM pg_stat_activity b
WHERE b.pid IN (SELECT unnest(pg_blocking_pids(pid)) FROM pg_stat_activity);

\echo '== ungranted locks'
SELECT l.pid, l.locktype, l.mode, coalesce(n.nspname || '.' || c.relname, l.locktype) AS object
FROM pg_locks l
LEFT JOIN pg_class c ON c.oid = l.relation
LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE NOT l.granted;

\echo '== lock counts by relation and mode (top 20)'
SELECT coalesce(n.nspname || '.' || c.relname, l.locktype) AS object, l.mode, l.granted, count(*)
FROM pg_locks l
LEFT JOIN pg_class c ON c.oid = l.relation
LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
GROUP BY 1, 2, 3
ORDER BY 4 DESC
LIMIT 20;
