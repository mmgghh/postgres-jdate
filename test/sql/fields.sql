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

-- dow/isodow are calendar-agnostic: must match the Gregorian answer for
-- the identical underlying day
SELECT jdate_part('dow', '1403-05-15'::jdate) = date_part('dow', '1403-05-15'::jdate::date) AS dow_matches_gregorian;
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
