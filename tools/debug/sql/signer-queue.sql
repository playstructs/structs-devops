-- TSA work queue: signer.tx (pending -> claimed -> broadcast | error) and
-- v0.22 submissions in signer.tx_submission.
\echo '== signer.tx by status'
SELECT status, count(*) AS n, min(created_at) AS oldest, max(updated_at) AS last_update
FROM signer.tx GROUP BY 1 ORDER BY 1;

\echo '== pending by command (older_24h rows are usually ineligible and re-checked on every claim)'
SELECT command, count(*) AS n, min(created_at) AS oldest,
       count(*) FILTER (WHERE created_at < now() - interval '24 hours') AS older_24h
FROM signer.tx WHERE status = 'pending'
GROUP BY 1 ORDER BY n DESC;

\echo '== pending by object (top 15)'
SELECT object_id, count(*) AS n, min(created_at) AS oldest, min(permission_requirement) AS perm
FROM signer.tx WHERE status = 'pending'
GROUP BY 1 ORDER BY n DESC LIMIT 15;

\echo '== claimed for more than 10 minutes'
SELECT id, command, object_id, account_id, now() - updated_at AS claimed_for
FROM signer.tx WHERE status = 'claimed' AND updated_at < now() - interval '10 minutes'
ORDER BY updated_at LIMIT 20;

\echo '== unresolved submissions'
SELECT state, count(*) AS n, min(updated_at) AS oldest, max(source_height) AS newest_source_height
FROM signer.tx_submission
WHERE state IN ('prepared', 'sending', 'unknown', 'accepted')
GROUP BY 1;

\echo '== submissions in the last hour by state, and the indexed height they must not fall behind'
SELECT state, count(*) AS n, min(source_height), max(source_height),
       (SELECT last_height FROM sync_state.sync_cursor LIMIT 1) AS indexed_height
FROM signer.tx_submission WHERE created_at > now() - interval '1 hour'
GROUP BY 1;

\echo '== latest 10 errors'
SELECT id, command, updated_at, left(regexp_replace(coalesce(output, ''), '\s+', ' ', 'g'), 200) AS output
FROM signer.tx WHERE status = 'error'
ORDER BY updated_at DESC LIMIT 10;

\echo '== throughput by hour, last 12 h'
SELECT date_trunc('hour', updated_at) AS hour, status, count(*)
FROM signer.tx WHERE updated_at > now() - interval '12 hours'
GROUP BY 1, 2 ORDER BY 1, 2;
