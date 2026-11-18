-- jdate_trunc for jtimestamp and jtimestamptz (src/jtimestamp_trunc.c).
--
-- Checks: the catalog shape, hand-computed rows (every Jalali date below was
-- converted by hand; 1403-01-01 is Gregorian 2024-03-20, a Wednesday, and
-- 1403-05-15 is 2024-08-05, a Monday), every unit against core's date_trunc on the
-- same numbers (jtimestamp <-> timestamp and jtimestamptz <-> timestamptz are binary
-- casts, so a Jalali value and its Gregorian twin are the same int64) and against
-- jdate_trunc of the same date for the Jalali units (year, quarter, month, week),
-- sweeps over the whole range and over several zones (a negative control shows the
-- sweeps can fail), half-hour zones (the hour is local), the Tehran and Sao Paulo
-- gap days, the explicit zone argument (names, abbreviations, POSIX offsets with
-- the POSIX sign), the lower-edge range checks of both types, infinity, the
-- unsupported and unknown units, NULL, the bare-literal ambiguity, volatility and
-- indexes. Errors are shown as SQLSTATE only; the message text is only tested for
-- the type name. The text input of both types is Jalali, so a literal that stands
-- for the Gregorian instant 2024-03-19 21:00 UTC is written 1402-12-29 21:00+00.
-- The named zones are Asia/Tehran (+03:30, no daylight saving time in 2024),
-- Asia/Kolkata (+05:30), Asia/Kathmandu (+05:45), Europe/Paris (+01 / +02),
-- America/Sao_Paulo and Pacific/Kiritimati; the range edges use fixed POSIX
-- offsets (+/-15:59), never a named zone, so no historic offset of tzdata is
-- baked in.
SET DateStyle = 'ISO, YMD';
SET timezone = 'UTC';

-- The text of the single value of a query, or "ERR <sqlstate>", under a session
-- time zone (restored afterwards).
CREATE FUNCTION pg_temp.zval(zone text, q text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE
    r text;
BEGIN
    PERFORM set_config('TimeZone', zone, false);
    BEGIN
        EXECUTE q INTO r;
        r := coalesce(r, 'NULL');
    EXCEPTION WHEN OTHERS THEN
        r := 'ERR ' || SQLSTATE;
    END;
    PERFORM set_config('TimeZone', 'UTC', false);
    RETURN r;
END
$f$;

-- The error message of a query, or 'no error'.
CREATE FUNCTION pg_temp.emsg(q text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE
    r text;
BEGIN
    BEGIN
        EXECUTE q INTO r;
        RETURN 'no error';
    EXCEPTION WHEN OTHERS THEN
        RETURN SQLERRM;
    END;
END
$f$;

-- 'ok' or "ERR <sqlstate>" for a statement that returns nothing.
CREATE FUNCTION pg_temp.ddl(q text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE q;
    RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
    RETURN 'ERR ' || SQLSTATE;
END
$f$;

-- ---------------------------------------------------------------------
-- catalog: three functions, jtimestamp IMMUTABLE (i), jtimestamptz in the
-- session zone STABLE (s), jtimestamptz with a zone IMMUTABLE; strict, parallel
-- safe, in the extension; core's date_trunc has the same volatilities
-- ---------------------------------------------------------------------
SELECT pg_get_function_identity_arguments(p.oid) AS args, p.prorettype::regtype AS returns,
       p.provolatile AS volatility, p.proisstrict AS strict, p.proparallel AS parallel,
       EXISTS (SELECT 1 FROM pg_depend d
               WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e'
                 AND d.refobjid = (SELECT oid FROM pg_extension WHERE extname = 'jdate')) AS in_extension
FROM pg_proc p
WHERE p.proname = 'jdate_trunc' AND p.pronamespace = (SELECT extnamespace FROM pg_extension WHERE extname = 'jdate')
ORDER BY 1;

SELECT pg_get_function_identity_arguments(p.oid) AS core_args, p.provolatile AS core_volatility
FROM pg_proc p
WHERE p.proname = 'date_trunc' AND p.pronamespace = 'pg_catalog'::regnamespace
  AND p.proargtypes[0] = 'text'::regtype
  AND p.proargtypes[1] IN ('timestamp'::regtype, 'timestamptz'::regtype)
ORDER BY 1;

-- ---------------------------------------------------------------------
-- jtimestamp: every unit of 1403-05-15 10:30:45.123456, by hand. 1403-05-15 is a
-- Monday, so its Saturday-first week starts on Saturday 1403-05-13 (2024-08-03);
-- month 5 is in the second quarter, which starts with month 4.
-- ---------------------------------------------------------------------
SELECT u, jdate_trunc(u, '1403-05-15 10:30:45.123456'::jtimestamp) AS trunc
FROM unnest(ARRAY['year', 'quarter', 'month', 'week', 'day', 'hour', 'minute', 'second',
                  'milliseconds', 'microseconds']) WITH ORDINALITY AS t(u, n)
ORDER BY n;

-- the spelling and case of the unit
SELECT jdate_trunc('MONTH', '1403-05-15 10:30:45'::jtimestamp) AS upper_month,
       jdate_trunc('Week', '1403-05-15 10:30:45'::jtimestamp) AS mixed_week,
       jdate_trunc('years', '1403-05-15 10:30:45'::jtimestamp) AS years_plural,
       jdate_trunc('Days', '1403-05-15 10:30:45'::jtimestamp) AS days_plural,
       jdate_trunc('hours', '1403-05-15 10:30:45'::jtimestamp) AS hours_plural,
       jdate_trunc('MiCrOsEcOnDs', '1403-05-15 10:30:45.123456'::jtimestamp) AS mixed_micro;

-- quarter starts: the first and last day of every quarter, and the leap day
SELECT v, jdate_trunc('quarter', v) AS quarter_start
FROM (VALUES ('1403-01-01 00:00:00'::jtimestamp), ('1403-03-31 23:59:59.999999'),
             ('1403-04-01 00:00:00'), ('1403-06-31 12:00:00'),
             ('1403-07-01 00:00:00'), ('1403-09-30 12:00:00'),
             ('1403-10-01 00:00:00'), ('1403-12-30 23:59:59.999999')) AS t(v)
ORDER BY v;

-- weeks: a Wednesday over the year boundary (1403-01-01 is Gregorian 2024-03-20),
-- a Saturday (its own week start), a Friday (the Saturday six days earlier), and the
-- leap day 1403-12-30, a Thursday (2025-03-20), whose week starts on 1403-12-25
SELECT v, to_char(v::timestamp, 'Dy') AS weekday, jdate_trunc('week', v) AS week_start,
       to_char(jdate_trunc('week', v)::timestamp, 'Dy') AS start_weekday
FROM (VALUES ('1403-01-01 12:00:00'::jtimestamp), ('1403-05-13 23:59:59.999999'),
             ('1403-05-12 08:00:00'), ('1403-12-30 10:00:00')) AS t(v)
ORDER BY v;

-- the end of a day, the beginning of a day: day truncation is the date at 00:00:00
SELECT jdate_trunc('day', '1403-05-15 23:59:59.999999'::jtimestamp) AS day_last_usec,
       jdate_trunc('day', '1403-05-15 00:00:00'::jtimestamp) AS day_midnight,
       jdate_trunc('second', '1403-05-15 10:30:45.999999'::jtimestamp) AS second_last_usec,
       jdate_trunc('milliseconds', '1403-05-15 10:30:45.999999'::jtimestamp) AS ms_last_usec;

-- ---------------------------------------------------------------------
-- jtimestamp against core and against jdate: sweeps. The values are core timestamps
-- of the Gregorian days that cover the Jalali range (every 997th day), the whole of
-- Jalali 1403 at three times of day, and 400 days at each end; the first week is
-- left out (the edge cases come later).
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jts AS
SELECT DISTINCT ((SELECT '-0061-01-01'::jdate::date) + d)::timestamp
                + ((d::bigint * 7919111) % 86400000000) * interval '1 microsecond' AS gv
FROM (SELECT generate_series(7, 1183019, 997) AS d
      UNION ALL SELECT generate_series(7, 407)
      UNION ALL SELECT generate_series(1182620, 1183019)
      UNION ALL SELECT g FROM generate_series(
          ('1403-01-01'::jdate - '-0061-01-01'::jdate), ('1403-12-30'::jdate - '-0061-01-01'::jdate)) g
      UNION ALL SELECT g + 7919 FROM generate_series(
          ('1403-01-01'::jdate - '-0061-01-01'::jdate), ('1403-12-30'::jdate - '-0061-01-01'::jdate)) g
     ) s;
ALTER TABLE jts ADD COLUMN v jtimestamp;
UPDATE jts SET v = gv::jtimestamp;

SELECT count(*) > 2500 AS enough_values,
       count(*) FILTER (WHERE v::timestamp = gv) = count(*) AS same_numbers_as_core,
       min(v) AS first_value, max(v) AS last_value
FROM jts;

-- day to microseconds: core's date_trunc on the same value; the Jalali units: the
-- jdate_trunc of the same date (jdate -> jtimestamp is date_timestamp: midnight)
SELECT u AS unit, count(*) AS n,
       count(*) FILTER (WHERE jdate_trunc(u, v)::timestamp IS DISTINCT FROM date_trunc(u, gv)) AS differ_from_core
FROM (VALUES ('day'), ('hour'), ('minute'), ('second'), ('milliseconds'), ('microseconds')) x(u)
CROSS JOIN jts
GROUP BY u ORDER BY array_position(ARRAY['day', 'hour', 'minute', 'second', 'milliseconds', 'microseconds'], u);

SELECT u AS unit, count(*) AS n,
       count(*) FILTER (WHERE jdate_trunc(u, v) IS DISTINCT FROM jdate_trunc(u, v::jdate)::jtimestamp) AS differ_from_jdate,
       count(*) FILTER (WHERE jdate_trunc(u, v) > v) AS above_input
FROM (VALUES ('year'), ('quarter'), ('month'), ('week')) x(u)
CROSS JOIN jts
GROUP BY u ORDER BY array_position(ARRAY['year', 'quarter', 'month', 'week'], u);

-- negative control: core's Gregorian month and week are not the Jalali ones
SELECT count(*) FILTER (WHERE jdate_trunc('month', v)::timestamp <> date_trunc('month', gv)) > 0 AS month_differs_from_gregorian,
       count(*) FILTER (WHERE jdate_trunc('week', v)::timestamp <> date_trunc('week', gv)) > 0 AS week_differs_from_iso,
       count(*) FILTER (WHERE jdate_trunc('year', v)::timestamp <> date_trunc('year', gv)) > 0 AS year_differs_from_gregorian
FROM jts;

-- the result of a truncation is a fixed point, never above its input, and the
-- units nest: hour of minute of second of day is the hour; month of week-start is
-- not asked (a week can start in the previous month)
SELECT count(*) FILTER (WHERE jdate_trunc('week', jdate_trunc('week', v)) <> jdate_trunc('week', v)) AS week_not_idempotent,
       count(*) FILTER (WHERE jdate_trunc('week', v) > v) AS week_above_input,
       count(*) FILTER (WHERE jdate_trunc('quarter', jdate_trunc('month', v)) <> jdate_trunc('quarter', v)) AS quarter_of_month_differs,
       count(*) FILTER (WHERE jdate_trunc('year', jdate_trunc('quarter', v)) <> jdate_trunc('year', v)) AS year_of_quarter_differs,
       count(*) FILTER (WHERE jdate_trunc('day', jdate_trunc('hour', v)) <> jdate_trunc('day', v)) AS day_of_hour_differs
FROM jts;

-- ---------------------------------------------------------------------
-- jtimestamp range edges. -0061-01-01 is a Thursday (Saturday-first dow 5), so the
-- week start of its first three days is below the minimum (22008, as
-- jdate_trunc('week', jdate)); the third day, -0061-01-03, is a Saturday. Every other
-- unit gives a start inside the range.
-- ---------------------------------------------------------------------
SELECT pg_temp.zval('UTC', $q$SELECT jdate_trunc('week', '-0061-01-01'::jdate)::text$q$) AS jdate_week_first_day,
       pg_temp.zval('UTC', $q$SELECT jdate_trunc('week', '-0061-01-03'::jdate)::text$q$) AS jdate_week_third_day;
SELECT u,
       pg_temp.zval('UTC', format('SELECT jdate_trunc(%L, %L::jtimestamp)::text', u, '-0061-01-01 00:00:00')) AS first_day_midnight,
       pg_temp.zval('UTC', format('SELECT jdate_trunc(%L, %L::jtimestamp)::text', u, '-0061-01-01 00:00:00.000001')) AS first_day_plus_usec,
       pg_temp.zval('UTC', format('SELECT jdate_trunc(%L, %L::jtimestamp)::text', u, '-0061-01-02 12:00:00')) AS second_day,
       pg_temp.zval('UTC', format('SELECT jdate_trunc(%L, %L::jtimestamp)::text', u, '-0061-01-03 12:00:00')) AS third_day_saturday,
       pg_temp.zval('UTC', format('SELECT jdate_trunc(%L, %L::jtimestamp)::text', u, '-0061-01-04 00:00:00')) AS fourth_day
FROM unnest(ARRAY['year', 'quarter', 'month', 'week', 'day', 'hour', 'minute', 'second',
                  'milliseconds', 'microseconds']) WITH ORDINALITY AS t(u, n)
ORDER BY n;

-- the top of the range: nothing can go above the input
SELECT u, jdate_trunc(u, '3177-12-29 23:59:59.999999'::jtimestamp) AS trunc
FROM unnest(ARRAY['year', 'quarter', 'month', 'week', 'day', 'hour', 'minute', 'second',
                  'milliseconds', 'microseconds']) WITH ORDINALITY AS t(u, n)
ORDER BY n;
SELECT jdate_trunc('week', '3177-12-29 23:59:59.999999'::jtimestamp)
       = jdate_trunc('week', '3177-12-29'::jdate)::jtimestamp AS top_week_as_jdate,
       to_char(jdate_trunc('week', '3177-12-29 23:59:59.999999'::jtimestamp)::timestamp, 'Dy') AS top_week_weekday;

-- ---------------------------------------------------------------------
-- jtimestamptz: hand rows. The instant 1402-12-29 21:00 UTC (2024-03-19 21:00 UTC,
-- a Tuesday) on the clock of several zones:
--   UTC         1402-12-29 21:00          Tuesday, week starts Sat 2024-03-16 = 1402-12-26
--   Tehran      1403-01-01 00:30 (+03:30)
--   Kolkata     1403-01-01 02:30 (+05:30)
--   Kathmandu   1403-01-01 02:45 (+05:45)
--   Paris       1402-12-29 22:00 (+01)
-- ---------------------------------------------------------------------
SELECT z, u, pg_temp.zval(z, format('SELECT jdate_trunc(%L, %L::jtimestamptz)::text', u, '1402-12-29 21:00:00+00')) AS trunc
FROM (VALUES ('UTC', 1), ('Asia/Tehran', 2), ('Asia/Kolkata', 3), ('Asia/Kathmandu', 4), ('Europe/Paris', 5)) AS z(z, zn)
CROSS JOIN unnest(ARRAY['year', 'quarter', 'month', 'week', 'day', 'hour', 'minute', 'second',
                        'milliseconds', 'microseconds']) WITH ORDINALITY AS t(u, n)
ORDER BY zn, n;

-- the offset of the result is the offset at the result: Paris, 1403-01-20 12:00+02
-- (2024-04-08, daylight saving time) truncates to 1403-01-01 00:00+01 (2024-03-20),
-- 1403-08-15 12:00+01 (2024-11-05) to 1403-08-01 00:00+02 (2024-10-22)
SELECT u, pg_temp.zval('Europe/Paris', format('SELECT jdate_trunc(%L, %L::jtimestamptz)::text', u, '1403-01-20 12:00:00+02')) AS spring,
          pg_temp.zval('Europe/Paris', format('SELECT jdate_trunc(%L, %L::jtimestamptz)::text', u, '1403-08-15 12:00:00+01')) AS autumn
FROM unnest(ARRAY['year', 'quarter', 'month', 'week', 'day']) WITH ORDINALITY AS t(u, n)
ORDER BY n;

-- hour is a local clock field: the same instant has different hours (and different
-- minutes in the 45-minute zone) in different zones, and the result prints in the
-- session zone
SELECT z, pg_temp.zval(z, format('SELECT jdate_trunc(%L, %L::jtimestamptz)::text', 'hour', '1402-12-29 21:00:00+00')) AS hour_start,
          pg_temp.zval(z, format('SELECT jdate_trunc(%L, %L::jtimestamptz)::text', 'hour', '1402-12-29 21:50:00+00')) AS hour_start_later
FROM (VALUES ('UTC', 1), ('Asia/Tehran', 2), ('Asia/Kolkata', 3), ('Asia/Kathmandu', 4)) AS z(z, zn)
ORDER BY zn;

-- ---------------------------------------------------------------------
-- The Tehran gap day: the clocks went from 00:00 to 01:00 on 2020-03-21
-- (1399-01-02, a Saturday), so that day has no midnight. Truncation gives the first
-- valid instant of the day, 01:00+04:30, exactly as core's date_trunc('day'). The
-- month and the year start on 1399-01-01 (2020-03-20), the day before the gap.
-- 2018-11-04 (1397-08-13) is the same in America/Sao_Paulo.
-- ---------------------------------------------------------------------
SELECT u, pg_temp.zval('Asia/Tehran', format('SELECT jdate_trunc(%L, %L::jtimestamptz)::text', u, '1399-01-02 12:00:00+04:30')) AS on_gap_day,
          pg_temp.zval('Asia/Tehran', format('SELECT jdate_trunc(%L, %L::jtimestamptz)::text', u, '1399-01-03 12:00:00+04:30')) AS day_after,
          pg_temp.zval('Asia/Tehran', format('SELECT jdate_trunc(%L, %L::jtimestamptz)::text', u, '1399-01-01 12:00:00+03:30')) AS day_before
FROM unnest(ARRAY['year', 'quarter', 'month', 'week', 'day']) WITH ORDINALITY AS t(u, n)
ORDER BY n;

SELECT pg_temp.zval('Asia/Tehran', 'SELECT date_trunc(''day'', ''2020-03-21 12:00+04:30''::timestamptz)::text') AS core_tehran_day,
       pg_temp.zval('Asia/Tehran', 'SELECT jdate_trunc(''day'', ''1399-01-02 12:00:00+04:30''::jtimestamptz)::timestamptz = date_trunc(''day'', ''2020-03-21 12:00+04:30''::timestamptz)') AS day_as_core,
       pg_temp.zval('America/Sao_Paulo', 'SELECT date_trunc(''day'', ''2018-11-04 12:00-02''::timestamptz)::text') AS core_sao_paulo_day,
       pg_temp.zval('America/Sao_Paulo', 'SELECT jdate_trunc(''day'', ''1397-08-13 12:00:00-02''::jtimestamptz)::timestamptz = date_trunc(''day'', ''2018-11-04 12:00-02''::timestamptz)') AS sao_paulo_day_as_core,
       pg_temp.zval('America/Sao_Paulo', 'SELECT jdate_trunc(''week'', ''1397-08-14 12:00:00-02''::jtimestamptz)::text') AS sao_paulo_week_start;

-- ---------------------------------------------------------------------
-- jtimestamptz sweeps against core, in eight session zones. The instants: every
-- 1013th day over the range with a varying time of day, every half hour around the
-- zone changes of Tehran (2020-03-21, 2020-09-21), Paris (2024-03-31, 2024-10-27) and
-- Sao Paulo (2018-11-04), and every 7 hours over Nowruz 1403 and the end of 1402. The
-- range sweep starts 400 days after the first day: the year start of the first Jalali
-- year (a local midnight before the first safe instant) is the edge cases' business.
-- The oracles are independent of the C code: core's date_trunc on the same
-- timestamptz for day to microseconds, and for the Jalali units the Jalali period
-- start of the local date (jtimestamptz -> jdate is core's timestamptz_date) as a
-- core date, read at local midnight (date -> timestamptz is core's date_timestamptz).
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jtz AS
SELECT DISTINCT gv FROM (
  SELECT (SELECT ('-0061-01-01'::jdate::date)::timestamp AT TIME ZONE 'UTC') + interval '400 days'
         + d * interval '1 day' + ((d::bigint * 7919111) % 86400000000) * interval '1 microsecond' AS gv
  FROM generate_series(0, 1183019 - 408, 1013) d
  UNION ALL SELECT g FROM generate_series(timestamptz '2020-03-19 12:00+00', timestamptz '2020-03-23 12:00+00', interval '30 minutes') g
  UNION ALL SELECT g FROM generate_series(timestamptz '2020-09-19 12:00+00', timestamptz '2020-09-23 12:00+00', interval '30 minutes') g
  UNION ALL SELECT g FROM generate_series(timestamptz '2024-03-30 12:00+00', timestamptz '2024-04-01 12:00+00', interval '30 minutes') g
  UNION ALL SELECT g FROM generate_series(timestamptz '2024-10-26 12:00+00', timestamptz '2024-10-28 12:00+00', interval '30 minutes') g
  UNION ALL SELECT g FROM generate_series(timestamptz '2018-11-03 12:00+00', timestamptz '2018-11-05 12:00+00', interval '30 minutes') g
  UNION ALL SELECT g FROM generate_series(timestamptz '2024-03-18 12:00+00', timestamptz '2024-03-22 12:00+00', interval '7 hours') g
  UNION ALL SELECT g FROM generate_series(timestamptz '2025-03-17 12:00+00', timestamptz '2025-03-23 12:00+00', interval '7 hours') g
) s;
ALTER TABLE jtz ADD COLUMN v jtimestamptz;
UPDATE jtz SET v = gv::jtimestamptz;

SELECT count(*) > 1500 AS enough_instants,
       count(*) FILTER (WHERE v::timestamptz = gv) = count(*) AS same_numbers_as_core
FROM jtz;

-- one row per zone: how many comparisons, how many differ
CREATE FUNCTION pg_temp.tz_sweep(zone text) RETURNS TABLE(units int, comparisons bigint, differ bigint)
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM set_config('TimeZone', zone, false);
    RETURN QUERY
    WITH r AS (
        SELECT x.u,
               jdate_trunc(x.u, j.v) AS got_session,
               CASE WHEN x.u IN ('year', 'quarter', 'month', 'week')
                    THEN jdate_trunc(x.u, j.v::jdate)::date::timestamptz
                    ELSE date_trunc(x.u, j.v::timestamptz) END AS want
        FROM (VALUES ('year'), ('quarter'), ('month'), ('week'), ('day'), ('hour'), ('minute'),
                     ('second'), ('milliseconds'), ('microseconds')) x(u)
        CROSS JOIN jtz j)
    SELECT count(DISTINCT r.u)::int, count(*),
           count(*) FILTER (WHERE r.got_session::timestamptz IS DISTINCT FROM r.want)
    FROM r;
    PERFORM set_config('TimeZone', 'UTC', false);
END
$f$;

-- (the explicit-zone variant is swept separately below, with its own oracle)
SELECT z AS zone, s.units, s.comparisons, s.differ
FROM (VALUES ('UTC', 1), ('Asia/Tehran', 2), ('Asia/Kolkata', 3), ('Asia/Kathmandu', 4),
             ('Europe/Paris', 5), ('America/Sao_Paulo', 6), ('Pacific/Kiritimati', 7),
             ('Pacific/Pago_Pago', 8)) AS z(z, zn),
     LATERAL pg_temp.tz_sweep(z.z) s
ORDER BY zn;

-- negative control: the oracle is not trivial (core's Gregorian month start is not the
-- Jalali month start, and the same sweep reports differences against it)
SET timezone = 'Asia/Tehran';
SELECT count(*) FILTER (WHERE jdate_trunc('month', v)::timestamptz <> date_trunc('month', v::timestamptz)) > 0 AS month_differs_from_gregorian,
       count(*) FILTER (WHERE jdate_trunc('hour', v)::timestamptz <> date_trunc('hour', v::timestamptz)) AS hour_differs_from_core
FROM jtz;
SET timezone = 'UTC';

-- the hour of a half-hour zone is local, not UTC aligned: after the truncation the
-- instant is at minute 30 of a UTC hour in Tehran and Kolkata, at minute 15 in
-- Kathmandu (2018 to 2025, no historic offsets involved)
SET timezone = 'Asia/Tehran';
SELECT count(*) > 100 AS instants_2018_to_2025,
       bool_and(extract(minute FROM jdate_trunc('hour', v)::timestamptz AT TIME ZONE 'UTC') = 30) AS tehran_hour_starts_at_utc_half,
       bool_and(jdate_trunc('hour', v)::timestamptz = date_trunc('hour', v::timestamptz)) AS as_core
FROM jtz WHERE gv >= timestamptz '2018-01-01+00' AND gv < timestamptz '2026-01-01+00';
SET timezone = 'Asia/Kolkata';
SELECT bool_and(extract(minute FROM jdate_trunc('hour', v)::timestamptz AT TIME ZONE 'UTC') = 30) AS kolkata_hour_starts_at_utc_half
FROM jtz WHERE gv >= timestamptz '2018-01-01+00' AND gv < timestamptz '2026-01-01+00';
SET timezone = 'Asia/Kathmandu';
SELECT bool_and(extract(minute FROM jdate_trunc('hour', v)::timestamptz AT TIME ZONE 'UTC') = 15) AS kathmandu_hour_starts_at_utc_quarter
FROM jtz WHERE gv >= timestamptz '2018-01-01+00' AND gv < timestamptz '2026-01-01+00';
SET timezone = 'UTC';

-- ---------------------------------------------------------------------
-- The explicit zone argument. The zone is read as in core: a name, an abbreviation,
-- or a POSIX offset with the POSIX sign ('+03:30' is UTC-3:30). It is swept against
-- core's three-argument date_trunc (day to microseconds) and, for the Jalali units,
-- against the Jalali period start of the local date (the wall clock in the zone as a
-- core date) read at local midnight in that zone (core's AT TIME ZONE); the session
-- zone is New York, which the argument must override.
-- ---------------------------------------------------------------------
SET timezone = 'America/New_York';
SELECT z AS zone, count(DISTINCT u) AS units, count(*) AS comparisons,
       count(*) FILTER (WHERE jdate_trunc(u, v, z)::timestamptz IS DISTINCT FROM
         CASE WHEN u IN ('year', 'quarter', 'month', 'week')
              THEN (jdate_trunc(u, ((v::timestamptz AT TIME ZONE z)::date)::jdate)::date::timestamp) AT TIME ZONE z
              ELSE date_trunc(u, v::timestamptz, z) END) AS differ
FROM (VALUES ('UTC', 1), ('Asia/Tehran', 2), ('Asia/Kolkata', 3), ('Asia/Kathmandu', 4),
             ('Europe/Paris', 5), ('America/Sao_Paulo', 6), ('Pacific/Kiritimati', 7),
             ('EST', 8), ('PST8PDT', 9), ('+03:30', 10), ('<+03:30>-03:30', 11), ('UTC+3', 12),
             ('<+15:59>-15:59', 13), ('<-15:59>+15:59', 14)) AS z(z, zn)
CROSS JOIN (VALUES ('year'), ('quarter'), ('month'), ('week'), ('day'), ('hour'), ('minute'),
                   ('second'), ('milliseconds'), ('microseconds')) x(u)
CROSS JOIN jtz j
GROUP BY z, zn ORDER BY zn;
SET timezone = 'UTC';

-- and the explicit zone gives the same instant as the session zone set to that zone
-- (named zones; the POSIX forms follow in the hand rows)
CREATE FUNCTION pg_temp.arg_vs_session(zone text) RETURNS bigint
LANGUAGE plpgsql AS $f$
DECLARE
    n bigint;
BEGIN
    PERFORM set_config('TimeZone', zone, false);
    SELECT count(*) FILTER (WHERE jdate_trunc(x.u, j.v, zone) IS DISTINCT FROM jdate_trunc(x.u, j.v))
      INTO n
    FROM (VALUES ('year'), ('quarter'), ('month'), ('week'), ('day'), ('hour'), ('minute'),
                 ('second'), ('milliseconds'), ('microseconds')) x(u)
    CROSS JOIN jtz j;
    PERFORM set_config('TimeZone', 'UTC', false);
    RETURN n;
END
$f$;
SELECT z AS zone, pg_temp.arg_vs_session(z) AS differ
FROM (VALUES ('UTC', 1), ('Asia/Tehran', 2), ('Asia/Kolkata', 3), ('Asia/Kathmandu', 4),
             ('Europe/Paris', 5), ('America/Sao_Paulo', 6)) AS z(z, zn)
ORDER BY zn;

-- the POSIX sign: '+03:30' is UTC-3:30, so 12:45 UTC is 09:15 there and its hour
-- starts at 09:00-03:30, which is 12:30 UTC; in Asia/Tehran (+03:30) the hour starts at
-- 16:00+03:30, the same 12:30 UTC, and in UTC at 12:00 (the sign shows in the day below)
SELECT jdate_trunc('hour', '1403-01-01 12:45:00+00'::jtimestamptz, '+03:30') AS posix_plus_0330,
       jdate_trunc('hour', '1403-01-01 12:45:00+00'::jtimestamptz, '-03:30') AS posix_minus_0330,
       jdate_trunc('hour', '1403-01-01 12:45:00+00'::jtimestamptz, 'Asia/Tehran') AS tehran,
       jdate_trunc('hour', '1403-01-01 12:45:00+00'::jtimestamptz, 'UTC') AS utc,
       jdate_trunc('hour', '1403-01-01 12:45:00+00'::jtimestamptz, '+03:30')::timestamptz
         = date_trunc('hour', '2024-03-20 12:45:00+00'::timestamptz, '+03:30') AS posix_as_core;
-- (the day starts at 00:00 on that clock: 03:30 UTC at UTC-3:30, 20:30 UTC the day
-- before at UTC+3:30)
SELECT jdate_trunc('day', '1403-01-01 12:45:00+00'::jtimestamptz, '+03:30') AS day_posix_plus_0330,
       jdate_trunc('day', '1403-01-01 12:45:00+00'::jtimestamptz, '-03:30') AS day_posix_minus_0330,
       jdate_trunc('day', '1403-01-01 12:45:00+00'::jtimestamptz, 'Asia/Tehran') AS day_tehran,
       jdate_trunc('week', '1403-01-01 12:45:00+00'::jtimestamptz, 'Asia/Tehran') AS week_tehran,
       jdate_trunc('month', '1403-01-01 02:00:00+00'::jtimestamptz, 'Asia/Tehran') AS month_tehran,
       jdate_trunc('month', '1403-01-01 02:00:00+00'::jtimestamptz, 'America/New_York') AS month_new_york;

-- unknown zone: 22023, for the Jalali units, for core's units and for infinity
SELECT pg_temp.zval('UTC', format('SELECT jdate_trunc(%L, %L::jtimestamptz, %L)::text', u, '1403-05-15 10:00:00+00', 'Nowhere/Land')) AS finite,
       pg_temp.zval('UTC', format('SELECT jdate_trunc(%L, %L::jtimestamptz, %L)::text', u, 'infinity', 'Nowhere/Land')) AS infinite
FROM unnest(ARRAY['month', 'hour']) AS t(u);

-- ---------------------------------------------------------------------
-- jtimestamptz lower edge. The first safe instant is -0061-01-01 16:00:00 UTC, the last
-- one 3177-12-29 07:59:59.999999 UTC: a truncated local clock can fall below the first
-- one. In UTC the day, month, quarter, year and week starts of the first safe instant
-- are all -0061-01-01 00:00, before it; in a zone 15:59 east the local clock of the
-- first safe instant is 07:59 on the second day, so even the hour start lies
-- below it; in a zone 15:59 west it is 00:01 on the first day.
-- ---------------------------------------------------------------------
SELECT z, u,
       pg_temp.zval(z, format('SELECT jdate_trunc(%L, %L::jtimestamptz)::text', u, '-0061-01-01 16:00:00+00')) AS first_safe,
       pg_temp.zval(z, format('SELECT jdate_trunc(%L, %L::jtimestamptz)::text', u, '-0061-01-01 16:00:00.000001+00')) AS first_safe_plus_usec,
       pg_temp.zval(z, format('SELECT jdate_trunc(%L, %L::jtimestamptz)::text', u, '-0061-01-02 00:00:00+00')) AS second_day_start
FROM (VALUES ('UTC', 1), ('<+15:59>-15:59', 2), ('<-15:59>+15:59', 3)) AS z(z, zn)
CROSS JOIN unnest(ARRAY['year', 'quarter', 'month', 'week', 'day', 'hour', 'minute', 'second',
                        'milliseconds', 'microseconds']) WITH ORDINALITY AS t(u, n)
ORDER BY zn, n;

-- the same for the last safe instant: the results are below the input, never above
SELECT z, u,
       pg_temp.zval(z, format('SELECT jdate_trunc(%L, %L::jtimestamptz)::text', u, '3177-12-29 07:59:59.999999+00')) AS last_safe
FROM (VALUES ('UTC', 1), ('<+15:59>-15:59', 2), ('<-15:59>+15:59', 3)) AS z(z, zn)
CROSS JOIN unnest(ARRAY['year', 'quarter', 'month', 'week', 'day', 'hour', 'minute', 'second',
                        'milliseconds', 'microseconds']) WITH ORDINALITY AS t(u, n)
ORDER BY zn, n;

-- A check against core's arithmetic for every zone, unit and edge instant: the
-- oracle instant (core's date_trunc, or the Jalali period start read at local midnight
-- through core's AT TIME ZONE) decides whether the result is valid (inside the safe
-- range, computed here from the Jalali dates) or 22008, for the session-zone
-- function and for the explicit-zone function.
CREATE FUNCTION pg_temp.edge_check(zone text, u text, t jtimestamptz) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE
    lo timestamptz := ('-0061-01-01'::jdate::date)::timestamp AT TIME ZONE 'UTC' + interval '16 hours';
    hi timestamptz := ((('3177-12-29'::jdate::date) + 1)::timestamp AT TIME ZONE 'UTC') - interval '16 hours';
    want timestamptz;
    got timestamptz;
    valid boolean;
    res text;
BEGIN
    PERFORM set_config('TimeZone', zone, false);
    IF u IN ('year', 'quarter', 'month', 'week') THEN
        -- the Jalali period start of the local date, in core terms; the date can lie
        -- below the Jalali range (the week of the first days), which is the same error
        BEGIN
            want := (jdate_trunc(u, t::jdate)::date)::timestamptz;
        EXCEPTION WHEN SQLSTATE '22008' THEN
            want := NULL;
        END;
    ELSE
        want := date_trunc(u, t::timestamptz);
    END IF;
    valid := want IS NOT NULL AND want >= lo AND want < hi;

    -- session zone
    BEGIN
        got := jdate_trunc(u, t)::timestamptz;
        res := CASE WHEN valid AND got = want THEN 'valid' ELSE 'MISMATCH session' END;
    EXCEPTION WHEN SQLSTATE '22008' THEN
        res := CASE WHEN NOT valid THEN '22008' ELSE 'MISMATCH session error' END;
    END;

    -- explicit zone
    BEGIN
        got := jdate_trunc(u, t, zone)::timestamptz;
        res := res || CASE WHEN valid AND got = want THEN '' ELSE ' / MISMATCH zone arg' END;
    EXCEPTION WHEN SQLSTATE '22008' THEN
        res := res || CASE WHEN NOT valid THEN '' ELSE ' / MISMATCH zone arg error' END;
    END;

    PERFORM set_config('TimeZone', 'UTC', false);
    RETURN res;
END
$f$;

SELECT result, count(*) AS cases
FROM (SELECT pg_temp.edge_check(z, u, t::jtimestamptz) AS result
      FROM (VALUES ('UTC'), ('<+15:59>-15:59'), ('<-15:59>+15:59')) AS z(z)
      CROSS JOIN unnest(ARRAY['year', 'quarter', 'month', 'week', 'day', 'hour', 'minute', 'second',
                              'milliseconds', 'microseconds']) AS x(u)
      CROSS JOIN (VALUES ('-0061-01-01 16:00:00+00'), ('-0061-01-01 16:00:00.000001+00'),
                         ('-0061-01-01 23:59:59.999999+00'), ('-0061-01-02 00:00:00+00'),
                         ('-0061-01-02 07:59:00+00'), ('-0061-01-02 08:00:00+00'),
                         ('-0061-01-03 00:00:00+00'), ('-0061-01-03 16:00:00+00'),
                         ('-0061-01-05 12:00:00+00'), ('-0061-01-10 12:00:00+00'),
                         ('3177-12-28 12:00:00+00'), ('3177-12-29 00:00:00+00'),
                         ('3177-12-29 07:59:59.999999+00')) AS e(t)) s
GROUP BY result ORDER BY result;

-- ---------------------------------------------------------------------
-- infinity: infinity of the same sign for every known unit (the unsupported ones
-- too, as in core and for jdate), in all three functions
-- ---------------------------------------------------------------------
SELECT u,
       jdate_trunc(u, 'infinity'::jtimestamp) AS ts_inf, jdate_trunc(u, '-infinity'::jtimestamp) AS ts_minf,
       jdate_trunc(u, 'infinity'::jtimestamptz) AS tstz_inf, jdate_trunc(u, '-infinity'::jtimestamptz) AS tstz_minf,
       jdate_trunc(u, 'infinity'::jtimestamptz, 'Asia/Tehran') AS tstz_zone_inf,
       jdate_trunc(u, '-infinity'::jtimestamptz, 'Asia/Tehran') AS tstz_zone_minf
FROM unnest(ARRAY['year', 'quarter', 'month', 'week', 'day', 'hour', 'minute', 'second',
                  'milliseconds', 'microseconds', 'decade', 'century', 'millennium']) WITH ORDINALITY AS t(u, n)
ORDER BY n;

SELECT jdate_trunc('week', 'infinity'::jdate) AS jdate_week_inf,
       jdate_trunc('decade', 'infinity'::jdate) AS jdate_decade_inf;

-- ---------------------------------------------------------------------
-- unsupported units are 0A000 (as for jdate_trunc: decade, century, millennium, and
-- every other known field name), unknown units 22023, for all three functions (and
-- jdate as before); the messages name the real type
-- ---------------------------------------------------------------------
SELECT u,
       pg_temp.zval('UTC', format('SELECT jdate_trunc(%L, %L::jtimestamp)::text', u, '1403-05-15 10:30:45')) AS ts,
       pg_temp.zval('UTC', format('SELECT jdate_trunc(%L, %L::jtimestamptz)::text', u, '1403-05-15 10:30:45+00')) AS tstz,
       pg_temp.zval('UTC', format('SELECT jdate_trunc(%L, %L::jtimestamptz, %L)::text', u, '1403-05-15 10:30:45+00', 'Asia/Tehran')) AS tstz_zone,
       pg_temp.zval('UTC', format('SELECT jdate_trunc(%L, %L::jdate)::text', u, '1403-05-15')) AS jdate
FROM unnest(ARRAY['decade', 'century', 'millennium', 'epoch', 'dow', 'doy', 'isodow', 'isoyear',
                  'julian', 'timezone', 'timezone_hour', 'fortnight', 'bogus', '']) WITH ORDINALITY AS t(u, n)
ORDER BY n;

SELECT pg_temp.emsg('SELECT jdate_trunc(''decade'', ''1403-05-15 10:30:45''::jtimestamp)') ~ 'jtimestamp' AS unsupported_names_jtimestamp,
       pg_temp.emsg('SELECT jdate_trunc(''decade'', ''1403-05-15 10:30:45+00''::jtimestamptz)') ~ 'jtimestamptz' AS unsupported_names_jtimestamptz,
       pg_temp.emsg('SELECT jdate_trunc(''decade'', ''1403-05-15 10:30:45+00''::jtimestamptz, ''UTC'')') ~ 'jtimestamptz' AS unsupported_zone_names_jtimestamptz,
       pg_temp.emsg('SELECT jdate_trunc(''decade'', ''1403-05-15 10:30:45''::jtimestamp)') ~ 'decade' AS unsupported_names_the_unit,
       pg_temp.emsg('SELECT jdate_trunc(''bogus'', ''1403-05-15 10:30:45''::jtimestamp)') ~ 'jtimestamp' AS unknown_names_jtimestamp,
       pg_temp.emsg('SELECT jdate_trunc(''bogus'', ''1403-05-15 10:30:45+00''::jtimestamptz)') ~ 'jtimestamptz' AS unknown_names_jtimestamptz,
       pg_temp.emsg('SELECT jdate_trunc(''bogus'', ''1403-05-15''::jdate)') ~ 'jdate' AS unknown_names_jdate,
       pg_temp.emsg('SELECT jdate_trunc(''bogus'', ''1403-05-15''::jdate)') !~ 'jtimestamp' AS unknown_jdate_unchanged;

-- ---------------------------------------------------------------------
-- NULL arguments, bare literals, volatility, indexes
-- ---------------------------------------------------------------------
SELECT jdate_trunc(NULL, '1403-05-15 10:30:45'::jtimestamp) IS NULL AS null_unit_ts,
       jdate_trunc('month', NULL::jtimestamp) IS NULL AS null_value_ts,
       jdate_trunc('month', NULL::jtimestamptz) IS NULL AS null_value_tstz,
       jdate_trunc('month', '1403-05-15 10:30:45+00'::jtimestamptz, NULL) IS NULL AS null_zone,
       jdate_trunc('month', NULL::jtimestamptz, 'UTC') IS NULL AS null_value_zone;

-- A bare literal for the value is ambiguous now that three types offer the function
-- (jdate_trunc('month', '1403-05-15') was resolved to jdate before this task):
-- 42725; typed values work; with a zone argument there is only one candidate, so
-- a bare literal resolves to jtimestamptz.
SELECT pg_temp.zval('UTC', $q$SELECT jdate_trunc('month', '1403-05-15')::text$q$) AS bare_two_args,
       pg_temp.zval('UTC', $q$SELECT jdate_trunc('month', '1403-05-15 10:00')::text$q$) AS bare_with_time,
       pg_temp.zval('UTC', $q$SELECT jdate_trunc('month', '1403-05-15'::jdate)::text$q$) AS typed_jdate,
       pg_temp.zval('UTC', $q$SELECT jdate_trunc('month', '1403-05-15 10:00'::jtimestamp)::text$q$) AS typed_jtimestamp,
       pg_temp.zval('UTC', $q$SELECT jdate_trunc('month', '1403-05-15 10:00+00'::jtimestamptz)::text$q$) AS typed_jtimestamptz,
       pg_temp.zval('UTC', $q$SELECT jdate_trunc('month', '1403-05-15 10:00+00', 'UTC')::text$q$) AS bare_with_zone;

-- volatility by behaviour: an index on the jtimestamp version, and on the jtimestamptz
-- version with an explicit zone, is allowed; one on the session-zone jtimestamptz
-- version is not (42P17); the planner uses the jtimestamp index
CREATE TEMP TABLE jtr (a jtimestamp, b jtimestamptz);
INSERT INTO jtr SELECT v, v::jtimestamptz FROM jts WHERE v > '0100-01-01 00:00:00' AND v < '3000-01-01 00:00:00';
SELECT pg_temp.ddl($q$CREATE INDEX jtr_month ON jtr (jdate_trunc('month', a))$q$) AS index_jtimestamp;
SELECT pg_temp.ddl($q$CREATE INDEX jtr_b_zone ON jtr (jdate_trunc('day', b, 'Asia/Tehran'))$q$) AS index_jtimestamptz_zone;
SELECT pg_temp.ddl($q$CREATE INDEX jtr_b_session ON jtr (jdate_trunc('day', b))$q$) AS index_jtimestamptz_session;
ANALYZE jtr;
SET enable_seqscan = off;
SELECT count(*) AS rows_in_the_month
FROM jtr WHERE jdate_trunc('month', a) = '1403-05-01 00:00:00'::jtimestamp;
CREATE FUNCTION pg_temp.plan_uses_index(q text) RETURNS boolean
LANGUAGE plpgsql AS $f$
DECLARE
    line text;
BEGIN
    FOR line IN EXECUTE 'EXPLAIN (COSTS OFF) ' || q LOOP
        IF line ~ 'Index' THEN
            RETURN true;
        END IF;
    END LOOP;
    RETURN false;
END
$f$;
SELECT pg_temp.plan_uses_index($q$SELECT * FROM jtr WHERE jdate_trunc('month', a) = '1403-05-01 00:00:00'::jtimestamp$q$) AS planner_uses_the_index;
RESET enable_seqscan;

-- grouping by the Jalali month of a jtimestamp, and of a jtimestamptz in a zone (the
-- instants of the Paris zone changes of 2024 are in two months, with offsets +01 and +02)
SELECT jdate_trunc('month', v) AS month, count(*) AS rows
FROM jts WHERE v >= '1403-01-01 00:00:00' AND v < '1403-04-01 00:00:00'
GROUP BY 1 ORDER BY 1;
SELECT jdate_trunc('month', v, 'Europe/Paris') AS month, count(*) AS rows
FROM jtz WHERE v >= '1403-01-01 00:00:00+00' AND v < '1403-09-01 00:00:00+00'
GROUP BY 1 ORDER BY 1;
