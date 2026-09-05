-- pin output style so this file's expected output is independent of the
-- server's configured defaults
SET DateStyle = 'ISO, YMD';
SET timezone = 'UTC';

-- jdate <-> date: binary-identical, same underlying day
SELECT '1403-01-01'::jdate::date AS jdate_to_date;
SELECT '2024-03-20'::date::jdate AS date_to_jdate;
SELECT ('1403-01-01'::jdate::date) = '2024-03-20'::date AS same_day;

-- jdate -> timestamp / timestamptz (assignment-level, not implicit)
SELECT '1403-01-01'::jdate::timestamp;
SELECT '1403-01-01'::jdate::timestamptz;

-- timestamp / timestamptz -> jdate (assignment-level)
SELECT timestamp '2024-03-20 15:30:00'::jdate;
SELECT timestamptz '2024-03-20 15:30:00+00'::jdate;

-- neither direction is implicit: plain comparisons across types must fail
-- rather than silently converting through a different calendar
SELECT '1403-01-01'::jdate = date '2024-03-20';
