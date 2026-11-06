-- pg_cron. If these fail, pg_cron may live in another database: check cron.database_name.
\echo '== cron database'
SHOW cron.database_name;

\echo '== jobs'
SELECT jobid, jobname, schedule, active, left(regexp_replace(command, '\s+', ' ', 'g'), 100) AS command
FROM cron.job ORDER BY jobid;

\echo '== runs in the last 24 h by job and status'
SELECT j.jobname, d.status, count(*) AS runs, max(d.start_time) AS last_start,
       round(avg(extract(epoch FROM d.end_time - d.start_time))::numeric, 2) AS avg_s,
       round(max(extract(epoch FROM d.end_time - d.start_time))::numeric, 1) AS max_s
FROM cron.job_run_details d LEFT JOIN cron.job j USING (jobid)
WHERE d.start_time > now() - interval '24 hours'
GROUP BY 1, 2
ORDER BY 1, 2;

\echo '== last 10 failures'
SELECT j.jobname, d.start_time, left(regexp_replace(d.return_message, '\s+', ' ', 'g'), 200) AS message
FROM cron.job_run_details d LEFT JOIN cron.job j USING (jobid)
WHERE d.status = 'failed'
ORDER BY d.start_time DESC
LIMIT 10;

\echo '== still running (> 5 min)'
SELECT j.jobname, d.start_time, now() - d.start_time AS running_for
FROM cron.job_run_details d LEFT JOIN cron.job j USING (jobid)
WHERE d.status = 'running' AND d.start_time < now() - interval '5 minutes';

\echo '== history table size (grows unless purged)'
SELECT count(*) AS rows, pg_size_pretty(pg_total_relation_size('cron.job_run_details')) AS size FROM cron.job_run_details;
