-- Sqitch registry (schema sqitch). structs-pg-auto-migrate deploys main every 120 s.
\echo '== deployed changes'
SELECT count(*) AS deployed, max(committed_at) AS last_deploy FROM sqitch.changes WHERE project = 'structs-pg';

\echo '== last 15 deployed changes'
SELECT change, committed_at, left(note, 80) AS note
FROM sqitch.changes WHERE project = 'structs-pg'
ORDER BY committed_at DESC LIMIT 15;

\echo '== last 10 registry events (deploy, revert, fail)'
SELECT event, change, committed_at
FROM sqitch.events WHERE project = 'structs-pg'
ORDER BY committed_at DESC LIMIT 10;

\echo '== contract-gated changes (the writer/signer contracts are session options of the auto-migrate container, not stored; see its env)'
SELECT change, committed_at
FROM sqitch.changes
WHERE project = 'structs-pg' AND change ~ '(denomination|20261030)'
ORDER BY committed_at DESC LIMIT 10;
