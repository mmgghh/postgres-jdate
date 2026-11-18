-- Consistency sweep for the J4 field functions and the stage gate of Stage J4
-- (EXTRACT, jdate_part, jdate_trunc, jday_format, jmonth_format on jdate,
-- jtimestamp and jtimestamptz).
--
-- The J4 tests each compare one function family with an oracle. This test
-- compares the families with EACH OTHER, on the same instants:
--   * jtimestamptz: every half hour of two windows (Gregorian 2024-03-17 to
--     2024-03-23, which holds the end of the common year 1402 and Nowruz 1403, and
--     2025-03-17 to 2025-03-23, which holds the leap day 1403-12-30 and Nowruz
--     1404), in Asia/Tehran (+03:30), Asia/Kolkata (+05:30), Asia/Kathmandu
--     (+05:45), Europe/Paris (+01, the 2024 and 2025 changes come later) and UTC,
--     289 instants per window and zone. The fields, jdate_part, the truncations,
--     jday_format / jmonth_format and the text of the value (x::text, which is
--     "YYYY-MM-DD HH:MM:SS+HH:MM" in the session zone) must all agree, and agree
--     with core where core has the same thing (extract of the timestamptz for the
--     time fields, epoch and the zone fields, date_trunc for day and finer) and
--     with the jdate / jtimestamp views of the same value (x::jdate and
--     x AT TIME ZONE zone).
--   * jtimestamp: the same half hours as wall clocks, in two session zones (the
--     type is zone free, so the answers must not move).
-- Mismatches are counted by check and by zone and every count must be 0; the
-- comparison counts are printed too, so a sweep that shrank would show. Three
-- negative controls prove that the checks can fail.
-- Then: hand-computed rows at Nowruz 1403 and at the end of the leap year 1403 in
-- every zone, the infinity matrix of every J4 function (as it really is: EXTRACT
-- raises 0A000 for an unsupported unit even on infinity, jdate_trunc returns
-- infinity for every unit it knows), the volatility catalog check, the index
-- recipes (an index on x AT TIME ZONE zone and on jday_format of it, which the
-- planner uses and which return what a sequential scan returns), and the list of
-- calls with a bare literal that are ambiguous (42725) or undefined (42883) now,
-- collected for the documentation.
-- Every text sort key says COLLATE "C", so the output does not depend on the
-- collation of the database. Errors are shown as SQLSTATE only. The text input of
-- both timestamp types is Jalali: the Gregorian 2024-03-19 20:30 UTC (Tehran
-- midnight of Nowruz 1403) is written 1402-12-29 20:30+00, and the Gregorian
-- 2025-03-20 20:29:59 UTC is written 1403-12-30 20:29:59+00. Saturday-first dow:
-- Saturday 0, Sunday 1, ..., Friday 6.
SET DateStyle = 'ISO, YMD';
SET timezone = 'UTC';

-- The text of the single value of a query, or "ERR <sqlstate>", under a session
-- time zone (restored afterwards).
CREATE FUNCTION pg_temp.val(zone text, q text) RETURNS text
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

-- 'ok' or "ERR <sqlstate>" for a statement (its rows, if any, are discarded).
CREATE FUNCTION pg_temp.state(q text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE q;
    RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
    RETURN 'ERR ' || SQLSTATE;
END
$f$;

-- Whether the plan of a query uses an index.
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

-- The count of a query once through an index path and once through a sequential
-- scan.
CREATE FUNCTION pg_temp.count_with(q text, use_index boolean) RETURNS bigint
LANGUAGE plpgsql AS $f$
DECLARE
    r bigint;
BEGIN
    PERFORM set_config('enable_seqscan', (NOT use_index)::text, false);
    PERFORM set_config('enable_indexscan', use_index::text, false);
    PERFORM set_config('enable_bitmapscan', use_index::text, false);
    EXECUTE q INTO r;
    PERFORM set_config('enable_seqscan', 'on', false);
    PERFORM set_config('enable_indexscan', 'on', false);
    PERFORM set_config('enable_bitmapscan', 'on', false);
    RETURN r;
END
$f$;

-- ---------------------------------------------------------------------
-- catalog: every J4 function (the new ones for jtimestamp and jtimestamptz and
-- the older jdate ones next to them), with its volatility. A call that reads the
-- session zone is STABLE (jtimestamptz); the explicit-zone jdate_trunc, which
-- reads no session setting, and the jtimestamp and jdate ones are IMMUTABLE. All
-- are strict and parallel safe.
-- ---------------------------------------------------------------------
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args, p.prorettype::regtype AS returns,
       p.provolatile AS volatility,
       p.provolatile = CASE WHEN pg_get_function_identity_arguments(p.oid) IN ('text, jtimestamptz', 'jtimestamptz, sep text')
                            THEN 's' ELSE 'i' END AS as_documented,
       p.proisstrict AS strict, p.proparallel AS parallel
FROM pg_proc p
WHERE p.proname IN ('extract', 'jdate_part', 'jdate_trunc', 'jday_format', 'jmonth_format')
  AND p.proargtypes::oid[] && ARRAY['jdate'::regtype::oid, 'jtimestamp'::regtype::oid, 'jtimestamptz'::regtype::oid]
ORDER BY p.proname COLLATE "C", pg_get_function_identity_arguments(p.oid) COLLATE "C";

SELECT count(*) AS j4_functions,
       count(*) FILTER (WHERE p.provolatile = 's') AS stable,
       count(*) FILTER (WHERE p.provolatile = 'i') AS immutable,
       count(*) FILTER (WHERE p.provolatile = 'v') AS volatile_,
       count(*) FILTER (WHERE p.proisstrict AND p.proparallel = 's') AS strict_and_parallel_safe
FROM pg_proc p
WHERE p.proname IN ('extract', 'jdate_part', 'jdate_trunc', 'jday_format', 'jmonth_format')
  AND p.proargtypes::oid[] && ARRAY['jdate'::regtype::oid, 'jtimestamp'::regtype::oid, 'jtimestamptz'::regtype::oid];

-- ---------------------------------------------------------------------
-- fixtures: the instants. The jtimestamptz values come from core's timestamptz
-- arithmetic (a fixed half hour step, so no zone is involved) through the
-- IMMUTABLE cast; the jtimestamp values are the same half hours as wall clocks.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jc_zone (z text PRIMARY KEY);
INSERT INTO jc_zone VALUES ('Asia/Tehran'), ('Asia/Kolkata'), ('Asia/Kathmandu'), ('Europe/Paris'), ('UTC');

CREATE TEMP TABLE jc_inst (w text, g int, x jtimestamptz);
INSERT INTO jc_inst
SELECT w.w, g, (w.t0 + g * interval '30 minutes')::jtimestamptz
FROM (VALUES ('A', timestamptz '2024-03-17 00:00:00+00'), ('B', timestamptz '2025-03-17 00:00:00+00')) w(w, t0),
     generate_series(0, 288) g;

CREATE TEMP TABLE jc_wall (w text, g int, p jtimestamp);
INSERT INTO jc_wall
SELECT w.w, g, (w.t0 + g * interval '30 minutes')::jtimestamp
FROM (VALUES ('A', timestamp '2024-03-17 00:00:00'), ('B', timestamp '2025-03-17 00:00:00')) w(w, t0),
     generate_series(0, 288) g;

SELECT w, count(*) AS instants, min(x)::timestamptz AS first_utc, max(x)::timestamptz AS last_utc
FROM jc_inst GROUP BY w ORDER BY w;
SELECT w, count(*) AS walls, min(p)::timestamp AS first_wall, max(p)::timestamp AS last_wall
FROM jc_wall GROUP BY w ORDER BY w;

CREATE TEMP TABLE jc_res (zone text, chk text, n bigint, bad bigint, first_bad text);
CREATE TEMP TABLE jc_cov (zone text, nowruz_1403_instants bigint, esfand_30_1403_instants bigint,
                          jalali_days bigint, offsets bigint);
CREATE TEMP TABLE jc_base (w text, g int, x jtimestamptz, t text, sfx text, l jtimestamp, d jdate, c timestamptz);

-- ---------------------------------------------------------------------
-- the jtimestamptz sweep, one zone per call
--   t   = x::text, "YYYY-MM-DD HH:MM:SS+HH[:MM]" in the session zone
--   sfx = the offset part of t (constant in both windows, for every zone here)
--   l   = x AT TIME ZONE zone: the wall clock as a jtimestamp
--   d   = x::jdate (session zone), c = x::timestamptz (core's twin, binary cast)
-- ---------------------------------------------------------------------
CREATE FUNCTION pg_temp.jc_sweep(zn text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM set_config('TimeZone', zn, false);
    TRUNCATE jc_base;
    INSERT INTO jc_base
    SELECT i.w, i.g, i.x, i.x::text, substring(i.x::text from 20), i.x AT TIME ZONE zn, i.x::jdate, i.x::timestamptz
    FROM jc_inst i;

    INSERT INTO jc_cov
    SELECT zn, count(*) FILTER (WHERE left(t, 10) = '1403-01-01'), count(*) FILTER (WHERE left(t, 10) = '1403-12-30'),
           count(DISTINCT left(t, 10)), count(DISTINCT sfx)
    FROM jc_base;

    -- one value of x per row
    INSERT INTO jc_res
    SELECT zn, k.chk, count(*), count(*) FILTER (WHERE k.ok IS NOT TRUE), min(b.t) FILTER (WHERE k.ok IS NOT TRUE)
    FROM jc_base b CROSS JOIN LATERAL (VALUES
        -- the fields against the text of the value
        ('text: year',   extract(year FROM b.x)   = substr(b.t, 1, 4)::int),
        ('text: month',  extract(month FROM b.x)  = substr(b.t, 6, 2)::int),
        ('text: day',    extract(day FROM b.x)    = substr(b.t, 9, 2)::int),
        ('text: hour',   extract(hour FROM b.x)   = substr(b.t, 12, 2)::int),
        ('text: minute', extract(minute FROM b.x) = substr(b.t, 15, 2)::int),
        ('text: second', extract(second FROM b.x) = substr(b.t, 18, 2)::int),
        ('text: timezone', extract(timezone FROM b.x)
             = (CASE substr(b.sfx, 1, 1) WHEN '-' THEN -1 ELSE 1 END)
               * (substr(b.sfx, 2, 2)::int * 3600 + coalesce(nullif(substr(b.sfx, 5, 2), ''), '0')::int * 60)),
        ('text: timezone_hour',   extract(timezone_hour FROM b.x) = substr(b.sfx, 2, 2)::int),
        ('text: timezone_minute', extract(timezone_minute FROM b.x) = coalesce(nullif(substr(b.sfx, 5, 2), ''), '0')::int),
        ('text: wall clock l', b.l::text = left(b.t, 19)),
        ('text: jdate d', b.d::text = left(b.t, 10)),
        ('text: input round trip', b.t::jtimestamptz = b.x),
        ('text: core round trip', b.x::timestamptz::jtimestamptz = b.x),
        -- jday_format and jmonth_format against the text and against the fields
        ('format: jday_format = text', jday_format(b.x) = left(b.t, 10)),
        ('format: jmonth_format = text', jmonth_format(b.x) = left(b.t, 7)),
        ('format: jday_format sep', jday_format(b.x, '/') = replace(left(b.t, 10), '-', '/')),
        ('format: jmonth_format sep', jmonth_format(b.x, '/') = replace(left(b.t, 7), '-', '/')),
        ('format: jday_format empty sep', jday_format(b.x, '') = replace(left(b.t, 10), '-', '')),
        ('format: jmonth_format empty sep', jmonth_format(b.x, '') = replace(left(b.t, 7), '-', '')),
        ('format: jday_format = fields', jday_format(b.x)
             = lpad(extract(year FROM b.x)::text, 4, '0') || '-' || lpad(extract(month FROM b.x)::text, 2, '0')
               || '-' || lpad(extract(day FROM b.x)::text, 2, '0')),
        ('format: jmonth_format = fields', jmonth_format(b.x)
             = lpad(extract(year FROM b.x)::text, 4, '0') || '-' || lpad(extract(month FROM b.x)::text, 2, '0')),
        ('format: jday_format(l) = jday_format(x)', jday_format(b.l) = jday_format(b.x)),
        ('format: jmonth_format(l) = jmonth_format(x)', jmonth_format(b.l) = jmonth_format(b.x)),
        ('format: jday_format(d) = jday_format(x)', jday_format(b.d) = jday_format(b.x)),
        ('format: jmonth_format(d) = jmonth_format(x)', jmonth_format(b.d) = jmonth_format(b.x)),
        ('format: jdate_format(timestamptz, false) = text', jdate_format(b.c, false) = left(b.t, 10)),
        ('format: jdate_format(timestamptz) = text', jdate_format(b.c) = left(b.t, 19)),
        -- the truncations against the text composed by hand (the offset is the
        -- same at the truncated instant in these windows)
        ('trunc text: second', jdate_trunc('second', b.x)::text = b.t),
        ('trunc text: minute', jdate_trunc('minute', b.x)::text = left(b.t, 16) || ':00' || b.sfx),
        ('trunc text: hour', jdate_trunc('hour', b.x)::text = left(b.t, 13) || ':00:00' || b.sfx),
        ('trunc text: day', jdate_trunc('day', b.x)::text = left(b.t, 10) || ' 00:00:00' || b.sfx),
        ('trunc text: month', jdate_trunc('month', b.x)::text = left(b.t, 7) || '-01 00:00:00' || b.sfx),
        ('trunc text: quarter', jdate_trunc('quarter', b.x)::text
             = left(b.t, 5) || lpad((3 * (extract(quarter FROM b.x)::int - 1) + 1)::text, 2, '0') || '-01 00:00:00' || b.sfx),
        ('trunc text: year', jdate_trunc('year', b.x)::text = left(b.t, 4) || '-01-01 00:00:00' || b.sfx),
        -- the Saturday-first week: two ways to the same start
        ('trunc text: week by the Gregorian calendar', jdate_trunc('week', b.x)::text
             = ((date_trunc('day', b.l::timestamp) - extract(dow FROM b.x)::int * interval '1 day')::jtimestamp
                AT TIME ZONE zn)::text),
        ('trunc text: week by jdate days', b.x::jdate - jdate_trunc('week', b.x)::jdate = extract(dow FROM b.x)::int),
        ('trunc text: week starts on a Saturday', extract(dow FROM jdate_trunc('week', b.x)) = 0)
    ) AS k(chk, ok)
    GROUP BY k.chk;

    -- every field and every function of the same name, unit by unit
    INSERT INTO jc_res
    SELECT zn, k.chk, count(*), count(*) FILTER (WHERE k.ok IS NOT TRUE), min(b.t || ' ' || u.u) FILTER (WHERE k.ok IS NOT TRUE)
    FROM jc_base b
         CROSS JOIN unnest(ARRAY['year', 'month', 'day', 'quarter', 'doy', 'decade', 'century', 'dow', 'isodow',
                                 'hour', 'minute', 'second', 'milliseconds', 'microseconds', 'epoch',
                                 'timezone', 'timezone_hour', 'timezone_minute']) AS u(u)
         CROSS JOIN LATERAL (VALUES
        ('units: jdate_part = extract (jtimestamptz)', jdate_part(u.u, b.x) = pg_catalog.extract(u.u, b.x))
    ) AS k(chk, ok)
    GROUP BY k.chk;

    -- the 15 units a jtimestamp has: the wall clock l has the fields of x (epoch
    -- of the wall clock is the epoch of the instant plus the offset)
    INSERT INTO jc_res
    SELECT zn, k.chk, count(*), count(*) FILTER (WHERE k.ok IS NOT TRUE), min(b.t || ' ' || u.u) FILTER (WHERE k.ok IS NOT TRUE)
    FROM jc_base b
         CROSS JOIN unnest(ARRAY['year', 'month', 'day', 'quarter', 'doy', 'decade', 'century', 'dow', 'isodow',
                                 'hour', 'minute', 'second', 'milliseconds', 'microseconds', 'epoch']) AS u(u)
         CROSS JOIN LATERAL (VALUES
        ('units: extract(l) = extract(x)', CASE WHEN u.u = 'epoch'
              THEN pg_catalog.extract('epoch', b.l) = pg_catalog.extract('epoch', b.x) + pg_catalog.extract('timezone', b.x)
              ELSE pg_catalog.extract(u.u, b.l) = pg_catalog.extract(u.u, b.x) END),
        ('units: jdate_part = extract (jtimestamp)', jdate_part(u.u, b.l) = pg_catalog.extract(u.u, b.l))
    ) AS k(chk, ok)
    GROUP BY k.chk;

    -- the date fields against the jdate of the same value
    INSERT INTO jc_res
    SELECT zn, k.chk, count(*), count(*) FILTER (WHERE k.ok IS NOT TRUE), min(b.t || ' ' || u.u) FILTER (WHERE k.ok IS NOT TRUE)
    FROM jc_base b
         CROSS JOIN unnest(ARRAY['year', 'month', 'day', 'quarter', 'doy', 'decade', 'century', 'dow', 'isodow']) AS u(u)
         CROSS JOIN LATERAL (VALUES
        ('date fields: extract(x) = extract(x::jdate)', pg_catalog.extract(u.u, b.x) = pg_catalog.extract(u.u, b.d)),
        ('date fields: jdate_part(x) = jdate_part(x::jdate)', jdate_part(u.u, b.x) = jdate_part(u.u, b.d)),
        ('date fields: extract(l) = extract(x::jdate)', pg_catalog.extract(u.u, b.l) = pg_catalog.extract(u.u, b.d))
    ) AS k(chk, ok)
    GROUP BY k.chk;

    -- the time fields, epoch and the zone fields against core's extract of the
    -- timestamptz (the same instant, the same session zone)
    INSERT INTO jc_res
    SELECT zn, k.chk, count(*), count(*) FILTER (WHERE k.ok IS NOT TRUE), min(b.t || ' ' || u.u) FILTER (WHERE k.ok IS NOT TRUE)
    FROM jc_base b
         CROSS JOIN unnest(ARRAY['hour', 'minute', 'second', 'milliseconds', 'microseconds', 'epoch',
                                 'timezone', 'timezone_hour', 'timezone_minute']) AS u(u)
         CROSS JOIN LATERAL (VALUES
        ('core: extract(x) = extract(timestamptz)', pg_catalog.extract(u.u, b.x) = pg_catalog.extract(u.u, b.c))
    ) AS k(chk, ok)
    GROUP BY k.chk;

    -- the truncation units of jdate_trunc
    INSERT INTO jc_res
    SELECT zn, k.chk, count(*), count(*) FILTER (WHERE k.ok IS NOT TRUE), min(b.t || ' ' || u.u) FILTER (WHERE k.ok IS NOT TRUE)
    FROM jc_base b
         CROSS JOIN unnest(ARRAY['year', 'quarter', 'month', 'week', 'day', 'hour', 'minute', 'second',
                                 'milliseconds', 'microseconds']) AS u(u)
         CROSS JOIN LATERAL (VALUES
        ('trunc: session zone = zone argument', jdate_trunc(u.u, b.x) = jdate_trunc(u.u, b.x, zn)),
        ('trunc: instant = wall clock at the zone', jdate_trunc(u.u, b.x) = (jdate_trunc(u.u, b.l) AT TIME ZONE zn)),
        ('trunc: never above the value', jdate_trunc(u.u, b.x) <= b.x),
        ('trunc: idempotent', jdate_trunc(u.u, jdate_trunc(u.u, b.x)) = jdate_trunc(u.u, b.x)),
        ('trunc: stays in the year of the value, but a week', jdate_trunc('year', jdate_trunc(u.u, b.x)) = jdate_trunc('year', b.x)
             OR u.u IN ('week', 'year'))
    ) AS k(chk, ok)
    GROUP BY k.chk;

    -- the units shared with jdate_trunc(jdate): the start is the local date
    INSERT INTO jc_res
    SELECT zn, k.chk, count(*), count(*) FILTER (WHERE k.ok IS NOT TRUE), min(b.t || ' ' || u.u) FILTER (WHERE k.ok IS NOT TRUE)
    FROM jc_base b
         CROSS JOIN unnest(ARRAY['year', 'quarter', 'month', 'week', 'day']) AS u(u)
         CROSS JOIN LATERAL (VALUES
        ('trunc dates: jdate_trunc(x::jdate) = date of jdate_trunc(x)',
             jdate_trunc(u.u, b.d)::text = left(jdate_trunc(u.u, b.x)::text, 10)),
        ('trunc dates: jdate_trunc(l) = jdate_trunc(x::jdate) at midnight',
             jdate_trunc(u.u, b.l)::text = jdate_trunc(u.u, b.d)::text || ' 00:00:00')
    ) AS k(chk, ok)
    GROUP BY k.chk;

    -- the units core has: the same truncation as core's date_trunc
    INSERT INTO jc_res
    SELECT zn, k.chk, count(*), count(*) FILTER (WHERE k.ok IS NOT TRUE), min(b.t || ' ' || u.u) FILTER (WHERE k.ok IS NOT TRUE)
    FROM jc_base b
         CROSS JOIN unnest(ARRAY['day', 'hour', 'minute', 'second', 'milliseconds', 'microseconds']) AS u(u)
         CROSS JOIN LATERAL (VALUES
        ('core trunc: jdate_trunc(x) = date_trunc(timestamptz)', jdate_trunc(u.u, b.x)::timestamptz = date_trunc(u.u, b.c)),
        ('core trunc: jdate_trunc(x, zone) = date_trunc(timestamptz, zone)',
             jdate_trunc(u.u, b.x, zn)::timestamptz = date_trunc(u.u, b.c, zn))
    ) AS k(chk, ok)
    GROUP BY k.chk;

    PERFORM set_config('TimeZone', 'UTC', false);
END
$f$;

SELECT count(pg_temp.jc_sweep(z)) AS zones_swept FROM jc_zone;

-- coverage: the sweep reaches the Nowruz day and the leap day (48 half hours in
-- each of those days in every zone), covers 14 distinct Jalali days (7 in each
-- window) and the offset of the zone never changes inside the windows (one value)
SELECT * FROM jc_cov ORDER BY zone COLLATE "C";

-- every comparison counted, by zone and by group of checks; all mismatches are 0
SELECT zone, count(*) AS kinds_of_check, sum(n) AS comparisons, sum(bad) AS mismatches
FROM jc_res GROUP BY zone ORDER BY zone COLLATE "C";
SELECT split_part(chk, ':', 1) AS grp, count(DISTINCT chk) AS kinds_of_check, sum(n) AS comparisons, sum(bad) AS mismatches
FROM jc_res GROUP BY split_part(chk, ':', 1) ORDER BY split_part(chk, ':', 1) COLLATE "C";
-- the failures, with the first failing value (none)
SELECT zone, chk, n, bad, first_bad FROM jc_res WHERE bad > 0 ORDER BY zone COLLATE "C", chk COLLATE "C";

-- ---------------------------------------------------------------------
-- the jtimestamp sweep: the same half hours as wall clocks, in two session
-- zones; the answers must not depend on the zone
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jc_wres (zone text, chk text, n bigint, bad bigint, first_bad text, signature text);

CREATE FUNCTION pg_temp.jc_sweep_wall(zn text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM set_config('TimeZone', zn, false);
    TRUNCATE jc_base;   -- reuse: x unused, l = the wall clock, d = its jdate, c unused
    INSERT INTO jc_base
    SELECT w.w, w.g, NULL, w.p::text, '', w.p, w.p::jdate, NULL
    FROM jc_wall w;

    INSERT INTO jc_wres
    SELECT zn, k.chk, count(*), count(*) FILTER (WHERE k.ok IS NOT TRUE), min(b.t) FILTER (WHERE k.ok IS NOT TRUE), NULL
    FROM jc_base b CROSS JOIN LATERAL (VALUES
        ('text: year',   extract(year FROM b.l)   = substr(b.t, 1, 4)::int),
        ('text: month',  extract(month FROM b.l)  = substr(b.t, 6, 2)::int),
        ('text: day',    extract(day FROM b.l)    = substr(b.t, 9, 2)::int),
        ('text: hour',   extract(hour FROM b.l)   = substr(b.t, 12, 2)::int),
        ('text: minute', extract(minute FROM b.l) = substr(b.t, 15, 2)::int),
        ('text: second', extract(second FROM b.l) = substr(b.t, 18, 2)::int),
        ('text: jdate d', b.d::text = left(b.t, 10)),
        ('format: jday_format = text', jday_format(b.l) = left(b.t, 10)),
        ('format: jmonth_format = text', jmonth_format(b.l) = left(b.t, 7)),
        ('format: jday_format sep', jday_format(b.l, '/') = replace(left(b.t, 10), '-', '/')),
        ('format: jmonth_format empty sep', jmonth_format(b.l, '') = replace(left(b.t, 7), '-', '')),
        ('format: jday_format(d) = jday_format(l)', jday_format(b.d) = jday_format(b.l)),
        ('format: jmonth_format(d) = jmonth_format(l)', jmonth_format(b.d) = jmonth_format(b.l)),
        ('trunc text: second', jdate_trunc('second', b.l)::text = b.t),
        ('trunc text: minute', jdate_trunc('minute', b.l)::text = left(b.t, 16) || ':00'),
        ('trunc text: hour', jdate_trunc('hour', b.l)::text = left(b.t, 13) || ':00:00'),
        ('trunc text: day', jdate_trunc('day', b.l)::text = left(b.t, 10) || ' 00:00:00'),
        ('trunc text: month', jdate_trunc('month', b.l)::text = left(b.t, 7) || '-01 00:00:00'),
        ('trunc text: quarter', jdate_trunc('quarter', b.l)::text
             = left(b.t, 5) || lpad((3 * (extract(quarter FROM b.l)::int - 1) + 1)::text, 2, '0') || '-01 00:00:00'),
        ('trunc text: year', jdate_trunc('year', b.l)::text = left(b.t, 4) || '-01-01 00:00:00'),
        ('trunc text: week by the Gregorian calendar', jdate_trunc('week', b.l)::timestamp
             = date_trunc('day', b.l::timestamp) - extract(dow FROM b.l)::int * interval '1 day'),
        ('trunc text: week by jdate days', b.d - jdate_trunc('week', b.l)::jdate = extract(dow FROM b.l)::int)
    ) AS k(chk, ok)
    GROUP BY k.chk;

    INSERT INTO jc_wres
    SELECT zn, k.chk, count(*), count(*) FILTER (WHERE k.ok IS NOT TRUE), min(b.t || ' ' || u.u) FILTER (WHERE k.ok IS NOT TRUE), NULL
    FROM jc_base b
         CROSS JOIN unnest(ARRAY['year', 'month', 'day', 'quarter', 'doy', 'decade', 'century', 'dow', 'isodow',
                                 'hour', 'minute', 'second', 'milliseconds', 'microseconds', 'epoch']) AS u(u)
         CROSS JOIN LATERAL (VALUES
        ('units: jdate_part = extract', jdate_part(u.u, b.l) = pg_catalog.extract(u.u, b.l)),
        ('units: extract(l) = extract(l::timestamp) for the time fields and epoch',
             u.u NOT IN ('hour', 'minute', 'second', 'milliseconds', 'microseconds', 'epoch')
             OR pg_catalog.extract(u.u, b.l) = pg_catalog.extract(u.u, b.l::timestamp)),
        ('units: extract(l) = extract(l::jdate) for the date fields',
             u.u IN ('hour', 'minute', 'second', 'milliseconds', 'microseconds', 'epoch')
             OR pg_catalog.extract(u.u, b.l) = pg_catalog.extract(u.u, b.d))
    ) AS k(chk, ok)
    GROUP BY k.chk;

    INSERT INTO jc_wres
    SELECT zn, k.chk, count(*), count(*) FILTER (WHERE k.ok IS NOT TRUE), min(b.t || ' ' || u.u) FILTER (WHERE k.ok IS NOT TRUE), NULL
    FROM jc_base b
         CROSS JOIN unnest(ARRAY['year', 'quarter', 'month', 'week', 'day', 'hour', 'minute', 'second',
                                 'milliseconds', 'microseconds']) AS u(u)
         CROSS JOIN LATERAL (VALUES
        ('trunc: never above, idempotent', jdate_trunc(u.u, b.l) <= b.l AND jdate_trunc(u.u, jdate_trunc(u.u, b.l)) = jdate_trunc(u.u, b.l)),
        ('trunc: core units = date_trunc', u.u IN ('year', 'quarter', 'month', 'week')
             OR jdate_trunc(u.u, b.l)::timestamp = date_trunc(u.u, b.l::timestamp)),
        ('trunc: Jalali units = jdate_trunc(jdate)', u.u NOT IN ('year', 'quarter', 'month', 'week', 'day')
             OR jdate_trunc(u.u, b.l) = jdate_trunc(u.u, b.d)::jtimestamp)
    ) AS k(chk, ok)
    GROUP BY k.chk;

    -- a signature of every answer (all of them are IMMUTABLE)
    INSERT INTO jc_wres
    SELECT zn, 'signature', count(*), 0, NULL,
           md5(string_agg(concat_ws('|', b.t, jday_format(b.l), jmonth_format(b.l, '/'), jdate_trunc('week', b.l)::text,
                                    jdate_trunc('month', b.l)::text, jdate_trunc('hour', b.l)::text,
                                    extract(dow FROM b.l)::text, extract(epoch FROM b.l)::text, jdate_part('doy', b.l)::text),
                           ',' ORDER BY b.w, b.g))
    FROM jc_base b;

    PERFORM set_config('TimeZone', 'UTC', false);
END
$f$;

SELECT count(pg_temp.jc_sweep_wall(z)) AS zones_swept FROM unnest(ARRAY['UTC', 'Pacific/Kiritimati', 'America/Sao_Paulo']) AS z;

SELECT zone, count(*) FILTER (WHERE chk <> 'signature') AS kinds_of_check,
       sum(n) FILTER (WHERE chk <> 'signature') AS comparisons, sum(bad) AS mismatches
FROM jc_wres GROUP BY zone ORDER BY zone COLLATE "C";
SELECT split_part(chk, ':', 1) AS grp, count(DISTINCT chk) AS kinds_of_check, sum(n) AS comparisons, sum(bad) AS mismatches
FROM jc_wres WHERE chk <> 'signature' GROUP BY split_part(chk, ':', 1) ORDER BY split_part(chk, ':', 1) COLLATE "C";
SELECT zone, chk, n, bad, first_bad FROM jc_wres WHERE bad > 0 ORDER BY zone COLLATE "C", chk COLLATE "C";
-- the answers do not move with the session zone: one distinct signature
SELECT count(*) AS zones, count(DISTINCT signature) AS distinct_signatures, min(n) AS values_in_each
FROM jc_wres WHERE chk = 'signature';

-- ---------------------------------------------------------------------
-- negative controls: the same comparisons against the wrong thing must find
-- mismatches (so a sweep that checks nothing could not pass above)
-- ---------------------------------------------------------------------
-- (1) the date in Asia/Tehran against the date in UTC: the Jalali day of Tehran
-- starts at 20:30 UTC, so 7 of the 48 half hours of each of the 12 days differ
-- (the last instant of each window, 00:00 UTC, is on the same day)
CREATE TEMP TABLE jc_utc_text AS SELECT w, g, x::text AS t FROM jc_inst;
SELECT pg_temp.val('Asia/Tehran', $q$
    SELECT count(*) FILTER (WHERE jday_format(i.x) <> left(u.t, 10))::text
    FROM jc_inst i JOIN jc_utc_text u USING (w, g)$q$) AS tehran_date_vs_utc_date_mismatches,
       pg_temp.val('UTC', $q$
    SELECT count(*) FILTER (WHERE jday_format(i.x) <> left(u.t, 10))::text
    FROM jc_inst i JOIN jc_utc_text u USING (w, g)$q$) AS utc_date_vs_utc_date_mismatches;
-- (2) the Saturday-first week against core's Monday-first date_trunc('week'):
-- never the same instant
SELECT pg_temp.val('Asia/Tehran', $q$
    SELECT count(*) FILTER (WHERE jdate_trunc('week', x)::timestamptz <> date_trunc('week', x::timestamptz))::text
    FROM jc_inst$q$) AS week_vs_core_week_mismatches,
       (SELECT count(*) FROM jc_inst) AS instants;
-- (3) the hour of Asia/Tehran against the hour of UTC: 3:30 apart, always differs
SELECT pg_temp.val('Asia/Tehran', $q$
    SELECT count(*) FILTER (WHERE extract(hour FROM x) <> extract(hour FROM x::timestamptz AT TIME ZONE 'UTC'))::text
    FROM jc_inst$q$) AS tehran_hour_vs_utc_hour_mismatches;
-- (4) the Jalali date against the Gregorian date of the same value
SELECT pg_temp.val('UTC', $q$
    SELECT count(*) FILTER (WHERE jday_format(x) <> to_char(x::timestamptz, 'YYYY-MM-DD'))::text
    FROM jc_inst$q$) AS jalali_vs_gregorian_date_mismatches;

-- ---------------------------------------------------------------------
-- hand-computed rows. Instant 1: the Gregorian 2024-03-19 20:30:00 UTC, the first
-- instant of Nowruz 1403 in Tehran (written 1402-12-29 20:30+00 as the Jalali
-- text). Instant 2: the Gregorian 2025-03-20 20:29:59 UTC, the last second of the
-- leap year 1403 in Tehran (1403-12-30 20:29:59+00). Hand values:
--   Tehran    1: 1403-01-01 00:00:00+03:30, Wednesday (dow 4), month and year start the same day
--             2: 1403-12-30 23:59:59+03:30, Thursday (dow 5), week start Saturday 1403-12-25
--   Kolkata   1: 1403-01-01 02:00:00+05:30  2: 1404-01-01 01:59:59+05:30, Friday (dow 6)
--   Kathmandu 1: 1403-01-01 02:15:00+05:45  2: 1404-01-01 02:14:59+05:45
--   Paris     1: 1402-12-29 21:30:00+01, Tuesday (dow 3), month start 1402-12-01, year 1402-01-01
--             2: 1403-12-30 21:29:59+01
--   UTC       1: 1402-12-29 20:30:00+00  2: 1403-12-30 20:29:59+00
-- Esfand 1402 has 29 days (common year) and the week of Tuesday 1402-12-29 starts
-- on Saturday 1402-12-26 (2024-03-16). Friday 1404-01-01 (2025-03-21) is in the
-- week that starts on Saturday 2025-03-15, which is 1403-12-25 (Esfand 1403 has
-- 30 days), as does Thursday 1403-12-30.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jc_hand (id int, zone text, inst text, exp_text text, exp_dow int, exp_day text, exp_month_start text,
                           exp_year_start text, exp_week_start text);
INSERT INTO jc_hand VALUES
 (1,  'Asia/Tehran',    '1402-12-29 20:30:00+00', '1403-01-01 00:00:00+03:30', 4, '1403-01-01', '1403-01-01 00:00:00+03:30', '1403-01-01 00:00:00+03:30', '1402-12-26 00:00:00+03:30'),
 (2,  'Asia/Kolkata',   '1402-12-29 20:30:00+00', '1403-01-01 02:00:00+05:30', 4, '1403-01-01', '1403-01-01 00:00:00+05:30', '1403-01-01 00:00:00+05:30', '1402-12-26 00:00:00+05:30'),
 (3,  'Asia/Kathmandu', '1402-12-29 20:30:00+00', '1403-01-01 02:15:00+05:45', 4, '1403-01-01', '1403-01-01 00:00:00+05:45', '1403-01-01 00:00:00+05:45', '1402-12-26 00:00:00+05:45'),
 (4,  'Europe/Paris',   '1402-12-29 20:30:00+00', '1402-12-29 21:30:00+01', 3, '1402-12-29', '1402-12-01 00:00:00+01', '1402-01-01 00:00:00+01', '1402-12-26 00:00:00+01'),
 (5,  'UTC',            '1402-12-29 20:30:00+00', '1402-12-29 20:30:00+00', 3, '1402-12-29', '1402-12-01 00:00:00+00', '1402-01-01 00:00:00+00', '1402-12-26 00:00:00+00'),
 (6,  'Asia/Tehran',    '1403-12-30 20:29:59+00', '1403-12-30 23:59:59+03:30', 5, '1403-12-30', '1403-12-01 00:00:00+03:30', '1403-01-01 00:00:00+03:30', '1403-12-25 00:00:00+03:30'),
 (7,  'Asia/Kolkata',   '1403-12-30 20:29:59+00', '1404-01-01 01:59:59+05:30', 6, '1404-01-01', '1404-01-01 00:00:00+05:30', '1404-01-01 00:00:00+05:30', '1403-12-25 00:00:00+05:30'),
 (8,  'Asia/Kathmandu', '1403-12-30 20:29:59+00', '1404-01-01 02:14:59+05:45', 6, '1404-01-01', '1404-01-01 00:00:00+05:45', '1404-01-01 00:00:00+05:45', '1403-12-25 00:00:00+05:45'),
 (9,  'Europe/Paris',   '1403-12-30 20:29:59+00', '1403-12-30 21:29:59+01', 5, '1403-12-30', '1403-12-01 00:00:00+01', '1403-01-01 00:00:00+01', '1403-12-25 00:00:00+01'),
 (10, 'UTC',            '1403-12-30 20:29:59+00', '1403-12-30 20:29:59+00', 5, '1403-12-30', '1403-12-01 00:00:00+00', '1403-01-01 00:00:00+00', '1403-12-25 00:00:00+00');

SELECT h.id, h.zone, r.txt, r.txt = h.exp_text AS text_ok,
       r.dow, r.dow = h.exp_dow AS dow_ok,
       r.day, r.day = h.exp_day AS day_ok,
       r.month_start, r.month_start = h.exp_month_start AS month_start_ok,
       r.year_start, r.year_start = h.exp_year_start AS year_start_ok,
       r.week_start, r.week_start = h.exp_week_start AS week_start_ok,
       r.month_key
FROM jc_hand h
     CROSS JOIN LATERAL (SELECT pg_temp.val(h.zone, format($q$SELECT %L::jtimestamptz::text$q$, h.inst)) AS txt,
                                pg_temp.val(h.zone, format($q$SELECT extract(dow FROM %L::jtimestamptz)$q$, h.inst))::int AS dow,
                                pg_temp.val(h.zone, format($q$SELECT jday_format(%L::jtimestamptz)$q$, h.inst)) AS day,
                                pg_temp.val(h.zone, format($q$SELECT jmonth_format(%L::jtimestamptz, '/')$q$, h.inst)) AS month_key,
                                pg_temp.val(h.zone, format($q$SELECT jdate_trunc('month', %L::jtimestamptz)::text$q$, h.inst)) AS month_start,
                                pg_temp.val(h.zone, format($q$SELECT jdate_trunc('year', %L::jtimestamptz)::text$q$, h.inst)) AS year_start,
                                pg_temp.val(h.zone, format($q$SELECT jdate_trunc('week', %L::jtimestamptz)::text$q$, h.inst)) AS week_start) r
ORDER BY h.id;

-- the same instants through the explicit-zone jdate_trunc and AT TIME ZONE, and
-- the wall clock they give
SELECT h.id, h.zone, r.day_start, r.wall, r.wall_day, r.wall_week
FROM jc_hand h
     CROSS JOIN LATERAL (SELECT pg_temp.val('Pacific/Pago_Pago', format($q$SELECT jdate_trunc('day', %L::jtimestamptz, %L)::text$q$, h.inst, h.zone)) AS day_start,
                                pg_temp.val('Pacific/Pago_Pago', format($q$SELECT (%L::jtimestamptz AT TIME ZONE %L)::text$q$, h.inst, h.zone)) AS wall,
                                pg_temp.val('Pacific/Pago_Pago', format($q$SELECT jday_format(%L::jtimestamptz AT TIME ZONE %L)$q$, h.inst, h.zone)) AS wall_day,
                                pg_temp.val('Pacific/Pago_Pago', format($q$SELECT jdate_trunc('week', %L::jtimestamptz AT TIME ZONE %L)::text$q$, h.inst, h.zone)) AS wall_week) r
ORDER BY h.id;

-- ---------------------------------------------------------------------
-- the infinity matrix of every J4 function, as it really is. Rows are grouped by
-- function and outcome: the units that give "+infinity / -infinity" results.
--   EXTRACT: year, decade, century, epoch are +/-Infinity, every other field is
--     NULL, and an unsupported unit (week, isoyear, millennium, julian, the zone
--     fields of a jtimestamp) raises 0A000 even for infinity; an unknown unit is
--     22023.
--   jdate_part: NULL for every supported unit (and the same errors).
--   jdate_trunc: infinity for every unit its decoder knows, also the ones it
--     rejects with 0A000 on a finite value (decade, century, epoch, dow, ...), so
--     it differs from EXTRACT here; an unknown unit is 22023.
--   jday_format, jmonth_format: 'infinity' / '-infinity' for any separator, NULL
--     for a NULL separator.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jc_units (u text);
INSERT INTO jc_units VALUES ('year'), ('month'), ('day'), ('quarter'), ('doy'), ('decade'), ('century'), ('dow'), ('isodow'),
                            ('hour'), ('minute'), ('second'), ('milliseconds'), ('microseconds'), ('epoch'),
                            ('timezone'), ('timezone_hour'), ('timezone_minute'),
                            ('week'), ('isoyear'), ('millennium'), ('julian'), ('bogus');

SELECT m.fn, m.pos, m.neg, string_agg(m.u, ',' ORDER BY m.u COLLATE "C") AS units
FROM (SELECT f.fn, u.u,
             pg_temp.val('Asia/Tehran', format(f.q, 'infinity', u.u)) AS pos,
             pg_temp.val('Asia/Tehran', format(f.q, '-infinity', u.u)) AS neg
      FROM jc_units u
           CROSS JOIN (VALUES
               ('extract(jtimestamp)',   $q$SELECT pg_catalog.extract(%2$L, %1$L::jtimestamp)$q$),
               ('extract(jtimestamptz)', $q$SELECT pg_catalog.extract(%2$L, %1$L::jtimestamptz)$q$),
               ('jdate_part(jtimestamp)',   $q$SELECT jdate_part(%2$L, %1$L::jtimestamp)$q$),
               ('jdate_part(jtimestamptz)', $q$SELECT jdate_part(%2$L, %1$L::jtimestamptz)$q$),
               ('jdate_trunc(jtimestamp)',   $q$SELECT jdate_trunc(%2$L, %1$L::jtimestamp)::text$q$),
               ('jdate_trunc(jtimestamptz)', $q$SELECT jdate_trunc(%2$L, %1$L::jtimestamptz)::text$q$),
               ('jdate_trunc(jtimestamptz, zone)', $q$SELECT jdate_trunc(%2$L, %1$L::jtimestamptz, 'Asia/Tehran')::text$q$)
           ) f(fn, q)) m
GROUP BY m.fn, m.pos, m.neg
ORDER BY m.fn COLLATE "C", m.pos COLLATE "C", m.neg COLLATE "C";

-- the formats: every type, both functions, four separators (default, '/', '', NULL)
SELECT m.fn, m.pos, m.neg, string_agg(m.sep, ' ' ORDER BY m.sep COLLATE "C") AS separators
FROM (SELECT f.fn || '(' || ty.ty || ')' AS fn, s.sep,
             pg_temp.val('Asia/Tehran', format('SELECT %s(%L::%s%s)', f.fn, 'infinity', ty.ty, s.sepsql)) AS pos,
             pg_temp.val('Asia/Tehran', format('SELECT %s(%L::%s%s)', f.fn, '-infinity', ty.ty, s.sepsql)) AS neg
      FROM (VALUES ('jday_format'), ('jmonth_format')) f(fn),
           (VALUES ('jdate'), ('jtimestamp'), ('jtimestamptz')) ty(ty),
           (VALUES ('default', ''), ('slash', ', ''/''::text'), ('empty', ', ''''::text'), ('null', ', NULL::text')) s(sep, sepsql)) m
GROUP BY m.fn, m.pos, m.neg
ORDER BY m.fn COLLATE "C", m.pos COLLATE "C", m.neg COLLATE "C";

-- the checks that come first: an unknown unit is 22023, an unsupported unit of
-- EXTRACT is 0A000 on infinity as on a finite value, and jdate_trunc with a zone
-- looks the zone up before it looks at the value (an unknown zone is 22023 for
-- infinity too), but an unsupported unit on infinity gives infinity
SELECT pg_temp.val('UTC', $q$SELECT jdate_trunc('day', 'infinity'::jtimestamptz, 'Nowhere/Land')$q$) AS trunc_unknown_zone_on_infinity,
       pg_temp.val('UTC', $q$SELECT jdate_trunc('bogus', 'infinity'::jtimestamptz, 'UTC')$q$) AS trunc_unknown_unit_on_infinity,
       pg_temp.val('UTC', $q$SELECT jdate_trunc('decade', 'infinity'::jtimestamptz, 'UTC')$q$) AS trunc_unsupported_unit_on_infinity,
       pg_temp.val('UTC', $q$SELECT pg_catalog.extract('week', 'infinity'::jtimestamptz)$q$) AS extract_unsupported_unit_on_infinity,
       pg_temp.val('UTC', $q$SELECT pg_catalog.extract('week', '1403-05-15 10:00'::jtimestamptz)$q$) AS extract_unsupported_unit_finite,
       pg_temp.val('UTC', $q$SELECT jdate_trunc('decade', '1403-05-15 10:00'::jtimestamptz)$q$) AS trunc_unsupported_unit_finite;

-- ---------------------------------------------------------------------
-- index recipes. A jtimestamptz column cannot carry an index on a function of
-- the session zone (STABLE: 42P17), but it can on x AT TIME ZONE 'zone' (a
-- jtimestamp, through the btree class of the type) and on jday_format / extract /
-- jdate_trunc of that; a jtimestamp column can carry an index on its own fields.
-- The planner uses them and the results are those of a sequential scan.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jc_ix AS
SELECT g AS id,
       (timestamptz '2024-03-19 00:00:00+00' + g * interval '30 minutes')::jtimestamptz AS tz,
       (timestamp '2024-03-19 00:00:00' + g * interval '30 minutes')::jtimestamp AS ts
FROM generate_series(0, 17519) g;

SELECT pg_temp.state($q$CREATE INDEX jc_ix_wall ON jc_ix ((tz AT TIME ZONE 'Asia/Tehran'))$q$) AS wall_clock_of_tz,
       pg_temp.state($q$CREATE INDEX jc_ix_day ON jc_ix (jday_format((tz AT TIME ZONE 'Asia/Tehran')))$q$) AS jday_format_of_it,
       pg_temp.state($q$CREATE INDEX jc_ix_month ON jc_ix (jmonth_format((tz AT TIME ZONE 'Asia/Tehran'), '/'))$q$) AS jmonth_format_of_it,
       pg_temp.state($q$CREATE INDEX jc_ix_year ON jc_ix (extract(year FROM (tz AT TIME ZONE 'Asia/Tehran')))$q$) AS extract_of_it,
       pg_temp.state($q$CREATE INDEX jc_ix_trunc_zone ON jc_ix (jdate_trunc('month', tz, 'Asia/Tehran'))$q$) AS jdate_trunc_with_zone,
       pg_temp.state($q$CREATE INDEX jc_ix_ts_wall ON jc_ix ((ts AT TIME ZONE 'Asia/Tehran'))$q$) AS wall_clock_of_ts,
       pg_temp.state($q$CREATE INDEX jc_ix_ts_day ON jc_ix (jday_format(ts))$q$) AS jday_format_of_ts,
       pg_temp.state($q$CREATE INDEX jc_ix_ts_part ON jc_ix (jdate_part('doy', ts))$q$) AS jdate_part_of_ts,
       pg_temp.state($q$CREATE INDEX jc_ix_ts_trunc ON jc_ix (jdate_trunc('week', ts))$q$) AS jdate_trunc_of_ts;
-- the session-zone forms are STABLE, so no index on them
SELECT pg_temp.state($q$CREATE INDEX jc_ix_bad1 ON jc_ix (jday_format(tz))$q$) AS jday_format_of_tz,
       pg_temp.state($q$CREATE INDEX jc_ix_bad2 ON jc_ix (jmonth_format(tz))$q$) AS jmonth_format_of_tz,
       pg_temp.state($q$CREATE INDEX jc_ix_bad3 ON jc_ix (jdate_trunc('day', tz))$q$) AS jdate_trunc_of_tz,
       pg_temp.state($q$CREATE INDEX jc_ix_bad4 ON jc_ix (extract(year FROM tz))$q$) AS extract_of_tz,
       pg_temp.state($q$CREATE INDEX jc_ix_bad5 ON jc_ix (jdate_part('day', tz))$q$) AS jdate_part_of_tz,
       pg_temp.state($q$CREATE INDEX jc_ix_bad6 ON jc_ix ((tz::jdate))$q$) AS cast_to_jdate;
ANALYZE jc_ix;

SET enable_seqscan = off;
SELECT pg_temp.plan_uses_index($q$SELECT id FROM jc_ix WHERE (tz AT TIME ZONE 'Asia/Tehran') >= '1403-02-01 00:00:00'::jtimestamp
                                  AND (tz AT TIME ZONE 'Asia/Tehran') < '1403-03-01 00:00:00'::jtimestamp$q$) AS planner_uses_the_wall_clock_index,
       pg_temp.plan_uses_index($q$SELECT id FROM jc_ix WHERE jday_format((tz AT TIME ZONE 'Asia/Tehran')) = '1403-01-01'$q$) AS planner_uses_the_jday_format_index,
       pg_temp.plan_uses_index($q$SELECT id FROM jc_ix WHERE jmonth_format((tz AT TIME ZONE 'Asia/Tehran'), '/') = '1403/01'$q$) AS planner_uses_the_jmonth_format_index,
       pg_temp.plan_uses_index($q$SELECT id FROM jc_ix WHERE extract(year FROM (tz AT TIME ZONE 'Asia/Tehran')) = 1404$q$) AS planner_uses_the_extract_index,
       pg_temp.plan_uses_index($q$SELECT id FROM jc_ix WHERE jdate_trunc('month', tz, 'Asia/Tehran') = '1403-03-01 00:00:00+03:30'::jtimestamptz$q$) AS planner_uses_the_trunc_index,
       pg_temp.plan_uses_index($q$SELECT id FROM jc_ix WHERE (ts AT TIME ZONE 'Asia/Tehran') = '1403-01-01 00:00:00+03:30'::jtimestamptz$q$) AS planner_uses_the_ts_wall_index,
       pg_temp.plan_uses_index($q$SELECT id FROM jc_ix WHERE jday_format(ts) = '1403-01-01'$q$) AS planner_uses_the_ts_jday_format_index,
       pg_temp.plan_uses_index($q$SELECT id FROM jc_ix WHERE jdate_part('doy', ts) = 100$q$) AS planner_uses_the_ts_part_index,
       pg_temp.plan_uses_index($q$SELECT id FROM jc_ix WHERE jdate_trunc('week', ts) = '1402-12-26 00:00:00'::jtimestamp$q$) AS planner_uses_the_ts_trunc_index;
RESET enable_seqscan;

-- the same answers through the index and through a sequential scan, with the
-- count worked out by hand (the series starts at 2024-03-19 00:00 UTC, 03:30 in
-- Tehran, 1402-12-29; Nowruz 1403 is 2024-03-19 20:30 UTC; Farvardin has 31 days
-- and so does Ordibehesht, 48 half hours in a day; the UTC Jalali day 1403-01-01
-- is the Gregorian 2024-03-20)
SELECT q.what, q.expected,
       pg_temp.count_with(q.sql, true) AS through_index, pg_temp.count_with(q.sql, false) AS through_seq_scan
FROM (VALUES
  (1, 'Tehran day 1403-01-01', 48, $q$SELECT count(*) FROM jc_ix WHERE jday_format((tz AT TIME ZONE 'Asia/Tehran')) = '1403-01-01'$q$),
  (2, 'Tehran month 1403/01', 1488, $q$SELECT count(*) FROM jc_ix WHERE jmonth_format((tz AT TIME ZONE 'Asia/Tehran'), '/') = '1403/01'$q$),
  (3, 'Tehran wall clock in Ordibehesht', 1488, $q$SELECT count(*) FROM jc_ix WHERE (tz AT TIME ZONE 'Asia/Tehran') >= '1403-02-01 00:00:00'::jtimestamp AND (tz AT TIME ZONE 'Asia/Tehran') < '1403-03-01 00:00:00'::jtimestamp$q$),
  (4, 'Tehran year 1403 (all rows up to Esfand 1403)', 17520, $q$SELECT count(*) FROM jc_ix WHERE extract(year FROM (tz AT TIME ZONE 'Asia/Tehran')) IN (1402, 1403)$q$),
  (5, 'Tehran month start of Khordad', 1488, $q$SELECT count(*) FROM jc_ix WHERE jdate_trunc('month', tz, 'Asia/Tehran') = '1403-03-01 00:00:00+03:30'::jtimestamptz$q$),
  (6, 'UTC day 1403-01-01 of the jtimestamp', 48, $q$SELECT count(*) FROM jc_ix WHERE jday_format(ts) = '1403-01-01'$q$),
  (7, 'UTC wall clock of the jtimestamp in Tehran', 1, $q$SELECT count(*) FROM jc_ix WHERE (ts AT TIME ZONE 'Asia/Tehran') = '1403-01-01 00:00:00+03:30'::jtimestamptz$q$),
  (8, 'day of the year 100 of the jtimestamp', 48, $q$SELECT count(*) FROM jc_ix WHERE jdate_part('doy', ts) = 100$q$),
  (9, 'week of the jtimestamp starting Saturday 1402-12-26 (2024-03-16), Tuesday to Friday of the series', 192, $q$SELECT count(*) FROM jc_ix WHERE jdate_trunc('week', ts) = '1402-12-26 00:00:00'::jtimestamp$q$)
) q(n, what, expected, sql)
ORDER BY q.n;

-- ---------------------------------------------------------------------
-- the bare-literal list. A call whose argument is an untyped literal is resolved
-- by the argument types of ALL the candidates in scope, so adding a function of
-- the same name for another type can make a call ambiguous (42725); a call
-- that names a type no candidate has is 42883 (there are no implicit casts from
-- core's date and timestamp types). Typed values always work. "ok" means the call
-- resolves (and runs). This is the list for the documentation.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jc_calls (n int, grp text, call text);
INSERT INTO jc_calls VALUES
 -- J4: fields, truncation, formats (ambiguous: three or more candidates)
 (1,  'extract',      $q$SELECT EXTRACT(year FROM '1403-05-15 10:00')$q$),
 (2,  'extract',      $q$SELECT EXTRACT(year FROM '1403-05-15')$q$),
 (3,  'extract',      $q$SELECT EXTRACT(year FROM '1403-05-15 10:00'::jtimestamp)$q$),
 (4,  'jdate_part',   $q$SELECT jdate_part('year', '1403-05-15')$q$),
 (5,  'jdate_part',   $q$SELECT jdate_part('year', '1403-05-15 10:00')$q$),
 (6,  'jdate_part',   $q$SELECT jdate_part('year', '1403-05-15'::jdate)$q$),
 (7,  'jdate_trunc',  $q$SELECT jdate_trunc('month', '1403-05-15')$q$),
 (8,  'jdate_trunc',  $q$SELECT jdate_trunc('month', '1403-05-15 10:00')$q$),
 (9,  'jdate_trunc',  $q$SELECT jdate_trunc('month', '1403-05-15 10:00+00', 'UTC')$q$),
 (10, 'jdate_trunc',  $q$SELECT jdate_trunc('month', '1403-05-15'::jdate)$q$),
 (11, 'jday_format',  $q$SELECT jday_format('1403-05-03')$q$),
 (12, 'jday_format',  $q$SELECT jday_format('1403-05-03', '/')$q$),
 (13, 'jday_format',  $q$SELECT jday_format(NULL)$q$),
 (14, 'jmonth_format', $q$SELECT jmonth_format('1403-05-03')$q$),
 (15, 'jmonth_format', $q$SELECT jmonth_format('1403-05-03 10:00')$q$),
 (16, 'jmonth_format', $q$SELECT jmonth_format('1403-05-03'::jdate)$q$),
 (17, 'extract',      $q$SELECT pg_catalog.extract('year', now())$q$),
 -- J4: core types are not accepted (no implicit casts): 42883
 (20, 'jday_format',  $q$SELECT jday_format(current_date)$q$),
 (21, 'jday_format',  $q$SELECT jday_format(now())$q$),
 (22, 'jday_format',  $q$SELECT jday_format(5)$q$),
 (23, 'jmonth_format', $q$SELECT jmonth_format(now()::timestamp)$q$),
 (24, 'jdate_trunc',  $q$SELECT jdate_trunc('day', now())$q$),
 (25, 'jdate_trunc',  $q$SELECT jdate_trunc('day', now()::timestamp)$q$),
 (26, 'jdate_part',   $q$SELECT jdate_part('year', now())$q$),
 -- J3: arithmetic, series, binning, overlaps
 (30, 'jdate +',      $q$SELECT '1403-05-03'::jdate + '5'$q$),
 (31, 'jdate +',      $q$SELECT '5' + '1403-05-03'::jdate$q$),
 (32, 'jdate +',      $q$SELECT '1403-05-03'::jdate + '1 day'$q$),
 (33, 'jdate -',      $q$SELECT '1403-05-03'::jdate - '5'$q$),
 (34, 'jdate +',      $q$SELECT '1403-05-03'::jdate + 5$q$),
 (35, 'jdate +',      $q$SELECT '1403-05-03'::jdate + interval '5 days'$q$),
 (36, 'jtimestamp +', $q$SELECT '1403-05-03 10:00'::jtimestamp + '1 day'$q$),
 (37, 'jtimestamp -', $q$SELECT '1403-05-03 10:00'::jtimestamp - '1 day'$q$),
 (38, 'jgenerate_series', $q$SELECT * FROM jgenerate_series('1403-01-01', '1403-03-01', interval '1 month')$q$),
 (39, 'jgenerate_series', $q$SELECT * FROM jgenerate_series('1403-01-01', '1403-03-01', '1 month')$q$),
 (40, 'jgenerate_series', $q$SELECT * FROM jgenerate_series('1403-01-01', '1403-01-05')$q$),
 (41, 'jgenerate_series', $q$SELECT * FROM jgenerate_series('1403-01-01', '1403-01-05', 1)$q$),
 (42, 'jgenerate_series', $q$SELECT * FROM jgenerate_series('1403-01-01'::jdate, '1403-03-01', '1 month')$q$),
 (421, 'jgenerate_series', $q$SELECT * FROM jgenerate_series('1403-01-01'::jdate, '1403-03-01', interval '1 month')$q$),
 (422, 'jgenerate_series', $q$SELECT * FROM jgenerate_series('1403-01-01'::jdate, '1403-03-01', 7)$q$),
 (43, 'jdate_bin',    $q$SELECT jdate_bin('1 day', '1403-01-01', '1403-01-01')$q$),
 (44, 'jdate_bin',    $q$SELECT jdate_bin('1 day', '1403-01-01'::jtimestamp, '1403-01-01')$q$),
 (45, 'overlaps',     $q$SELECT ('1403-01-01', '1403-01-10') OVERLAPS ('1403-01-05', '1403-01-20')$q$),
 (46, 'overlaps',     $q$SELECT ('1403-01-01'::jtimestamp, '1403-01-10') OVERLAPS ('1403-01-05', '1403-01-20')$q$),
 (47, 'AT TIME ZONE', $q$SELECT '2024-03-20 12:00:00' AT TIME ZONE 'UTC'$q$),
 (48, 'AT TIME ZONE', $q$SELECT '1403-01-01 12:00:00'::jtimestamp AT TIME ZONE 'UTC'$q$),
 -- comparison operators with a bare literal keep resolving (the same-type operator)
 (70, 'comparison',   $q$SELECT '1403-01-01'::jdate = '1403-01-01'$q$),
 (71, 'comparison',   $q$SELECT '1403-01-01 10:00'::jtimestamp < '1403-01-01 11:00'$q$),
 (72, 'comparison',   $q$SELECT '1403-01-01 10:00+00'::jtimestamptz >= '1403-01-01 11:00+00'$q$),
 (73, 'comparison',   $q$SELECT '1403-01-01'::jdate = '1403-01-01 00:00'::jtimestamp$q$),
 -- a parameter next to a jdate (the extended protocol): the same as a bare literal
 (50, 'parameter',    $q$PREPARE jc_p1 AS SELECT '1403-05-03'::jdate + $1$q$),
 (51, 'parameter',    $q$PREPARE jc_p2 AS SELECT '1403-05-03'::jdate + $1::int$q$),
 (52, 'parameter',    $q$PREPARE jc_p3 AS SELECT jday_format($1)$q$),
 (53, 'parameter',    $q$PREPARE jc_p4 AS SELECT jday_format($1::jtimestamp)$q$),
 -- not defined, whatever the literals: 42883
 (60, 'operators',    $q$SELECT '1403-05-03'::jdate = current_date$q$),
 (61, 'operators',    $q$SELECT '1403-05-03 10:00'::jtimestamp = now()::timestamp$q$),
 (62, 'operators',    $q$SELECT '1403-05-03 10:00'::jtimestamp + '1403-05-03'::jdate$q$),
 (63, 'operators',    $q$SELECT '1403-05-03 10:00'::jtimestamp + 1$q$),
 (64, 'operators',    $q$SELECT ('1403-01-01'::jtimestamp, interval '1 day') OVERLAPS ('1403-01-01'::jtimestamp, '1403-01-05'::jtimestamp)$q$),
 (65, 'core functions', $q$SELECT date_trunc('day', '1403-05-03 10:00'::jtimestamp)$q$),
 (66, 'core functions', $q$SELECT generate_series('1403-01-01 00:00'::jtimestamp, '1403-01-03 00:00'::jtimestamp, interval '1 day')$q$),
 (67, 'core functions', $q$SELECT age('1403-05-03 10:00'::jtimestamp)$q$),
 (68, 'core functions', $q$SELECT to_char('1403-05-03 10:00'::jtimestamp, 'YYYY')$q$);

SELECT c.n, c.grp, c.call, pg_temp.state(c.call) AS result
FROM jc_calls c
ORDER BY c.n;
DEALLOCATE ALL;
