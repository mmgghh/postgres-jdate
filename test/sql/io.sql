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

-- integer overflow in a field is an error, never a wrapped value. sscanf's %d
-- truncated these to 1403, 1, 1, 1403 and -1 respectively.
\set VERBOSITY sqlstate
SELECT '4294968699-01-01'::jdate;           -- year 2^32 + 1403
SELECT '1403-4294967297-01'::jdate;         -- month 2^32 + 1
SELECT '1403-01-4294967297'::jdate;         -- day 2^32 + 1
SELECT '-4294965893-01-01'::jdate;          -- year -(2^32 - 1403)
SELECT '99999999999999999999-01-01'::jdate; -- far beyond int64 too
-- the int32 boundaries: the extremes that fit are out of the Jalali range,
-- the ones that do not fit overflow; all are 22008
SELECT '2147483647-01-01'::jdate;           -- INT32_MAX
SELECT '2147483648-01-01'::jdate;           -- INT32_MAX + 1
SELECT '-2147483648-01-01'::jdate;          -- INT32_MIN
SELECT '-2147483649-01-01'::jdate;          -- INT32_MIN - 1
-- syntax errors stay 22007
SELECT ''::jdate;
SELECT '-'::jdate;
SELECT '1403'::jdate;
SELECT '1403-01'::jdate;
SELECT '1403-01-'::jdate;
SELECT '1403-x-01'::jdate;
SELECT '1403-01-01-01'::jdate;
\set VERBOSITY default
SELECT '4294968699-01-01'::jdate;           -- the message for an overflow

-- redundant leading zeros are not an overflow
SELECT '0000000000000000000001403-01-01'::jdate;
SELECT '1403-0000000000000000001-0000000000000000001'::jdate;

-- the grammar is otherwise unchanged: leading and trailing whitespace, an
-- optional '+' sign on any field, and whitespace around the dashes are
-- accepted
SELECT ' 1403-01-01'::jdate;
SELECT '+1403-01-01'::jdate;
SELECT '1403-+01-+01'::jdate;
SELECT '1403 - 01 - 01'::jdate;
