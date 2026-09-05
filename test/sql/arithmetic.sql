SELECT '1403-01-01'::jdate + 10 AS plus_ten;
SELECT '1403-01-11'::jdate - 10 AS minus_ten;
SELECT '1403-01-01'::jdate - 1 AS crosses_year_boundary;  -- expect 1402-12-29
SELECT '1403-01-10'::jdate - '1403-01-01'::jdate AS day_diff;
SELECT '1403-01-01'::jdate - '1403-02-01'::jdate AS negative_day_diff;

-- arithmetic does not eagerly validate the Jalali-supported range: it
-- stays a cheap integer operation, same as date's own arithmetic. The
-- error is raised lazily, the first time the value is displayed.
SELECT ('3177-12-29'::jdate + 1) IS NOT NULL AS arithmetic_does_not_error;
SELECT '3177-12-29'::jdate + 1;
