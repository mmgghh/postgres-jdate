SELECT '1403-01-01'::jdate + 10 AS plus_ten;
SELECT '1403-01-11'::jdate - 10 AS minus_ten;
SELECT '1403-01-01'::jdate - 1 AS crosses_year_boundary;  -- expect 1402-12-29
SELECT '1403-01-10'::jdate - '1403-01-01'::jdate AS day_diff;
SELECT '1403-01-01'::jdate - '1403-02-01'::jdate AS negative_day_diff;

-- arithmetic results outside the supported Jalali range are rejected
-- immediately (SQLSTATE 22008), not lazily when first displayed. IS NOT
-- NULL keeps the error from coming from display. Edge cases and the
-- date/timestamp casts are covered in range.sql.
\set VERBOSITY sqlstate
SELECT ('3177-12-29'::jdate + 1) IS NOT NULL AS arithmetic_errors_eagerly;
SELECT '3177-12-29'::jdate + 1;
\set VERBOSITY default
