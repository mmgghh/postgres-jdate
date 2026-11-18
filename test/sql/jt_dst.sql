-- Interval arithmetic on jtimestamptz, and the session time zone: jtimestamptz
-- +/- interval, jtimestamptz - jtimestamptz, jdate - jtimestamptz and
-- jtimestamptz - jdate. As in core, months and days of an interval are applied
-- on the local wall clock of the session zone and the time part as elapsed time;
-- the month part counts Jalali months. Four zones are used (Europe/Paris,
-- Asia/Tehran, America/Sao_Paulo, Asia/Kolkata), the last one has no DST at all,
-- and two fixed zones at the largest offsets (+15:59 and -15:59) for the edges of
-- the safe range.
--
-- Everything is checked three ways: hand-computed rows (every Jalali date below
-- was converted by hand and its Gregorian equivalent is in a comment), core's own
-- timestamptz + interval on the same instants wherever no month is involved, and
-- an independent model of the month step wherever one is: the wall clock through
-- core's AT TIME ZONE, the month added to a jtimestamp (jt_arith checks that
-- against an SQL model of its own), then back through AT TIME ZONE and core's day
-- and time arithmetic. Errors are shown as SQLSTATE only, never as message text.
--
-- Nothing here depends on the number of rows of the zone database: only booleans
-- and counts of mismatches are printed, never counts of instants.
SET DateStyle = 'ISO, YMD';
SET IntervalStyle = 'postgres';
SET timezone = 'UTC';

-- The text of the result of a one-value query, or "ERR <sqlstate>", under a given
-- session time zone (restored afterwards).
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

-- "ok" or the SQLSTATE of a statement that returns nothing (DDL), under a zone.
CREATE FUNCTION pg_temp.zstate(zone text, q text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE
    r text := 'ok';
BEGIN
    PERFORM set_config('TimeZone', zone, false);
    BEGIN
        EXECUTE q;
    EXCEPTION WHEN OTHERS THEN
        r := SQLSTATE;
    END;
    PERFORM set_config('TimeZone', 'UTC', false);
    RETURN r;
END
$f$;

-- ---------------------------------------------------------------------
-- the operators in the catalog: + and - with interval are STABLE (they read
-- the session zone), jtimestamptz - jtimestamptz is IMMUTABLE like core's, the
-- differences with a jdate are STABLE (the day is a midnight in the session
-- zone); STRICT and PARALLEL SAFE throughout; + has its commutator
-- ---------------------------------------------------------------------
SELECT o.oprname AS operator, o.oprleft::regtype AS left_type,
       o.oprright::regtype AS right_type, o.oprresult::regtype AS result_type,
       o.oprcode::text AS function, p.provolatile AS volatility,
       p.proisstrict AS strict, p.proparallel AS parallel,
       o.oprcom <> 0 AS has_commutator
FROM pg_operator o JOIN pg_proc p ON p.oid = o.oprcode
WHERE o.oprname IN ('+', '-')
  AND 'jtimestamptz'::regtype IN (o.oprleft, o.oprright)
ORDER BY o.oprname COLLATE "C", o.oprleft::regtype::text COLLATE "C",
         o.oprright::regtype::text COLLATE "C";

-- core's counterparts have the same volatilities (timestamptz + interval and
-- timestamptz - interval STABLE, timestamptz - timestamptz IMMUTABLE)
SELECT o.oprname AS operator, o.oprleft::regtype AS left_type,
       o.oprright::regtype AS right_type, p.provolatile AS volatility
FROM pg_operator o JOIN pg_proc p ON p.oid = o.oprcode
WHERE o.oprname IN ('+', '-')
  AND o.oprleft IN ('timestamptz'::regtype, 'interval'::regtype)
  AND o.oprright IN ('timestamptz'::regtype, 'interval'::regtype)
ORDER BY o.oprname COLLATE "C", o.oprleft::regtype::text COLLATE "C",
         o.oprright::regtype::text COLLATE "C";

-- ---------------------------------------------------------------------
-- hand-computed rows. The Jalali dates and their Gregorian days:
--   Paris, 2024: 1403-01-11 = 03-30, 1403-01-12 = 03-31 (the gap 02:00 to 03:00
--     at 01:00 UTC), 1403-08-05 = 10-26, 1403-08-06 = 10-27 (the overlap 02:00 to
--     03:00 at 01:00 UTC); +01 in winter, +02 in summer
--   Tehran, 2020: 1399-01-01 = 03-20, 1399-01-02 = 03-21 (the gap 00:00 to 01:00),
--     1399-06-29 = 09-19, 1399-06-30 = 09-20 (the overlap 23:00 to 24:00 at 19:30
--     UTC); +03:30 in winter, +04:30 in summer
--   Sao Paulo: 1397-08-12 = 2018-11-03, 1397-08-13 = 11-04 (the gap 00:00 to 01:00,
--     -03 then -02), 1397-11-26 = 2019-02-15, 1397-11-27 = 02-16 (the overlap 23:00
--     to 24:00 at 02:00 UTC), 1397-11-28 = 02-17
--   Kolkata: +05:30 all year
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jd_cases (ord serial, zone text, start text, op text, step text, expected text);
INSERT INTO jd_cases (zone, start, op, step, expected) VALUES
-- Paris: a day keeps the wall time, 24 hours do not
('Europe/Paris', '1403-01-11 12:00+01', '+', '1 day',         '1403-01-12 12:00:00+02'),
('Europe/Paris', '1403-01-11 12:00+01', '+', '24 hours',      '1403-01-12 13:00:00+02'),
('Europe/Paris', '1403-01-11 12:00+01', '+', '1 day 1 hour',  '1403-01-12 13:00:00+02'),
('Europe/Paris', '1403-01-12 12:00+02', '-', '1 day',         '1403-01-11 12:00:00+01'),
('Europe/Paris', '1403-01-12 12:00+02', '-', '24 hours',      '1403-01-11 11:00:00+01'),
-- Paris: a wall time in the gap moves forward, by the length of the gap
('Europe/Paris', '1403-01-11 02:30+01', '+', '1 day',         '1403-01-12 03:30:00+02'),
('Europe/Paris', '1403-01-11 02:30+01', '+', '2 days',        '1403-01-13 02:30:00+02'),
('Europe/Paris', '1403-01-13 02:30+02', '-', '1 day',         '1403-01-12 03:30:00+02'),
('Europe/Paris', '1403-01-11 02:30+01', '+', '1 day 1 hour',  '1403-01-12 04:30:00+02'),
-- Paris: the month step, with Jalali months (the Gregorian 2024-01-31 02:30 + 2
-- months of the report is 1402-11-12 here: 2024-02-01 + 2 Jalali months is 03-31)
('Europe/Paris', '1402-11-12 02:30+01', '+', '2 months',       '1403-01-12 03:30:00+02'),
('Europe/Paris', '1402-11-12 02:30+01', '+', '2 months 1 day', '1403-01-13 03:30:00+02'),
('Europe/Paris', '1402-12-12 02:30+01', '+', '1 month',        '1403-01-12 03:30:00+02'),
('Europe/Paris', '1403-05-15 12:00+02', '+', '1 month',        '1403-06-15 12:00:00+02'),
('Europe/Paris', '1403-07-15 12:00+02', '+', '1 month',        '1403-08-15 12:00:00+01'),
('Europe/Paris', '1403-08-15 12:00+01', '-', '1 month',        '1403-07-15 12:00:00+02'),
('Europe/Paris', '1403-06-31 12:00+02', '+', '1 month',        '1403-07-30 12:00:00+02'),
('Europe/Paris', '1403-06-31 12:00+02', '+', '2 months',       '1403-08-30 12:00:00+01'),
-- Paris: a wall time that occurs twice takes its second occurrence (+01, the later
-- offset), as core's DetermineTimeZoneOffset does for timestamptz + interval; the
-- elapsed-time steps (24 and 25 hours) show both
('Europe/Paris', '1403-08-05 02:30+02', '+', '1 day',          '1403-08-06 02:30:00+01'),
('Europe/Paris', '1403-08-05 02:30+02', '+', '24 hours',       '1403-08-06 02:30:00+02'),
('Europe/Paris', '1403-08-05 02:30+02', '+', '25 hours',       '1403-08-06 02:30:00+01'),
('Europe/Paris', '1403-08-06 02:30+01', '+', '1 day',          '1403-08-07 02:30:00+01'),
('Europe/Paris', '1403-08-06 02:30+01', '-', '1 day',          '1403-08-05 02:30:00+02'),
('Europe/Paris', '1403-08-06 02:30+01', '+', '0 days',         '1403-08-06 02:30:00+01'),
('Europe/Paris', '1403-08-06 02:30+01', '+', '1 hour',         '1403-08-06 03:30:00+01'),
('Europe/Paris', '1403-07-06 02:30+02', '+', '1 month',        '1403-08-06 02:30:00+01'),
('Europe/Paris', '1403-09-06 02:30+01', '-', '1 month',        '1403-08-06 02:30:00+01'),
-- Tehran, the 2020 gap at 00:00
('Asia/Tehran', '1399-01-01 12:00+03:30', '+', '1 day',        '1399-01-02 12:00:00+04:30'),
('Asia/Tehran', '1399-01-01 12:00+03:30', '+', '24 hours',     '1399-01-02 13:00:00+04:30'),
('Asia/Tehran', '1399-01-01 00:00+03:30', '+', '1 day',        '1399-01-02 01:00:00+04:30'),
('Asia/Tehran', '1399-01-01 00:30+03:30', '+', '1 day',        '1399-01-02 01:30:00+04:30'),
('Asia/Tehran', '1399-01-01 00:00+03:30', '+', '24 hours',     '1399-01-02 01:00:00+04:30'),
('Asia/Tehran', '1399-01-03 00:00+04:30', '-', '1 day',        '1399-01-02 01:00:00+04:30'),
('Asia/Tehran', '1399-01-03 00:00+04:30', '-', '2 days',       '1399-01-01 00:00:00+03:30'),
('Asia/Tehran', '1398-12-02 00:00+03:30', '+', '1 month',      '1399-01-02 01:00:00+04:30'),
-- Tehran, the overlap at 23:00 to 24:00 on 1399-06-30 (the second occurrence again)
('Asia/Tehran', '1399-06-29 23:30+04:30', '+', '1 day',        '1399-06-30 23:30:00+03:30'),
('Asia/Tehran', '1399-06-29 23:30+04:30', '+', '24 hours',     '1399-06-30 23:30:00+04:30'),
('Asia/Tehran', '1399-06-29 23:30+04:30', '+', '25 hours',     '1399-06-30 23:30:00+03:30'),
('Asia/Tehran', '1399-06-30 23:30+03:30', '+', '1 day',        '1399-06-31 23:30:00+03:30'),
('Asia/Tehran', '1399-06-30 23:30+03:30', '-', '1 day',        '1399-06-29 23:30:00+04:30'),
-- Sao Paulo, the 2018 gap at 00:00 and the 2019 overlap at 23:00
('America/Sao_Paulo', '1397-08-12 00:30-03', '+', '1 day',     '1397-08-13 01:30:00-02'),
('America/Sao_Paulo', '1397-08-12 00:00-03', '+', '1 day',     '1397-08-13 01:00:00-02'),
('America/Sao_Paulo', '1397-08-12 12:00-03', '+', '1 day',     '1397-08-13 12:00:00-02'),
('America/Sao_Paulo', '1397-08-12 12:00-03', '+', '24 hours',  '1397-08-13 13:00:00-02'),
('America/Sao_Paulo', '1397-07-13 12:00-03', '+', '1 month',   '1397-08-13 12:00:00-02'),
('America/Sao_Paulo', '1397-11-26 23:30-02', '+', '1 day',     '1397-11-27 23:30:00-03'),
('America/Sao_Paulo', '1397-11-26 23:30-02', '+', '24 hours',  '1397-11-27 23:30:00-02'),
('America/Sao_Paulo', '1397-11-26 23:30-02', '+', '25 hours',  '1397-11-27 23:30:00-03'),
('America/Sao_Paulo', '1397-11-27 23:30-03', '+', '1 day',     '1397-11-28 23:30:00-03'),
-- Kolkata, no DST: a day is 24 hours, the wall time never moves
('Asia/Kolkata', '1403-01-11 12:00+05:30', '+', '1 day',       '1403-01-12 12:00:00+05:30'),
('Asia/Kolkata', '1403-01-11 12:00+05:30', '+', '24 hours',    '1403-01-12 12:00:00+05:30'),
('Asia/Kolkata', '1403-06-31 12:00+05:30', '+', '1 month',     '1403-07-30 12:00:00+05:30'),
('Asia/Kolkata', '1403-12-30 00:00+05:30', '+', '1 year',      '1404-12-29 00:00:00+05:30'),
('Asia/Kolkata', '1403-01-12 02:30+05:30', '+', '1 day',       '1403-01-13 02:30:00+05:30');

SELECT zone, start || ' ' || op || ' ' || step AS expression,
       pg_temp.zval(zone, format($q$SELECT (jtimestamptz %L %s interval %L)::text$q$,
                                 start, op, step)) AS result,
       pg_temp.zval(zone, format($q$SELECT (jtimestamptz %L %s interval %L)::text$q$,
                                 start, op, step)) = expected AS as_expected
FROM jd_cases ORDER BY ord;

-- interval + jtimestamptz is the same as jtimestamptz + interval, and
-- jtimestamptz - interval is jtimestamptz + the negated interval, in every row
-- of the table above that uses +
SELECT count(*) AS plus_rows,
       count(*) FILTER (WHERE pg_temp.zval(zone, format($q$SELECT (interval %L + jtimestamptz %L)::text$q$, step, start))
                              = expected) AS flipped_agree
FROM jd_cases WHERE op = '+';
SELECT count(*) AS minus_rows,
       count(*) FILTER (WHERE pg_temp.zval(zone, format($q$SELECT (jtimestamptz %L + (-interval %L))::text$q$, start, step))
                              = expected) AS negated_agree
FROM jd_cases WHERE op = '-';

-- the months-then-days order: adding the day to the result of the month step
-- gives the same as one step with both parts (core does the same: it localises
-- the month step before it adds the days)
SELECT pg_temp.zval('Europe/Paris', $q$SELECT ((jtimestamptz '1402-11-12 02:30+01' + interval '2 months') + interval '1 day')
                                          = (jtimestamptz '1402-11-12 02:30+01' + interval '2 months 1 day')$q$) AS paris_gap_month_then_day,
       pg_temp.zval('Asia/Tehran', $q$SELECT ((jtimestamptz '1398-12-02 00:00+03:30' + interval '1 month') + interval '1 day')
                                          = (jtimestamptz '1398-12-02 00:00+03:30' + interval '1 month 1 day')$q$) AS tehran_gap_month_then_day;

-- the same statement gives a different instant in a different session zone: the
-- operator is STABLE, not IMMUTABLE (1403-01-11 12:00+01 is 11:00 UTC)
SELECT z.zone,
       pg_temp.zval(z.zone, $q$SELECT ((jtimestamptz '1403-01-11 12:00+01' + interval '1 day')::timestamptz
                                       AT TIME ZONE 'UTC')::text$q$) AS plus_one_day_in_utc
FROM (VALUES ('UTC'), ('Europe/Paris'), ('Asia/Kolkata')) z(zone);

-- STABLE, so not usable where an index needs IMMUTABLE (42P17 for the index
-- expression); the difference of two instants is IMMUTABLE and is allowed
CREATE TABLE jd_idx (id int, ts jtimestamptz, ts2 jtimestamptz);
SELECT pg_temp.zstate('UTC', $q$CREATE INDEX jd_idx_plus ON jd_idx ((ts + interval '1 day'))$q$) AS index_on_plus,
       pg_temp.zstate('UTC', $q$CREATE INDEX jd_idx_minus ON jd_idx ((ts - interval '1 day'))$q$) AS index_on_minus,
       pg_temp.zstate('UTC', $q$CREATE INDEX jd_idx_diff ON jd_idx ((ts - ts2))$q$) AS index_on_difference;
DROP TABLE jd_idx;

-- ---------------------------------------------------------------------
-- the zones against core and against the model. The instants: every 15 minutes
-- within two days of every offset change of each zone from 2018 to 2024 (found by
-- comparing the offset hour by hour), and a coarse series over the whole span.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jd_zones (zone text);
INSERT INTO jd_zones VALUES ('Europe/Paris'), ('Asia/Tehran'), ('America/Sao_Paulo'), ('Asia/Kolkata');

CREATE TEMP TABLE jd_changes AS
SELECT z.zone, h.t
FROM jd_zones z,
     LATERAL (SELECT t, (t AT TIME ZONE z.zone) - (t AT TIME ZONE 'UTC') AS off,
                     lag((t AT TIME ZONE z.zone) - (t AT TIME ZONE 'UTC')) OVER (ORDER BY t) AS prev_off
              FROM generate_series(timestamptz '2018-01-01 00:00+00', timestamptz '2024-12-31 23:00+00',
                                   interval '1 hour') t) h
WHERE h.off IS DISTINCT FROM h.prev_off AND h.prev_off IS NOT NULL;

CREATE TEMP TABLE jd_instants AS
SELECT DISTINCT c.zone, g AS t
FROM jd_changes c,
     LATERAL generate_series(c.t - interval '2 days', c.t + interval '2 days', interval '15 minutes') g
UNION
SELECT z.zone, g
FROM jd_zones z,
     LATERAL generate_series(timestamptz '2018-01-01 00:07+00', timestamptz '2024-12-31 00:00+00',
                             interval '6 hours 53 minutes') g;

-- the steps: months and the rest, so the model can apply them separately
CREATE TEMP TABLE jd_steps (label text, months int, rest interval, days_only boolean, step interval);
INSERT INTO jd_steps (label, months, rest, days_only) VALUES
('1 day', 0, interval '1 day', true), ('-1 day', 0, interval '-1 day', true),
('24 hours', 0, interval '24 hours', false), ('-24 hours', 0, interval '-24 hours', false),
('2 days', 0, interval '2 days', true), ('7 days', 0, interval '7 days', true),
('1 day 1 hour', 0, interval '1 day 1 hour', false),
('-1 day 90 minutes', 0, interval '-1 day 90 minutes', false),
('45 minutes', 0, interval '45 minutes', false), ('1 month', 1, interval '0', true),
('-1 month', -1, interval '0', true), ('1 month 1 day', 1, interval '1 day', true),
('2 months', 2, interval '0', true), ('-2 months 3 days 5 hours', -2, interval '3 days 5 hours', false),
('1 year', 12, interval '0', true), ('-1 year 1 hour', -12, interval '1 hour', false),
('11 months 30 days', 11, interval '30 days', true);
UPDATE jd_steps SET step = make_interval(months => months) + rest;

-- For every zone, instant and step: with no month the result is core's
-- timestamptz + interval on the same instant; with a month it is the model; the
-- flipped and the negated forms agree. "dst_crossings" and "wall_time_moves" say
-- that the instants really include results on the other side of an offset change
-- and day or month steps whose wall time moved (a gap), which only a zone with
-- DST can have.
CREATE FUNCTION pg_temp.check_zone(zname text, OUT zone_name text, OUT enough_cases boolean,
                                   OUT core_mismatches bigint, OUT model_mismatches bigint,
                                   OUT flipped_mismatches bigint, OUT negated_mismatches bigint,
                                   OUT dst_crossings boolean, OUT wall_time_moves boolean)
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM set_config('TimeZone', zname, false);
    zone_name := zname;
    SELECT count(*) > 5000,
           count(*) FILTER (WHERE s.months = 0 AND
               (x.t::jtimestamptz + s.step)::timestamptz IS DISTINCT FROM x.t + s.step),
           count(*) FILTER (WHERE s.months <> 0 AND
               (x.t::jtimestamptz + s.step)::timestamptz
               IS DISTINCT FROM
               ((((x.t AT TIME ZONE zname)::jtimestamp + make_interval(months => s.months))::timestamp
                 AT TIME ZONE zname) + s.rest)),
           count(*) FILTER (WHERE s.step + x.t::jtimestamptz IS DISTINCT FROM x.t::jtimestamptz + s.step),
           count(*) FILTER (WHERE x.t::jtimestamptz - s.step IS DISTINCT FROM x.t::jtimestamptz + (-s.step)),
           count(*) FILTER (WHERE extract(timezone FROM (x.t::jtimestamptz + s.step)::timestamptz)
                                  <> extract(timezone FROM x.t)) > 0,
           count(*) FILTER (WHERE s.days_only AND
               ((x.t::jtimestamptz + s.step)::timestamptz AT TIME ZONE zname)::time
               <> (x.t AT TIME ZONE zname)::time) > 0
    INTO enough_cases, core_mismatches, model_mismatches, flipped_mismatches, negated_mismatches,
         dst_crossings, wall_time_moves
    FROM jd_instants x JOIN jd_steps s ON true
    WHERE x.zone = zname;
    PERFORM set_config('TimeZone', 'UTC', false);
END
$f$;

SELECT * FROM pg_temp.check_zone('Europe/Paris');
SELECT * FROM pg_temp.check_zone('Asia/Tehran');
SELECT * FROM pg_temp.check_zone('America/Sao_Paulo');
SELECT * FROM pg_temp.check_zone('Asia/Kolkata');

-- negative controls: the comparisons above can fail. Jalali months are not
-- Gregorian months, and in a zone with DST a day is not 24 hours.
SET timezone = 'Europe/Paris';
SELECT count(*) FILTER (WHERE (x.t::jtimestamptz + interval '1 month')::timestamptz
                              <> x.t + interval '1 month') > 0 AS jalali_month_is_not_gregorian,
       count(*) FILTER (WHERE (x.t::jtimestamptz + interval '1 day')::timestamptz
                              <> (x.t::jtimestamptz + interval '24 hours')::timestamptz) > 0 AS day_is_not_24_hours,
       count(*) FILTER (WHERE (x.t::jtimestamptz + interval '1 day')::timestamptz
                              = (x.t::jtimestamptz + interval '24 hours')::timestamptz) > 0 AS day_is_24_hours_mostly
FROM jd_instants x WHERE x.zone = 'Europe/Paris';
RESET timezone;
SET timezone = 'UTC';

-- ---------------------------------------------------------------------
-- a zone without DST (Kolkata) and UTC: wall-clock arithmetic is the same as on
-- a jtimestamp, whatever the step, so every result must equal the jtimestamp
-- result (checked in jt_arith against its own model of the month rule) for
-- wall times from 1370 to 1450 (Kolkata has been +05:30 since 1945)
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jd_walls AS
SELECT jdate '1370-01-01'::jtimestamp + g * interval '3 days' + (g * 53 % 1440) * interval '1 minute' AS w
FROM generate_series(0, 9700) g;
CREATE FUNCTION pg_temp.check_walls(zname text, OUT zone_name text, OUT enough_cases boolean,
                                    OUT mismatches bigint)
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM set_config('TimeZone', zname, false);
    zone_name := zname;
    SELECT count(*) > 100000,
           count(*) FILTER (WHERE (x.w::jtimestamptz + s.step)::jtimestamp IS DISTINCT FROM x.w + s.step)
    INTO enough_cases, mismatches
    FROM jd_walls x JOIN jd_steps s ON true;
    PERFORM set_config('TimeZone', 'UTC', false);
END
$f$;
SELECT * FROM pg_temp.check_walls('Asia/Kolkata');
SELECT * FROM pg_temp.check_walls('UTC');
-- and in Paris the same comparison fails where a wall time does not exist or
-- occurs twice, so it can fail
SELECT zone_name, mismatches > 0 AS differs_where_dst_matters FROM pg_temp.check_walls('Europe/Paris');

-- ---------------------------------------------------------------------
-- jtimestamptz - jtimestamptz: elapsed time (days of 24 hours and the time of
-- day, never a month), the same under every session zone
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jd_diffs (ord serial, a text, b text, expected text);
INSERT INTO jd_diffs (a, b, expected) VALUES
('1403-01-12 12:00+02', '1403-01-11 12:00+01', '23:00:00'),      -- Paris spring: the wall clock says 1 day
('1403-01-11 12:00+01', '1403-01-12 12:00+02', '-23:00:00'),
('1399-01-02 12:00+04:30', '1399-01-01 12:00+03:30', '23:00:00'),   -- Tehran 2020
('1397-08-13 12:00-02', '1397-08-12 12:00-03', '23:00:00'),         -- Sao Paulo 2018
('1403-08-07 02:30+01', '1403-08-05 02:30+02', '2 days 01:00:00'),  -- 00:30 UTC to 01:30 UTC two days on
('1403-08-07 02:30+01', '1403-08-05 02:30+01', '2 days'),
('1403-01-12 12:00+05:30', '1403-01-11 12:00+05:30', '1 day'),
('1403-01-11 12:00+00', '1403-01-11 12:00+00', '00:00:00'),
('1403-05-15 10:00+00', '1403-04-15 10:00+00', '31 days'),         -- days only, never a month: Tir has 31 days
('1405-01-01 00:00+00', '1403-01-01 00:00+00', '731 days');         -- 1403 is leap: 366 + 365 days
SELECT ord, a, b, expected,
       pg_temp.zval('UTC', format($q$SELECT (jtimestamptz %L - jtimestamptz %L)::text$q$, a, b)) AS in_utc,
       (SELECT count(DISTINCT pg_temp.zval(z.zone, format($q$SELECT (jtimestamptz %L - jtimestamptz %L)::text$q$, a, b)))
        FROM jd_zones z) AS distinct_across_the_four_zones
FROM jd_diffs ORDER BY ord;

-- the same as core's timestamptz - timestamptz for instants spread over 2018 to
-- 2024, in four zones, for gaps of one minute up to 400 days, both signs
CREATE FUNCTION pg_temp.check_diffs(zname text, OUT zone_name text, OUT enough_cases boolean,
                                    OUT mismatches bigint)
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM set_config('TimeZone', zname, false);
    zone_name := zname;
    SELECT count(*) > 20000,
           count(*) FILTER (WHERE (x.t::jtimestamptz - (x.t - g.gap)::jtimestamptz)::text
                                  IS DISTINCT FROM (x.t - (x.t - g.gap))::text)
    INTO enough_cases, mismatches
    FROM jd_instants x,
         (VALUES (interval '1 minute'), (interval '1 hour'), (interval '25 hours'), (interval '-3 days'),
                 (interval '45 days 7 hours'), (interval '400 days'), (interval '-400 days 5 minutes')) g(gap)
    WHERE x.zone = zname;
    PERFORM set_config('TimeZone', 'UTC', false);
END
$f$;
SELECT * FROM pg_temp.check_diffs('Europe/Paris');
SELECT * FROM pg_temp.check_diffs('Asia/Tehran');
SELECT * FROM pg_temp.check_diffs('America/Sao_Paulo');
SELECT * FROM pg_temp.check_diffs('Asia/Kolkata');

-- ---------------------------------------------------------------------
-- jdate - jtimestamptz and jtimestamptz - jdate: the day is its midnight in the
-- session zone. Same operands, four zones (the midnight of 1403-01-12, 2024-03-31,
-- is 23:00 UTC the day before in Paris, 20:30 in Tehran, 18:30 in Kolkata, 03:00
-- in Sao Paulo; 1403-01-11 12:00+01 is 11:00 UTC); and the midnights in a gap
-- (Sao Paulo 2018-11-04 and Tehran 2020-03-21 do not have a 00:00)
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jd_daydiffs (ord serial, zone text, d text, ts text, d_minus_ts text, ts_minus_d text);
INSERT INTO jd_daydiffs (zone, d, ts, d_minus_ts, ts_minus_d) VALUES
('UTC',               '1403-01-12', '1403-01-11 12:00+01', '13:00:00', '-13:00:00'),
('Europe/Paris',      '1403-01-12', '1403-01-11 12:00+01', '12:00:00', '-12:00:00'),
('Asia/Tehran',       '1403-01-12', '1403-01-11 12:00+01', '09:30:00', '-09:30:00'),
('Asia/Kolkata',      '1403-01-12', '1403-01-11 12:00+01', '07:30:00', '-07:30:00'),
('America/Sao_Paulo', '1403-01-12', '1403-01-11 12:00+01', '16:00:00', '-16:00:00'),
('America/Sao_Paulo', '1397-08-13', '1397-08-12 12:00-03', '12:00:00', '-12:00:00'),
('Asia/Tehran',       '1399-01-02', '1399-01-01 12:00+03:30', '12:00:00', '-12:00:00'),
('UTC',               '1403-05-15', '1403-05-15 00:00+00', '00:00:00', '00:00:00'),
('UTC',               '1403-05-25', '1403-05-15 12:00+00', '9 days 12:00:00', '-9 days -12:00:00');
SELECT ord, zone, d, ts, d_minus_ts, ts_minus_d,
       pg_temp.zval(zone, format($q$SELECT (jdate %L - jtimestamptz %L)::text$q$, d, ts)) AS result_d_minus_ts,
       pg_temp.zval(zone, format($q$SELECT (jtimestamptz %L - jdate %L)::text$q$, ts, d)) AS result_ts_minus_d
FROM jd_daydiffs ORDER BY ord;
SELECT count(*) AS rows,
       count(*) FILTER (WHERE pg_temp.zval(zone, format($q$SELECT (jdate %L - jtimestamptz %L)::text$q$, d, ts)) = d_minus_ts) AS d_minus_ts_agree,
       count(*) FILTER (WHERE pg_temp.zval(zone, format($q$SELECT (jtimestamptz %L - jdate %L)::text$q$, ts, d)) = ts_minus_d) AS ts_minus_d_agree
FROM jd_daydiffs;

-- against core's date - timestamptz and timestamptz - date, for days around each
-- instant (the day before, the day itself, the day after and a month on), in
-- four zones
CREATE FUNCTION pg_temp.check_daydiffs(zname text, OUT zone_name text, OUT enough_cases boolean,
                                       OUT mismatches_d_minus_ts bigint, OUT mismatches_ts_minus_d bigint)
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM set_config('TimeZone', zname, false);
    zone_name := zname;
    SELECT count(*) > 20000,
           count(*) FILTER (WHERE (q.d::jdate - x.t::jtimestamptz)::text IS DISTINCT FROM (q.d - x.t)::text),
           count(*) FILTER (WHERE (x.t::jtimestamptz - q.d::jdate)::text IS DISTINCT FROM (x.t - q.d)::text)
    INTO enough_cases, mismatches_d_minus_ts, mismatches_ts_minus_d
    FROM jd_instants x,
         LATERAL (SELECT (x.t AT TIME ZONE zname)::date + k AS d FROM unnest(ARRAY[-1, 0, 1, 31]) k) q
    WHERE x.zone = zname;
    PERFORM set_config('TimeZone', 'UTC', false);
END
$f$;
SELECT * FROM pg_temp.check_daydiffs('Europe/Paris');
SELECT * FROM pg_temp.check_daydiffs('Asia/Tehran');
SELECT * FROM pg_temp.check_daydiffs('America/Sao_Paulo');
SELECT * FROM pg_temp.check_daydiffs('Asia/Kolkata');

-- ---------------------------------------------------------------------
-- infinity, as core: infinity passes through + and -, and the differences give
-- core's value or core's SQLSTATE (an infinite interval from PostgreSQL 17, an
-- error before; opposite and equal infinities as core decides)
-- ---------------------------------------------------------------------
SELECT 'infinity'::jtimestamptz + interval '1 month' AS inf_plus,
       '-infinity'::jtimestamptz - interval '1 year' AS neg_inf_minus,
       interval '3 days' + 'infinity'::jtimestamptz AS flipped,
       'infinity'::jtimestamptz - interval '-5 days 3 hours' AS inf_minus_negative,
       '-infinity'::jtimestamptz + interval '1 month 1 day 1 hour' AS all_parts;

-- + and - with finite and infinite instants and intervals (days and time only, so
-- core's own result can be converted to jtimestamptz for the comparison): the same
-- value or SQLSTATE as core's timestamptz + interval; an infinite interval exists
-- from PostgreSQL 17, the literal is refused before
WITH t(j, g) AS (VALUES ('infinity', 'infinity'), ('-infinity', '-infinity'),
                        ('1403-05-15 10:00+00', '2024-08-05 10:00+00')),
     i(step) AS (VALUES ('1 day'), ('-5 days 3 hours'), ('infinity'), ('-infinity'), ('0'))
SELECT count(*) AS cases,
       count(*) FILTER (WHERE
           pg_temp.zval('UTC', format($q$SELECT (%L::jtimestamptz + interval %L)::text$q$, t.j, i.step))
           = pg_temp.zval('UTC', format($q$SELECT ((%L::timestamptz + interval %L)::jtimestamptz)::text$q$, t.g, i.step))) AS plus_agree,
       count(*) FILTER (WHERE
           pg_temp.zval('UTC', format($q$SELECT (interval %L + %L::jtimestamptz)::text$q$, i.step, t.j))
           = pg_temp.zval('UTC', format($q$SELECT ((interval %L + %L::timestamptz)::jtimestamptz)::text$q$, i.step, t.g))) AS flipped_agree,
       count(*) FILTER (WHERE
           pg_temp.zval('UTC', format($q$SELECT (%L::jtimestamptz - interval %L)::text$q$, t.j, i.step))
           = pg_temp.zval('UTC', format($q$SELECT ((%L::timestamptz - interval %L)::jtimestamptz)::text$q$, t.g, i.step))) AS minus_agree
FROM t, i;

WITH t(j, g) AS (VALUES ('infinity', 'infinity'), ('-infinity', '-infinity'),
                        ('1403-05-15 10:00+00', '2024-08-05 10:00+00')),
     u(j, g) AS (VALUES ('infinity', 'infinity'), ('-infinity', '-infinity'),
                        ('1403-05-15 10:00+00', '2024-08-05 10:00+00')),
     d(j, g) AS (VALUES ('infinity', 'infinity'), ('-infinity', '-infinity'),
                        ('1403-05-15', '2024-08-05'))
SELECT (SELECT count(*) FROM t, u) AS ts_minus_ts_cases,
       (SELECT count(*) FROM t, u
        WHERE pg_temp.zval('UTC', format($q$SELECT (%L::jtimestamptz - %L::jtimestamptz)::text$q$, t.j, u.j))
            = pg_temp.zval('UTC', format($q$SELECT (%L::timestamptz - %L::timestamptz)::text$q$, t.g, u.g))) AS ts_minus_ts_agree,
       (SELECT count(*) FROM d, t
        WHERE pg_temp.zval('UTC', format($q$SELECT (%L::jdate - %L::jtimestamptz)::text$q$, d.j, t.j))
            = pg_temp.zval('UTC', format($q$SELECT (%L::date - %L::timestamptz)::text$q$, d.g, t.g))) AS date_minus_ts_agree,
       (SELECT count(*) FROM d, t
        WHERE pg_temp.zval('UTC', format($q$SELECT (%L::jtimestamptz - %L::jdate)::text$q$, t.j, d.j))
            = pg_temp.zval('UTC', format($q$SELECT (%L::timestamptz - %L::date)::text$q$, t.g, d.g))) AS ts_minus_date_agree;

-- ---------------------------------------------------------------------
-- the safe-range edges. The range of a jtimestamptz is the Jalali range shrunk by
-- 16 hours at each end, as instants, so that every zone shows a Jalali day. The
-- first valid instant is -0061-01-01 16:00:00 UTC and the last 3177-12-29
-- 07:59:59.999999 UTC. In the two largest zones (written UTC-15:59 for +15:59 and
-- UTC+15:59 for -15:59: POSIX zone names have the opposite sign) these are
--   +15:59: first -0061-01-02 07:59:00, last 3177-12-29 23:58:59.999999
--   -15:59: first -0061-01-01 00:01:00, last 3177-12-28 16:00:59.999999
-- Results exactly on the edge are valid, one microsecond outside is 22008; the day,
-- month and time steps are tested on both sides of both edges in both zones.
-- A month step that itself lands outside the safe range is an error even when the
-- days of the same interval would bring the result back inside.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jd_edges (ord serial, zone text, start text, op text, step text, expected text);
INSERT INTO jd_edges (zone, start, op, step, expected) VALUES
-- UTC
('UTC', '-0061-01-01 16:00:00+00',          '-', '1 microsecond', 'ERR 22008'),
('UTC', '-0061-01-01 16:00:00.000001+00',   '-', '1 microsecond', '-0061-01-01 16:00:00+00'),
('UTC', '-0061-01-02 16:00:00+00',          '-', '1 day',         '-0061-01-01 16:00:00+00'),
('UTC', '-0061-01-02 15:59:59.999999+00',   '-', '1 day',         'ERR 22008'),
('UTC', '3177-12-29 07:59:59.999998+00',    '+', '1 microsecond', '3177-12-29 07:59:59.999999+00'),
('UTC', '3177-12-29 07:59:59.999999+00',    '+', '1 microsecond', 'ERR 22008'),
('UTC', '3177-12-28 07:59:59.999999+00',    '+', '1 day',         '3177-12-29 07:59:59.999999+00'),
('UTC', '3177-12-28 08:00:00+00',           '+', '1 day',         'ERR 22008'),
('UTC', '3177-11-29 07:59:59.999999+00',    '+', '1 month',       '3177-12-29 07:59:59.999999+00'),
('UTC', '3177-11-29 08:00:00+00',           '+', '1 month',       'ERR 22008'),
-- +15:59: the last valid instant is the last minute but one of the last day
('UTC-15:59', '3177-12-29 23:58:59.999998+15:59', '+', '1 microsecond', '3177-12-29 23:58:59.999999+15:59'),
('UTC-15:59', '3177-12-29 23:58:59.999999+15:59', '+', '1 microsecond', 'ERR 22008'),
('UTC-15:59', '3177-12-29 00:00:00+15:59',        '+', '23:58:59.999999', '3177-12-29 23:58:59.999999+15:59'),
('UTC-15:59', '3177-12-29 00:00:00+15:59',        '+', '23:59:00',        'ERR 22008'),
('UTC-15:59', '3177-12-28 23:58:59.999999+15:59', '+', '1 day',           '3177-12-29 23:58:59.999999+15:59'),
('UTC-15:59', '3177-12-28 23:59:00+15:59',        '+', '1 day',           'ERR 22008'),
('UTC-15:59', '3177-11-29 23:58:59.999999+15:59', '+', '1 month',         '3177-12-29 23:58:59.999999+15:59'),
('UTC-15:59', '3177-11-30 23:58:59.999999+15:59', '+', '1 month',         '3177-12-29 23:58:59.999999+15:59'),
('UTC-15:59', '3177-11-29 23:59:00+15:59',        '+', '1 month',         'ERR 22008'),
('UTC-15:59', '3177-12-29 23:58:59.999999+15:59', '+', '1 year',          'ERR 22008'),
('UTC-15:59', '3177-12-29 23:58:59.999999+15:59', '-', '12 months',       '3176-12-29 23:58:59.999999+15:59'),
-- +15:59, the first end
('UTC-15:59', '-0061-01-02 07:59:00+15:59',          '-', '1 microsecond',    'ERR 22008'),
('UTC-15:59', '-0061-01-02 07:59:00.000001+15:59',   '-', '1 microsecond',    '-0061-01-02 07:59:00+15:59'),
('UTC-15:59', '-0061-01-03 07:59:00+15:59',          '-', '1 day',            '-0061-01-02 07:59:00+15:59'),
('UTC-15:59', '-0061-01-03 07:58:59.999999+15:59',   '-', '1 day',            'ERR 22008'),
('UTC-15:59', '-0061-02-02 07:59:00+15:59',          '-', '1 month',          '-0061-01-02 07:59:00+15:59'),
('UTC-15:59', '-0061-02-02 07:59:00+15:59',          '-', '1 month 1 microsecond', 'ERR 22008'),
('UTC-15:59', '-0061-02-02 07:58:59.999999+15:59',   '+', '-1 month 1 day',   'ERR 22008'),
('UTC-15:59', '-0061-02-02 07:59:00+15:59',          '+', '-1 month 1 day',   '-0061-01-03 07:59:00+15:59'),
-- -15:59, the last valid instant is on the 28th, in the afternoon
('UTC+15:59', '3177-12-28 16:00:59.999998-15:59', '+', '1 microsecond', '3177-12-28 16:00:59.999999-15:59'),
('UTC+15:59', '3177-12-28 16:00:59.999999-15:59', '+', '1 microsecond', 'ERR 22008'),
('UTC+15:59', '3177-12-27 16:00:59.999999-15:59', '+', '1 day',         '3177-12-28 16:00:59.999999-15:59'),
('UTC+15:59', '3177-12-27 16:01:00-15:59',        '+', '1 day',         'ERR 22008'),
('UTC+15:59', '3177-11-28 16:00:59.999999-15:59', '+', '1 month',       '3177-12-28 16:00:59.999999-15:59'),
('UTC+15:59', '3177-11-28 16:01:00-15:59',        '+', '1 month',       'ERR 22008'),
('UTC+15:59', '3177-12-28 16:00:59.999999-15:59', '+', '1 year',        'ERR 22008'),
('UTC+15:59', '3177-12-29 00:00:00-15:59',        '+', '0 days',        'ERR 22008'),   -- the literal itself is outside
-- -15:59, the first end
('UTC+15:59', '-0061-01-01 00:01:00-15:59',          '-', '1 microsecond', 'ERR 22008'),
('UTC+15:59', '-0061-01-01 00:01:00.000001-15:59',   '-', '1 microsecond', '-0061-01-01 00:01:00-15:59'),
('UTC+15:59', '-0061-01-02 00:01:00-15:59',          '-', '1 day',         '-0061-01-01 00:01:00-15:59'),
('UTC+15:59', '-0061-01-02 00:00:59.999999-15:59',   '-', '1 day',         'ERR 22008'),
('UTC+15:59', '-0061-02-01 00:01:00-15:59',          '-', '1 month',       '-0061-01-01 00:01:00-15:59'),
('UTC+15:59', '-0061-02-01 00:00:59.999999-15:59',   '-', '1 month',       'ERR 22008'),
('UTC+15:59', '-0061-02-01 00:00:59.999999-15:59',   '+', '-1 month 1 day', 'ERR 22008');
SELECT ord, zone, start || ' ' || op || ' ' || step AS expression,
       pg_temp.zval(zone, format($q$SELECT (jtimestamptz %L %s interval %L)::text$q$, start, op, step)) AS result,
       pg_temp.zval(zone, format($q$SELECT (jtimestamptz %L %s interval %L)::text$q$, start, op, step)) = expected AS as_expected
FROM jd_edges ORDER BY ord;

-- ---------------------------------------------------------------------
-- extreme intervals are range errors, as in core (they leave the range of the
-- timestamp type), and an interval of -2147483648 months or days cannot be
-- negated
-- ---------------------------------------------------------------------
SELECT z.zone, e.step,
       pg_temp.zval(z.zone, format($q$SELECT (jtimestamptz '1403-05-15 10:00+00' + interval %L)::text$q$, e.step)) AS plus,
       pg_temp.zval(z.zone, format($q$SELECT (jtimestamptz '1403-05-15 10:00+00' - interval %L)::text$q$, e.step)) AS minus
FROM (VALUES ('UTC'), ('Europe/Paris')) z(zone),
     (VALUES ('-2147483648 months'), ('2147483647 months'), ('-2147483648 days'), ('2147483647 days'),
             ('2147483647 months 2147483647 days')) e(step)
ORDER BY z.zone COLLATE "C", e.step COLLATE "C";

RESET DateStyle;
RESET IntervalStyle;
RESET timezone;
