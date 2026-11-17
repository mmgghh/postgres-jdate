-- jtimestamp: text and binary I/O, typmod, special words, error classes.
-- Errors are shown as SQLSTATE only (\set VERBOSITY sqlstate), never as
-- message text, which core words differently between major versions.
SET DateStyle = 'ISO, YMD';
SET timezone = 'UTC';

-- ---------------------------------------------------------------------
-- valid input and output
-- ---------------------------------------------------------------------
SELECT '1403-01-01 00:00:00'::jtimestamp;
SELECT '1403-01-01'::jtimestamp AS date_only_is_midnight;
SELECT '1403-12-29 23:59:59'::jtimestamp;
SELECT '1395-12-30 12:00:00'::jtimestamp AS leap_day;
-- both ends of the Jalali range
SELECT '-0061-01-01 00:00:00'::jtimestamp AS first_valid;
SELECT '3177-12-29 23:59:59.999999'::jtimestamp AS last_valid;
SELECT '0001-01-01 00:00:00'::jtimestamp, '0000-12-30 00:00:00'::jtimestamp;
-- fractional seconds: microseconds, trailing zeros dropped, rounded past six
SELECT '1403-05-15 12:34:56.5'::jtimestamp;
SELECT '1403-05-15 12:34:56.123456'::jtimestamp;
SELECT '1403-05-15 12:34:56.123456789'::jtimestamp AS rounds_up;
SELECT '1403-05-15 12:34:56.1234564'::jtimestamp AS rounds_down;
SELECT '1403-05-15 12:34:56.000001'::jtimestamp;
-- separators and time notations core accepts
SELECT '1403-05-15T12:34:56'::jtimestamp AS t_separator;
SELECT '1403-05-15T12:34'::jtimestamp AS no_seconds;
SELECT '1403-05-15 24:00:00'::jtimestamp AS twenty_four_is_next_day;
SELECT '1403-12-29 24:00:00'::jtimestamp AS twenty_four_crosses_the_year;
SELECT '1403-05-15 12:00 AM'::jtimestamp, '1403-05-15 12:00 PM'::jtimestamp,
       '1403-05-15 11:59:59 PM'::jtimestamp, '1403-05-15 1:05 am'::jtimestamp;
SELECT '1403-05-15 12:34:56 AD'::jtimestamp AS ad_is_harmless;
-- the same leniency as jdate_in: signs and whitespace around the date, trailing space
SELECT ' 1403-05-15 12:34:56'::jtimestamp AS leading_space;
SELECT '+1403-05-15 12:34:56'::jtimestamp AS signed_year;
SELECT '1403-+05-+15 12:34:56'::jtimestamp AS signed_fields;
SELECT '1403 - 05 - 15 12:34:56'::jtimestamp AS spaced_dashes;
SELECT '1403-05-15 12:34:56  '::jtimestamp AS trailing_space;
SELECT '1403-05-15 '::jtimestamp AS date_and_trailing_space;
SELECT '0000000000000001403-05-15 12:00'::jtimestamp AS leading_zeros;
-- a time zone in the text of a timestamp without time zone is ignored, as in core
SELECT '1403-05-15 12:34:56+05'::jtimestamp AS zone_ignored;
SELECT '1403-05-15 12:34:56 America/New_York'::jtimestamp AS zone_name_ignored;

-- every output is the same text again on input
SELECT s, s::jtimestamp::text = s AS round_trips
FROM (VALUES ('-0061-01-01 00:00:00'), ('3177-12-29 23:59:59.999999'),
             ('1403-01-01 00:00:00'), ('1402-12-29 23:59:59.000001'),
             ('1395-12-30 12:00:00.5'), ('infinity'), ('-infinity')) v(s);

-- ---------------------------------------------------------------------
-- special words: an exact, case-insensitive list, core's values
-- ---------------------------------------------------------------------
SELECT 'infinity'::jtimestamp, '-infinity'::jtimestamp;
SELECT 'INFINITY'::jtimestamp, '-Infinity'::jtimestamp;
-- epoch is 1970-01-01 00:00:00, which is 1348-10-11 in the Jalali calendar
SELECT 'epoch'::jtimestamp, 'EPOCH'::jtimestamp;
-- now, today, tomorrow and yesterday follow the clock and the session zone,
-- like core's timestamp: compare with jdate_format of the same statement's now()
SELECT 'now'::jtimestamp::text = jdate_format(now(), true) AS now_matches;
SELECT 'today'::jtimestamp::text = jdate_format(now(), false) || ' 00:00:00' AS today_matches;
SELECT 'tomorrow'::jtimestamp::text
       = jdate_format(now() + interval '1 day', false) || ' 00:00:00' AS tomorrow_matches;
SELECT 'yesterday'::jtimestamp::text
       = jdate_format(now() - interval '1 day', false) || ' 00:00:00' AS yesterday_matches;
SELECT 'NOW'::jtimestamp::text = jdate_format(now(), true) AS now_uppercase;
SET timezone = 'Pacific/Kiritimati';
SELECT 'now'::jtimestamp::text = jdate_format(now(), true) AS now_matches_in_kiritimati;
SELECT 'today'::jtimestamp::text = jdate_format(now(), false) || ' 00:00:00' AS today_matches_in_kiritimati;
SET timezone = 'UTC';

-- ---------------------------------------------------------------------
-- errors
-- ---------------------------------------------------------------------
\set VERBOSITY sqlstate
-- 22007: no Jalali date, and not one of the special words
SELECT 'allballs'::jtimestamp;                 -- a time-only word in core
SELECT 'March 20, 2024 12:00'::jtimestamp;     -- a Gregorian spelling
SELECT '20240320'::jtimestamp;
SELECT '12:00:00'::jtimestamp;
SELECT 'garbage'::jtimestamp;
SELECT ''::jtimestamp;
SELECT ' now'::jtimestamp;                     -- the words are matched exactly
SELECT 'now '::jtimestamp;
SELECT 'nowhere'::jtimestamp;
SELECT '1403-05'::jtimestamp;
SELECT '1403/05/15 12:00'::jtimestamp;
-- 22007: a date and then junk, a second date field
SELECT '1403-05-15x'::jtimestamp;
SELECT '1403-05-15-05'::jtimestamp;
SELECT '1403-05-15 12:00 1403-05-16'::jtimestamp;
SELECT '1403-05-15 12:00 2024-03-21'::jtimestamp;
-- 22008: an invalid Jalali date, a time field out of range
SELECT '1403-13-01 12:00'::jtimestamp;
SELECT '1403-00-01 12:00'::jtimestamp;
SELECT '1403-01-32 12:00'::jtimestamp;
SELECT '1404-12-30 12:00'::jtimestamp;         -- 1404 is a common year
SELECT '1403-07-31 12:00'::jtimestamp;         -- Mehr has 30 days
SELECT '4294968699-01-01 12:00'::jtimestamp;   -- year 2^32 + 1403, an int32 overflow
SELECT '1403-01-01 25:00'::jtimestamp;
SELECT '1403-01-01 24:00:01'::jtimestamp;
SELECT '1403-01-01 12:60'::jtimestamp;
SELECT '1403-05-15 12:61:00'::jtimestamp;
-- 22008: outside the Jalali range
SELECT '-0062-12-29 23:59:59.999999'::jtimestamp;
SELECT '3178-01-01 00:00:00'::jtimestamp;
-- 22008: a BC token puts the date before the range
SELECT '1403-01-01 12:00 BC'::jtimestamp;
-- 22023 and 22009: the zone is parsed by core even though it is ignored
SELECT '1403-01-01 12:00 Nowhere/Zone'::jtimestamp;
SELECT '1403-01-01 12:00 +17:00'::jtimestamp;
\set VERBOSITY default
-- the message names our type, and for a rejected date, the text as typed
SELECT '1403-13-01 12:00'::jtimestamp;
SELECT 'March 20, 2024 12:00'::jtimestamp;
SELECT '1403-01-01 25:00'::jtimestamp;

-- ---------------------------------------------------------------------
-- soft errors: pg_input_is_valid and pg_input_error_info (SQLSTATE only)
-- ---------------------------------------------------------------------
SELECT pg_input_is_valid('1403-05-15 12:00', 'jtimestamp') AS valid,
       pg_input_is_valid('epoch', 'jtimestamp') AS valid_epoch,
       pg_input_is_valid('allballs', 'jtimestamp') AS allballs,
       pg_input_is_valid('1403-13-01 12:00', 'jtimestamp') AS bad_date,
       pg_input_is_valid('1403-01-01 25:00', 'jtimestamp') AS bad_time,
       pg_input_is_valid('3178-01-01', 'jtimestamp') AS above_range,
       pg_input_is_valid('1403-01-01 12:00 BC', 'jtimestamp') AS bc;
SELECT s, (pg_input_error_info(s, 'jtimestamp')).sql_error_code AS sqlstate
FROM (VALUES ('garbage'), ('1403-05-15 12:00 1403-05-16'), ('1403-13-01 12:00'),
             ('1403-01-01 25:00'), ('3178-01-01 00:00'), ('1403-01-01 12:00 BC'),
             ('1403-01-01 12:00 Nowhere/Zone'), ('1403-01-01 12:00 +17:00')) v(s);
SELECT pg_input_is_valid('{"1403-01-01 12:00","1403-12-29 23:59:59"}', 'jtimestamp[]') AS good_array,
       pg_input_is_valid('{"1403-01-01 12:00","1403-01-01 25:00"}', 'jtimestamp[]') AS bad_element,
       pg_input_is_valid('{"1403-01-01 12:00","3178-01-01 00:00"}', 'jtimestamp[]') AS range_element;

-- ---------------------------------------------------------------------
-- typmod: jtimestamp(p), p = 0..6. The input function applies it (COPY, array
-- input, pg_input_is_valid, a direct call); the scale cast that a cast or an
-- INSERT of a non-literal goes through comes with the other casts.
-- ---------------------------------------------------------------------
SELECT format_type('jtimestamp'::regtype, NULL) AS no_typmod,
       format_type('jtimestamp'::regtype, 0) AS p0,
       format_type('jtimestamp'::regtype, 3) AS p3,
       format_type('jtimestamp'::regtype, 6) AS p6;
SELECT to_regtype('jtimestamp(3)') = 'jtimestamp'::regtype AS typmod_is_not_part_of_the_oid;
-- (7) is clamped to 6 with core's WARNING; (-1) and two modifiers are refused
\set VERBOSITY sqlstate
SELECT '1403-01-01 12:00:00'::jtimestamp(7);
SET client_min_messages = error;
CREATE TABLE jt_io_p7 (c jtimestamp(7));
RESET client_min_messages;
SELECT atttypmod, format_type(atttypid, atttypmod) AS type
FROM pg_attribute WHERE attrelid = 'jt_io_p7'::regclass AND attname = 'c';
SELECT '1403-01-01 12:00:00'::jtimestamp(-1);
SELECT '1403-01-01 12:00:00'::jtimestamp(1, 2);
\set VERBOSITY default
-- a column with a typmod, in the catalog and loaded through the input function
CREATE TABLE jt_io_typmod (p0 jtimestamp(0), p3 jtimestamp(3), p6 jtimestamp(6), pn jtimestamp);
SELECT attname, format_type(atttypid, atttypmod) AS type, atttypmod
FROM pg_attribute WHERE attrelid = 'jt_io_typmod'::regclass AND attnum > 0 ORDER BY attnum;
COPY jt_io_typmod FROM STDIN;
1403-01-01 12:00:00.5	1403-01-01 12:00:00.1236	1403-01-01 12:00:00.1234567	1403-01-01 12:00:00.1234567
1403-01-01 12:00:00.4	1403-01-01 12:00:00.1234	1403-01-01 12:00:00.1234564	1403-01-01 12:00:00.9999999
1402-12-29 23:59:59.5	1402-12-29 23:59:59.9996	1402-12-29 23:59:59.9999996	1402-12-29 23:59:59.9999996
\.
SELECT * FROM jt_io_typmod;
-- rounding to the typmod can carry past the last valid microsecond: 22008
\set VERBOSITY sqlstate
SELECT pg_input_is_valid('3177-12-29 23:59:59.4', 'jtimestamp(0)') AS rounds_down_stays_valid,
       pg_input_is_valid('3177-12-29 23:59:59.5', 'jtimestamp(0)') AS rounds_up_out_of_range,
       pg_input_is_valid('3177-12-29 23:59:59.9996', 'jtimestamp(3)') AS rounds_up_p3,
       pg_input_is_valid('3177-12-29 23:59:59.999999', 'jtimestamp(6)') AS p6_stays_valid;
SELECT (pg_input_error_info('3177-12-29 23:59:59.5', 'jtimestamp(0)')).sql_error_code AS sqlstate;
CREATE TABLE jt_io_edge (p0 jtimestamp(0));
COPY jt_io_edge FROM STDIN;
3177-12-29 23:59:59.5
\.
SELECT count(*) AS rows_after_rounding_past_the_edge FROM jt_io_edge;
\set VERBOSITY default

-- ---------------------------------------------------------------------
-- DateStyle does not change the text, in or out
-- ---------------------------------------------------------------------
DO $do$
DECLARE s text;
BEGIN
  FOREACH s IN ARRAY ARRAY['ISO, YMD', 'ISO, DMY', 'ISO, MDY', 'SQL, DMY', 'SQL, MDY',
                           'German', 'Postgres, DMY', 'Postgres, MDY']
  LOOP
    PERFORM set_config('DateStyle', s, false);
    RAISE INFO '%: % and %', s, '1403-05-02 12:34:56.5'::jtimestamp,
               '1403-02-05 01:02:03'::jtimestamp;
  END LOOP;
  PERFORM set_config('DateStyle', 'ISO, YMD', false);
END
$do$;
SET DateStyle = 'German';
SELECT '1403-05-02 12:34:56'::jtimestamp, '1403-02-05 01:02:03'::jtimestamp;
SET DateStyle = 'Postgres, MDY';
SELECT '1403-05-02 12:34:56'::jtimestamp, '1403-02-05 01:02:03'::jtimestamp;
SET DateStyle = 'SQL, DMY';
SELECT '1403-05-02 12:34:56'::jtimestamp, 'infinity'::jtimestamp;
SET DateStyle = 'ISO, YMD';

-- ---------------------------------------------------------------------
-- arrays
-- ---------------------------------------------------------------------
SELECT ARRAY['1403-01-01 10:00', '1403-12-29 23:59:59.5']::jtimestamp[] AS arr;
SELECT '{"1403-01-01 10:00:00", NULL, "1403-12-29T23:59:59.5", infinity}'::jtimestamp[] AS arr_literal;
SELECT ('{"1403-01-01 10:00:00","1403-12-29 23:59:59.5"}'::jtimestamp[])[2] AS second_element;
SELECT array_length('{"1403-01-01 10:00:00","1403-12-29 23:59:59.5"}'::jtimestamp[], 1) AS len;
SELECT pg_typeof(ARRAY['1403-01-01 10:00']::jtimestamp[]) AS array_type;
\set VERBOSITY sqlstate
SELECT '{"1403-01-01 10:00:00","3178-01-01 00:00:00"}'::jtimestamp[];
SELECT '{"1403-01-01 10:00:00","garbage"}'::jtimestamp[];
\set VERBOSITY default

-- ---------------------------------------------------------------------
-- the type in the catalog
-- ---------------------------------------------------------------------
SELECT typname, typlen, typbyval, typalign, typstorage, typcategory, typispreferred,
       typtype, typdelim, typinput::regproc AS input, typoutput::regproc AS output,
       typreceive::regproc AS receive, typsend::regproc AS send,
       typmodin::regproc AS typmodin, typmodout::regproc AS typmodout,
       typarray::regtype AS array_type
FROM pg_type WHERE typname = 'jtimestamp';
-- the same layout as core's timestamp, apart from the OIDs and function names
SELECT a.typlen = b.typlen AND a.typbyval = b.typbyval AND a.typalign = b.typalign
       AND a.typstorage = b.typstorage AND a.typcategory = b.typcategory AS same_layout_as_timestamp,
       a.typispreferred AS jtimestamp_preferred, b.typispreferred AS timestamp_preferred
FROM pg_type a, pg_type b WHERE a.typname = 'jtimestamp' AND b.typname = 'timestamp';
SELECT typname, typelem::regtype AS element_type FROM pg_type WHERE typname = '_jtimestamp';
-- volatility: input STABLE (now, today, ...), the rest IMMUTABLE; all strict and parallel safe
SELECT proname, provolatile, proisstrict, proparallel, prorettype::regtype AS returns
FROM pg_proc
WHERE proname IN ('jtimestamp_in', 'jtimestamp_out', 'jtimestamp_recv', 'jtimestamp_send',
                  'jtimestamp_typmodout')
ORDER BY proname;
-- which makes a text to jtimestamp cast unusable in an index, and jtimestamp to text usable
CREATE TABLE jt_io_idx (s text, j jtimestamp);
\set VERBOSITY sqlstate
CREATE INDEX jt_io_idx_from_text ON jt_io_idx ((s::jtimestamp));
\set VERBOSITY default
CREATE INDEX jt_io_idx_to_text ON jt_io_idx ((j::text));
SELECT count(*) AS index_to_text_exists FROM pg_indexes WHERE indexname = 'jt_io_idx_to_text';
SELECT count(*) AS index_from_text_exists FROM pg_indexes WHERE indexname = 'jt_io_idx_from_text';
SELECT obj_description('jtimestamp'::regtype, 'pg_type') IS NOT NULL AS has_comment;

-- ---------------------------------------------------------------------
-- binary: send is core's timestamp wire format, recv checks the Jalali range
-- ---------------------------------------------------------------------
CREATE TABLE jt_io_vals (t jtimestamp);
INSERT INTO jt_io_vals VALUES
    ('1403-01-01 00:00:00'), ('-0061-01-01 00:00:00'), ('3177-12-29 23:59:59.999999'),
    ('1348-10-11 00:00:00'), ('infinity'), ('-infinity');
-- the same eight bytes as core's timestamp of the Gregorian date
SELECT j, g, encode(jtimestamp_send(j::jtimestamp), 'hex') AS wire,
       jtimestamp_send(j::jtimestamp) = timestamp_send(g::timestamp) AS same_as_timestamp
FROM (VALUES ('1403-01-01 00:00:00', '2024-03-20 00:00:00'),
             ('-0061-01-01 00:00:00', '0560-03-20 00:00:00'),
             ('3177-12-29 23:59:59.999999', '3799-03-19 23:59:59.999999'),
             ('1348-10-11 00:00:00', '1970-01-01 00:00:00')) v(j, g)
ORDER BY j COLLATE "C";
SELECT t, encode(jtimestamp_send(t), 'hex') AS wire,
       jtimestamp_send(t) = timestamp_send(g::timestamp) AS same_as_timestamp
FROM jt_io_vals JOIN (VALUES ('infinity', 'infinity'), ('-infinity', '-infinity')) v(j, g)
  ON t::text = j
ORDER BY t::text COLLATE "C";
\copy jt_io_vals TO 'test/results/jt_io_vals.bin' WITH (FORMAT binary)
CREATE TABLE jt_io_back (t jtimestamp);
\copy jt_io_back FROM 'test/results/jt_io_vals.bin' WITH (FORMAT binary)
SELECT t FROM jt_io_back ORDER BY t::text COLLATE "C";
SELECT (SELECT array_agg(t::text ORDER BY t::text COLLATE "C") FROM jt_io_vals)
     = (SELECT array_agg(t::text ORDER BY t::text COLLATE "C") FROM jt_io_back) AS roundtrip_equal;
-- recv: a timestamp that core accepts but the Jalali range does not (22008, nothing loaded)
CREATE TABLE jt_io_core (t timestamp);
CREATE TABLE jt_io_target (t jtimestamp);
CREATE TABLE jt_io_target0 (t jtimestamp(0));
\set VERBOSITY sqlstate
-- one microsecond below the first valid instant (-0061-01-01 is 0560-03-20)
INSERT INTO jt_io_core VALUES ('0560-03-19 23:59:59.999999');
\copy jt_io_core TO 'test/results/jt_io_bad.bin' WITH (FORMAT binary)
\copy jt_io_target FROM 'test/results/jt_io_bad.bin' WITH (FORMAT binary)
SELECT count(*) AS rows_after_below_min FROM jt_io_target;
-- the first instant after the last valid one (3177-12-29 is 3799-03-19)
TRUNCATE jt_io_core;
INSERT INTO jt_io_core VALUES ('3799-03-20 00:00:00');
\copy jt_io_core TO 'test/results/jt_io_bad.bin' WITH (FORMAT binary)
\copy jt_io_target FROM 'test/results/jt_io_bad.bin' WITH (FORMAT binary)
SELECT count(*) AS rows_after_above_max FROM jt_io_target;
-- far outside core's own range is core's error, also 22008
TRUNCATE jt_io_core;
INSERT INTO jt_io_core VALUES ('0001-01-01 00:00:00 BC');
\copy jt_io_core TO 'test/results/jt_io_bad.bin' WITH (FORMAT binary)
\copy jt_io_target FROM 'test/results/jt_io_bad.bin' WITH (FORMAT binary)
SELECT count(*) AS rows_after_bc FROM jt_io_target;
-- the typmod of the column is applied on receive, and the check comes after it
TRUNCATE jt_io_core;
INSERT INTO jt_io_core VALUES ('3799-03-19 23:59:59.5');
\copy jt_io_core TO 'test/results/jt_io_bad.bin' WITH (FORMAT binary)
\copy jt_io_target0 FROM 'test/results/jt_io_bad.bin' WITH (FORMAT binary)
SELECT count(*) AS rows_after_rounding_past_the_edge FROM jt_io_target0;
\copy jt_io_target FROM 'test/results/jt_io_bad.bin' WITH (FORMAT binary)
SELECT t FROM jt_io_target;
\set VERBOSITY default

-- ---------------------------------------------------------------------
-- clean up: extension_schema drops the extension, which needs no column of
-- its types left behind
-- ---------------------------------------------------------------------
DROP TABLE jt_io_typmod, jt_io_edge, jt_io_p7, jt_io_idx, jt_io_vals, jt_io_back,
           jt_io_core, jt_io_target, jt_io_target0;
