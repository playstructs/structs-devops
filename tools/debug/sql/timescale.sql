\echo '== extension versions'
SELECT extname, extversion FROM pg_extension WHERE extname IN ('timescaledb', 'pg_cron', 'pg_stat_statements') ORDER BY 1;

\echo '== hypertables'
SELECT hypertable_schema || '.' || hypertable_name AS hypertable, num_chunks, compression_enabled,
       pg_size_pretty(hypertable_size(format('%I.%I', hypertable_schema, hypertable_name)::regclass)) AS size
FROM timescaledb_information.hypertables
ORDER BY hypertable_size(format('%I.%I', hypertable_schema, hypertable_name)::regclass) DESC;

\echo '== background jobs (policies) and their last run'
SELECT j.job_id, j.application_name, j.hypertable_name, j.schedule_interval,
       s.last_run_status, s.last_run_started_at, s.total_runs, s.total_failures, s.next_start
FROM timescaledb_information.jobs j
LEFT JOIN timescaledb_information.job_stats s USING (job_id)
ORDER BY s.total_failures DESC NULLS LAST, j.job_id;

\echo '== job errors, last 7 days'
SELECT job_id, proc_name, start_time, left(err_message, 160) AS err
FROM timescaledb_information.job_errors
WHERE start_time > now() - interval '7 days'
ORDER BY start_time DESC
LIMIT 15;
