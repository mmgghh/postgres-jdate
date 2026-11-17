-- jdate_part
SELECT jdate_part('year', '1403-05-15'::jdate) AS f_year;
SELECT jdate_part('month', '1403-05-15'::jdate) AS f_month;
SELECT jdate_part('day', '1403-05-15'::jdate) AS f_day;
SELECT jdate_part('quarter', '1403-05-15'::jdate) AS f_quarter;
SELECT jdate_part('quarter', '1403-11-01'::jdate) AS f_quarter_q4;
SELECT jdate_part('doy', '1403-01-01'::jdate) AS f_doy_new_year;
SELECT jdate_part('doy', '1403-07-01'::jdate) AS f_doy_second_half;
SELECT jdate_part('decade', '1403-05-15'::jdate) AS f_decade;
SELECT jdate_part('century', '1403-05-15'::jdate) AS f_century;
SELECT jdate_part('hour', '1403-05-15'::jdate) AS f_hour_zero;
SELECT jdate_part('minute', '1403-05-15'::jdate) AS f_minute_zero;
SELECT jdate_part('second', '1403-05-15'::jdate) AS f_second_zero;

-- dow is Saturday-first (Saturday 0 .. Friday 6): core's dow (Sunday 0) plus
-- one, modulo 7. isodow is the plain ISO number and must equal core's. Both
-- are calendar-agnostic, so they follow the identical underlying day.
SELECT jdate_part('dow', '1403-05-15'::jdate) = (date_part('dow', '1403-05-15'::jdate::date)::int + 1) % 7 AS dow_saturday_first;
SELECT jdate_part('isodow', '1403-05-15'::jdate) = date_part('isodow', '1403-05-15'::jdate::date) AS isodow_matches_gregorian;

-- epoch is calendar-agnostic too: must match the Gregorian answer for
-- the identical underlying day
SELECT jdate_part('epoch', '1403-05-15'::jdate) = date_part('epoch', '1403-05-15'::jdate::date) AS epoch_matches_gregorian;
SELECT EXTRACT(epoch FROM '1403-01-01'::jdate) AS extract_epoch;

-- unsupported unit
SELECT jdate_part('week', '1403-05-15'::jdate);

-- EXTRACT() overload, registered directly in pg_catalog
SELECT EXTRACT(year FROM '1403-05-15'::jdate) AS extract_year;
SELECT EXTRACT(month FROM '1403-05-15'::jdate) AS extract_month;
SELECT pg_typeof(EXTRACT(year FROM '1403-05-15'::jdate)) AS extract_returns_numeric;

-- confirm EXTRACT for pre-existing types is completely unaffected
SELECT EXTRACT(year FROM date '2024-01-01') AS extract_year_date_unaffected;
SELECT EXTRACT(year FROM timestamp '2024-01-01 00:00:00') AS extract_year_timestamp_unaffected;

-- jdate_trunc
SELECT jdate_trunc('day', '1403-05-15'::jdate) AS trunc_day;
SELECT jdate_trunc('month', '1403-05-15'::jdate) AS trunc_month;
SELECT jdate_trunc('quarter', '1403-05-15'::jdate) AS trunc_quarter;
SELECT jdate_trunc('quarter', '1403-11-20'::jdate) AS trunc_quarter_q4;
SELECT jdate_trunc('year', '1403-05-15'::jdate) AS trunc_year;
SELECT jdate_trunc('year', '-infinity'::jdate) AS trunc_year_infinite;
SELECT jdate_trunc('week', '1403-05-15'::jdate);  -- unsupported unit

-- decade is year / 10, as in core (decade 202 is 2020-2029), not the first
-- year of the decade: the jdate years 1400..1409 are decade 140
SELECT jdate_part('decade', '1403-05-15'::jdate) AS decade_1403;
SELECT EXTRACT(decade FROM '1403-05-15'::jdate) AS extract_decade_1403;
SELECT pg_typeof(EXTRACT(decade FROM '1403-05-15'::jdate)) AS extract_decade_type;
SELECT d AS jdate, jdate_part('decade', d::jdate) AS decade
FROM (VALUES ('0000-05-15'), ('0009-05-15'), ('0010-05-15'), ('0019-05-15'),
             ('1399-05-15'), ('1400-05-15'), ('1409-05-15'), ('1410-05-15'),
             ('3177-12-29')) AS v(d);

-- the documented examples side by side: the decade is a number (year / 10
-- rounded down), never the first year of the decade, so there is no 1400
SELECT jdate_part('year', d::jdate) AS year, jdate_part('decade', d::jdate) AS decade
FROM (VALUES ('1403-05-15'), ('1400-01-01'), ('1399-12-29'),
             ('0000-05-15'), ('-0001-05-15')) AS v(d);

-- Jalali years below 0 follow core's decade numbering, which for the same
-- (astronomical, year 0 exists) year number is floor(year / 10): decade 0 is
-- years 0..9 and decade -1 is years -10..-1, so every decade has ten years.
-- Core agrees, e.g. EXTRACT(decade FROM date '0002-06-01 BC') = -1 for the
-- astronomical year -1, and date '0062-06-01 BC' (year -61) gives -7.
SELECT d AS jdate, jdate_part('decade', d::jdate) AS decade
FROM (VALUES ('-0001-05-15'), ('-0010-05-15'), ('-0011-05-15'), ('-0020-05-15'),
             ('-0021-05-15'), ('-0060-05-15'), ('-0061-01-01')) AS v(d);
SELECT EXTRACT(decade FROM date '0002-06-01 BC') AS core_decade_year_m1,
       EXTRACT(decade FROM date '0062-06-01 BC') AS core_decade_year_m61;

-- every year of the supported range: decade matches floor(year / 10), matches
-- core's decade for the same year number (core has no year 0, so astronomical
-- year y <= 0 is core's (y - 1) BC-shifted year), matches trunc(year / 10)
-- from year 0 up, and EXTRACT agrees with jdate_part; the year column proves
-- the generated dates are the intended years
WITH y AS (
    SELECT g,
           (CASE WHEN g < 0 THEN '-' ELSE '' END || lpad(abs(g)::text, 4, '0') || '-05-15')::jdate AS d,
           make_date(CASE WHEN g >= 1 THEN g ELSE g - 1 END, 6, 1) AS core_d
    FROM generate_series(-61, 3177) AS g
)
SELECT count(*) AS years,
       count(*) FILTER (WHERE jdate_part('year', d) <> g) AS wrong_year,
       count(*) FILTER (WHERE jdate_part('decade', d) <> floor(jdate_part('year', d) / 10)) AS not_floor_div,
       count(*) FILTER (WHERE g >= 0 AND jdate_part('decade', d) <> trunc(jdate_part('year', d) / 10)) AS not_trunc_div,
       count(*) FILTER (WHERE jdate_part('decade', d) <> date_part('decade', core_d)) AS differs_from_core,
       count(*) FILTER (WHERE EXTRACT(decade FROM d) <> jdate_part('decade', d)::numeric) AS extract_differs
FROM y;

-- dow, isodow and epoch are calendar-agnostic: isodow and epoch must equal
-- core's answer for the identical day, and dow is core's shifted to a
-- Saturday start ((core dow + 1) % 7), including at both ends of the
-- supported range
SELECT d AS jdate,
       jdate_part('dow', d::jdate) AS dow,
       jdate_part('dow', d::jdate) = (date_part('dow', d::jdate::date)::int + 1) % 7 AS dow_ok,
       jdate_part('isodow', d::jdate) AS isodow,
       jdate_part('isodow', d::jdate) = date_part('isodow', d::jdate::date) AS isodow_ok,
       jdate_part('epoch', d::jdate) AS epoch,
       jdate_part('epoch', d::jdate) = date_part('epoch', d::jdate::date) AS epoch_ok,
       EXTRACT(epoch FROM d::jdate) = EXTRACT(epoch FROM d::jdate::date) AS extract_epoch_ok
FROM (VALUES ('-0061-01-01'), ('0000-01-01'), ('1348-10-11'), ('1403-05-15'),
             ('3177-12-29')) AS v(d);

-- one full week, Saturday to Friday, side by side: dow counts from Saturday
-- (0) to Friday (6), isodow from Monday (1) to Sunday (7). The first week
-- crosses a month boundary (Mordad 31 -> Shahrivar 1, 1403); the second is in
-- negative years and crosses the year boundary from -1 to 0. The to_char
-- column is core's own weekday name for the same day, from the Gregorian date.
SELECT d AS jdate,
       to_char(d::date, 'Dy') AS weekday,
       jdate_part('dow', d) AS dow,
       jdate_part('isodow', d) AS isodow,
       EXTRACT(dow FROM d) AS extract_dow,
       EXTRACT(isodow FROM d) AS extract_isodow,
       date_part('dow', d::date) AS core_dow
FROM (SELECT '1403-05-27'::jdate + n AS d FROM generate_series(0, 6) AS n) AS w
ORDER BY d;
SELECT d AS jdate,
       to_char(d::date, 'Dy') AS weekday,
       jdate_part('dow', d) AS dow,
       jdate_part('isodow', d) AS isodow,
       EXTRACT(dow FROM d) AS extract_dow,
       EXTRACT(isodow FROM d) AS extract_isodow,
       date_part('dow', d::date) AS core_dow
FROM (SELECT '-0001-12-26'::jdate + n AS d FROM generate_series(0, 6) AS n) AS w
ORDER BY d;

-- 1403-01-01 is a Wednesday: dow 4 (Saturday-first), isodow 3
SELECT jdate_part('dow', '1403-01-01'::jdate) AS dow_new_year,
       jdate_part('isodow', '1403-01-01'::jdate) AS isodow_new_year,
       jdate_part('dow', '1403-01-01'::jdate) + 1 AS dow_one_based;

-- the same over every day of the supported range, jdate_part and EXTRACT
SELECT count(*) AS days,
       count(*) FILTER (WHERE jdate_part('dow', d) <> (date_part('dow', d::date)::int + 1) % 7) AS dow_differs,
       count(*) FILTER (WHERE jdate_part('isodow', d) <> date_part('isodow', d::date)) AS isodow_differs,
       count(*) FILTER (WHERE jdate_part('epoch', d) <> date_part('epoch', d::date)) AS epoch_differs,
       count(*) FILTER (WHERE EXTRACT(dow FROM d) <> (EXTRACT(dow FROM d::date)::int + 1) % 7) AS extract_dow_differs,
       count(*) FILTER (WHERE EXTRACT(epoch FROM d) <> EXTRACT(epoch FROM d::date)) AS extract_epoch_differs
FROM (SELECT g::date::jdate AS d
      FROM generate_series('-0061-01-01'::jdate::date::timestamp,
                           '3177-12-29'::jdate::date::timestamp,
                           interval '1 day') AS g) AS s;

-- infinity: epoch is +/-Infinity (it errored before)
SELECT EXTRACT(epoch FROM 'infinity'::jdate) AS extract_epoch_inf,
       EXTRACT(epoch FROM '-infinity'::jdate) AS extract_epoch_ninf;
SELECT jdate_part('epoch', 'infinity'::jdate) AS part_epoch_inf,
       jdate_part('epoch', '-infinity'::jdate) AS part_epoch_ninf;

-- infinity: every supported unit gives the same answer as core's date, which
-- is NULL for the units that cycle (dow, isodow, month, day, quarter, doy) and
-- +/-Infinity for the ones that only grow (year, decade, century, epoch)
SELECT f, v,
       jdate_part(f, v::jdate) AS jdate_part,
       date_part(f, v::date) AS core_part,
       jdate_part(f, v::jdate) IS NOT DISTINCT FROM date_part(f, v::date) AS part_same
FROM (VALUES ('dow'), ('isodow'), ('epoch'), ('year'), ('month'), ('day'),
             ('quarter'), ('doy'), ('decade'), ('century')) AS u(f),
     (VALUES ('infinity'), ('-infinity')) AS i(v)
ORDER BY v <> 'infinity', f;

-- the same through EXTRACT (numeric)
SELECT v,
       EXTRACT(dow FROM v::jdate) IS NOT DISTINCT FROM (EXTRACT(dow FROM v::date)::int + 1) % 7 AS dow_same,
       EXTRACT(isodow FROM v::jdate) IS NOT DISTINCT FROM EXTRACT(isodow FROM v::date) AS isodow_same,
       EXTRACT(epoch FROM v::jdate) IS NOT DISTINCT FROM EXTRACT(epoch FROM v::date) AS epoch_same,
       EXTRACT(year FROM v::jdate) IS NOT DISTINCT FROM EXTRACT(year FROM v::date) AS year_same,
       EXTRACT(month FROM v::jdate) IS NOT DISTINCT FROM EXTRACT(month FROM v::date) AS month_same,
       EXTRACT(day FROM v::jdate) IS NOT DISTINCT FROM EXTRACT(day FROM v::date) AS day_same,
       EXTRACT(quarter FROM v::jdate) IS NOT DISTINCT FROM EXTRACT(quarter FROM v::date) AS quarter_same,
       EXTRACT(doy FROM v::jdate) IS NOT DISTINCT FROM EXTRACT(doy FROM v::date) AS doy_same,
       EXTRACT(decade FROM v::jdate) IS NOT DISTINCT FROM EXTRACT(decade FROM v::date) AS decade_same,
       EXTRACT(century FROM v::jdate) IS NOT DISTINCT FROM EXTRACT(century FROM v::date) AS century_same
FROM (VALUES ('infinity'), ('-infinity')) AS i(v)
ORDER BY v <> 'infinity';
SELECT EXTRACT(year FROM 'infinity'::jdate) AS extract_year_inf,
       EXTRACT(century FROM '-infinity'::jdate) AS extract_century_ninf,
       EXTRACT(month FROM 'infinity'::jdate) IS NULL AS extract_month_inf_null;

-- time-of-day units give 0 for finite dates and NULL for infinity (they do
-- not grow); an unsupported unit still fails on infinity
SELECT jdate_part('hour', 'infinity'::jdate) IS NULL AS hour_inf_null,
       jdate_part('second', '-infinity'::jdate) IS NULL AS second_ninf_null,
       jdate_part('hour', '1403-05-15'::jdate) AS hour_finite;
SELECT jdate_part('week', 'infinity'::jdate);
