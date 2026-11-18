-- Write workload: insert, update and delete this client's own rows. Every
-- change updates the client's ledger row in the same transaction, so the
-- ledger always equals the number of rows the client owns.
-- The day offsets are cast to int: under -M extended and -M prepared pgbench sends
-- them as untyped parameters, and jdate + $1 is ambiguous (42725) between the
-- integer, interval and time forms of the operator.
\set day random(0, 1183019)
\set upd random(0, 1183019)
\set dlo random(0, 1183019)
\set dhi least(:dlo + 20000, 1183019)
\set tz random(1, 5)
SELECT set_config('TimeZone', (ARRAY['UTC', 'Asia/Tehran', 'America/New_York', 'Pacific/Kiritimati', 'Etc/GMT+12'])[:tz], false);
BEGIN;
WITH i AS (
    INSERT INTO jd_stress (d, owner)
    VALUES ('-0061-01-01'::jdate + :day::int, :client_id),
           ('-0061-01-01'::jdate + :upd::int, :client_id),
           (('-0061-01-01'::jdate + :dlo::int)::timestamptz::jdate, :client_id)
    RETURNING 1)
UPDATE jd_ledger SET n = n + (SELECT count(*) FROM i) WHERE owner = :client_id;
UPDATE jd_stress SET d = d + 1
 WHERE owner = :client_id
   AND d BETWEEN '-0061-01-01'::jdate + :upd::int AND '-0061-01-01'::jdate + least(:upd + 500, 1183018);
WITH x AS (
    DELETE FROM jd_stress
     WHERE owner = :client_id
       AND d BETWEEN '-0061-01-01'::jdate + :dlo::int AND '-0061-01-01'::jdate + :dhi::int
    RETURNING 1)
UPDATE jd_ledger SET n = n - (SELECT count(*) FROM x) WHERE owner = :client_id;
COMMIT;
