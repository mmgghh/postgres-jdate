-- Binary send/receive of jtimestamp and jtimestamptz. Both types use core's
-- wire format (a big-endian int64 of microseconds since 2000-01-01 00:00:00,
-- the same as timestamp and timestamptz), so core's types can build binary
-- input that recv has to validate: core accepts far more instants than the
-- Jalali range holds, and a stored out-of-range value could never be shown
-- again. The binary files live under test/results/ (the harness runs from the
-- repository root). There are no comparison operators on the new types yet,
-- so values are compared as text and as their send bytes.
--
-- The tables created here are dropped at the end: extension_schema runs
-- DROP EXTENSION, which needs no column of our types left behind.
SET DateStyle = 'ISO, YMD';
SET timezone = 'UTC';

-- ---------------------------------------------------------------------
-- send: the wire bytes are exactly the core type's for the same value
-- ---------------------------------------------------------------------
CREATE TABLE jt_bin_vals (id int PRIMARY KEY, ts jtimestamp, tz jtimestamptz,
                          tsa jtimestamp[], tza jtimestamptz[]);
INSERT INTO jt_bin_vals (id, ts, tz) VALUES
  (1, '1403-01-01 00:00:00',            '1403-01-01 00:00:00+00'),
  (2, '-0061-01-01 00:00:00',           '-0061-01-01 16:00:00+00'),
  (3, '3177-12-29 23:59:59.999999',     '3177-12-29 07:59:59.999999+00'),
  (4, '1378-10-11 00:00:00',            '1378-10-11 00:00:00+00'),
  (5, '1378-10-12 00:00:00',            '1378-10-12 00:00:00+00'),
  (6, '1378-10-10 23:59:59.999999',     '1378-10-10 23:59:59.999999+00'),
  (7, 'epoch',                          'epoch'),
  (8, '1403-05-15 10:00:00.123456',     '1403-05-15 10:00:00.123456+03:30'),
  (9, 'infinity',                       'infinity'),
  (10, '-infinity',                     '-infinity'),
  (11, NULL, NULL);
UPDATE jt_bin_vals
SET tsa = ARRAY[ts, NULL, 'infinity'::jtimestamp, '1403-01-01 00:00:00'::jtimestamp],
    tza = ARRAY[tz, NULL, '-infinity'::jtimestamptz, '1403-01-01 00:00:00+00'::jtimestamptz];

-- 1378-10-11 is 2000-01-01 (wire value 0), the next day is 86400000000
-- microseconds (0x141dd76000), the last microsecond of the day before is -1
SELECT id, encode(jtimestamp_send(ts), 'hex') AS ts_wire,
       encode(jtimestamptz_send(tz), 'hex') AS tz_wire
FROM jt_bin_vals WHERE id IN (1, 2, 3, 4, 5, 6, 9, 10) ORDER BY id;

-- the same bytes as core's send for the same value, and as the value computed
-- from core's epoch arithmetic (microseconds since 2000-01-01, as int8)
SELECT count(*) AS finite_rows,
       count(*) FILTER (WHERE jtimestamp_send(ts) <> timestamp_send(ts::timestamp)) AS ts_differs_from_core,
       count(*) FILTER (WHERE jtimestamptz_send(tz) <> timestamptz_send(tz::timestamptz)) AS tz_differs_from_core,
       count(*) FILTER (WHERE jtimestamp_send(ts)
             <> int8send(round((extract(epoch FROM ts::timestamp) - 946684800) * 1000000)::bigint)) AS ts_differs_from_epoch,
       count(*) FILTER (WHERE jtimestamptz_send(tz)
             <> int8send(round((extract(epoch FROM tz::timestamptz) - 946684800) * 1000000)::bigint)) AS tz_differs_from_epoch
FROM jt_bin_vals WHERE ts IS NOT NULL AND ts::text NOT IN ('infinity', '-infinity');
-- infinities are core's int64 limits
SELECT jtimestamp_send('infinity') = timestamp_send('infinity') AS ts_inf_as_core,
       jtimestamp_send('-infinity') = timestamp_send('-infinity') AS ts_ninf_as_core,
       jtimestamptz_send('infinity') = timestamptz_send('infinity') AS tz_inf_as_core,
       jtimestamptz_send('-infinity') = timestamptz_send('-infinity') AS tz_ninf_as_core;

-- ---------------------------------------------------------------------
-- COPY (FORMAT binary) round trip of both types, with arrays and NULLs
-- ---------------------------------------------------------------------
\copy jt_bin_vals TO 'test/results/jt_binary_vals.bin' WITH (FORMAT binary)
CREATE TABLE jt_bin_back (id int, ts jtimestamp, tz jtimestamptz,
                          tsa jtimestamp[], tza jtimestamptz[]);
\copy jt_bin_back FROM 'test/results/jt_binary_vals.bin' WITH (FORMAT binary)
SELECT a.id, a.ts, a.tz
FROM jt_bin_back a ORDER BY a.id;
SELECT count(*) AS rows_back,
       count(*) FILTER (WHERE a.ts::text IS DISTINCT FROM b.ts::text
                           OR jtimestamp_send(a.ts) IS DISTINCT FROM jtimestamp_send(b.ts)) AS ts_violations,
       count(*) FILTER (WHERE a.tz::text IS DISTINCT FROM b.tz::text
                           OR jtimestamptz_send(a.tz) IS DISTINCT FROM jtimestamptz_send(b.tz)) AS tz_violations,
       count(*) FILTER (WHERE a.tsa::text IS DISTINCT FROM b.tsa::text) AS tsa_violations,
       count(*) FILTER (WHERE a.tza::text IS DISTINCT FROM b.tza::text) AS tza_violations
FROM jt_bin_vals a JOIN jt_bin_back b USING (id);
-- the round trip does not depend on the session zone (jtimestamptz is an instant)
SET timezone = 'Asia/Tehran';
SELECT count(*) FILTER (WHERE jtimestamptz_send(a.tz) IS DISTINCT FROM jtimestamptz_send(b.tz)
                           OR a.tz::text IS DISTINCT FROM b.tz::text) AS tz_violations_in_tehran
FROM jt_bin_vals a JOIN jt_bin_back b USING (id);
SET timezone = 'UTC';

-- the same values written without the arrays and read as core's types give
-- the same values (jtimestamp -> timestamp and jtimestamptz -> timestamptz
-- are free casts)
\copy (SELECT id, ts, tz FROM jt_bin_vals) TO 'test/results/jt_binary_plain.bin' WITH (FORMAT binary)
CREATE TABLE jt_bin_core (id int, ts timestamp, tz timestamptz);
\copy jt_bin_core FROM 'test/results/jt_binary_plain.bin' WITH (FORMAT binary)
SELECT count(*) AS rows_as_core,
       count(*) FILTER (WHERE a.ts::timestamp IS DISTINCT FROM c.ts) AS ts_violations,
       count(*) FILTER (WHERE a.tz::timestamptz IS DISTINCT FROM c.tz) AS tz_violations
FROM jt_bin_vals a JOIN jt_bin_core c USING (id);

-- ---------------------------------------------------------------------
-- recv: an instant outside the range must be rejected with 22008 and load
-- nothing. The files are built byte by byte from microsecond counts (the
-- COPY BINARY header, one tuple with one 8-byte field per value, the
-- trailer), so the values do not pass through a core type's range checks.
-- The count of microseconds since 2000-01-01 comes from core's epoch
-- arithmetic on a Gregorian timestamp.
-- ---------------------------------------------------------------------
CREATE FUNCTION pg_temp.us(t text) RETURNS bigint LANGUAGE sql AS
$$ SELECT round((extract(epoch FROM t::timestamp) - 946684800) * 1000000)::bigint $$;

CREATE FUNCTION pg_temp.wire(VARIADIC us bigint[]) RETURNS bytea LANGUAGE sql AS
$$ SELECT decode('5047434f50590aff0d0a00' || '00000000' || '00000000', 'hex')
       || coalesce((SELECT string_agg(decode('0001' || '00000008', 'hex') || int8send(u), ''::bytea ORDER BY ord)
                    FROM unnest(us) WITH ORDINALITY AS x(u, ord)), ''::bytea)
       || '\xffff'::bytea $$;

CREATE TABLE jt_bin_ts (ts jtimestamp);
CREATE TABLE jt_bin_tz (tz jtimestamptz);
CREATE TABLE jt_bin_ts0 (ts jtimestamp(0));
CREATE TABLE jt_bin_tz0 (tz jtimestamptz(0));

-- the builder works: the edge values and both infinities of each type load.
-- jtimestamptz stops 16 hours inside the range at both ends.
SELECT lo_from_bytea(0, pg_temp.wire(pg_temp.us('0560-03-20 00:00:00'),
                                     pg_temp.us('3799-03-19 23:59:59.999999'),
                                     9223372036854775807, -9223372036854775807 - 1)) AS loid \gset
\lo_export :loid 'test/results/jt_binary_good.bin'
SELECT lo_unlink(:loid) AS unlinked;
\copy jt_bin_ts FROM 'test/results/jt_binary_good.bin' WITH (FORMAT binary)
SELECT ts FROM jt_bin_ts ORDER BY ts::text COLLATE "C";

SELECT lo_from_bytea(0, pg_temp.wire(pg_temp.us('0560-03-20 16:00:00'),
                                     pg_temp.us('3799-03-19 07:59:59.999999'),
                                     9223372036854775807, -9223372036854775807 - 1)) AS loid \gset
\lo_export :loid 'test/results/jt_binary_good.bin'
SELECT lo_unlink(:loid) AS unlinked;
\copy jt_bin_tz FROM 'test/results/jt_binary_good.bin' WITH (FORMAT binary)
SELECT tz FROM jt_bin_tz ORDER BY tz::text COLLATE "C";

-- jtimestamp: one value outside the range per file, 22008 each
\set VERBOSITY sqlstate
-- 1 us below the first instant (-0061-01-01 is 0560-03-20)
SELECT lo_from_bytea(0, pg_temp.wire(pg_temp.us('0560-03-19 23:59:59.999999'))) AS loid \gset
\lo_export :loid 'test/results/jt_binary_bad.bin'
SELECT lo_unlink(:loid) AS unlinked;
\copy jt_bin_ts FROM 'test/results/jt_binary_bad.bin' WITH (FORMAT binary)
-- 1 us above the last instant (3177-12-29 is 3799-03-19)
SELECT lo_from_bytea(0, pg_temp.wire(pg_temp.us('3799-03-20 00:00:00'))) AS loid \gset
\lo_export :loid 'test/results/jt_binary_bad.bin'
SELECT lo_unlink(:loid) AS unlinked;
\copy jt_bin_ts FROM 'test/results/jt_binary_bad.bin' WITH (FORMAT binary)
-- far outside, up to core's own limits
SELECT lo_from_bytea(0, pg_temp.wire(pg_temp.us('9999-12-31 00:00:00'))) AS loid \gset
\lo_export :loid 'test/results/jt_binary_bad.bin'
SELECT lo_unlink(:loid) AS unlinked;
\copy jt_bin_ts FROM 'test/results/jt_binary_bad.bin' WITH (FORMAT binary)
SELECT lo_from_bytea(0, pg_temp.wire(pg_temp.us('4714-11-24 00:00:00 BC'))) AS loid \gset
\lo_export :loid 'test/results/jt_binary_bad.bin'
SELECT lo_unlink(:loid) AS unlinked;
\copy jt_bin_ts FROM 'test/results/jt_binary_bad.bin' WITH (FORMAT binary)
-- not an instant at all for core either: the largest and smallest int8
-- next to the infinities
SELECT lo_from_bytea(0, pg_temp.wire(9223372036854775806)) AS loid \gset
\lo_export :loid 'test/results/jt_binary_bad.bin'
SELECT lo_unlink(:loid) AS unlinked;
\copy jt_bin_ts FROM 'test/results/jt_binary_bad.bin' WITH (FORMAT binary)
SELECT lo_from_bytea(0, pg_temp.wire(-9223372036854775807)) AS loid \gset
\lo_export :loid 'test/results/jt_binary_bad.bin'
SELECT lo_unlink(:loid) AS unlinked;
\copy jt_bin_ts FROM 'test/results/jt_binary_bad.bin' WITH (FORMAT binary)
-- a bad value among good ones fails the whole COPY
SELECT lo_from_bytea(0, pg_temp.wire(pg_temp.us('2024-03-20 00:00:00'),
                                     pg_temp.us('9999-12-31 00:00:00'),
                                     pg_temp.us('2025-03-21 00:00:00'))) AS loid \gset
\lo_export :loid 'test/results/jt_binary_bad.bin'
SELECT lo_unlink(:loid) AS unlinked;
\copy jt_bin_ts FROM 'test/results/jt_binary_bad.bin' WITH (FORMAT binary)
\set VERBOSITY default
-- still the four rows of the good file
SELECT count(*) AS ts_rows_after_failures FROM jt_bin_ts;

-- jtimestamptz: the same, around the safe range
\set VERBOSITY sqlstate
-- 1 us below the first safe instant
SELECT lo_from_bytea(0, pg_temp.wire(pg_temp.us('0560-03-20 15:59:59.999999'))) AS loid \gset
\lo_export :loid 'test/results/jt_binary_bad.bin'
SELECT lo_unlink(:loid) AS unlinked;
\copy jt_bin_tz FROM 'test/results/jt_binary_bad.bin' WITH (FORMAT binary)
-- 1 us above the last safe instant
SELECT lo_from_bytea(0, pg_temp.wire(pg_temp.us('3799-03-19 08:00:00'))) AS loid \gset
\lo_export :loid 'test/results/jt_binary_bad.bin'
SELECT lo_unlink(:loid) AS unlinked;
\copy jt_bin_tz FROM 'test/results/jt_binary_bad.bin' WITH (FORMAT binary)
-- inside the Jalali range but outside the safe range: the first and last
-- microsecond of the range itself
SELECT lo_from_bytea(0, pg_temp.wire(pg_temp.us('0560-03-20 00:00:00'))) AS loid \gset
\lo_export :loid 'test/results/jt_binary_bad.bin'
SELECT lo_unlink(:loid) AS unlinked;
\copy jt_bin_tz FROM 'test/results/jt_binary_bad.bin' WITH (FORMAT binary)
SELECT lo_from_bytea(0, pg_temp.wire(pg_temp.us('3799-03-19 23:59:59.999999'))) AS loid \gset
\lo_export :loid 'test/results/jt_binary_bad.bin'
SELECT lo_unlink(:loid) AS unlinked;
\copy jt_bin_tz FROM 'test/results/jt_binary_bad.bin' WITH (FORMAT binary)
-- far outside
SELECT lo_from_bytea(0, pg_temp.wire(pg_temp.us('9999-12-31 00:00:00'))) AS loid \gset
\lo_export :loid 'test/results/jt_binary_bad.bin'
SELECT lo_unlink(:loid) AS unlinked;
\copy jt_bin_tz FROM 'test/results/jt_binary_bad.bin' WITH (FORMAT binary)
SELECT lo_from_bytea(0, pg_temp.wire(9223372036854775806)) AS loid \gset
\lo_export :loid 'test/results/jt_binary_bad.bin'
SELECT lo_unlink(:loid) AS unlinked;
\copy jt_bin_tz FROM 'test/results/jt_binary_bad.bin' WITH (FORMAT binary)
-- a bad value among good ones fails the whole COPY
SELECT lo_from_bytea(0, pg_temp.wire(pg_temp.us('2024-03-20 00:00:00'),
                                     pg_temp.us('0560-03-20 15:59:59.999999'),
                                     pg_temp.us('2025-03-21 00:00:00'))) AS loid \gset
\lo_export :loid 'test/results/jt_binary_bad.bin'
SELECT lo_unlink(:loid) AS unlinked;
\copy jt_bin_tz FROM 'test/results/jt_binary_bad.bin' WITH (FORMAT binary)
\set VERBOSITY default
SELECT count(*) AS tz_rows_after_failures FROM jt_bin_tz;

-- the same range violations written by core: a table of core's types holds
-- them, a COPY BINARY of it is read as the new types (two columns per row)
CREATE TABLE jt_bin_src (ts timestamp, tz timestamptz);
CREATE TABLE jt_bin_pair (ts jtimestamp, tz jtimestamptz);
\set VERBOSITY sqlstate
INSERT INTO jt_bin_src VALUES ('0560-03-19 23:59:59.999999', '2024-03-20 00:00:00+00');
\copy jt_bin_src TO 'test/results/jt_binary_bad.bin' WITH (FORMAT binary)
\copy jt_bin_pair FROM 'test/results/jt_binary_bad.bin' WITH (FORMAT binary)
TRUNCATE jt_bin_src;
INSERT INTO jt_bin_src VALUES ('2024-03-20 00:00:00', '0560-03-20 15:59:59.999999+00');
\copy jt_bin_src TO 'test/results/jt_binary_bad.bin' WITH (FORMAT binary)
\copy jt_bin_pair FROM 'test/results/jt_binary_bad.bin' WITH (FORMAT binary)
TRUNCATE jt_bin_src;
INSERT INTO jt_bin_src VALUES ('2024-03-20 00:00:00', '3799-03-19 08:00:00+00');
\copy jt_bin_src TO 'test/results/jt_binary_bad.bin' WITH (FORMAT binary)
\copy jt_bin_pair FROM 'test/results/jt_binary_bad.bin' WITH (FORMAT binary)
\set VERBOSITY default
SELECT count(*) AS pair_rows_after_failures FROM jt_bin_pair;
-- both columns on their first valid values load
TRUNCATE jt_bin_src;
INSERT INTO jt_bin_src VALUES ('0560-03-20 00:00:00', '0560-03-20 16:00:00+00'),
                              ('3799-03-19 23:59:59.999999', '3799-03-19 07:59:59.999999+00');
\copy jt_bin_src TO 'test/results/jt_binary_good.bin' WITH (FORMAT binary)
\copy jt_bin_pair FROM 'test/results/jt_binary_good.bin' WITH (FORMAT binary)
SELECT ts, tz FROM jt_bin_pair ORDER BY ts::text COLLATE "C";
DROP TABLE jt_bin_src, jt_bin_pair;

-- typmod on receive: the value is rounded first, then checked. 23:59:59.999999
-- of the last day rounds into the next day (out of range), .4 rounds down.
\set VERBOSITY sqlstate
SELECT lo_from_bytea(0, pg_temp.wire(pg_temp.us('3799-03-19 23:59:59.999999'))) AS loid \gset
\lo_export :loid 'test/results/jt_binary_bad.bin'
SELECT lo_unlink(:loid) AS unlinked;
\copy jt_bin_ts0 FROM 'test/results/jt_binary_bad.bin' WITH (FORMAT binary)
SELECT lo_from_bytea(0, pg_temp.wire(pg_temp.us('3799-03-19 07:59:59.999999'))) AS loid \gset
\lo_export :loid 'test/results/jt_binary_bad.bin'
SELECT lo_unlink(:loid) AS unlinked;
\copy jt_bin_tz0 FROM 'test/results/jt_binary_bad.bin' WITH (FORMAT binary)
\set VERBOSITY default
SELECT lo_from_bytea(0, pg_temp.wire(pg_temp.us('3799-03-19 23:59:59.4'),
                                     pg_temp.us('0560-03-20 00:00:00.4'))) AS loid \gset
\lo_export :loid 'test/results/jt_binary_good.bin'
SELECT lo_unlink(:loid) AS unlinked;
\copy jt_bin_ts0 FROM 'test/results/jt_binary_good.bin' WITH (FORMAT binary)
SELECT ts FROM jt_bin_ts0 ORDER BY ts::text COLLATE "C";
SELECT lo_from_bytea(0, pg_temp.wire(pg_temp.us('3799-03-19 07:59:59.4'),
                                     pg_temp.us('0560-03-20 16:00:00.4'),
                                     pg_temp.us('0560-03-20 15:59:59.6'))) AS loid \gset
\lo_export :loid 'test/results/jt_binary_good.bin'
SELECT lo_unlink(:loid) AS unlinked;
\copy jt_bin_tz0 FROM 'test/results/jt_binary_good.bin' WITH (FORMAT binary)
SELECT tz FROM jt_bin_tz0 ORDER BY tz::text COLLATE "C";

-- the file written by the round trip above loads a second time into a fresh
-- table (the same shape, so the array element type OIDs match)
CREATE TABLE jt_bin_again (id int, ts jtimestamp, tz jtimestamptz, tsa jtimestamp[], tza jtimestamptz[]);
\copy jt_bin_again FROM 'test/results/jt_binary_vals.bin' WITH (FORMAT binary)
SELECT count(*) AS rows_again FROM jt_bin_again;

DROP TABLE jt_bin_vals, jt_bin_back, jt_bin_core, jt_bin_ts, jt_bin_tz,
           jt_bin_ts0, jt_bin_tz0, jt_bin_again;
