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
