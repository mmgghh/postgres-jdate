-- jtimestamp and jtimestamptz report bad input softly (through an
-- ErrorSaveContext, with our type name and core's SQLSTATE), so
-- pg_input_is_valid, pg_input_error_info, array input and COPY ... ON_ERROR
-- ignore can handle it instead of aborting the statement. Modelled on
-- softerr.sql; only SQLSTATEs are printed, never message text.
--
-- Version note: pg_input_is_valid/pg_input_error_info need PostgreSQL 16+,
-- but COPY ... (ON_ERROR ignore) needs PostgreSQL 17+, so the COPY half of
-- this file does not run on 16 (softerr_1.out is the alternate for softerr;
-- jt_softerr would need the same). Whether core's timestamp_in and
-- timestamptz_in report all their errors softly on 16 has not been verified:
-- the first CI run on 16 decides whether a jt_softerr_1.out is needed.
--
-- The table created here is dropped at the end: extension_schema runs
-- DROP EXTENSION, which needs no column of our types left behind.
SET DateStyle = 'ISO, YMD';
SET timezone = 'UTC';

-- ---------------------------------------------------------------------
-- pg_input_is_valid and the SQLSTATE of pg_input_error_info, for the same
-- inputs under both types. sqlstate is NULL for a good input.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE soft_in (n int, kind text, v text);
INSERT INTO soft_in VALUES
  (1,  'good',            '1403-05-15 10:00:00'),
  (2,  'good',            '1403-05-15'),
  (3,  'good, fraction',  '1403-05-15 10:00:00.123456'),
  (4,  'good, offset',    '1403-05-15 10:00:00+03:30'),
  (5,  'good, 24:00:00',  '1403-05-15 24:00:00'),
  (6,  'good, first',     '-0061-01-01 16:00:00+00'),
  (7,  'good, last',      '3177-12-29 07:59:59.999999+00'),
  (8,  'infinity',        'infinity'),
  (9,  '-infinity',       '-infinity'),
  (10, 'epoch',           'epoch'),
  (11, 'syntax',          'garbage'),
  (12, 'syntax, empty',   ''),
  (13, 'syntax, time only', '12:00:00'),
  (14, 'syntax, Gregorian words', 'March 20, 2024 12:00'),
  (15, 'syntax, duplicate date', '1403-05-15 1403-05-16'),
  (16, 'month',           '1403-13-01 10:00:00'),
  (17, 'day (not a leap year)', '1404-12-30 10:00:00'),
  (18, 'day (month 7)',   '1403-07-31 10:00:00'),
  (19, 'range, above',    '3178-01-01 00:00:00'),
  (20, 'range, below',    '-0062-12-29 00:00:00'),
  (21, 'range, last day end (above for jtimestamptz)', '3177-12-29 23:59:59.999999+00'),
  (22, 'range, BC',       '1403-05-15 10:00:00 BC'),
  (23, 'overflow',        '99999999999-01-01 10:00:00'),
  (24, 'time field, hour 25', '1403-05-15 25:00:00'),
  (25, 'time field, minute 60', '1403-05-15 10:60:00'),
  (26, 'time field, second 61', '1403-05-15 10:00:61'),
  (27, 'zone, unknown',   '1403-05-15 10:00:00 Mars/Olympus'),
  (28, 'zone, displacement +16:00', '1403-05-15 10:00:00+16:00'),
  (29, 'zone, displacement -16:00', '1403-05-15 10:00:00-16:00');

SELECT s.n, s.kind, t.typ,
       pg_input_is_valid(s.v, t.typ) AS valid,
       (SELECT e.sql_error_code FROM pg_input_error_info(s.v, t.typ) e) AS sqlstate
FROM soft_in s CROSS JOIN (VALUES ('jtimestamp'), ('jtimestamptz')) AS t(typ)
ORDER BY s.n, t.typ;

-- the input function with a typmod: rounding happens before the range check
SELECT t.typ, s.kind, pg_input_is_valid(s.v, t.typ || '(0)') AS valid,
       (SELECT e.sql_error_code FROM pg_input_error_info(s.v, t.typ || '(0)') e) AS sqlstate
FROM (VALUES
  (1, 'jtimestamp',   'last microsecond rounds up past the end', '3177-12-29 23:59:59.999999'),
  (2, 'jtimestamp',   'last second, .4 rounds down',             '3177-12-29 23:59:59.4'),
  (3, 'jtimestamptz', 'last microsecond rounds up past the end', '3177-12-29 07:59:59.999999+00'),
  (4, 'jtimestamptz', 'last second, .4 rounds down',             '3177-12-29 07:59:59.4+00')
) AS s(n, typ, kind, v)
JOIN (VALUES ('jtimestamp'), ('jtimestamptz')) AS t(typ) USING (typ)
ORDER BY s.n;

-- array input: one bad element makes the whole literal invalid
SELECT t.typ, a.kind,
       pg_input_is_valid(a.v, t.typ || '[]') AS valid,
       (SELECT e.sql_error_code FROM pg_input_error_info(a.v, t.typ || '[]') e) AS sqlstate
FROM (VALUES
  (1, 'good',              '{"1403-01-01 10:00:00","1403-12-29 23:59:59"}'),
  (2, 'good, with NULL',   '{"1403-01-01 10:00:00",NULL}'),
  (3, 'good, infinity',    '{infinity,-infinity}'),
  (4, 'bad element',       '{"1403-01-01 10:00:00",x}'),
  (5, 'range element',     '{"1403-01-01 10:00:00","3178-01-01 00:00:00"}'),
  (6, 'month element',     '{"1403-13-01 10:00:00"}'),
  (7, 'time-field element', '{"1403-05-15 25:00:00"}'),
  (8, 'zone element',      '{"1403-05-15 10:00:00 Mars/Olympus"}'),
  (9, 'displacement element', '{"1403-05-15 10:00:00+16:00"}')
) AS a(n, kind, v)
CROSS JOIN (VALUES ('jtimestamp'), ('jtimestamptz')) AS t(typ)
ORDER BY a.n, t.typ;

-- the same array literal gives an array when it is valid
SELECT '{"1403-01-01 10:00:00",NULL,infinity}'::jtimestamp[] AS ts_array,
       '{"1403-01-01 10:00:00+03:30",NULL,-infinity}'::jtimestamptz[] AS tz_array;

-- hard errors still raise, with the same SQLSTATEs
\set VERBOSITY sqlstate
SELECT 'garbage'::jtimestamp;
SELECT 'garbage'::jtimestamptz;
SELECT '1403-13-01 10:00:00'::jtimestamp;
SELECT '1403-13-01 10:00:00'::jtimestamptz;
SELECT '3178-01-01 00:00:00'::jtimestamp;
SELECT '3178-01-01 00:00:00+00'::jtimestamptz;
SELECT '1403-05-15 25:00:00'::jtimestamp;
SELECT '1403-05-15 25:00:00'::jtimestamptz;
SELECT '1403-05-15 10:00:00 Mars/Olympus'::jtimestamp;
SELECT '1403-05-15 10:00:00 Mars/Olympus'::jtimestamptz;
SELECT '1403-05-15 10:00:00+16:00'::jtimestamptz;
SELECT '{"1403-01-01 10:00:00",x}'::jtimestamp[];
SELECT '{"1403-01-01 10:00:00+00","3178-01-01 00:00:00+00"}'::jtimestamptz[];
\set VERBOSITY default

-- ---------------------------------------------------------------------
-- COPY ... ON_ERROR ignore skips bad rows and loads the good ones. Row 1,
-- 7 and 9 are good; the others each fail in one column.
-- ---------------------------------------------------------------------
CREATE TABLE jt_softerr_t (id int, ts jtimestamp, tz jtimestamptz);
COPY jt_softerr_t FROM STDIN (ON_ERROR ignore);
1	1403-01-01 10:00:00	1403-01-01 10:00:00+03:30
2	garbage	1403-01-01 10:00:00+00
3	1403-12-29 23:59:59	3178-01-01 00:00:00+00
4	1403-13-01 10:00:00	1403-01-01 10:00:00+00
5	1403-05-15 25:00:00	1403-05-15 10:00:00+00
6	1403-05-15 10:00:00	1403-05-15 10:00:00 Mars/Olympus
7	infinity	-infinity
8	3178-01-01 00:00:00	1403-05-15 10:00:00+16:00
9	1403-05-15 10:00:00.5	1403-05-15 10:00:00.5+00
\.
SELECT id, ts, tz FROM jt_softerr_t ORDER BY id;

-- a typmod column rounds in the input function, so a value that rounds out
-- of the range is skipped and one that rounds into it loads
CREATE TABLE jt_softerr_p (id int, ts jtimestamp(0), tz jtimestamptz(0));
COPY jt_softerr_p FROM STDIN (ON_ERROR ignore);
1	3177-12-29 23:59:59.4	3177-12-29 07:59:59.4+00
2	3177-12-29 23:59:59.999999	3177-12-29 07:59:59.4+00
3	3177-12-29 23:59:59.4	3177-12-29 07:59:59.999999+00
4	-0061-01-01 00:00:00.4	-0061-01-01 15:59:59.6+00
\.
SELECT id, ts, tz FROM jt_softerr_p ORDER BY id;

-- the default, ON_ERROR stop, still aborts on the first bad row (one run
-- with the bad value in each column) and keeps the earlier rows out
TRUNCATE jt_softerr_t;
\set VERBOSITY sqlstate
COPY jt_softerr_t FROM STDIN (ON_ERROR stop);
1	1403-01-01 10:00:00	1403-01-01 10:00:00+00
2	garbage	1403-01-01 10:00:00+00
3	1403-12-29 23:59:59	1403-12-29 23:59:59+00
\.
COPY jt_softerr_t FROM STDIN (ON_ERROR stop);
1	1403-01-01 10:00:00	1403-01-01 10:00:00+00
2	1403-01-02 10:00:00	3178-01-01 00:00:00+00
3	1403-12-29 23:59:59	1403-12-29 23:59:59+00
\.
COPY jt_softerr_t FROM STDIN;
1	1403-01-01 10:00:00	1403-01-01 10:00:00+00
2	1403-01-02 10:00:00	1403-01-02 10:00:00+16:00
\.
\set VERBOSITY default
SELECT count(*) AS rows_after_stop FROM jt_softerr_t;

DROP TABLE jt_softerr_t, jt_softerr_p;
