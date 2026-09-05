CREATE EXTENSION jdate;

-- valid round trips
SELECT '1403-01-01'::jdate;
SELECT '1402-12-29'::jdate;   -- last day of a common (29-day Esfand) year
SELECT '1395-12-30'::jdate;   -- last day of a leap (30-day Esfand) year
SELECT '0001-01-01'::jdate;
SELECT '-0061-01-01'::jdate;  -- JALAALI_MIN_YEAR
SELECT '3177-12-29'::jdate;   -- JALAALI_MAX_YEAR, common year, 29-day Esfand

-- infinity
SELECT 'infinity'::jdate, '-infinity'::jdate;
SELECT 'INFINITY'::jdate, 'Infinity'::jdate;

-- invalid input: format errors
SELECT 'garbage'::jdate;
SELECT '1403/01/01'::jdate;
SELECT '1403-01-01 '::jdate;
SELECT '1403-01-01extra'::jdate;

-- invalid input: out-of-range values
SELECT '1402-13-01'::jdate;    -- bad month
SELECT '1402-00-01'::jdate;    -- bad month
SELECT '1402-01-32'::jdate;    -- bad day
SELECT '1394-12-30'::jdate;    -- 1394 is common: no day 30 in Esfand
SELECT '-0062-01-01'::jdate;   -- one below JALAALI_MIN_YEAR
SELECT '3178-01-01'::jdate;    -- one above JALAALI_MAX_YEAR
