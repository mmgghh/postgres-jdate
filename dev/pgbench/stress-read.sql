-- Read workload: range scans, aggregates and the field/format functions under
-- a per-client TimeZone. Never writes.
\set lo random(0, 1100000)
\set hi least(:lo + 500, 1183019)
\set wide random(0, 1000000)
\set tz random(1, 5)
\set pt random(1, 6)
SELECT set_config('TimeZone', (ARRAY['UTC', 'Asia/Tehran', 'America/New_York', 'Pacific/Kiritimati', 'Etc/GMT+12'])[:tz], false);
SELECT count(*), min(d), max(d) FROM jd_stress
 WHERE d BETWEEN '-0061-01-01'::jdate + :lo AND '-0061-01-01'::jdate + :hi;
SELECT d, count(*) FROM jd_stress
 WHERE d BETWEEN '-0061-01-01'::jdate + :wide AND '-0061-01-01'::jdate + :wide + 100000
 GROUP BY d ORDER BY d LIMIT 5;
SELECT id FROM jd_stress WHERE d = '-0061-01-01'::jdate + :lo;
SELECT jdate_part((ARRAY['year', 'month', 'day', 'quarter', 'doy', 'dow'])[:pt], d),
       jdate_trunc('month', d), jdate_format(d::timestamptz), jdate_format(d::timestamptz, false)
  FROM jd_stress
 WHERE d BETWEEN '-0061-01-01'::jdate + :lo AND '-0061-01-01'::jdate + :hi
 LIMIT 50;
SELECT jdate_format(timestamptz '2000-01-01 00:00:00+00' + :lo * interval '1 hour'),
       (timestamptz '2000-01-01 00:00:00+00' + :lo * interval '1 hour')::jdate;
