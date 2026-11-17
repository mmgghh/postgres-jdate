-- Mixed workload: one transaction that writes (ledger kept in step) and then
-- reads. One run in twenty also forces a parallel plan.
\set day random(0, 1183019)
\set lo random(0, 1100000)
\set hi least(:lo + 2000, 1183019)
\set tz random(1, 5)
\set par random(1, 20)
SELECT set_config('TimeZone', (ARRAY['UTC', 'Asia/Tehran', 'America/New_York', 'Pacific/Kiritimati', 'Etc/GMT+12'])[:tz], false);
BEGIN;
WITH i AS (
    INSERT INTO jd_stress (d, owner)
    VALUES ('-0061-01-01'::jdate + :day, :client_id)
    RETURNING 1)
UPDATE jd_ledger SET n = n + (SELECT count(*) FROM i) WHERE owner = :client_id;
SELECT count(*), min(d), max(d) FROM jd_stress WHERE owner = :client_id;
SELECT jdate_part('year', d), jdate_trunc('year', d), jdate_format(d::timestamptz)
  FROM jd_stress WHERE owner = :client_id AND d BETWEEN '-0061-01-01'::jdate + :lo AND '-0061-01-01'::jdate + :hi LIMIT 20;
COMMIT;
\if :par = 1
BEGIN;
SET LOCAL parallel_setup_cost = 0;
SET LOCAL parallel_tuple_cost = 0;
SET LOCAL min_parallel_table_scan_size = 0;
SET LOCAL max_parallel_workers_per_gather = 2;
SELECT count(*), min(d), max(d), count(DISTINCT jdate_part('month', d)) FROM jd_stress;
COMMIT;
\endif
