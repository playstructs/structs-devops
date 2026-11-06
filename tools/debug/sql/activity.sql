-- What every backend is doing right now. Pair with the host CPU list the
-- runner prints after this pack (docker top on the structs-pg container).
\echo '== client backends by user, application, state'
SELECT usename, application_name, state, count(*) AS n,
       max(now() - state_change) AS longest_in_state
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY 1, 2, 3
ORDER BY n DESC;

\echo '== non-idle backends, oldest query first'
SELECT pid, usename, application_name, state, wait_event_type, wait_event,
       now() - xact_start AS xact_age, now() - query_start AS query_age,
       left(regexp_replace(query, '\s+', ' ', 'g'), 200) AS query
FROM pg_stat_activity
WHERE backend_type = 'client backend' AND state <> 'idle' AND pid <> pg_backend_pid()
ORDER BY query_start
LIMIT 30;

\echo '== idle in transaction > 1 min (hold locks and block vacuum)'
SELECT pid, usename, application_name, now() - state_change AS idle_for,
       left(regexp_replace(query, '\s+', ' ', 'g'), 160) AS last_query
FROM pg_stat_activity
WHERE state LIKE 'idle in transaction%' AND now() - state_change > interval '1 minute'
ORDER BY state_change;

\echo '== background workers'
SELECT backend_type, count(*) FROM pg_stat_activity GROUP BY 1 ORDER BY 2 DESC;
