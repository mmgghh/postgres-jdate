-- Interval arithmetic and differences for jtimestamp: jtimestamp + interval,
-- interval + jtimestamp, jtimestamp - interval, jtimestamp - jtimestamp,
-- jdate - jtimestamp and jtimestamp - jdate. The month part of an interval is
-- applied with Jalali month lengths, then days, then time, as core does for
-- timestamp; the day and time parts are core's. Results are checked against
-- hand-computed tables, against an independent SQL model of the month rule over
-- every month of the range, and (for what does not involve months) against
-- core's operators on the same instants as `timestamp`. Errors are shown as
-- SQLSTATE only (a helper catches them), never as message text.
--
-- Everything created here is temporary or dropped at the end: extension_schema
-- runs DROP EXTENSION, which needs no column of our types left behind.
SET DateStyle = 'ISO, YMD';
SET IntervalStyle = 'postgres';
SET timezone = 'UTC';

-- The text of the result of a one-value query, or "ERR <sqlstate>".
CREATE FUNCTION pg_temp.val(q text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE
    r text;
BEGIN
    EXECUTE q INTO r;
    RETURN coalesce(r, 'NULL');
EXCEPTION WHEN OTHERS THEN
    RETURN 'ERR ' || SQLSTATE;
END
$f$;

-- ---------------------------------------------------------------------
-- the operators in the catalog
-- ---------------------------------------------------------------------
-- all IMMUTABLE, STRICT and PARALLEL SAFE; + has its commutator, - has none
SELECT o.oprname AS operator, o.oprleft::regtype AS left_type,
       o.oprright::regtype AS right_type, o.oprresult::regtype AS result_type,
       o.oprcode::text AS function, p.provolatile AS volatility,
       p.proisstrict AS strict, p.proparallel AS parallel,
       o.oprcom <> 0 AS has_commutator, o.oprnegate <> 0 AS has_negator
FROM pg_operator o JOIN pg_proc p ON p.oid = o.oprcode
WHERE o.oprname IN ('+', '-')
  AND 'jtimestamp'::regtype IN (o.oprleft, o.oprright)
ORDER BY o.oprname COLLATE "C", o.oprleft::regtype::text COLLATE "C",
         o.oprright::regtype::text COLLATE "C";

-- the result types, as written in the operator table
SELECT pg_typeof(jtimestamp '1403-05-15 10:00' + interval '1 day') AS ts_plus,
       pg_typeof(interval '1 day' + jtimestamp '1403-05-15 10:00') AS plus_ts,
       pg_typeof(jtimestamp '1403-05-15 10:00' - interval '1 day') AS ts_minus,
       pg_typeof(jtimestamp '1403-05-15 10:00' - jtimestamp '1403-05-14 10:00') AS ts_minus_ts,
       pg_typeof(jdate '1403-05-15' - jtimestamp '1403-05-14 10:00') AS d_minus_ts,
       pg_typeof(jtimestamp '1403-05-15 10:00' - jdate '1403-05-14') AS ts_minus_d;

-- ---------------------------------------------------------------------
-- the month rule: the table of Jalali month steps (a time of day rides along
-- unchanged); "ERR 22008" is the range error past the last day
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jta_months (ord serial, start text, months int, expected text);
INSERT INTO jta_months (start, months, expected) VALUES
('1403-06-31',   1, '1403-07-30'),   -- clamp: Mehr has 30 days
('1403-06-31',   6, '1403-12-30'),   -- 1403 is leap
('1403-07-30',  -1, '1403-06-30'),   -- not 06-31: not invertible
('1403-12-30',  12, '1404-12-29'),   -- 1404 is not leap
('1403-12-30',  60, '1408-12-30'),   -- 1408 is leap
('1403-12-30', -12, '1402-12-29'),
('1403-12-30', -60, '1398-12-29'),
('1403-11-30',   1, '1403-12-30'),
('1404-11-30',   1, '1404-12-29'),
('1403-01-31',  11, '1403-12-30'),
('1403-01-31',  12, '1404-01-31'),
('0000-01-31',  -1, '-0001-12-29'),
('0001-01-30',  -1, '0000-12-30'),  -- year 0 is leap in this implementation
('3177-12-29',  -1, '3177-11-29'),
('3177-12-29',   1, 'ERR 22008');   -- 3178-01-29 is outside the range

-- ts + n months, n months + ts, and ts - (-n) months all agree and give the
-- expected value
SELECT start, months,
       pg_temp.val(format($q$SELECT (jtimestamp %L + make_interval(months => %s))::text$q$,
                          start || ' 13:45:30.123456', months)) AS result,
       pg_temp.val(format($q$SELECT (jtimestamp %L + make_interval(months => %s))::text$q$,
                          start || ' 13:45:30.123456', months))
         = CASE WHEN expected LIKE 'ERR%' THEN expected
                ELSE expected || ' 13:45:30.123456' END AS as_expected,
       pg_temp.val(format($q$SELECT (make_interval(months => %s) + jtimestamp %L)::text$q$,
                          months, start || ' 13:45:30.123456'))
         = pg_temp.val(format($q$SELECT (jtimestamp %L + make_interval(months => %s))::text$q$,
                          start || ' 13:45:30.123456', months)) AS commutes,
       pg_temp.val(format($q$SELECT (jtimestamp %L - make_interval(months => %s))::text$q$,
                          start || ' 13:45:30.123456', -months))
         = pg_temp.val(format($q$SELECT (jtimestamp %L + make_interval(months => %s))::text$q$,
                          start || ' 13:45:30.123456', months)) AS minus_agrees
FROM jta_months ORDER BY ord;

-- ---------------------------------------------------------------------
-- months first, then days, then time
-- ---------------------------------------------------------------------
-- 1403-06-30 + 1 month is 1403-07-30, one more day is 1403-08-01 (days first
-- would give 06-31, then 07-30)
SELECT jtimestamp '1403-06-30 10:00' + interval '1 month 1 day 2 hours' AS months_days_time,
       (jtimestamp '1403-06-30 10:00' + interval '1 month 1 day 2 hours')
         = (jtimestamp '1403-06-30 10:00' + interval '1 month'
                                           + interval '1 day' + interval '2 hours') AS months_first,
       (jtimestamp '1403-06-30 10:00' + interval '1 month 1 day 2 hours')
         <> (jtimestamp '1403-06-30 10:00' + interval '1 day'
                                            + interval '1 month' + interval '2 hours') AS not_days_first;

-- the same through core: a day step of core, applied after our month step
SELECT jtimestamp '1403-06-31 23:00' + interval '1 month -1 day' AS month_then_back_a_day,
       jtimestamp '1403-06-31 23:00' + interval '1 month 1 hour' AS month_then_hour,
       jtimestamp '1403-06-31 23:00' + interval '1 month 1 day 1 hour' AS crosses_midnight,
       jtimestamp '1403-01-01 00:00' + interval '1.5 months' AS fractional_month;

-- subtraction is the negated interval: the month step goes back first
SELECT jtimestamp '1403-08-01 12:00' - interval '1 month 1 day 2 hours' AS minus_all,
       jtimestamp '1403-08-01 12:00' + interval '-1 month -1 day -2 hours' AS plus_negated,
       jtimestamp '1403-12-30 00:00' - interval '1 year' AS minus_year,
       jtimestamp '1404-12-29 00:00' - interval '1 year' AS minus_year_leap;

-- not invertible, as in core
SELECT jtimestamp '1403-06-31 08:00' + interval '1 month' AS plus_month,
       jtimestamp '1403-06-31 08:00' + interval '1 month' - interval '1 month' AS and_back,
       jtimestamp '1403-06-31 08:00' + interval '1 month' - interval '1 month'
         = jtimestamp '1403-06-31 08:00' AS inverted;

-- 1 year is 12 months: 1403 and 1408 are leap, 1404 to 1407 are not
SELECT s AS start,
       (s::jtimestamp + interval '1 year')::text AS plus_year,
       (s::jtimestamp + interval '12 months')::text AS plus_12_months,
       s::jtimestamp + interval '1 year' = s::jtimestamp + interval '12 months' AS same,
       (s::jtimestamp + interval '1 year 2 months')::text AS plus_1y2m,
       s::jtimestamp + interval '1 year 2 months' = s::jtimestamp + interval '14 months' AS same_14
FROM (VALUES ('1403-12-30 00:00'), ('1399-12-30 06:00'), ('1403-01-31 00:00'),
             ('1404-12-29 23:59:59.999999')) v(s);
SELECT jtimestamp '1403-12-30 00:00' + interval '5 years' AS leap_to_leap,
       jtimestamp '1399-12-30 00:00' + interval '4 years' AS leap_to_leap_4,
       jtimestamp '1403-12-30 00:00' + interval '1 year' AS leap_to_common;

-- ---------------------------------------------------------------------
-- the model: the month rule against an independent SQL implementation, for the
-- last and the first day of every month of every year of the range, with
-- eight month counts
-- ---------------------------------------------------------------------
-- text of a Jalali date, month length and floor division, written with the jdate
-- parser only (the leap test is: does 12-30 parse)
CREATE FUNCTION pg_temp.ymd(y int, m int, d int) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN y < 0 THEN '-' ELSE '' END || lpad(abs(y)::text, 4, '0')
           || '-' || lpad(m::text, 2, '0') || '-' || lpad(d::text, 2, '0')
$$;
CREATE FUNCTION pg_temp.mlen(y int, m int) RETURNS int
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN m <= 6 THEN 31 WHEN m <= 11 THEN 30
                ELSE 29 + pg_input_is_valid(pg_temp.ymd(y, 12, 30), 'jdate')::int END
$$;

CREATE TEMP TABLE jta_model AS
WITH starts AS (
    SELECT y, m, d
    FROM generate_series(-61, 3177) y, generate_series(1, 12) m,
         LATERAL (VALUES (1), (pg_temp.mlen(y, m))) dd(d)
), steps AS (
    SELECT s.*, n, (s.y * 12 + (s.m - 1) + n) AS t
    FROM starts s, unnest(ARRAY[1, -1, 5, -7, 12, -12, 25, -61]) n
), target AS (
    SELECT y, m, d, n, floor(t / 12.0)::int AS ny, (t - floor(t / 12.0)::int * 12 + 1) AS nm
    FROM steps
)
SELECT y, m, d, n, ny, nm, pg_temp.mlen(ny, nm) AS nlen
FROM target
WHERE ny BETWEEN -61 AND 3177;

SELECT count(*) AS cases,
       count(*) FILTER (WHERE
           ((pg_temp.ymd(y, m, d) || ' 13:45:30.123456')::jtimestamp
              + make_interval(months => n))::text
           = pg_temp.ymd(ny, nm, least(d, nlen)) || ' 13:45:30.123456') AS agree
FROM jta_model;

-- negative control: a model without the clamp to the last day of the target
-- month must disagree somewhere, so the comparison above can fail
SELECT count(*) FILTER (WHERE
           ((pg_temp.ymd(y, m, d) || ' 13:45:30.123456')::jtimestamp
              + make_interval(months => n))::text
           <> pg_temp.ymd(ny, nm, d) || ' 13:45:30.123456') > 0 AS unclamped_model_disagrees
FROM jta_model;

-- ---------------------------------------------------------------------
-- the range edges
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jta_edges (ord serial, label text, stmt text);
INSERT INTO jta_edges (label, stmt) VALUES
('last instant, built by adding time',
 $$SELECT (jtimestamp '3177-12-29 00:00:00' + interval '23:59:59.999999')::text$$),
('last instant + 1 microsecond',
 $$SELECT (jtimestamp '3177-12-29 23:59:59.999999' + interval '1 microsecond')::text$$),
('last day + 1 day',
 $$SELECT (jtimestamp '3177-12-29 12:00' + interval '1 day')::text$$),
('last day + 1 month',
 $$SELECT (jtimestamp '3177-12-29 12:00' + interval '1 month')::text$$),
('last day + 1 year',
 $$SELECT (jtimestamp '3177-12-29 12:00' + interval '1 year')::text$$),
('last day, the month step leaves the range, the days would bring it back',
 $$SELECT (jtimestamp '3177-12-29 12:00' + interval '1 month -40 days')::text$$),
('3177-10-30 + 2 months clamps to the last day',
 $$SELECT (jtimestamp '3177-10-30 12:00' + interval '2 months')::text$$),
('3177-11-29 + 1 month',
 $$SELECT (jtimestamp '3177-11-29 12:00' + interval '1 month')::text$$),
('last day - 12 months',
 $$SELECT (jtimestamp '3177-12-29 12:00' - interval '12 months')::text$$),
('first instant - 1 microsecond',
 $$SELECT (jtimestamp '-0061-01-01 00:00:00' - interval '1 microsecond')::text$$),
('first day - 1 day',
 $$SELECT (jtimestamp '-0061-01-01 00:00:00' - interval '1 day')::text$$),
('second day - 1 day',
 $$SELECT (jtimestamp '-0061-01-02 00:00:00' - interval '1 day')::text$$),
('first day + 1 month',
 $$SELECT (jtimestamp '-0061-01-01 00:00:00' + interval '1 month')::text$$),
('first day - 1 month',
 $$SELECT (jtimestamp '-0061-01-01 00:00:00' - interval '1 month')::text$$),
('first day + 1 microsecond - 1 month',
 $$SELECT (jtimestamp '-0061-01-01 00:00:00.000001' - interval '1 month')::text$$),
('-0061-03-31 - 2 months',
 $$SELECT (jtimestamp '-0061-03-31 12:00' - interval '2 months')::text$$),
('minus 1 year at -0060',
 $$SELECT (jtimestamp '-0060-06-15 12:00' - interval '1 year')::text$$),
('minus 1 year at -0061',
 $$SELECT (jtimestamp '-0061-06-15 12:00' - interval '1 year')::text$$),
('an interval of -2147483648 months',
 $$SELECT (jtimestamp '1403-05-15 10:00' + interval '-2147483648 months')::text$$),
('an interval of 2147483647 months',
 $$SELECT (jtimestamp '1403-05-15 10:00' + interval '2147483647 months')::text$$),
('minus an interval of -2147483648 months (cannot be negated)',
 $$SELECT (jtimestamp '1403-05-15 10:00' - interval '-2147483648 months')::text$$),
('minus an interval of 2147483647 months',
 $$SELECT (jtimestamp '1403-05-15 10:00' - interval '2147483647 months')::text$$),
('an interval of -2147483648 days',
 $$SELECT (jtimestamp '1403-05-15 10:00' + interval '-2147483648 days')::text$$),
('an interval of 2147483647 days',
 $$SELECT (jtimestamp '1403-05-15 10:00' + interval '2147483647 days')::text$$),
('minus an interval of -2147483648 days',
 $$SELECT (jtimestamp '1403-05-15 10:00' - interval '-2147483648 days')::text$$),
('an interval of 2147483647 months 2147483647 days',
 $$SELECT (jtimestamp '1403-05-15 10:00' + interval '2147483647 months 2147483647 days')::text$$),
('interval + jtimestamp at the last instant',
 $$SELECT (interval '1 microsecond' + jtimestamp '3177-12-29 23:59:59.999999')::text$$),
('interval + jtimestamp, month, from the first day',
 $$SELECT (interval '1 month' + jtimestamp '-0061-01-31 00:00:00')::text$$);

SELECT label, pg_temp.val(stmt) AS result FROM jta_edges ORDER BY ord;

-- ---------------------------------------------------------------------
-- infinity
-- ---------------------------------------------------------------------
SELECT 'infinity'::jtimestamp + interval '1 month' AS inf_plus,
       '-infinity'::jtimestamp - interval '1 year' AS neg_inf_minus,
       interval '3 days' + 'infinity'::jtimestamp AS flipped,
       'infinity'::jtimestamp - interval '-5 days 3 hours' AS inf_minus_negative,
       '-infinity'::jtimestamp + interval '1 month 1 day 1 hour' AS all_parts;

-- against core, on the same infinity and finite values and on intervals without
-- months (infinite ones included: they exist from PostgreSQL 17, and where they
-- do not, core and we both refuse the literal): the same value or the same
-- SQLSTATE, for + and -, in both orders of + (core's errors, such as opposite
-- infinities, are core's own)
WITH t(j, g) AS (VALUES ('infinity', 'infinity'), ('-infinity', '-infinity'),
                        ('1403-05-15 10:00', '2024-08-05 10:00'),
                        ('0001-01-01 00:00:00.5', '0622-03-22 00:00:00.5'),
                        ('3000-12-29 23:00', '3622-03-19 23:00')),
     i(iv) AS (VALUES ('infinity'), ('-infinity'), ('0'), ('1 day'), ('-1 day'),
                      ('36 hours'), ('-2 days 3 hours'),
                      ('1 day 2 hours 3 minutes 4.5 seconds'), ('-0.000001 seconds')),
     r AS (
    SELECT t.j, t.g, i.iv,
           pg_temp.val(format($q$SELECT (%L::jtimestamp + %L::interval)::timestamp::text$q$, t.j, i.iv)) AS j_plus,
           pg_temp.val(format($q$SELECT (%L::timestamp + %L::interval)::text$q$, t.g, i.iv)) AS g_plus,
           pg_temp.val(format($q$SELECT (%L::interval + %L::jtimestamp)::timestamp::text$q$, i.iv, t.j)) AS j_flip,
           pg_temp.val(format($q$SELECT (%L::jtimestamp - %L::interval)::timestamp::text$q$, t.j, i.iv)) AS j_minus,
           pg_temp.val(format($q$SELECT (%L::timestamp - %L::interval)::text$q$, t.g, i.iv)) AS g_minus
    FROM t, i)
SELECT count(*) AS cases,
       count(*) FILTER (WHERE j_plus = g_plus) AS plus_agrees,
       count(*) FILTER (WHERE j_flip = g_plus) AS flipped_agrees,
       count(*) FILTER (WHERE j_minus = g_minus) AS minus_agrees,
       count(*) FILTER (WHERE g_plus LIKE 'ERR%') > 0 AS some_errors_compared
FROM r;

-- opposite infinities are core's error (22008) on PostgreSQL 17 and later; the
-- literal itself is refused before that. Same-sign infinities are infinity.
SELECT pg_temp.val($$SELECT ('-infinity'::jtimestamp + interval 'infinity')::text$$)
         IN ('ERR 22008', 'ERR 22007') AS opposite_plus,
       pg_temp.val($$SELECT ('infinity'::jtimestamp - interval 'infinity')::text$$)
         IN ('ERR 22008', 'ERR 22007') AS opposite_minus,
       pg_temp.val($$SELECT ('infinity'::jtimestamp + interval 'infinity')::text$$)
         IN ('infinity', 'ERR 22007') AS same_sign,
       pg_temp.val($$SELECT (jtimestamp '1403-05-15 10:00' + interval 'infinity')::text$$)
         IN ('infinity', 'ERR 22007') AS finite_plus_infinite;

-- ---------------------------------------------------------------------
-- day and time parts are core's: the same as core's timestamp + interval on the
-- Gregorian instants, over the whole range
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jta_days AS
SELECT t, i
FROM generate_series(timestamp '0560-03-20', timestamp '3799-03-19 23:59:59',
                     interval '37 days 5 hours 11 minutes') t,
     (VALUES (interval '1 day'), (interval '-1 day'), (interval '45 days 3 hours'),
             (interval '-400 days'), (interval '90 minutes'),
             (interval '-36 hours 5 seconds'), (interval '0')) v(i);

SELECT count(*) AS plus_cases,
       count(*) FILTER (WHERE (t::jtimestamp + i)::timestamp = t + i) AS plus_agrees,
       count(*) FILTER (WHERE (i + t::jtimestamp)::timestamp = t + i) AS flipped_agrees
FROM jta_days
WHERE t + i BETWEEN timestamp '0560-03-20' AND timestamp '3799-03-19 23:59:59.999999';
SELECT count(*) AS minus_cases,
       count(*) FILTER (WHERE (t::jtimestamp - i)::timestamp = t - i) AS minus_agrees
FROM jta_days
WHERE t - i BETWEEN timestamp '0560-03-20' AND timestamp '3799-03-19 23:59:59.999999';

-- negative control: comparing with the result of a different step must fail
SELECT count(*) FILTER (WHERE (t::jtimestamp + i)::timestamp <> t - i) > 0 AS wrong_step_disagrees
FROM jta_days
WHERE i <> interval '0'
  AND t + i BETWEEN timestamp '0560-03-20' AND timestamp '3799-03-19 23:59:59.999999'
  AND t - i BETWEEN timestamp '0560-03-20' AND timestamp '3799-03-19 23:59:59.999999';

-- the result of a day step or a time step of a jtimestamp is the same under any
-- session time zone (a jtimestamp has none: no DST gap or overlap can change it)
CREATE TEMP TABLE jta_zones (zone text, r text);
SET timezone = 'Asia/Tehran';
INSERT INTO jta_zones SELECT 'Asia/Tehran',
    ((jtimestamp '1403-01-01 00:30:00' + interval '1 hour')::text || ' ' ||
     (jtimestamp '1402-12-29 23:30:00' + interval '1 day 1 hour')::text || ' ' ||
     (jtimestamp '1403-06-31 02:30:00' + interval '1 month')::text);
SET timezone = 'Europe/Paris';
INSERT INTO jta_zones SELECT 'Europe/Paris',
    ((jtimestamp '1403-01-01 00:30:00' + interval '1 hour')::text || ' ' ||
     (jtimestamp '1402-12-29 23:30:00' + interval '1 day 1 hour')::text || ' ' ||
     (jtimestamp '1403-06-31 02:30:00' + interval '1 month')::text);
SET timezone = 'America/Sao_Paulo';
INSERT INTO jta_zones SELECT 'America/Sao_Paulo',
    ((jtimestamp '1403-01-01 00:30:00' + interval '1 hour')::text || ' ' ||
     (jtimestamp '1402-12-29 23:30:00' + interval '1 day 1 hour')::text || ' ' ||
     (jtimestamp '1403-06-31 02:30:00' + interval '1 month')::text);
SET timezone = 'UTC';
SELECT count(DISTINCT r) AS distinct_results, min(r) AS result, count(*) AS zones FROM jta_zones;

-- ---------------------------------------------------------------------
-- jtimestamp - jtimestamp: days plus time (core's timestamp_mi)
-- ---------------------------------------------------------------------
SELECT jtimestamp '1403-05-25 12:00' - jtimestamp '1403-05-15 00:00' AS ten_days_noon,
       jtimestamp '1403-05-15 00:00' - jtimestamp '1403-05-25 12:00' AS negative,
       jtimestamp '1403-07-01 00:00' - jtimestamp '1403-06-31 00:00' AS across_month_end,
       jtimestamp '1404-01-01 00:00' - jtimestamp '1403-12-30 00:00' AS across_leap_year_end,
       jtimestamp '1404-01-01 00:00' - jtimestamp '1403-01-01 00:00' AS leap_year_366_days,
       jtimestamp '1403-05-15 10:00:00.000001' - jtimestamp '1403-05-15 10:00' AS one_microsecond,
       jtimestamp '3177-12-29 23:59:59.999999' - jtimestamp '-0061-01-01 00:00' AS whole_range;

-- every pair of a spread of instants (and the two edges) gives core's interval
CREATE TEMP TABLE jta_pts AS
SELECT g AS t FROM generate_series(timestamp '0560-03-20',
                                   timestamp '3799-03-19 23:59:59.999999',
                                   interval '29 years 41 days 7 hours 13 minutes 5.123456 seconds') g
UNION ALL SELECT timestamp '0560-03-20 00:00:00'
UNION ALL SELECT timestamp '3799-03-19 23:59:59.999999'
UNION ALL SELECT timestamp '2024-03-20 00:00:00'
UNION ALL SELECT timestamp '2024-03-19 23:59:59.999999';
SELECT count(*) AS pairs,
       count(*) FILTER (WHERE (a.t::jtimestamp - b.t::jtimestamp)::text = (a.t - b.t)::text) AS agree,
       count(*) FILTER (WHERE (a.t::jtimestamp - b.t::jtimestamp)::text <> (b.t - a.t)::text) > 0 AS swapped_disagrees
FROM jta_pts a, jta_pts b;

-- infinity: the same value or SQLSTATE as core (an infinite interval on 17 and
-- later, an error before)
WITH t(j, g) AS (VALUES ('infinity', 'infinity'), ('-infinity', '-infinity'),
                        ('1403-05-15 10:00', '2024-08-05 10:00'))
SELECT count(*) AS cases,
       count(*) FILTER (WHERE
           pg_temp.val(format($q$SELECT (%L::jtimestamp - %L::jtimestamp)::text$q$, a.j, b.j))
           = pg_temp.val(format($q$SELECT (%L::timestamp - %L::timestamp)::text$q$, a.g, b.g))) AS agree
FROM t a, t b;

-- ---------------------------------------------------------------------
-- jdate - jtimestamp and jtimestamp - jdate: the day is its midnight
-- ---------------------------------------------------------------------
SELECT jdate '1403-05-25' - jtimestamp '1403-05-15 12:00' AS nine_days_half,
       jtimestamp '1403-05-15 12:00' - jdate '1403-05-25' AS negated,
       jdate '1403-05-15' - jtimestamp '1403-05-15 00:00' AS zero,
       jtimestamp '1403-05-15 00:00' - jdate '1403-05-15' AS zero_too,
       jdate '1404-01-01' - jtimestamp '1403-12-30 18:00' AS across_leap_year_end;

CREATE TEMP TABLE jta_dates AS
SELECT date '0560-03-20' + g AS d FROM generate_series(0, 1183019, 9973) g
UNION ALL SELECT date '3799-03-19';
SELECT count(*) AS pairs,
       count(*) FILTER (WHERE (a.d::jdate - b.t::jtimestamp)::text = (a.d - b.t)::text) AS date_minus_ts_agree,
       count(*) FILTER (WHERE (b.t::jtimestamp - a.d::jdate)::text = (b.t - a.d)::text) AS ts_minus_date_agree
FROM jta_dates a, jta_pts b;

-- infinity: the same value or SQLSTATE as core's date - timestamp
WITH d(j, g) AS (VALUES ('infinity', 'infinity'), ('-infinity', '-infinity'),
                        ('1403-05-15', '2024-08-05')),
     t(j, g) AS (VALUES ('infinity', 'infinity'), ('-infinity', '-infinity'),
                        ('1403-05-15 10:00', '2024-08-05 10:00'))
SELECT count(*) AS cases,
       count(*) FILTER (WHERE
           pg_temp.val(format($q$SELECT (%L::jdate - %L::jtimestamp)::text$q$, d.j, t.j))
           = pg_temp.val(format($q$SELECT (%L::date - %L::timestamp)::text$q$, d.g, t.g))) AS date_minus_ts_agree,
       count(*) FILTER (WHERE
           pg_temp.val(format($q$SELECT (%L::jtimestamp - %L::jdate)::text$q$, t.j, d.j))
           = pg_temp.val(format($q$SELECT (%L::timestamp - %L::date)::text$q$, t.g, d.g))) AS ts_minus_date_agree
FROM d, t;

-- ---------------------------------------------------------------------
-- what is not there: no operator against the core types, and nothing between
-- two points in time other than the differences above
-- ---------------------------------------------------------------------
SELECT pg_temp.val($$SELECT (jtimestamp '1403-05-15 10:00' - timestamp '2024-08-05 10:00')::text$$) AS ts_minus_core,
       pg_temp.val($$SELECT (timestamp '2024-08-05 10:00' - jtimestamp '1403-05-15 10:00')::text$$) AS core_minus_ts,
       pg_temp.val($$SELECT (jtimestamp '1403-05-15 10:00' + jtimestamp '1403-05-15 10:00')::text$$) AS ts_plus_ts,
       pg_temp.val($$SELECT (jtimestamp '1403-05-15 10:00' + jdate '1403-05-15')::text$$) AS ts_plus_date,
       pg_temp.val($$SELECT (jdate '1403-05-15' + jtimestamp '1403-05-15 10:00')::text$$) AS date_plus_ts,
       pg_temp.val($$SELECT (jtimestamp '1403-05-15 10:00' + 1)::text$$) AS ts_plus_int,
       pg_temp.val($$SELECT (jtimestamp '1403-05-15 10:00' - 1)::text$$) AS ts_minus_int,
       pg_temp.val($$SELECT (jtimestamp '1403-05-15 10:00' - timestamptz '2024-08-05 10:00')::text$$) AS ts_minus_tz;

-- a bare literal as the interval resolves: the only operator with a jtimestamp
-- on the left and an unknown on the right is jtimestamp + interval
SELECT jtimestamp '1403-05-15 10:00' + '1 day' AS bare_literal_plus,
       '1 month' + jtimestamp '1403-06-31 10:00' AS bare_literal_flipped;

-- with minus a bare literal on the right is read as the type of the left
-- operand (jtimestamp - jtimestamp is an exact match), as core reads it for
-- timestamp: the literal is not a jtimestamp, 22007 in both
SELECT pg_temp.val($$SELECT (jtimestamp '1403-05-15 10:00' - '1 day')::text$$) AS bare_literal_minus,
       pg_temp.val($$SELECT (timestamp '2024-08-05 10:00' - '1 day')::text$$) AS core_bare_literal_minus;

-- ---------------------------------------------------------------------
-- IMMUTABLE: usable in an index expression and a generated column
-- ---------------------------------------------------------------------
CREATE TABLE jta_idx (
    id int,
    ts jtimestamp,
    next_month jtimestamp GENERATED ALWAYS AS (ts + interval '1 month') STORED
);
CREATE INDEX jta_idx_prev_day ON jta_idx ((ts - interval '1 day'));
INSERT INTO jta_idx (id, ts) VALUES (1, '1403-06-31 10:00'), (2, '1403-12-30 00:00'),
                                    (3, '1404-11-30 23:59:59.999999');
SELECT id, ts, next_month FROM jta_idx ORDER BY id;
SELECT count(*) AS found FROM jta_idx WHERE ts - interval '1 day' = jtimestamp '1403-06-30 10:00';
DROP TABLE jta_idx;

RESET DateStyle;
RESET IntervalStyle;
RESET timezone;
