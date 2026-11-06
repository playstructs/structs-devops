# Host probe (streamed). Env: PG_CONTAINER. Read-only SQL (pgq runs READ ONLY).
pgq "select 'conn=' || count(*) from pg_stat_activity" || { echo "pg_error=1"; exit 0; }
pgq "select 'max_conn=' || setting from pg_settings where name='max_connections'"
pgq "select 'reserved=' || setting from pg_settings where name='superuser_reserved_connections'"
pgq "select 'state_' || replace(coalesce(state,'none'),' ','_') || '=' || count(*) from pg_stat_activity group by state"
pgq "select 'user_' || coalesce(usename,'none') || '=' || count(*) from pg_stat_activity group by usename order by count(*) desc limit 10"
pgq "select 'idle_in_tx_5m=' || count(*) from pg_stat_activity where state like 'idle in transaction%' and now()-state_change > interval '5 minutes'"
pgq "select 'longest_active_s=' || coalesce(max(extract(epoch from now()-query_start))::int,0) from pg_stat_activity where state='active' and pid<>pg_backend_pid() and backend_type='client backend'"
pgq "select 'longest_active_q=' || left(regexp_replace(query, '\s+', ' ', 'g'), 120) from pg_stat_activity where state='active' and pid<>pg_backend_pid() and backend_type='client backend' order by query_start limit 1"
pgq "select 'blocked=' || count(*) from pg_locks where not granted"
pgq "select 'xid_age=' || max(age(datfrozenxid)) from pg_database"
pgq "select 'db_size=' || pg_size_pretty(pg_database_size(current_database()))"
pgq "select 'cron_failed_1h=' || count(*) from cron.job_run_details where status='failed' and start_time > now()-interval '1 hour'" 2>/dev/null || true
