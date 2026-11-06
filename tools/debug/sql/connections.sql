-- Connection budget. structs-pg runs max_connections 100; the webapp goes
-- through PgBouncer (transaction pool 30), TSA, sync-state and the crawler
-- connect directly to structs-pg:5432.
\echo '== budget'
SELECT (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') AS max_connections,
       (SELECT setting::int FROM pg_settings WHERE name = 'superuser_reserved_connections') AS superuser_reserved,
       (SELECT setting FROM pg_settings WHERE name = 'reserved_connections') AS reserved,
       count(*) AS in_use,
       count(*) FILTER (WHERE backend_type = 'client backend') AS client_backends
FROM pg_stat_activity;

\echo '== by user and application'
SELECT usename, application_name, count(*) AS n,
       count(*) FILTER (WHERE state = 'active') AS active,
       count(*) FILTER (WHERE state = 'idle') AS idle,
       count(*) FILTER (WHERE state LIKE 'idle in transaction%') AS idle_in_tx
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY 1, 2
ORDER BY n DESC;

\echo '== by client address (bouncer, containers)'
SELECT client_addr, usename, count(*) AS n
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY 1, 2
ORDER BY n DESC
LIMIT 15;

\echo '== per-role connection limits'
SELECT rolname, rolconnlimit FROM pg_roles WHERE rolcanlogin ORDER BY rolname;
