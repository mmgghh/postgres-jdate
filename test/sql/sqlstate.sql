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
('jdate_trunc week',
 $$SELECT jdate_trunc('week', jdate '1403-05-15')$$, '0A000'),
('jdate_trunc hour',
 $$SELECT jdate_trunc('hour', jdate '1403-05-15')$$, '0A000'),
('ALTER EXTENSION SET SCHEMA (not relocatable)',
 $$ALTER EXTENSION jdate SET SCHEMA sqlstate_other$$, '0A000'),

-- 42883: an operator or function the type does not define
('jdate = date',
 $$SELECT jdate '1403-05-15' = date '2024-08-05'$$, '42883'),
('jdate + interval',
 $$SELECT jdate '1403-05-15' + interval '1 day'$$, '42883'),
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
 $$SELECT jdate '-0061-01-01' - 1$$, '22008');

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
