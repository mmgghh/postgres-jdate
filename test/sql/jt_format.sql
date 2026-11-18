-- jday_format and jmonth_format for jdate, jtimestamp and jtimestamptz
-- (src/jtimestamp_format.c).
--
-- Checks: the catalog shape and volatilities, the values of the design report
-- (1403-05-03 with '/', '' and the default separator, the month key, the negative
-- year -0061 and 0007-12), every type with the same day, odd separators, NULLs,
-- the same instant giving 1403-01-01 under Asia/Tehran and 1402-12-29 under UTC,
-- the safe-range edges of jtimestamptz in zones +/-15:59, the infinity matrix,
-- GROUP BY over a generate_series-built table, agreement with the text of the
-- value (left(x::text, 10) and left(x::text, 7)) for jdate, jtimestamp and, in ten
-- session zones, jtimestamptz (with a negative control), the cast to jdate and
-- AT TIME ZONE, bare literals and the missing variants, and indexes (jdate and
-- jtimestamp work, jtimestamptz is 42P17, the AT TIME ZONE recipe works and is
-- used by the planner). Errors are shown as SQLSTATE only. The text input of both
-- timestamp types is Jalali, so a literal for the Gregorian instant
-- 2024-03-19 21:00 UTC is written 1402-12-29 21:00+00. The named zones are
-- Asia/Tehran (+03:30, no daylight saving time in 2024), Asia/Kolkata,
-- Asia/Kathmandu, Europe/Paris, America/Sao_Paulo, Pacific/Kiritimati (+14) and
-- Pacific/Pago_Pago (-11); the range edges use fixed POSIX offsets (+/-15:59).
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

-- ---------------------------------------------------------------------
-- catalog: six functions, jdate and jtimestamp IMMUTABLE (i), jtimestamptz STABLE
-- (s), all strict, parallel safe, in the extension, returning text, with one
-- default argument (the separator, '-')
-- ---------------------------------------------------------------------
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args, p.prorettype::regtype AS returns,
       p.provolatile AS volatility, p.proisstrict AS strict, p.proparallel AS parallel,
       p.pronargdefaults AS defaults, p.prolang = (SELECT oid FROM pg_language WHERE lanname = 'c') AS is_c,
       EXISTS (SELECT 1 FROM pg_depend d
               WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e'
                 AND d.refobjid = (SELECT oid FROM pg_extension WHERE extname = 'jdate')) AS in_extension
FROM pg_proc p
WHERE p.proname IN ('jday_format', 'jmonth_format')
ORDER BY p.proname COLLATE "C", pg_get_function_identity_arguments(p.oid) COLLATE "C";

-- ---------------------------------------------------------------------
-- the values of the design report, for jdate
-- ---------------------------------------------------------------------
SELECT jday_format('1403-05-03'::jdate, '/') AS day_slash,
       jday_format('1403-05-03'::jdate, '') AS day_no_separator,
       jday_format('1403-05-03'::jdate) AS day_default,
       jday_format('1403-05-03'::jdate, '-') AS day_dash,
       jmonth_format('1403-05-03'::jdate, '/') AS month_slash,
       jmonth_format('1403-05-03'::jdate, '') AS month_no_separator,
       jmonth_format('1403-05-03'::jdate) AS month_default;
SELECT jday_format('-0061-05-03'::jdate) AS negative_year_day,
       jmonth_format('-0061-05-03'::jdate) AS negative_year_month,
       jday_format('0007-12-29'::jdate) AS year_7_day,
       jmonth_format('0007-12-29'::jdate) AS year_7_month,
       jday_format('0000-01-01'::jdate) AS year_0_day,
       jday_format('-0001-12-29'::jdate, '') AS year_minus_1_no_separator,
       jday_format('0001-01-01'::jdate, '.') AS year_1_dot;
-- the named argument form and the default are the same function
SELECT jday_format('1403-05-03'::jdate, sep => '/') AS named,
       jday_format('1403-05-03'::jdate) = jday_format('1403-05-03'::jdate, '-') AS default_is_dash,
       pg_typeof(jday_format('1403-05-03'::jdate)) AS day_type,
       pg_typeof(jmonth_format('1403-05-03'::jdate)) AS month_type;

-- ---------------------------------------------------------------------
-- the same values for jtimestamp (the time of day is ignored) and jtimestamptz
-- (the day on the clock of the session zone; 14:30 UTC is the same day in UTC and in
-- Asia/Tehran)
-- ---------------------------------------------------------------------
SELECT jday_format('1403-05-03 14:30:15.5'::jtimestamp, '/') AS day_slash,
       jday_format('1403-05-03 14:30:15.5'::jtimestamp, '') AS day_no_separator,
       jday_format('1403-05-03 14:30:15.5'::jtimestamp) AS day_default,
       jmonth_format('1403-05-03 14:30:15.5'::jtimestamp, '/') AS month_slash,
       jmonth_format('1403-05-03 14:30:15.5'::jtimestamp) AS month_default,
       jday_format('-0061-05-03 23:59:59.999999'::jtimestamp) AS negative_year_day,
       jmonth_format('0007-12-29 00:00:00'::jtimestamp) AS year_7_month;
SELECT jday_format('1403-05-03 14:30:15.5+00'::jtimestamptz, '/') AS day_slash,
       jday_format('1403-05-03 14:30:15.5+00'::jtimestamptz, '') AS day_no_separator,
       jday_format('1403-05-03 14:30:15.5+00'::jtimestamptz) AS day_default,
       jmonth_format('1403-05-03 14:30:15.5+00'::jtimestamptz, '/') AS month_slash,
       jmonth_format('1403-05-03 14:30:15.5+00'::jtimestamptz) AS month_default,
       jday_format('-0060-05-03 14:30:15+00'::jtimestamptz) AS negative_year_day,
       jmonth_format('0007-12-29 12:00+00'::jtimestamptz) AS year_7_month;
SET timezone = 'Asia/Tehran';
SELECT jday_format('1403-05-03 14:30:15.5+00'::jtimestamptz, '/') AS tehran_day_slash,
       jmonth_format('1403-05-03 14:30:15.5+00'::jtimestamptz, '/') AS tehran_month_slash;
SET timezone = 'UTC';

-- a day or month boundary crossed by the zone: the instants 21:00 UTC of Mordad 3, of
-- the last day of Mordad (month 5 has 31 days) and of the leap day Esfand 30 of 1403
-- are the next local day, month and year in Asia/Tehran (+03:30, 00:30 local)
SELECT z.zone,
       pg_temp.zval(z.zone, $q$SELECT jday_format('1403-05-03 21:00+00'::jtimestamptz)$q$) AS day_next,
       pg_temp.zval(z.zone, $q$SELECT jday_format('1403-05-31 21:00+00'::jtimestamptz)$q$) AS month_end,
       pg_temp.zval(z.zone, $q$SELECT jmonth_format('1403-05-31 21:00+00'::jtimestamptz)$q$) AS month_end_month,
       pg_temp.zval(z.zone, $q$SELECT jday_format('1403-12-30 20:30+00'::jtimestamptz)$q$) AS year_end,
       pg_temp.zval(z.zone, $q$SELECT jmonth_format('1403-12-30 20:30+00'::jtimestamptz, '/')$q$) AS year_end_month
FROM (VALUES ('UTC'), ('Asia/Tehran'), ('Asia/Kolkata'), ('Asia/Kathmandu'), ('Europe/Paris'),
             ('Pacific/Kiritimati'), ('Pacific/Pago_Pago')) AS z(zone);

-- ---------------------------------------------------------------------
-- NULL: a NULL separator or a NULL value gives NULL (strict)
-- ---------------------------------------------------------------------
SELECT jday_format('1403-05-03'::jdate, NULL) IS NULL AS null_sep_jdate,
       jday_format('1403-05-03 10:00'::jtimestamp, NULL) IS NULL AS null_sep_jtimestamp,
       jday_format('1403-05-03 10:00+00'::jtimestamptz, NULL) IS NULL AS null_sep_jtimestamptz,
       jmonth_format('1403-05-03'::jdate, NULL) IS NULL AS null_sep_month_jdate,
       jmonth_format('1403-05-03 10:00'::jtimestamp, NULL) IS NULL AS null_sep_month_jtimestamp,
       jmonth_format('1403-05-03 10:00+00'::jtimestamptz, NULL) IS NULL AS null_sep_month_jtimestamptz,
       jday_format(NULL::jdate) IS NULL AS null_jdate,
       jday_format(NULL::jtimestamp, '/') IS NULL AS null_jtimestamp,
       jmonth_format(NULL::jtimestamptz) IS NULL AS null_jtimestamptz,
       jday_format(NULL::jdate, NULL) IS NULL AS both_null,
       jday_format('1403-05-03'::jdate, '') IS NOT NULL AS empty_separator_not_null;

-- ---------------------------------------------------------------------
-- separators: any text. The separator goes into the text as it is (no format
-- directive is read from it), is repeated between the fields, and may be long.
-- ---------------------------------------------------------------------
SELECT s AS separator, jday_format('1403-05-03'::jdate, s) AS day, jmonth_format('1403-05-03'::jdate, s) AS month
FROM (VALUES ('/'), ('.'), (' '), (' / '), ('ab'), ('%'), ('%s%d'), ('\n'), ('"'), (''''), ('--'), ('')) AS v(s)
ORDER BY s COLLATE "C";
SELECT jday_format('1403-05-03'::jdate, E'\t') = E'1403\t05\t03' AS tab,
       jday_format('1403-05-03'::jdate, E'\n') = E'1403\n05\n03' AS newline,
       length(jday_format('1403-05-03'::jdate, repeat('x', 1000))) AS day_len_1000,
       length(jmonth_format('1403-05-03 10:00'::jtimestamp, repeat('xy', 500))) AS month_len_1000,
       length(jday_format('1403-05-03 10:00+00'::jtimestamptz, repeat('-', 100))) AS tz_day_len_100,
       jday_format('1403-05-03'::jdate, repeat('x', 3)) AS day_xxx,
       jday_format('1403-05-03'::jdate, '') = '14030503' AS no_separator,
       length(jday_format('1403-05-03'::jdate, '')) AS no_separator_len,
       length(jmonth_format('1403-05-03'::jdate, '')) AS no_separator_month_len;

-- ---------------------------------------------------------------------
-- the edges of the supported range (years -0061 to 3177): the first and last day
-- of jdate, the first and last microsecond of jtimestamp
-- ---------------------------------------------------------------------
SELECT jday_format('-0061-01-01'::jdate) AS jdate_min, jday_format('3177-12-29'::jdate) AS jdate_max,
       jmonth_format('-0061-01-01'::jdate) AS jdate_min_month, jmonth_format('3177-12-29'::jdate, '/') AS jdate_max_month,
       jday_format('-0061-01-01 00:00:00'::jtimestamp) AS jtimestamp_min,
       jday_format('3177-12-29 23:59:59.999999'::jtimestamp) AS jtimestamp_max,
       jmonth_format('-0061-01-01 00:00:00'::jtimestamp) AS jtimestamp_min_month,
       jmonth_format('3177-12-29 23:59:59.999999'::jtimestamp, '/') AS jtimestamp_max_month,
       jday_format('-0061-01-01 00:00:00'::jtimestamp, '') AS jtimestamp_min_no_separator,
       jday_format('3177-12-29 23:59:59.999999'::jtimestamp, '') AS jtimestamp_max_no_separator;

-- the first and last instant of jtimestamptz (the safe range) seen from UTC and from the
-- two extreme zones: the first instant is -0061-01-01 16:00 UTC, the last is
-- 3177-12-29 07:59:59.999999 UTC; 15:59 east of UTC is the next day for the first
-- instant (07:59 on -0061-01-02), 15:59 west is the day before for the last
-- (16:00:59.999999 on 3177-12-28)
SELECT z.zone,
       pg_temp.zval(z.zone, $q$SELECT jday_format('-0061-01-01 16:00:00+00'::jtimestamptz)$q$) AS first_day,
       pg_temp.zval(z.zone, $q$SELECT jmonth_format('-0061-01-01 16:00:00+00'::jtimestamptz)$q$) AS first_month,
       pg_temp.zval(z.zone, $q$SELECT jday_format('3177-12-29 07:59:59.999999+00'::jtimestamptz, '')$q$) AS last_day_no_separator,
       pg_temp.zval(z.zone, $q$SELECT jmonth_format('3177-12-29 07:59:59.999999+00'::jtimestamptz, '/')$q$) AS last_month
FROM (VALUES ('UTC'), ('<+15:59>-15:59'), ('<-15:59>+15:59')) AS z(zone)
ORDER BY z.zone COLLATE "C";

-- ---------------------------------------------------------------------
-- infinity: the text jdate_out and the output functions of the timestamp types give,
-- 'infinity' or '-infinity', for either function, whatever the separator and the
-- session zone
-- ---------------------------------------------------------------------
SELECT t, v, jday_format AS day_default, day_slash, day_empty, jmonth_format AS month_default, month_slash, month_empty,
       jday_format = v AS day_is_out_text, jmonth_format = v AS month_is_out_text
FROM (
  SELECT 'jdate' AS t, v::text AS v, jday_format(v), jday_format(v, '/') AS day_slash, jday_format(v, '') AS day_empty,
         jmonth_format(v), jmonth_format(v, '/') AS month_slash, jmonth_format(v, '') AS month_empty
  FROM (VALUES ('infinity'::jdate), ('-infinity'::jdate)) AS x(v)
  UNION ALL
  SELECT 'jtimestamp', v::text, jday_format(v), jday_format(v, '/'), jday_format(v, ''),
         jmonth_format(v), jmonth_format(v, '/'), jmonth_format(v, '')
  FROM (VALUES ('infinity'::jtimestamp), ('-infinity'::jtimestamp)) AS x(v)
  UNION ALL
  SELECT 'jtimestamptz', v::text, jday_format(v), jday_format(v, '/'), jday_format(v, ''),
         jmonth_format(v), jmonth_format(v, '/'), jmonth_format(v, '')
  FROM (VALUES ('infinity'::jtimestamptz), ('-infinity'::jtimestamptz)) AS x(v)
) AS m
ORDER BY t COLLATE "C", v COLLATE "C";
SELECT z.zone,
       pg_temp.zval(z.zone, $q$SELECT jday_format('infinity'::jtimestamptz, '/') || ' ' || jmonth_format('-infinity'::jtimestamptz)$q$) AS infinity_in_zone
FROM (VALUES ('UTC'), ('Asia/Tehran'), ('Pacific/Kiritimati'), ('<-15:59>+15:59')) AS z(zone)
ORDER BY z.zone COLLATE "C";

-- ---------------------------------------------------------------------
-- the same instant, 2024-03-19 21:00 UTC, is Nowruz 1403 in Asia/Tehran (00:30 on
-- 2024-03-20) and the last day of 1402 in UTC; jtimestamptz is STABLE because of
-- this. A jtimestamp and a jdate carry no zone: their key does not move.
-- ---------------------------------------------------------------------
SELECT z.zone,
       pg_temp.zval(z.zone, $q$SELECT jday_format('1402-12-29 21:00+00'::jtimestamptz)$q$) AS day,
       pg_temp.zval(z.zone, $q$SELECT jmonth_format('1402-12-29 21:00+00'::jtimestamptz)$q$) AS month,
       pg_temp.zval(z.zone, $q$SELECT jday_format('1402-12-29 21:00+00'::jtimestamptz, '/')$q$) AS day_slash,
       pg_temp.zval(z.zone, $q$SELECT left('1402-12-29 21:00+00'::jtimestamptz::text, 10)$q$) AS text_of_value,
       pg_temp.zval(z.zone, $q$SELECT jday_format('1402-12-29 21:00'::jtimestamp)$q$) AS jtimestamp_day,
       pg_temp.zval(z.zone, $q$SELECT jday_format('1402-12-29'::jdate)$q$) AS jdate_day
FROM (VALUES ('Asia/Tehran'), ('UTC'), ('Asia/Kolkata'), ('Europe/Paris'),
             ('Pacific/Kiritimati'), ('Pacific/Pago_Pago')) AS z(zone)
ORDER BY z.zone COLLATE "C";
-- the instant is 1710882000 seconds after the Unix epoch in every zone
SELECT jdate_part('epoch', '1402-12-29 21:00+00'::jtimestamptz) AS epoch;

-- ---------------------------------------------------------------------
-- GROUP BY over a table built with generate_series: three Jalali years (1402 and
-- 1404 have 365 days, 1403 is a leap year with 366), 1096 days, as jdate, as
-- jtimestamp and as jtimestamptz (the day at 13:30 UTC, the same day in UTC)
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jf_days AS
SELECT d, d::jtimestamp AS a, (d::jtimestamp + interval '13 hours 30 minutes')::jtimestamptz AS b
FROM jgenerate_series('1402-01-01'::jdate, '1404-12-29'::jdate) AS g(d);
SELECT count(*) AS days FROM jf_days;
SELECT jmonth_format(d) AS month, count(*) AS days FROM jf_days
WHERE d >= '1403-01-01' AND d < '1404-01-01' GROUP BY 1 ORDER BY 1;
SELECT jmonth_format(a, '/') AS month, count(*) AS days, min(jday_format(a, '/')) AS first_day, max(jday_format(a, '/')) AS last_day
FROM jf_days WHERE a >= '1404-10-01' GROUP BY 1 ORDER BY 1;
SELECT jmonth_format(b) AS month, count(*) AS days FROM jf_days
WHERE b < '1402-04-01 00:00+00' GROUP BY 1 ORDER BY 1;
-- every group is a run of consecutive days; the three types group alike; the day keys
-- are distinct and sort in date order; the key of a month is the prefix of the key of
-- its days
SELECT count(*) AS groups, sum(n) AS rows, bool_and(n = last_day - first_day + 1) AS runs_of_days,
       bool_and(n = nb AND n = na) AS types_agree
FROM (SELECT jmonth_format(d) AS k, count(*) AS n, max(d) AS last_day, min(d) AS first_day,
             count(*) FILTER (WHERE jmonth_format(a) = jmonth_format(d)) AS na,
             count(*) FILTER (WHERE jmonth_format(b) = jmonth_format(d)) AS nb
      FROM jf_days GROUP BY 1) AS s;
SELECT count(DISTINCT jday_format(d)) AS distinct_day_keys,
       count(*) FILTER (WHERE jday_format(d) = jday_format(a) AND jday_format(a) = jday_format(b)) AS types_agree,
       count(*) FILTER (WHERE jday_format(d) = d::text AND jday_format(d, '-') = d::text) AS equal_to_text,
       count(*) FILTER (WHERE jday_format(d, '') = replace(d::text, '-', '')) AS no_separator_is_digits,
       count(*) FILTER (WHERE left(jday_format(d), 7) = jmonth_format(d)) AS month_is_prefix,
       bool_and(jday_format(d) < jday_format(d + 1)) AS keys_sorted
FROM jf_days;
-- jtimestamptz in a zone where the day changes before 13:30 UTC (Kiritimati, +14: 03:30
-- on the next day): every instant counts for the next day, so Esfand 1403 has 29 of its
-- days, the leap day goes to 1404-01 with the 30 days of Farvardin before the last, and
-- the last day of Farvardin goes to Ordibehesht
SET timezone = 'Pacific/Kiritimati';
SELECT jmonth_format(b) AS month, count(*) AS days FROM jf_days
WHERE b >= '1403-12-01 00:00+00' AND b < '1404-02-01 00:00+00' GROUP BY 1 ORDER BY 1;
SET timezone = 'UTC';

-- ---------------------------------------------------------------------
-- agreement with the text of the value. jdate_out and the timestamp output functions
-- print the Jalali date as the first 10 characters (11 for a negative year: the sign
-- is outside the four digits), so the keys are left(x::text, 10) and left(x::text, 7)
-- (11 and 8 for a negative year). Sweeps over the whole range: every day of the
-- negative years and year 0 (the 23000 days before year 1) and a stride of 101 days
-- through the rest, with a time of day on each jtimestamp (the sign of a negative
-- year stays outside the digits when the separator is '' or '/').
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jf_sweep AS
SELECT '-0061-01-01'::jdate + g AS d,
       '-0061-01-01'::jdate::jtimestamp + (g * interval '1 day') + (g % 86400) * interval '1 second'
         + (g % 1000000) * interval '1 microsecond' AS a
FROM generate_series(0, 1183019) AS g
WHERE g < 23000 OR g % 101 = 0;
SELECT count(*) AS rows,
       count(*) FILTER (WHERE d < '0000-01-01') = '0000-01-01'::jdate - '-0061-01-01'::jdate AS every_negative_day,
       count(*) FILTER (WHERE d >= '0000-01-01' AND d < '0001-01-01') = '0001-01-01'::jdate - '0000-01-01'::jdate AS every_day_of_year_0,
       min(d) AS first, max(d) AS last
FROM jf_sweep;
SELECT count(*) FILTER (WHERE jday_format(d) <> left(d::text, 10 + (d::text LIKE '-%')::int)) AS jdate_day_mismatch,
       count(*) FILTER (WHERE jmonth_format(d) <> left(d::text, 7 + (d::text LIKE '-%')::int)) AS jdate_month_mismatch,
       count(*) FILTER (WHERE jday_format(a) <> left(a::text, 10 + (a::text LIKE '-%')::int)) AS jtimestamp_day_mismatch,
       count(*) FILTER (WHERE jmonth_format(a) <> left(a::text, 7 + (a::text LIKE '-%')::int)) AS jtimestamp_month_mismatch,
       count(*) FILTER (WHERE jday_format(a) <> jday_format(a::jdate)) AS jtimestamp_cast_mismatch,
       count(*) FILTER (WHERE jday_format(a) <> jday_format(d)) AS jtimestamp_vs_jdate_mismatch,
       count(*) FILTER (WHERE jday_format(d, '/') <> (CASE WHEN d < '0000-01-01' THEN '-' ELSE '' END)
                                                      || replace(ltrim(d::text, '-'), '-', '/')) AS slash_mismatch,
       count(*) FILTER (WHERE jday_format(d, '') <> (CASE WHEN d < '0000-01-01' THEN '-' ELSE '' END)
                                                      || replace(ltrim(d::text, '-'), '-', '')) AS no_separator_mismatch,
       count(*) FILTER (WHERE jday_format(d, '') !~ '^-?[0-9]{8}$') AS not_digits
FROM jf_sweep;
-- negative control: the Gregorian date of the same value is not the Jalali key
SELECT count(*) FILTER (WHERE jday_format(a) <> left(a::timestamp::text, 10)) > 0.99 * count(*) AS gregorian_differs
FROM jf_sweep WHERE a >= '0001-01-01 00:00:00';

-- jtimestamptz: instants from the jtimestamp sweep (read in UTC, so the same wall clock),
-- both safe-range edges and half-hourly instants across Nowruz 1403 (1402-12-27 to
-- 1403-01-03, the days around 2024-03-20, with several zones' midnights in it)
CREATE TEMP TABLE jf_tz AS
SELECT a::jtimestamptz AS v FROM jf_sweep WHERE a >= '-0060-01-01 00:00:00' AND a < '3177-01-01 00:00:00'
UNION ALL
SELECT '-0061-01-01 16:00:00+00'::jtimestamptz
UNION ALL
SELECT '3177-12-29 07:59:59.999999+00'::jtimestamptz
UNION ALL
SELECT g FROM jgenerate_series('1402-12-27 00:00+00'::jtimestamptz, '1403-01-03 00:00+00'::jtimestamptz, interval '30 minutes') AS g;
SELECT count(*) AS instants FROM jf_tz;

-- In each zone, as the session zone: the key is the date of the text of the value,
-- the same as the date of the cast to jdate, and the same as the key of the value
-- AT TIME ZONE the zone (a jtimestamp, whose function is immutable: the index recipe).
-- differs_from_utc is the negative control: the zones with a different calendar day
-- for some instant give different keys than UTC.
CREATE FUNCTION pg_temp.tz_agree(zone text, OUT instants bigint, OUT day_mismatch bigint, OUT month_mismatch bigint,
                                 OUT cast_mismatch bigint, OUT at_time_zone_mismatch bigint,
                                 OUT month_at_time_zone_mismatch bigint, OUT differs_from_utc bigint)
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM set_config('TimeZone', zone, false);
    SELECT count(*),
           count(*) FILTER (WHERE jday_format(v) <> left(v::text, 10 + (v::text LIKE '-%')::int)),
           count(*) FILTER (WHERE jmonth_format(v) <> left(v::text, 7 + (v::text LIKE '-%')::int)),
           count(*) FILTER (WHERE jday_format(v) <> jday_format(v::jdate)),
           count(*) FILTER (WHERE jday_format(v) <> jday_format(v AT TIME ZONE zone)),
           count(*) FILTER (WHERE jmonth_format(v, '/') <> jmonth_format(v AT TIME ZONE zone, '/')),
           count(*) FILTER (WHERE jday_format(v) <> jday_format(v AT TIME ZONE 'UTC'))
    INTO instants, day_mismatch, month_mismatch, cast_mismatch, at_time_zone_mismatch,
         month_at_time_zone_mismatch, differs_from_utc
    FROM pg_temp.jf_tz;
    PERFORM set_config('TimeZone', 'UTC', false);
END
$f$;
SELECT z.zone, r.instants, r.day_mismatch, r.month_mismatch, r.cast_mismatch, r.at_time_zone_mismatch,
       r.month_at_time_zone_mismatch, r.differs_from_utc > 0 AS differs_from_utc
FROM (VALUES ('UTC'), ('Asia/Tehran'), ('Asia/Kolkata'), ('Asia/Kathmandu'), ('Europe/Paris'),
             ('America/Sao_Paulo'), ('Pacific/Kiritimati'), ('Pacific/Pago_Pago'),
             ('<+15:59>-15:59'), ('<-15:59>+15:59')) AS z(zone),
     LATERAL pg_temp.tz_agree(z.zone) AS r
ORDER BY z.zone COLLATE "C";

-- jdate and jtimestamp converted to jtimestamptz at local midnight, in a zone: the key
-- is the day it came from
CREATE FUNCTION pg_temp.midnight_agree(zone text) RETURNS bigint
LANGUAGE plpgsql AS $f$
DECLARE
    n bigint;
BEGIN
    PERFORM set_config('TimeZone', zone, false);
    SELECT count(*) FILTER (WHERE jday_format(d::jtimestamptz) <> jday_format(d)
                               OR jmonth_format(a::jtimestamptz) <> jmonth_format(a))
    INTO n FROM pg_temp.jf_days;
    PERFORM set_config('TimeZone', 'UTC', false);
    RETURN n;
END
$f$;
SELECT z.zone, pg_temp.midnight_agree(z.zone) AS mismatches
FROM (VALUES ('UTC'), ('Asia/Tehran'), ('Europe/Paris'), ('America/Sao_Paulo'), ('Pacific/Kiritimati'),
             ('Pacific/Pago_Pago')) AS z(zone)
ORDER BY z.zone COLLATE "C";
-- Asia/Tehran skipped local midnight on 1399-01-02 (2020-03-21, the clocks went from
-- 00:00 to 01:00): the day at "midnight" is 01:00, and its key is still that day
SET timezone = 'Asia/Tehran';
SELECT '1399-01-02'::jdate::jtimestamptz AS gap_day_start, jday_format('1399-01-02'::jdate::jtimestamptz) AS gap_day_key,
       jday_format('1399-01-01 20:29:59+00'::jtimestamptz) AS last_second_of_1399_01_01,
       jday_format('1399-01-01 20:30:00+00'::jtimestamptz) AS first_instant_of_1399_01_02;
SET timezone = 'UTC';

-- ---------------------------------------------------------------------
-- bare literals are ambiguous now that three types offer the functions (42725, as
-- jdate_trunc and extract); typed values work. There is no explicit-zone variant
-- and no function on the core types or on integers (42883).
-- ---------------------------------------------------------------------
SELECT pg_temp.zval('UTC', $q$SELECT jday_format('1403-05-03')$q$) AS bare_day,
       pg_temp.zval('UTC', $q$SELECT jday_format('1403-05-03', '/')$q$) AS bare_day_slash,
       pg_temp.zval('UTC', $q$SELECT jmonth_format('1403-05-03 10:00')$q$) AS bare_month,
       pg_temp.zval('UTC', $q$SELECT jday_format(NULL)$q$) AS bare_null,
       pg_temp.zval('UTC', $q$SELECT jday_format('1403-05-03'::jdate)$q$) AS typed_jdate,
       pg_temp.zval('UTC', $q$SELECT jday_format('1403-05-03 10:00'::jtimestamp)$q$) AS typed_jtimestamp,
       pg_temp.zval('UTC', $q$SELECT jday_format('1403-05-03 10:00+00'::jtimestamptz)$q$) AS typed_jtimestamptz,
       pg_temp.zval('UTC', $q$SELECT jday_format(date '2024-03-20')$q$) AS core_date,
       pg_temp.zval('UTC', $q$SELECT jday_format(timestamp '2024-03-20 10:00')$q$) AS core_timestamp,
       pg_temp.zval('UTC', $q$SELECT jday_format(timestamptz '2024-03-20 10:00+00')$q$) AS core_timestamptz,
       pg_temp.zval('UTC', $q$SELECT jday_format(1403)$q$) AS integer_arg,
       pg_temp.zval('UTC', $q$SELECT jday_format('1403-05-03 10:00+00'::jtimestamptz, '/', 'Asia/Tehran')$q$) AS zone_argument,
       pg_temp.zval('UTC', $q$SELECT jday_format('1403-05-03'::jdate, 5)$q$) AS integer_separator,
       pg_temp.zval('UTC', $q$SELECT jday_format('1403-05-03'::jdate, '/', '/')$q$) AS three_arguments;

-- ---------------------------------------------------------------------
-- volatility by behaviour: indexes. jdate and jtimestamp are immutable, so the keys
-- can be indexed (with the default separator, with a given one, for the month key
-- and for the index recipe: the key of the value AT TIME ZONE a zone, a jtimestamp);
-- jtimestamptz is stable (the session zone) and is refused with 42P17, also with a
-- separator and for the month key.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jf_idx (d jdate, a jtimestamp, b jtimestamptz);
INSERT INTO jf_idx SELECT d, a, (a + interval '13 hours 30 minutes')::jtimestamptz FROM jf_days;
SELECT pg_temp.ddl($q$CREATE INDEX jf_idx_d ON jf_idx (jday_format(d))$q$) AS index_jdate,
       pg_temp.ddl($q$CREATE INDEX jf_idx_d_sep ON jf_idx (jday_format(d, '/'))$q$) AS index_jdate_separator,
       pg_temp.ddl($q$CREATE INDEX jf_idx_d_month ON jf_idx (jmonth_format(d))$q$) AS index_jdate_month,
       pg_temp.ddl($q$CREATE INDEX jf_idx_a ON jf_idx (jday_format(a))$q$) AS index_jtimestamp,
       pg_temp.ddl($q$CREATE INDEX jf_idx_a_sep ON jf_idx (jday_format(a, ''))$q$) AS index_jtimestamp_separator,
       pg_temp.ddl($q$CREATE INDEX jf_idx_a_month ON jf_idx (jmonth_format(a, '/'))$q$) AS index_jtimestamp_month,
       pg_temp.ddl($q$CREATE INDEX jf_idx_b ON jf_idx (jday_format(b))$q$) AS index_jtimestamptz,
       pg_temp.ddl($q$CREATE INDEX jf_idx_b_sep ON jf_idx (jday_format(b, '/'))$q$) AS index_jtimestamptz_separator,
       pg_temp.ddl($q$CREATE INDEX jf_idx_b_month ON jf_idx (jmonth_format(b))$q$) AS index_jtimestamptz_month,
       pg_temp.ddl($q$CREATE INDEX jf_idx_b_tehran ON jf_idx (jday_format((b AT TIME ZONE 'Asia/Tehran')))$q$) AS index_at_time_zone_recipe,
       pg_temp.ddl($q$CREATE INDEX jf_idx_b_tehran_month ON jf_idx (jmonth_format((b AT TIME ZONE 'Asia/Tehran'), '/'))$q$) AS index_at_time_zone_month,
       pg_temp.ddl($q$CREATE INDEX jf_idx_b_stmp ON jf_idx ((b AT TIME ZONE 'Asia/Tehran'))$q$) AS index_at_time_zone_value;
-- the planner uses them
ANALYZE jf_idx;
SET enable_seqscan = off;
SELECT count(*) AS rows_on_the_day FROM jf_idx WHERE jday_format(d) = '1403-05-03';
SELECT count(*) AS rows_in_the_month FROM jf_idx WHERE jmonth_format(a, '/') = '1403/05';
SELECT count(*) AS rows_of_the_tehran_day
FROM jf_idx WHERE jday_format((b AT TIME ZONE 'Asia/Tehran')) = '1403-05-03';
SELECT pg_temp.plan_uses_index($q$SELECT * FROM jf_idx WHERE jday_format(d) = '1403-05-03'$q$) AS planner_uses_the_jdate_index,
       pg_temp.plan_uses_index($q$SELECT * FROM jf_idx WHERE jday_format(a) = '1403-05-03'$q$) AS planner_uses_the_jtimestamp_index,
       pg_temp.plan_uses_index($q$SELECT * FROM jf_idx WHERE jmonth_format(a, '/') = '1403/05'$q$) AS planner_uses_the_month_index,
       pg_temp.plan_uses_index($q$SELECT * FROM jf_idx WHERE jday_format((b AT TIME ZONE 'Asia/Tehran')) = '1403-05-03'$q$) AS planner_uses_the_recipe_index;
RESET enable_seqscan;
-- the volatility is in the catalog (jtimestamptz is s) and the same in a generated
-- expression: a stored generated column over the immutable ones works, one over
-- jtimestamptz is refused
SELECT pg_temp.ddl($q$CREATE TEMP TABLE jf_gen_ok (d jdate, k text GENERATED ALWAYS AS (jday_format(d, '/')) STORED)$q$) AS generated_jdate,
       pg_temp.ddl($q$CREATE TEMP TABLE jf_gen_ts (a jtimestamp, k text GENERATED ALWAYS AS (jmonth_format(a)) STORED)$q$) AS generated_jtimestamp,
       pg_temp.ddl($q$CREATE TEMP TABLE jf_gen_bad (b jtimestamptz, k text GENERATED ALWAYS AS (jday_format(b)) STORED)$q$) AS generated_jtimestamptz;
