-- Ledger correctness. The reconciler only compares the index with itself, so
-- also compare balances with the LCD and the other guild's database.
-- Never "fix" a ledger by replaying blocks into a live database
-- (seen 2026-09-28 after history was replayed into a live database).
\echo '== negative amounts (expected 0)'
SELECT count(*) AS negative_rows FROM structs.ledger WHERE amount_p < 0;

SELECT id, block_height, address, counterparty, denom, action, direction, amount_p
FROM structs.ledger WHERE amount_p < 0 ORDER BY id LIMIT 20;

\echo '== ingestion rate per hour, last 48 h (a burst far above ~600 blocks/h is a backfill or replay)'
SELECT date_trunc('hour', ingested_at) AS hour, count(*) AS blocks, min(height), max(height)
FROM sync_state.block_log
WHERE ingested_at > now() - interval '48 hours'
GROUP BY 1 ORDER BY 1;

\echo '== identical ledger rows in the last 7 days (can be legitimate; compare with the LCD)'
SELECT block_height, address, denom, action, direction, amount_p, count(*) AS n
FROM structs.ledger
WHERE time > now() - interval '7 days'
GROUP BY 1, 2, 3, 4, 5, 6 HAVING count(*) > 1
ORDER BY 1 DESC LIMIT 20;

\echo '== api_inventory vs ledger (p_log=false: compares without logging; full scan, may hit the statement timeout)'
SELECT count(*) AS discrepancies FROM structs.api_inventory_reconcile(false);
