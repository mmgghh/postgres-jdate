-- SQLSTATE codes of the errors that the other tests only pin by message (or
-- not at all): an unknown unit (22023), an unsupported unit or schema move
-- (0A000), operators and functions the type does not define (42883), and
-- the 22007/22008 input and range errors as a sanity check.
--
-- Only the SQLSTATE is compared, never message text: core's messages change
-- between major versions, the codes do not. Each statement runs inside a
-- plpgsql block that catches the error, so one failure does not stop the file.
SET DateStyle = 'ISO, YMD';
SET timezone = 'UTC';

CREATE FUNCTION pg_temp.state(q text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
  EXECUTE q;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE;
END
$f$;

-- A schema other than the one jdate is installed in: ALTER EXTENSION ... SET
-- SCHEMA is a no-op, and gives no error, when the target is the current schema.
CREATE SCHEMA sqlstate_other;

CREATE TEMP TABLE cases (n serial, label text, stmt text, expected text);

INSERT INTO cases (label, stmt, expected) VALUES
-- 22023: a unit core does not recognise
('jdate_part unknown unit',
 $$SELECT jdate_part('foo', jdate '1403-05-15')$$, '22023'),
('extract unknown unit',
 $$SELECT extract('foo' FROM jdate '1403-05-15')$$, '22023'),
('jdate_trunc unknown unit',
 $$SELECT jdate_trunc('foo', jdate '1403-05-15')$$, '22023'),
-- "epoch" is a RESERV token for core's lookup, not a UNITS token: still valid
('jdate_part epoch (RESERV, must succeed)',
 $$SELECT jdate_part('epoch', jdate '1403-05-15')$$, 'ok'),
('extract epoch (RESERV, must succeed)',
 $$SELECT extract('epoch' FROM jdate '1403-05-15')$$, 'ok'),
('jdate_part year (must succeed)',
 $$SELECT jdate_part('year', jdate '1403-05-15')$$, 'ok'),
('jdate_trunc month (must succeed)',
 $$SELECT jdate_trunc('month', jdate '1403-05-15')$$, 'ok'),

-- 0A000: a recognised unit the type does not support
('jdate_part week',
 $$SELECT jdate_part('week', jdate '1403-05-15')$$, '0A000'),
('jdate_part millennium',
 $$SELECT jdate_part('millennium', jdate '1403-05-15')$$, '0A000'),
('jdate_part julian',
 $$SELECT jdate_part('julian', jdate '1403-05-15')$$, '0A000'),
('jdate_part isoyear',
 $$SELECT jdate_part('isoyear', jdate '1403-05-15')$$, '0A000'),
('jdate_part timezone',
 $$SELECT jdate_part('timezone', jdate '1403-05-15')$$, '0A000'),
('jdate_part timezone_hour',
 $$SELECT jdate_part('timezone_hour', jdate '1403-05-15')$$, '0A000'),
('jdate_part timezone_minute',
 $$SELECT jdate_part('timezone_minute', jdate '1403-05-15')$$, '0A000'),
('extract week',
 $$SELECT extract('week' FROM jdate '1403-05-15')$$, '0A000'),
('jdate_trunc decade',
 $$SELECT jdate_trunc('decade', jdate '1403-05-15')$$, '0A000'),
('jdate_trunc hour',
 $$SELECT jdate_trunc('hour', jdate '1403-05-15')$$, '0A000'),
('ALTER EXTENSION SET SCHEMA (not relocatable)',
 $$ALTER EXTENSION jdate SET SCHEMA sqlstate_other$$, '0A000'),

-- 42883: an operator or function the type does not define
('jdate = date',
 $$SELECT jdate '1403-05-15' = date '2024-08-05'$$, '42883'),
('jdate + jdate',
 $$SELECT jdate '1403-05-15' + jdate '1403-05-16'$$, '42883'),
('jdate + bigint',
 $$SELECT jdate '1403-05-15' + 1::bigint$$, '42883'),
('date_part(text, jdate)',
 $$SELECT date_part('year', jdate '1403-05-15')$$, '42883'),

-- 22008: core's own error for subtracting an infinite date
('infinity - jdate',
 $$SELECT jdate 'infinity' - jdate '1403-01-01'$$, '22008'),
('jdate - infinity',
 $$SELECT jdate '1403-01-01' - jdate '-infinity'$$, '22008'),

-- sanity rows for the input and range errors (asserted in detail elsewhere)
('input: syntax error',
 $$SELECT 'garbage'::jdate$$, '22007'),
('input: month 13',
 $$SELECT '1403-13-01'::jdate$$, '22008'),
('input: year above range',
 $$SELECT '3178-01-01'::jdate$$, '22008'),
('input: year below range',
 $$SELECT '-0062-12-29'::jdate$$, '22008'),
('arithmetic: past the last day',
 $$SELECT jdate '3177-12-29' + 1$$, '22008'),
('arithmetic: before the first day',
 $$SELECT jdate '-0061-01-01' - 1$$, '22008'),
('jdate_trunc week: start before the first day',
 $$SELECT jdate_trunc('week', jdate '-0061-01-02')$$, '22008');

-- jtimestamp and jtimestamptz, one row per entry of the SQLSTATE table of the
-- design (the same code for both types). 22007: not a Jalali Y-M-D prefix, a
-- second date, allballs; 22008: invalid Jalali date, a time field out of
-- range, a value outside the range, BC, rounding past the edge, a cast or
-- to_jtimestamptz result outside it; 22009: a zone displacement beyond
-- +/-15:59:59; 22023: an unknown zone. Then spellings that must succeed.
INSERT INTO cases (label, stmt, expected)
SELECT t.typ || ': ' || e.label, format(e.stmt, t.typ), e.expected
FROM (VALUES ('jtimestamp'), ('jtimestamptz')) AS t(typ),
(VALUES
  -- 22007: invalid_datetime_format
  ('no Y-M-D prefix (garbage)',          $$SELECT 'garbage'::%s$$, '22007'),
  ('no Y-M-D prefix (empty)',            $$SELECT ''::%s$$, '22007'),
  ('no Y-M-D prefix (time only)',        $$SELECT '12:00:00'::%s$$, '22007'),
  ('no Y-M-D prefix (Gregorian words)',  $$SELECT 'March 20, 2024 12:00'::%s$$, '22007'),
  ('no Y-M-D prefix (special word with a prefix)', $$SELECT 'epoch 12:00'::%s$$, '22007'),
  ('duplicate date',                     $$SELECT '1403-05-15 1403-05-16'::%s$$, '22007'),
  ('allballs without a date',            $$SELECT 'allballs'::%s$$, '22007'),
  ('trailing junk after the date',       $$SELECT '1403-05-15x 10:00'::%s$$, '22007'),
  -- 22008: datetime_field_overflow
  ('month 13',                           $$SELECT '1403-13-01 10:00'::%s$$, '22008'),
  ('1404-12-30 (not a leap year)',       $$SELECT '1404-12-30 10:00'::%s$$, '22008'),
  ('1403-07-31 (month 7 has 30 days)',   $$SELECT '1403-07-31 10:00'::%s$$, '22008'),
  ('hour 25',                            $$SELECT '1403-05-15 25:00'::%s$$, '22008'),
  ('minute 60',                          $$SELECT '1403-05-15 10:60'::%s$$, '22008'),
  ('BC token',                           $$SELECT '1403-05-15 10:00 BC'::%s$$, '22008'),
  ('year above the range',               $$SELECT '3178-01-01 00:00:00'::%s$$, '22008'),
  ('year below the range',               $$SELECT '-0062-12-29 00:00:00'::%s$$, '22008'),
  ('year overflowing int32',             $$SELECT '99999999999-01-01 10:00'::%s$$, '22008'),
  ('24:00:00 of the last day',           $$SELECT '3177-12-29 24:00:00'::%s$$, '22008'),
  ('1403-05-15 24:00:00 is the next day (must succeed)', $$SELECT '1403-05-15 24:00:00'::%s$$, 'ok'),
  -- 22009: invalid_time_zone_displacement_value
  ('zone displacement +16:00',           $$SELECT '1403-05-15 10:00+16:00'::%s$$, '22009'),
  ('zone displacement -16:00',           $$SELECT '1403-05-15 10:00-16:00'::%s$$, '22009'),
  ('zone displacement +15:59:59 (must succeed)', $$SELECT '1403-05-15 10:00+15:59:59'::%s$$, 'ok'),
  -- 22023: invalid_parameter_value
  ('unknown zone name',                  $$SELECT '1403-05-15 10:00 Mars/Olympus'::%s$$, '22023'),
  -- spellings that must succeed
  ('plain value',                        $$SELECT '1403-05-15 10:00'::%s$$, 'ok'),
  ('date only',                          $$SELECT '1403-05-15'::%s$$, 'ok'),
  ('first valid day',                    $$SELECT '-0061-01-01 16:00:00+00'::%s$$, 'ok'),
  ('last valid instant of jtimestamptz',  $$SELECT '3177-12-29 07:59:59.999999+00'::%s$$, 'ok'),
  ('fraction beyond 6 digits is rounded', $$SELECT '1403-05-15 10:00:00.123456789'::%s$$, 'ok'),
  ('named zone',                         $$SELECT '1403-05-15 10:00 America/New_York'::%s$$, 'ok'),
  ('offset with minutes',                $$SELECT '1403-05-15 10:00+03:30'::%s$$, 'ok'),
  ('AM/PM',                              $$SELECT '1403-05-15 10:00 PM'::%s$$, 'ok'),
  ('infinity',                           $$SELECT 'infinity'::%s$$, 'ok'),
  ('-infinity',                          $$SELECT '-infinity'::%s$$, 'ok'),
  ('epoch',                              $$SELECT 'epoch'::%s$$, 'ok'),
  ('now',                                $$SELECT 'now'::%s$$, 'ok'),
  ('today',                              $$SELECT 'today'::%s$$, 'ok'),
  ('typmod (3) rounds within the range', $$SELECT '1403-05-15 10:00:00.1234'::%s(3)$$, 'ok')
) AS e(label, stmt, expected);

-- 22008 from the casts, typmod rounding and to_jtimestamptz (not from input)
INSERT INTO cases (label, stmt, expected) VALUES
('jtimestamp: last valid microsecond (must succeed)',
 $$SELECT '3177-12-29 23:59:59.999999'::jtimestamp$$, 'ok'),
('jtimestamptz: the same clock time is above the safe range',
 $$SELECT '3177-12-29 23:59:59.999999+00'::jtimestamptz$$, '22008'),
('jtimestamp: typmod (0) rounds past the last edge',
 $$SELECT '3177-12-29 23:59:59.999999'::jtimestamp(0)$$, '22008'),
('jtimestamptz: typmod (0) rounds past the last instant',
 $$SELECT '3177-12-29 07:59:59.999999+00'::jtimestamptz(0)$$, '22008'),
('timestamp -> jtimestamp: below the first',
 $$SELECT timestamp '0560-03-19 23:59:59.999999'::jtimestamp$$, '22008'),
('timestamp -> jtimestamp: above the last',
 $$SELECT timestamp '3799-03-20 00:00:00'::jtimestamp$$, '22008'),
('date -> jtimestamp: above the last',
 $$SELECT date '3799-03-20'::jtimestamp$$, '22008'),
('timestamptz -> jtimestamptz: below the first instant',
 $$SELECT timestamptz '0560-03-20 15:59:59.999999+00'::jtimestamptz$$, '22008'),
('timestamptz -> jtimestamptz: above the last instant',
 $$SELECT timestamptz '3799-03-19 08:00:00+00'::jtimestamptz$$, '22008'),
('jdate -> jtimestamptz: first day (local midnight is below the safe range)',
 $$SELECT jdate '-0061-01-01'::jtimestamptz$$, '22008'),
('jtimestamp -> jtimestamptz: end of the last day',
 $$SELECT jtimestamp '3177-12-29 23:59:59.999999'::jtimestamptz$$, '22008'),
('to_jtimestamptz: NaN',
 $$SELECT to_jtimestamptz('NaN'::float8)$$, '22008'),
('to_jtimestamptz: epoch of the first Jalali day start (below the safe range)',
 $$SELECT to_jtimestamptz(-44488483200)$$, '22008'),
('to_jtimestamptz: first valid second (must succeed)',
 $$SELECT to_jtimestamptz(-44488425600)$$, 'ok'),
('to_jtimestamptz: infinity (must succeed)',
 $$SELECT to_jtimestamptz('infinity'::float8)$$, 'ok');

SELECT label,
       pg_temp.state(stmt) AS sqlstate,
       pg_temp.state(stmt) = expected AS as_expected
FROM cases
ORDER BY n;

-- Any row that did not give its expected code (none)
SELECT label, expected, pg_temp.state(stmt) AS got
FROM cases
WHERE pg_temp.state(stmt) IS DISTINCT FROM expected
ORDER BY n;

-- The failed ALTER EXTENSION left the extension where it was
SELECT extname, extnamespace::regnamespace AS schema
FROM pg_extension WHERE extname = 'jdate';

DROP SCHEMA sqlstate_other;
