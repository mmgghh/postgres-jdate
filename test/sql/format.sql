SET timezone = 'Asia/Tehran';
SELECT jdate_format(timestamptz '2024-03-20 00:30:00+03:30') AS tehran_local;
SELECT jdate_format(timestamptz '2024-03-20 00:30:00+03:30', false) AS tehran_date_only;

SET timezone = 'UTC';
SELECT jdate_format(timestamptz '2024-03-20 00:30:00+03:30') AS utc_crosses_to_prior_day;

RESET timezone;

-- years are printed exactly as jdate_out prints them: a sign for a negative
-- year, then a four digit magnitude (-0061, not -061). UTC keeps the calendar
-- day of the midnight timestamps below fixed.
SET timezone = 'UTC';
SELECT jdate_format('-0061-01-01'::jdate::timestamptz) AS min_year;
SELECT jdate_format('-0061-01-01'::jdate::timestamptz, false) AS min_year_date_only;
SELECT jdate_format('-0061-01-01'::jdate::timestamptz + interval '13:45:10') AS min_year_with_time;
SELECT jdate_format('-0010-12-29'::jdate::timestamptz) AS year_minus_10;
SELECT jdate_format('-0001-06-15'::jdate::timestamptz) AS year_minus_1;
SELECT jdate_format('-0001-06-15'::jdate::timestamptz, false) AS year_minus_1_date_only;
SELECT jdate_format('0000-01-01'::jdate::timestamptz) AS year_0;
SELECT jdate_format('0001-01-01'::jdate::timestamptz) AS year_1;
SELECT jdate_format('1403-01-01'::jdate::timestamptz) AS year_1403;
SELECT jdate_format('3177-12-29'::jdate::timestamptz) AS max_year;
SELECT jdate_format('3177-12-29'::jdate::timestamptz, false) AS max_year_date_only;

-- the invariant behind it: formatting a midnight timestamptz gives the text
-- of the jdate, for every day of the negative years and year 0 (all of them
-- precede year 1) and for a stride through the rest of the range
SELECT count(*) AS days,
       count(*) FILTER (WHERE d < '0001-01-01'::jdate) AS days_before_year_1,
       '0001-01-01'::jdate - '-0061-01-01'::jdate AS expected_days_before_year_1,
       count(*) FILTER (WHERE jdate_format(d::timestamptz, false) <> d::text) AS date_only_mismatches,
       count(*) FILTER (WHERE jdate_format(d::timestamptz) <> d::text || ' 00:00:00') AS with_time_mismatches
FROM (SELECT '-0061-01-01'::jdate + g AS d
      FROM generate_series(0, 1183019) AS g
      WHERE g < 23000 OR g % 101 = 0) AS s;

RESET timezone;

-- infinity: jdate_format returns the text jdate_out uses ('infinity' and
-- '-infinity'), with or without the time (it errored before). jdate_trunc and
-- jdate_part on infinity are covered in fields.sql.
SET timezone = 'UTC';
SELECT jdate_format('infinity'::timestamptz) AS inf,
       jdate_format('infinity'::timestamptz, true) AS inf_with_time,
       jdate_format('infinity'::timestamptz, false) AS inf_date_only;
SELECT jdate_format('-infinity'::timestamptz) AS ninf,
       jdate_format('-infinity'::timestamptz, true) AS ninf_with_time,
       jdate_format('-infinity'::timestamptz, false) AS ninf_date_only;
SELECT jdate_format('infinity'::timestamptz) = 'infinity'::jdate::text AS inf_matches_jdate_out,
       jdate_format('-infinity'::timestamptz) = '-infinity'::jdate::text AS ninf_matches_jdate_out;
-- infinity does not depend on the session time zone
SET timezone = 'Asia/Tehran';
SELECT jdate_format('infinity'::timestamptz) AS inf_tehran,
       jdate_format('-infinity'::timestamptz, false) AS ninf_tehran_date_only;
SET timezone = 'UTC';

-- a day beyond the Jalali range fails with 22008, on either side and with or
-- without the time; the first days inside the range still format
\set VERBOSITY sqlstate
SELECT jdate_format('9999-12-31'::timestamptz);
SELECT jdate_format('9999-12-31'::timestamptz, false);
SELECT jdate_format('3177-12-29'::jdate::timestamptz + interval '1 day');
SELECT jdate_format('3177-12-29'::jdate::timestamptz + interval '1 day', false);
SELECT jdate_format('-0061-01-01'::jdate::timestamptz - interval '1 day');
SELECT jdate_format('-0061-01-01'::jdate::timestamptz - interval '1 day', false);
\set VERBOSITY default
SELECT jdate_format('3177-12-29'::jdate::timestamptz + interval '23:59:59') AS max_year_last_second;
SELECT jdate_format('-0061-01-01'::jdate::timestamptz, false) AS min_year_still_formats;

RESET timezone;
