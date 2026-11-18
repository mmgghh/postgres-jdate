-- EXTRACT and jdate_part for jtimestamp and jtimestamptz.
--
-- Checks: the catalog shape, hand-computed rows (every Jalali date below was
-- converted by hand; 1403-01-01 is Gregorian 2024-03-20, a Wednesday), the time
-- fields, epoch and the timezone fields against core's extract on the same value
-- cast to the core type (the jtimestamp <-> timestamp and jtimestamptz <->
-- timestamptz casts are binary, so a Jalali value and its Gregorian twin are the
-- same int64), the date fields against the jdate fields of the same value cast to
-- jdate, sweeps over the whole range and over several zones (a negative control
-- shows the sweeps can fail), the range edges, infinity, the unsupported and
-- unknown units, NULL, the bare-literal ambiguity, volatility and indexes. Errors
-- are shown as SQLSTATE only; the message text is only tested for the type name.
-- The named zones are Asia/Tehran (+03:30, no daylight saving time in 2024),
-- Asia/Kolkata (+05:30), Asia/Kathmandu (+05:45), America/St_Johns (negative
-- offset, with daylight saving time) and fixed offsets (+/-15:59) for the edges.
-- The text input of both types is Jalali, so a literal that stands for the
-- Gregorian 2024-03-19 21:00 UTC is written 1402-12-29 21:00+00.
SET DateStyle = 'ISO, YMD';
SET timezone = 'UTC';

-- The text of the single value of a query, or "ERR <sqlstate>", under a session
-- time zone (restored afterwards).
CREATE FUNCTION pg_temp.fval(zone text, q text) RETURNS text
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
-- catalog: extract() in pg_catalog and jdate_part, both numeric; jtimestamp
-- IMMUTABLE (i), jtimestamptz STABLE (s); strict, parallel safe
-- ---------------------------------------------------------------------
SELECT p.pronamespace::regnamespace AS schema, p.proname,
       pg_get_function_identity_arguments(p.oid) AS args,
       p.prorettype::regtype AS rettype, p.provolatile, p.proparallel, p.proisstrict
FROM pg_proc p
WHERE p.proname IN ('extract', 'jdate_part')
  AND p.proargtypes[1] IN ('jtimestamp'::regtype, 'jtimestamptz'::regtype)
ORDER BY p.proname, p.proargtypes[1]::regtype::text;

-- the jdate versions are untouched: jdate_part is still bigint
SELECT p.proname, p.prorettype::regtype AS rettype, p.provolatile
FROM pg_proc p
WHERE p.proname IN ('extract', 'jdate_part') AND p.proargtypes[1] = 'jdate'::regtype
ORDER BY p.proname;

-- ---------------------------------------------------------------------
-- jtimestamp: every field of 1403-05-15 10:30:45.123456, by hand.
-- 1403-05-15 is the 139th day of the year ((5 - 1) * 31 + 15) and Gregorian
-- 2024-08-05, a Monday: dow (Saturday 0) is 2, isodow 1. Its epoch, as if UTC, is
-- 1722816000 (2024-08-05 00:00) + 37845 (10:30:45) + the fraction.
-- ---------------------------------------------------------------------
SELECT u,
       pg_catalog.extract(u, '1403-05-15 10:30:45.123456'::jtimestamp) AS extract,
       jdate_part(u, '1403-05-15 10:30:45.123456'::jtimestamp) AS part,
       pg_typeof(pg_catalog.extract(u, '1403-05-15 10:30:45.123456'::jtimestamp)) AS extract_type,
       pg_typeof(jdate_part(u, '1403-05-15 10:30:45.123456'::jtimestamp)) AS part_type
FROM unnest(ARRAY['year', 'month', 'day', 'quarter', 'doy', 'decade', 'century',
                  'dow', 'isodow', 'hour', 'minute', 'second', 'milliseconds',
                  'microseconds', 'epoch']) AS t(u)
ORDER BY array_position(ARRAY['year', 'month', 'day', 'quarter', 'doy', 'decade', 'century',
                              'dow', 'isodow', 'hour', 'minute', 'second', 'milliseconds',
                              'microseconds', 'epoch'], u);

-- the EXTRACT syntax, and the spelling and case of the unit
SELECT EXTRACT(year FROM '1403-05-15 10:30:45.123456'::jtimestamp) AS year,
       EXTRACT(MONTH FROM '1403-05-15 10:30:45.123456'::jtimestamp) AS month,
       EXTRACT(second FROM '1403-05-15 10:30:45.123456'::jtimestamp) AS second,
       EXTRACT(epoch FROM '1403-05-15 10:30:45.123456'::jtimestamp) AS epoch,
       jdate_part('Day', '1403-05-15 10:30:45.123456'::jtimestamp) AS day_mixed_case,
       jdate_part('HOUR', '1403-05-15 10:30:45.123456'::jtimestamp) AS hour_upper,
       jdate_part('years', '1403-05-15 10:30:45.123456'::jtimestamp) AS years_plural;

-- the example of the report: epoch is exact at the top of the range
-- (3177-12-29 is Gregorian 3799-03-19), core loses the microseconds in date_part
SELECT EXTRACT(epoch FROM '3177-12-29 23:59:59.999999'::jtimestamp) AS epoch_top,
       EXTRACT(epoch FROM '3177-12-29 23:59:59.999999'::jtimestamp)
         = EXTRACT(epoch FROM '3799-03-19 23:59:59.999999'::timestamp) AS same_as_core,
       jdate_part('epoch', '3177-12-29 23:59:59.999999'::jtimestamp) AS part_epoch_top;

-- local midnight and the last microsecond of a day, and a leap day
SELECT v,
       pg_catalog.extract('year', v) AS year, pg_catalog.extract('month', v) AS month,
       pg_catalog.extract('day', v) AS day, pg_catalog.extract('doy', v) AS doy,
       pg_catalog.extract('hour', v) AS hour, pg_catalog.extract('minute', v) AS minute,
       pg_catalog.extract('second', v) AS second
FROM (VALUES ('1403-01-01 00:00:00'::jtimestamp), ('1402-12-29 23:59:59.999999'),
             ('1403-12-30 00:00:00'), ('1403-12-30 23:59:59.999999'),
             ('0000-01-01 12:00:00.5'), ('-0001-12-29 23:59:59.999999')) AS t(v)
ORDER BY v;

-- ---------------------------------------------------------------------
-- jtimestamp against jdate (date fields) and against core (time fields, epoch)
-- on edge values: the same text, so the scale is the same as well
-- ---------------------------------------------------------------------
SELECT v,
       bool_and(pg_catalog.extract(u, v)::text = pg_catalog.extract(u, v::jdate)::text)
         AS date_fields_as_jdate,
       count(*) AS units
FROM (VALUES ('-0061-01-01 00:00:00'::jtimestamp), ('-0061-01-01 00:00:00.000001'),
             ('-0001-12-29 23:59:59.999999'), ('0000-01-01 00:00:00'),
             ('1402-12-29 23:59:59.999999'), ('1403-01-01 00:00:00'),
             ('1403-12-30 12:00:00'), ('3177-12-29 23:59:59.999999')) AS t(v),
     unnest(ARRAY['year', 'month', 'day', 'quarter', 'doy', 'decade', 'century',
                  'dow', 'isodow']) AS x(u)
GROUP BY v ORDER BY v;

SELECT v,
       bool_and(pg_catalog.extract(u, v)::text = pg_catalog.extract(u, v::timestamp)::text)
         AS time_fields_as_core,
       count(*) AS units
FROM (VALUES ('-0061-01-01 00:00:00'::jtimestamp), ('-0061-01-01 00:00:00.000001'),
             ('-0001-12-29 23:59:59.999999'), ('0000-01-01 00:00:00'),
             ('1402-12-29 23:59:59.999999'), ('1403-01-01 00:00:00'),
             ('1403-12-30 12:00:00'), ('3177-12-29 23:59:59.999999')) AS t(v),
     unnest(ARRAY['hour', 'minute', 'second', 'milliseconds', 'microseconds',
                  'epoch']) AS x(u)
GROUP BY v ORDER BY v;

-- jdate_part is the same number as EXTRACT, for every unit and both types
SELECT count(*) AS checks,
       count(*) FILTER (WHERE pg_catalog.extract(u, v)::text IS DISTINCT FROM jdate_part(u, v)::text) AS differ
FROM (VALUES ('1403-05-15 10:30:45.123456'::jtimestamp), ('-0061-01-01 00:00:00'),
             ('3177-12-29 23:59:59.999999')) AS t(v),
     unnest(ARRAY['year', 'month', 'day', 'quarter', 'doy', 'decade', 'century', 'dow',
                  'isodow', 'hour', 'minute', 'second', 'milliseconds', 'microseconds',
                  'epoch']) AS x(u);
SELECT count(*) AS checks,
       count(*) FILTER (WHERE pg_catalog.extract(u, v)::text IS DISTINCT FROM jdate_part(u, v)::text) AS differ
FROM (VALUES ('1403-05-15 10:30:45.123456+00'::jtimestamptz), ('-0061-01-01 16:00:00+00'),
             ('3177-12-29 07:59:59.999999+00')) AS t(v),
     unnest(ARRAY['year', 'month', 'day', 'quarter', 'doy', 'decade', 'century', 'dow',
                  'isodow', 'hour', 'minute', 'second', 'milliseconds', 'microseconds',
                  'epoch', 'timezone', 'timezone_hour', 'timezone_minute']) AS x(u);

-- ---------------------------------------------------------------------
-- jtimestamptz in zones, by hand. The instant 2024-03-19 21:00:00+00 (the literals
-- say 1402-12-29, because the text input is Jalali) is
-- 00:30 on 2024-03-20 = 1403-01-01 in Tehran (+03:30), 02:30 in Kolkata (+05:30),
-- 02:45 in Kathmandu (+05:45), but still 1402-12-29 21:00 in UTC (1402 is not a
-- leap year, so Esfand has 29 days and the day is the 365th). Its epoch is
-- 1710882000 in every zone. St. John's is at -02:30 on that day (daylight saving
-- time started on 2024-03-10), so it is 18:30 on 2024-03-19 = 1402-12-29 there,
-- and the fixed zones show negative offsets without any daylight saving time.
-- ---------------------------------------------------------------------
CREATE FUNCTION pg_temp.zfields(zone text, ts jtimestamptz) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE
    r text;
BEGIN
    PERFORM set_config('TimeZone', zone, false);
    r := format('%s-%s-%s doy=%s dow=%s h=%s m=%s s=%s ms=%s us=%s epoch=%s tz=%s tzh=%s tzm=%s',
                pg_catalog.extract('year', ts), pg_catalog.extract('month', ts),
                pg_catalog.extract('day', ts), pg_catalog.extract('doy', ts),
                pg_catalog.extract('dow', ts),
                pg_catalog.extract('hour', ts), pg_catalog.extract('minute', ts),
                pg_catalog.extract('second', ts), pg_catalog.extract('milliseconds', ts),
                pg_catalog.extract('microseconds', ts), pg_catalog.extract('epoch', ts),
                pg_catalog.extract('timezone', ts), pg_catalog.extract('timezone_hour', ts),
                pg_catalog.extract('timezone_minute', ts));
    PERFORM set_config('TimeZone', 'UTC', false);
    RETURN r;
END
$f$;

SELECT z, pg_temp.zfields(z, '1402-12-29 21:00:00.25+00'::jtimestamptz) AS fields
FROM (VALUES ('UTC'), ('Asia/Tehran'), ('Asia/Kolkata'), ('Asia/Kathmandu'),
             ('America/St_Johns'), ('<-03:30>+03:30'), ('<+15:59>-15:59')) AS t(z)
ORDER BY z COLLATE "C";

-- the Jalali day changes at local midnight, so at 20:30:00 UTC in Tehran
SELECT pg_temp.zfields('Asia/Tehran', '1402-12-29 20:29:59.999999+00'::jtimestamptz) AS before_midnight,
       pg_temp.zfields('Asia/Tehran', '1402-12-29 20:30:00+00'::jtimestamptz) AS at_midnight;

-- the same instant, three session zones, through EXTRACT itself
SET timezone = 'UTC';
SELECT EXTRACT(day FROM '1402-12-29 21:00+00'::jtimestamptz) AS day_utc,
       EXTRACT(timezone FROM '1402-12-29 21:00+00'::jtimestamptz) AS tz_utc;
SET timezone = 'Asia/Tehran';
SELECT EXTRACT(day FROM '1402-12-29 21:00+00'::jtimestamptz) AS day_tehran,
       EXTRACT(timezone FROM '1402-12-29 21:00+00'::jtimestamptz) AS tz_tehran,
       EXTRACT(timezone_hour FROM '1402-12-29 21:00+00'::jtimestamptz) AS tzh_tehran,
       EXTRACT(timezone_minute FROM '1402-12-29 21:00+00'::jtimestamptz) AS tzm_tehran;
SET timezone = 'UTC';

-- a jtimestamp is a wall clock: no zone changes anything
SELECT z, pg_temp.fval(z, $q$SELECT EXTRACT(hour FROM '1403-05-15 10:30:45'::jtimestamp)$q$) AS hour,
       pg_temp.fval(z, $q$SELECT EXTRACT(epoch FROM '1403-05-15 10:30:45'::jtimestamp)$q$) AS epoch
FROM (VALUES ('UTC'), ('Asia/Tehran'), ('America/St_Johns')) AS t(z)
ORDER BY z COLLATE "C";

-- ---------------------------------------------------------------------
-- Sweeps over the whole range. The core twin of every value is generated with
-- core's generate_series (in UTC); the casts are binary.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE sw_ts AS
SELECT g, g::jtimestamp AS j
FROM generate_series('-0061-01-01 00:00:00'::jtimestamp::timestamp,
                     '3177-12-29 23:59:59.999999'::jtimestamp::timestamp,
                     interval '41 days 05:23:17.123457') AS g
UNION ALL
SELECT g, g::jtimestamp
FROM (VALUES ('-0061-01-01 00:00:00'::jtimestamp::timestamp),
             ('-0061-01-01 00:00:00.000001'::jtimestamp::timestamp),
             ('1402-12-29 23:59:59.999999'::jtimestamp::timestamp),
             ('1403-01-01 00:00:00'::jtimestamp::timestamp),
             ('3177-12-29 23:59:59.999999'::jtimestamp::timestamp)) AS e(g);
SELECT count(*) > 25000 AS sweep_rows, min(j)::text AS first, max(j)::text AS last FROM sw_ts;

-- time fields and epoch against core, date fields against jdate; every call
-- site sees the units alternate, so the unit cache is exercised
SELECT kind, count(*) AS checks, count(*) FILTER (WHERE NOT ok) AS bad
FROM (
    SELECT 'time and epoch as core' AS kind,
           pg_catalog.extract(u, j)::text = pg_catalog.extract(u, g)::text AS ok
    FROM sw_ts, unnest(ARRAY['hour', 'minute', 'second', 'milliseconds', 'microseconds',
                             'epoch']) AS x(u)
    UNION ALL
    SELECT 'date fields as jdate',
           pg_catalog.extract(u, j)::text = pg_catalog.extract(u, j::jdate)::text
    FROM sw_ts, unnest(ARRAY['year', 'month', 'day', 'quarter', 'doy', 'decade', 'century',
                             'dow', 'isodow']) AS x(u)
    UNION ALL
    SELECT 'jdate_part as extract',
           pg_catalog.extract(u, j) = jdate_part(u, j)
    FROM sw_ts, unnest(ARRAY['year', 'month', 'day', 'hour', 'second', 'epoch']) AS x(u)
) c
GROUP BY kind ORDER BY kind;

-- negative control: the Gregorian day of the same value differs from the Jalali
-- day (and the dow too: Saturday-first), so the same comparison must fail
SELECT count(*) FILTER (WHERE pg_catalog.extract('day', j) <> pg_catalog.extract('day', g)) > 25000 AS day_differs,
       count(*) FILTER (WHERE pg_catalog.extract('dow', j) <> pg_catalog.extract('dow', g)) > 25000 AS dow_differs
FROM sw_ts;

CREATE TEMP TABLE sw_tz AS
SELECT g, g::jtimestamptz AS j
FROM generate_series('-0061-01-01 16:00:00+00'::jtimestamptz::timestamptz,
                     '3177-12-29 07:59:59.999999+00'::jtimestamptz::timestamptz,
                     interval '53 days 05:23:17.123457') AS g
UNION ALL
SELECT g, g::jtimestamptz
FROM (VALUES ('-0061-01-01 16:00:00+00'::jtimestamptz::timestamptz),
             ('-0061-01-01 16:00:00.000001+00'::jtimestamptz::timestamptz),
             ('-0061-01-02 15:59:59.999999+00'::jtimestamptz::timestamptz),
             ('1402-12-29 20:29:59.999999+00'::jtimestamptz::timestamptz),
             ('1402-12-29 20:30:00+00'::jtimestamptz::timestamptz),
             ('3177-12-29 07:59:59.999999+00'::jtimestamptz::timestamptz)) AS e(g);
SELECT count(*) > 15000 AS sweep_rows, min(j)::text AS first, max(j)::text AS last FROM sw_tz;

-- the same comparisons for jtimestamptz in each zone: time fields, epoch and
-- the three timezone fields against core's extract of the same instant (that
-- is the offset of the session zone), date fields against the jdate of the same
-- value (the session zone's local day). The two fixed zones put the first and
-- last safe instants on the edges of the Jalali range.
CREATE FUNCTION pg_temp.sweep_zone(zone text)
RETURNS TABLE (zone_name text, checks bigint, bad bigint, bad_units text)
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM set_config('TimeZone', zone, false);
    RETURN QUERY
    SELECT zone, count(*), count(*) FILTER (WHERE NOT ok),
           string_agg(DISTINCT u, ',') FILTER (WHERE NOT ok)
    FROM (
        SELECT u, pg_catalog.extract(u, j)::text = pg_catalog.extract(u, g)::text AS ok
        FROM sw_tz, unnest(ARRAY['hour', 'minute', 'second', 'milliseconds', 'microseconds',
                                 'epoch', 'timezone', 'timezone_hour',
                                 'timezone_minute']) AS x(u)
        UNION ALL
        SELECT u, pg_catalog.extract(u, j)::text = pg_catalog.extract(u, j::jdate)::text
        FROM sw_tz, unnest(ARRAY['year', 'month', 'day', 'quarter', 'doy', 'decade',
                                 'century', 'dow', 'isodow']) AS x(u)
    ) c;
    PERFORM set_config('TimeZone', 'UTC', false);
END
$f$;

SELECT * FROM pg_temp.sweep_zone('UTC');
SELECT * FROM pg_temp.sweep_zone('Asia/Tehran');
SELECT * FROM pg_temp.sweep_zone('Asia/Kolkata');
SELECT * FROM pg_temp.sweep_zone('Asia/Kathmandu');
SELECT * FROM pg_temp.sweep_zone('America/St_Johns');
SELECT * FROM pg_temp.sweep_zone('Europe/Paris');
SELECT * FROM pg_temp.sweep_zone('<+15:59>-15:59');
SELECT * FROM pg_temp.sweep_zone('<-15:59>+15:59');

-- negative control: in Tehran the local day of an instant is not its UTC day
SET timezone = 'Asia/Tehran';
SELECT count(*) FILTER (WHERE pg_catalog.extract('hour', j) <> (SELECT pg_catalog.extract('hour', g AT TIME ZONE 'UTC'))) > 15000 AS hour_differs_from_utc
FROM sw_tz;
SET timezone = 'UTC';

-- edge values: the first and last safe instants show a Jalali day inside the
-- range in every zone (here UTC and the two extreme offsets); none is an error
SELECT pg_temp.zfields('UTC', '-0061-01-01 16:00:00+00'::jtimestamptz) AS first_utc,
       pg_temp.zfields('<-15:59>+15:59', '-0061-01-01 16:00:00+00'::jtimestamptz) AS first_west,
       pg_temp.zfields('<+15:59>-15:59', '-0061-01-01 16:00:00+00'::jtimestamptz) AS first_east;
SELECT pg_temp.zfields('UTC', '3177-12-29 07:59:59.999999+00'::jtimestamptz) AS last_utc,
       pg_temp.zfields('<-15:59>+15:59', '3177-12-29 07:59:59.999999+00'::jtimestamptz) AS last_west,
       pg_temp.zfields('<+15:59>-15:59', '3177-12-29 07:59:59.999999+00'::jtimestamptz) AS last_east;

-- ---------------------------------------------------------------------
-- infinity: the units that only grow are +/-Infinity in EXTRACT and NULL in
-- jdate_part, every other unit is NULL; timezone fields are NULL for a
-- jtimestamptz and 0A000 for a jtimestamp (unsupported units are refused first)
-- ---------------------------------------------------------------------
SELECT u,
       pg_temp.fval('UTC', format('SELECT pg_catalog.extract(%L, %L::jtimestamp)', u, 'infinity')) AS ts_ext_inf,
       pg_temp.fval('UTC', format('SELECT pg_catalog.extract(%L, %L::jtimestamp)', u, '-infinity')) AS ts_ext_neg,
       pg_temp.fval('UTC', format('SELECT jdate_part(%L, %L::jtimestamp)', u, 'infinity')) AS ts_part_inf,
       pg_temp.fval('UTC', format('SELECT pg_catalog.extract(%L, %L::jtimestamptz)', u, 'infinity')) AS tz_ext_inf,
       pg_temp.fval('UTC', format('SELECT pg_catalog.extract(%L, %L::jtimestamptz)', u, '-infinity')) AS tz_ext_neg,
       pg_temp.fval('UTC', format('SELECT jdate_part(%L, %L::jtimestamptz)', u, '-infinity')) AS tz_part_neg
FROM unnest(ARRAY['year', 'month', 'day', 'quarter', 'doy', 'decade', 'century', 'dow',
                  'isodow', 'hour', 'minute', 'second', 'milliseconds', 'microseconds',
                  'epoch', 'timezone', 'timezone_hour', 'timezone_minute']) AS t(u)
ORDER BY array_position(ARRAY['year', 'month', 'day', 'quarter', 'doy', 'decade', 'century',
                              'dow', 'isodow', 'hour', 'minute', 'second', 'milliseconds',
                              'microseconds', 'epoch', 'timezone', 'timezone_hour',
                              'timezone_minute'], u);

-- the infinite answers have the numeric type, and the same infinities as jdate
SELECT pg_typeof(EXTRACT(epoch FROM 'infinity'::jtimestamp)) AS ts_type,
       EXTRACT(epoch FROM 'infinity'::jtimestamp) = EXTRACT(epoch FROM 'infinity'::jdate) AS ts_as_jdate,
       EXTRACT(year FROM '-infinity'::jtimestamptz) = EXTRACT(year FROM '-infinity'::jdate) AS tz_as_jdate,
       EXTRACT(year FROM 'infinity'::jtimestamptz) > 1e100 AS positive;

-- ---------------------------------------------------------------------
-- errors, as SQLSTATE: week, isoyear, millennium, julian are 0A000 for both
-- types (also on infinity), the timezone fields are 0A000 for jtimestamp only,
-- an unknown unit is 22023; both are raised before the value is looked at
-- ---------------------------------------------------------------------
SELECT u,
       pg_temp.fval('UTC', format('SELECT pg_catalog.extract(%L, %L::jtimestamp)', u, '1403-05-15 10:00')) AS ts_extract,
       pg_temp.fval('UTC', format('SELECT jdate_part(%L, %L::jtimestamp)', u, '1403-05-15 10:00')) AS ts_part,
       pg_temp.fval('UTC', format('SELECT pg_catalog.extract(%L, %L::jtimestamp)', u, 'infinity')) AS ts_extract_inf,
       pg_temp.fval('UTC', format('SELECT pg_catalog.extract(%L, %L::jtimestamptz)', u, '1403-05-15 10:00+00')) AS tz_extract,
       pg_temp.fval('UTC', format('SELECT jdate_part(%L, %L::jtimestamptz)', u, '1403-05-15 10:00+00')) AS tz_part,
       pg_temp.fval('UTC', format('SELECT jdate_part(%L, %L::jtimestamptz)', u, '-infinity')) AS tz_part_neg_inf
FROM unnest(ARRAY['week', 'isoyear', 'millennium', 'julian', 'foo', '', 'timestamp']) AS t(u)
ORDER BY u;

-- the same units are 0A000 / 22023 for jdate today (unchanged)
SELECT u,
       pg_temp.fval('UTC', format('SELECT pg_catalog.extract(%L, %L::jdate)', u, '1403-05-15')) AS jdate_extract,
       pg_temp.fval('UTC', format('SELECT jdate_part(%L, %L::jdate)', u, '1403-05-15')) AS jdate_part
FROM unnest(ARRAY['week', 'isoyear', 'millennium', 'julian', 'foo']) AS t(u)
ORDER BY u;

-- the messages name the real type; the jdate messages did not change
SELECT pg_temp.emsg($q$SELECT jdate_part('foo', '1403-05-15 10:00'::jtimestamp)$q$) ~ 'type jtimestamp$' AS unknown_jtimestamp,
       pg_temp.emsg($q$SELECT jdate_part('foo', '1403-05-15 10:00+00'::jtimestamptz)$q$) ~ 'type jtimestamptz$' AS unknown_jtimestamptz,
       pg_temp.emsg($q$SELECT pg_catalog.extract('foo', '1403-05-15 10:00'::jtimestamp)$q$) ~ 'type jtimestamp$' AS unknown_extract_jtimestamp,
       pg_temp.emsg($q$SELECT jdate_part('foo', '1403-05-15'::jdate)$q$) ~ 'type jdate$' AS unknown_jdate,
       pg_temp.emsg($q$SELECT jdate_part('week', '1403-05-15 10:00'::jtimestamp)$q$) ~ 'type jtimestamp$' AS unsupported_jtimestamp,
       pg_temp.emsg($q$SELECT jdate_part('timezone', '1403-05-15 10:00'::jtimestamp)$q$) ~ 'type jtimestamp$' AS timezone_jtimestamp,
       pg_temp.emsg($q$SELECT jdate_part('julian', '1403-05-15 10:00+00'::jtimestamptz)$q$) ~ 'type jtimestamptz$' AS unsupported_jtimestamptz,
       pg_temp.emsg($q$SELECT jdate_part('week', '1403-05-15'::jdate)$q$) = 'unit not supported for jdate_part/extract' AS unsupported_jdate;

-- NULL in, NULL out (strict)
SELECT pg_catalog.extract('year', NULL::jtimestamp) IS NULL AS null_value,
       pg_catalog.extract(NULL, '1403-05-15 10:00'::jtimestamp) IS NULL AS null_unit,
       jdate_part('year', NULL::jtimestamptz) IS NULL AS null_value_tz,
       jdate_part(NULL, '1403-05-15 10:00+00'::jtimestamptz) IS NULL AS null_unit_tz;

-- ---------------------------------------------------------------------
-- bare literals: with three types offering extract() and jdate_part() the
-- unknown literal no longer picks one (it used to be jdate for jdate_part);
-- EXTRACT(year FROM '1403-05-15 10:00') is ambiguous (42725). A typed value
-- is unambiguous.
-- ---------------------------------------------------------------------
SELECT pg_temp.fval('UTC', $q$SELECT EXTRACT(year FROM '1403-05-15 10:00')$q$) AS extract_literal,
       pg_temp.fval('UTC', $q$SELECT jdate_part('year', '1403-05-15 10:00')$q$) AS part_literal,
       pg_temp.fval('UTC', $q$SELECT jdate_part('year', '1403-05-15')$q$) AS part_date_literal,
       pg_temp.fval('UTC', $q$SELECT EXTRACT(year FROM '1403-05-15 10:00'::jtimestamp)$q$) AS extract_typed,
       pg_temp.fval('UTC', $q$SELECT jdate_part('year', jdate '1403-05-15')$q$) AS part_jdate;

-- ---------------------------------------------------------------------
-- volatility: jtimestamptz fields follow the session zone (STABLE),
-- jtimestamp fields never do (IMMUTABLE); an index expression must be immutable
-- ---------------------------------------------------------------------
SELECT z, pg_temp.fval(z, $q$SELECT jdate_part('day', '1402-12-29 21:00+00'::jtimestamptz)$q$) AS tz_day
FROM (VALUES ('UTC'), ('Asia/Tehran')) AS t(z) ORDER BY z COLLATE "C";
SELECT z, pg_temp.fval(z, $q$SELECT jdate_part('day', '1403-01-01 00:30'::jtimestamp)$q$) AS ts_day
FROM (VALUES ('UTC'), ('Asia/Tehran')) AS t(z) ORDER BY z COLLATE "C";

CREATE TEMP TABLE fx (a jtimestamp, b jtimestamptz);
SELECT pg_temp.ddl('CREATE INDEX ON fx ((EXTRACT(year FROM a)))') AS index_extract_jtimestamp,
       pg_temp.ddl('CREATE INDEX ON fx ((jdate_part(''month'', a)))') AS index_part_jtimestamp,
       pg_temp.ddl('CREATE INDEX ON fx ((EXTRACT(year FROM b)))') AS index_extract_jtimestamptz,
       pg_temp.ddl('CREATE INDEX ON fx ((jdate_part(''month'', b)))') AS index_part_jtimestamptz;
-- ... and it is used for jtimestamp, after the table has some rows
INSERT INTO fx SELECT '1403-01-01'::jtimestamp + make_interval(days => i), NULL
FROM generate_series(0, 4000) AS i;
ANALYZE fx;
SET enable_seqscan = off;
SELECT count(*) AS rows_in_1405 FROM fx WHERE EXTRACT(year FROM a) = 1405;
RESET enable_seqscan;

-- the planner can use the index: the plan has an index scan on the expression
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
SET enable_seqscan = off;
SELECT pg_temp.plan_uses_index('SELECT * FROM fx WHERE EXTRACT(year FROM a) = 1405') AS year_index_used;
RESET enable_seqscan;
