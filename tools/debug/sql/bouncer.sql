-- PgBouncer admin console (run against the bouncer, not structs-pg). SHOW only.
-- cl_waiting > 0 for long means the pool (transaction mode, 30) is exhausted.
\echo '== pools'
SHOW POOLS;
\echo '== databases (pool sizes per alias)'
SHOW DATABASES;
\echo '== traffic and wait times'
SHOW STATS;
\echo '== server connections'
SHOW SERVERS;
\echo '== lists'
SHOW LISTS;
