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

-- to_jdate(double precision): the inverse of EXTRACT(epoch FROM jdate)
SELECT to_jdate(extract(epoch from timestamptz '2024-03-20 12:00:00+00')) AS epoch_to_jdate;
SELECT to_jdate(extract(epoch from '1403-01-01'::jdate::timestamptz)) = '1403-01-01'::jdate AS epoch_roundtrip;
-- a plain integer literal works too, via implicit promotion to float8
SELECT to_jdate(0) AS epoch_zero;
-- fractional seconds don't change the calendar day
SELECT to_jdate(extract(epoch from timestamptz '2024-03-20 12:00:00+00') + 0.75)
     = to_jdate(extract(epoch from timestamptz '2024-03-20 12:00:00+00')) AS epoch_fraction_same_day;

-- ---------------------------------------------------------------------
-- to_jdate() is the UTC day of the epoch: the session TimeZone is
-- irrelevant, so the function is IMMUTABLE and gives the same answer in
-- every zone. (It used to go through timestamptz and the session zone:
-- in America/New_York to_jdate(epoch of 1403-01-01) was 1402-12-29.)
-- ---------------------------------------------------------------------
CREATE TABLE to_jdate_probe (e float8, expect jdate);
INSERT INTO to_jdate_probe VALUES
    (-86400.5,        '1348-10-09'),  -- 1969-12-30 23:59:59.5 UTC
    (-86400,          '1348-10-10'),  -- 1969-12-31 00:00:00 UTC
    (-1,              '1348-10-10'),
    (-0.5,            '1348-10-10'),  -- half a second before the Unix epoch
    (0,               '1348-10-11'),  -- 1970-01-01 is 11 Dey 1348
    (0.5,             '1348-10-11'),
    (86399.9999999,   '1348-10-11'),  -- last instant of day 0
    (86400,           '1348-10-12'),  -- first instant of day 1
    (1710892800,      '1403-01-01'),  -- 2024-03-20 00:00:00 UTC
    (1710979199.999,  '1403-01-01'),  -- 2024-03-20 23:59:59.999 UTC
    (1710979200,      '1403-01-02');  -- 2024-03-21 00:00:00 UTC

CREATE TABLE to_jdate_days (d jdate);
INSERT INTO to_jdate_days VALUES
    ('-0061-01-01'), ('0000-01-01'), ('1402-12-29'), ('1403-01-01'),
    ('3177-12-29');

-- in each zone: no probe may differ from its expected day (the query lists
-- the ones that do), and every day must round-trip through its epoch, both
-- at midnight UTC and 23:59:59.999 UTC (a zone east of UTC moves the latter
-- into the next local day). The round trip prints booleans, not days: a
-- wrong, out-of-range day must not hide behind a display error.
SET timezone = 'America/New_York';
SELECT to_jdate(extract(epoch from '1403-01-01'::jdate)) AS new_york_nowruz;
SELECT e, expect, to_jdate(e) AS got FROM to_jdate_probe
WHERE to_jdate(e) <> expect ORDER BY e;
SELECT d, to_jdate(extract(epoch from d)) = d AS midnight_ok,
       to_jdate(extract(epoch from d) + 86399.999) = d AS end_of_day_ok
FROM to_jdate_days ORDER BY d;

SET timezone = 'Asia/Tehran';
SELECT to_jdate(extract(epoch from '1403-01-01'::jdate)) AS tehran_nowruz;
SELECT e, expect, to_jdate(e) AS got FROM to_jdate_probe
WHERE to_jdate(e) <> expect ORDER BY e;
SELECT d, to_jdate(extract(epoch from d)) = d AS midnight_ok,
       to_jdate(extract(epoch from d) + 86399.999) = d AS end_of_day_ok
FROM to_jdate_days ORDER BY d;

SET timezone = 'Pacific/Kiritimati';
SELECT to_jdate(extract(epoch from '1403-01-01'::jdate)) AS kiritimati_nowruz;
SELECT e, expect, to_jdate(e) AS got FROM to_jdate_probe
WHERE to_jdate(e) <> expect ORDER BY e;
SELECT d, to_jdate(extract(epoch from d)) = d AS midnight_ok,
       to_jdate(extract(epoch from d) + 86399.999) = d AS end_of_day_ok
FROM to_jdate_days ORDER BY d;

-- the supported range ends exactly at the first and last day, whatever
-- the zone. Out-of-range results fail when computed (IS NOT NULL keeps the
-- error from coming from displaying the result).
\set VERBOSITY sqlstate
SET timezone = 'America/New_York';
SELECT to_jdate(extract(epoch from '3177-12-29'::jdate) + 86400) IS NOT NULL;
SELECT to_jdate(extract(epoch from '-0061-01-01'::jdate) - 0.001) IS NOT NULL;
SET timezone = 'Pacific/Kiritimati';
SELECT to_jdate(extract(epoch from '3177-12-29'::jdate) + 86400) IS NOT NULL;
SELECT to_jdate(extract(epoch from '-0061-01-01'::jdate) - 0.001) IS NOT NULL;
SET timezone = 'UTC';
SELECT to_jdate(extract(epoch from '3177-12-29'::jdate) + 86400) IS NOT NULL;
SELECT to_jdate(extract(epoch from '-0061-01-01'::jdate) - 0.001) IS NOT NULL;
SELECT to_jdate(extract(epoch from date '9999-12-31')) IS NOT NULL;
SELECT to_jdate(extract(epoch from date '0001-01-01')) IS NOT NULL;

-- NaN and epochs far outside any date are range errors, never wrapped
SELECT to_jdate('NaN'::float8) IS NOT NULL;
SELECT to_jdate(1e15) IS NOT NULL;
SELECT to_jdate(-1e15) IS NOT NULL;
SELECT to_jdate(1e300) IS NOT NULL;
SELECT to_jdate(-1e300) IS NOT NULL;
SELECT to_jdate(9.3e18) IS NOT NULL;
SELECT to_jdate(-9.3e18) IS NOT NULL;
\set VERBOSITY default

-- infinity maps to infinity, like EXTRACT(epoch FROM infinity) the other way
SELECT to_jdate('Infinity'::float8) AS inf, to_jdate('-Infinity'::float8) AS ninf;

-- IMMUTABLE: it can be used in an index expression
SELECT provolatile, proisstrict, proparallel
FROM pg_proc WHERE proname = 'to_jdate';
CREATE TABLE to_jdate_idx_t (e float8);
CREATE INDEX to_jdate_idx_t_idx ON to_jdate_idx_t (to_jdate(e));
INSERT INTO to_jdate_idx_t VALUES (1710892800), (1710979200), (0);
SET enable_seqscan = off;
SELECT e FROM to_jdate_idx_t WHERE to_jdate(e) = '1403-01-01' ORDER BY e;
RESET enable_seqscan;

DROP TABLE to_jdate_probe, to_jdate_days, to_jdate_idx_t;
