-- The TSA join pool: signer.account (stub, generating, pending, available,
-- signing) and the keys each TSA instance reports in signer.local_key.
\echo '== accounts by status'
SELECT status, count(*) AS n, min(updated_at) AS oldest_update, max(updated_at) AS newest_update
FROM signer.account GROUP BY 1 ORDER BY 1;

\echo '== accounts stuck in generating/pending/signing for > 10 min'
SELECT id, role_id, address, status, now() - updated_at AS stuck_for
FROM signer.account
WHERE status IN ('generating', 'pending', 'signing') AND updated_at < now() - interval '10 minutes'
ORDER BY updated_at LIMIT 20;

\echo '== local keys by state (fresh = heartbeat within 120 s)'
SELECT state, present, count(*) AS n,
       count(*) FILTER (WHERE seen_at > now() - interval '120 seconds') AS fresh_120s,
       min(seen_at) AS oldest_seen, max(seen_at) AS newest_seen
FROM signer.local_key GROUP BY 1, 2 ORDER BY 1, 2;

\echo '== key inventories (one per TSA accounts volume)'
SELECT inventory_id, count(*) AS keys, max(seen_at) AS last_heartbeat,
       max(observed_height) AS observed_height
FROM signer.local_key GROUP BY 1 ORDER BY 3 DESC;
