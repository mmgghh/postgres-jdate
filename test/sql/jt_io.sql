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

-- =====================================================================
-- jtimestamptz: the same I/O for a timestamp with time zone. The text is
-- always printed in the session zone with a numeric offset, so every block
-- sets timezone explicitly. The valid range is the safe range (the Jalali
-- range shrunk by 16 hours at both ends), checked on the UTC instant.
-- =====================================================================
SET DateStyle = 'ISO, YMD';
SET timezone = 'UTC';

-- ---------------------------------------------------------------------
-- valid input and output
-- ---------------------------------------------------------------------
SELECT '1403-01-01 00:00:00'::jtimestamptz AS no_zone_is_session_zone;
SELECT '1403-01-01'::jtimestamptz AS date_only_is_midnight;
SELECT '1395-12-30 12:00:00'::jtimestamptz AS leap_day;
-- offsets in the text: hours, hours:minutes, with seconds, Z, names, abbreviations
SELECT '1403-01-01 12:00:00+03:30'::jtimestamptz AS hh_mm;
SELECT '1403-01-01 12:00:00+03'::jtimestamptz AS hh;
SELECT '1403-01-01 12:00:00-03:30'::jtimestamptz AS negative;
SELECT '1403-01-01 12:00:00+03:30:15'::jtimestamptz AS with_seconds;
SELECT '1403-01-01T12:00:00Z'::jtimestamptz AS z_suffix, '1403-01-01 12:00:00 z'::jtimestamptz AS lower_z;
SELECT '1403-01-01 12:00 Asia/Tehran'::jtimestamptz AS zone_name;
SELECT '1403-01-01 12:00 America/New_York'::jtimestamptz AS zone_name_with_dst;
SELECT '1403-06-01 12:00 America/New_York'::jtimestamptz AS zone_name_without_dst;
SELECT '1403-01-01 12:00 EST'::jtimestamptz AS abbreviation;
SELECT '1403-01-01 12:00 UTC'::jtimestamptz AS utc_name;
SELECT '1403-01-01 12:00:00 +15:59:59'::jtimestamptz AS largest_offset;
SELECT '1403-01-01 12:00:00 -15:59:59'::jtimestamptz AS largest_negative_offset;
-- the same instant, written four ways
SELECT s, s::jtimestamptz AS instant
FROM (VALUES ('1403-01-01 12:00:00+00'), ('1403-01-01 15:30:00+03:30'),
             ('1403-01-01 07:00:00-05'), ('1403-01-01 12:00:00 Z')) v(s);
-- fractional seconds, separators and time notations core accepts
SELECT '1403-05-15 12:34:56.123456+00'::jtimestamptz;
SELECT '1403-05-15 12:34:56.123456789+00'::jtimestamptz AS rounds_up;
SELECT '1403-05-15 12:34:56.5'::jtimestamptz AS half_second;
SELECT '1403-05-15T12:34'::jtimestamptz AS t_separator_no_seconds;
SELECT '1403-05-15 24:00:00'::jtimestamptz AS twenty_four_is_next_day;
SELECT '1403-12-29 24:00:00'::jtimestamptz AS twenty_four_crosses_the_year;
SELECT '1403-05-15 12:00 AM'::jtimestamptz, '1403-05-15 12:00 PM'::jtimestamptz,
       '1403-05-15 11:59:59 PM'::jtimestamptz;
SELECT '1403-05-15 12:34:56 AD'::jtimestamptz AS ad_is_harmless;
-- the same leniency as jdate_in
SELECT ' 1403-05-15 12:34:56'::jtimestamptz AS leading_space;
SELECT '+1403-05-15 12:34:56'::jtimestamptz AS signed_year;
SELECT '1403 - 05 - 15 12:34:56'::jtimestamptz AS spaced_dashes;
SELECT '1403-05-15 12:34:56  '::jtimestamptz AS trailing_space;
SELECT '0000000000000001403-05-15 12:00'::jtimestamptz AS leading_zeros;

-- no zone in the text: the session zone is used, so the instant differs
SET timezone = 'Asia/Tehran';
SELECT '1403-01-01 00:00:00'::jtimestamptz AS tehran_midnight;
SET timezone = 'UTC';
SELECT '1403-01-01 00:00:00'::jtimestamptz AS utc_midnight;

-- every output is the same text again on input, in the same session zone
SELECT s, s::jtimestamptz::text = s AS round_trips
FROM (VALUES ('-0061-01-01 16:00:00+00'), ('3177-12-29 07:59:59.999999+00'),
             ('1403-01-01 00:00:00+00'), ('1402-12-29 23:59:59.000001+00'),
             ('1395-12-30 12:00:00.5+00'), ('infinity'), ('-infinity')) v(s);
SET timezone = 'Asia/Tehran';
SELECT s, s::jtimestamptz::text = s AS round_trips
FROM (VALUES ('1403-01-01 12:00:00+03:30'), ('1348-10-11 03:30:00+03:30'),
             ('1200-01-01 00:00:00+03:25:44')) v(s);
SET timezone = 'UTC';

-- ---------------------------------------------------------------------
-- output: the instant in the session zone, numeric offset +HH, +HH:MM, +HH:MM:SS
-- ---------------------------------------------------------------------
-- 1403-01-01 12:00 UTC, as seen in different zones
SET timezone = 'UTC';
SELECT '1403-01-01 12:00:00+00'::jtimestamptz AS utc;
SET timezone = 'Asia/Tehran';
SELECT '1403-01-01 12:00:00+00'::jtimestamptz AS tehran;
SET timezone = 'Asia/Kolkata';
SELECT '1403-01-01 12:00:00+00'::jtimestamptz AS kolkata;
SET timezone = 'Asia/Kathmandu';
SELECT '1403-01-01 12:00:00+00'::jtimestamptz AS kathmandu;
SET timezone = 'America/New_York';
SELECT '1403-01-01 12:00:00+00'::jtimestamptz AS new_york;
SET timezone = 'Pacific/Kiritimati';
SELECT '1403-01-01 12:00:00+00'::jtimestamptz AS kiritimati_plus_14;
SET timezone = 'Pacific/Pago_Pago';
SELECT '1403-01-01 12:00:00+00'::jtimestamptz AS pago_pago_minus_11;
SET timezone = 'UTC';
-- the local date can differ from the UTC one, in either direction
SET timezone = 'Pacific/Kiritimati';
SELECT '1403-12-29 23:00:00+00'::jtimestamptz AS next_day_locally;
SET timezone = 'Pacific/Pago_Pago';
SELECT '1403-01-01 02:00:00+00'::jtimestamptz AS previous_day_locally;
SET timezone = 'UTC';
-- the same instant prints differently, and reads back as the same instant
SET timezone = 'UTC';
SELECT '1403-01-01 12:00:00+00'::jtimestamptz::text AS in_utc \gset
SET timezone = 'Asia/Tehran';
SELECT '1403-01-01 12:00:00+00'::jtimestamptz::text AS in_tehran \gset
SELECT :'in_utc' AS in_utc, :'in_tehran' AS in_tehran,
       :'in_tehran'::jtimestamptz::text = :'in_tehran' AS tehran_text_reads_back,
       :'in_utc'::jtimestamptz::text = :'in_tehran' AS same_instant_in_both;
SET timezone = 'UTC';
SELECT :'in_tehran'::jtimestamptz::text AS tehran_text_in_utc;

-- epoch is 1970-01-01 00:00:00 UTC, which is 1348-10-11 in the Jalali calendar
SELECT 'epoch'::jtimestamptz AS epoch_utc;
SET timezone = 'Asia/Tehran';
SELECT 'epoch'::jtimestamptz AS epoch_tehran;
SELECT 'EPOCH'::jtimestamptz AS epoch_uppercase;
SET timezone = 'America/New_York';
SELECT 'epoch'::jtimestamptz AS epoch_new_york_previous_day;
SET timezone = 'UTC';
SELECT 'infinity'::jtimestamptz, '-infinity'::jtimestamptz, 'INFINITY'::jtimestamptz, '-Infinity'::jtimestamptz;

-- historic offsets: a zone's local mean time, with seconds
SET timezone = 'Asia/Manila';
SELECT '1222-03-10 12:00:00+00'::jtimestamptz AS manila_in_1843;
SET timezone = 'Asia/Tehran';
SELECT '0579-03-11 12:00:00+00'::jtimestamptz AS tehran_in_1200_ad;
SET timezone = 'UTC';

-- now, today, tomorrow and yesterday follow the clock and the session zone
SELECT left('now'::jtimestamptz::text, 10) = jdate_format(now(), false) AS now_date_matches;
SELECT 'today'::jtimestamptz::text = jdate_format(now(), false) || ' 00:00:00+00' AS today_matches;
SELECT 'tomorrow'::jtimestamptz::text
       = jdate_format(now() + interval '1 day', false) || ' 00:00:00+00' AS tomorrow_matches;
SELECT 'yesterday'::jtimestamptz::text
       = jdate_format(now() - interval '1 day', false) || ' 00:00:00+00' AS yesterday_matches;
SELECT 'NOW'::jtimestamptz::text = 'now'::jtimestamptz::text AS now_uppercase;
SET timezone = 'Pacific/Kiritimati';
SELECT 'today'::jtimestamptz::text = jdate_format(now(), false) || ' 00:00:00+14' AS today_matches_in_kiritimati;
SELECT left('now'::jtimestamptz::text, 10) = jdate_format(now(), false) AS now_date_matches_in_kiritimati;
SET timezone = 'UTC';

-- ---------------------------------------------------------------------
-- errors
-- ---------------------------------------------------------------------
\set VERBOSITY sqlstate
-- 22007: no Jalali date, and not one of the special words
SELECT 'allballs'::jtimestamptz;
SELECT 'March 20, 2024 12:00+00'::jtimestamptz;
SELECT '20240320'::jtimestamptz;
SELECT '12:00:00+03:30'::jtimestamptz;
SELECT 'garbage'::jtimestamptz;
SELECT ''::jtimestamptz;
SELECT ' now'::jtimestamptz;
SELECT 'now '::jtimestamptz;
SELECT 'nowhere'::jtimestamptz;
SELECT '1403-05'::jtimestamptz;
SELECT '1403-05-15x'::jtimestamptz;
SELECT '1403-05-15 12:00+00 1403-05-16'::jtimestamptz;
SELECT '1403-05-15 12:00+00 2024-03-21'::jtimestamptz;
-- 22008: an invalid Jalali date, a time field out of range
SELECT '1403-13-01 12:00'::jtimestamptz;
SELECT '1404-12-30 12:00'::jtimestamptz;
SELECT '1403-07-31 12:00'::jtimestamptz;
SELECT '4294968699-01-01 12:00'::jtimestamptz;
SELECT '1403-01-01 25:00'::jtimestamptz;
SELECT '1403-01-01 12:60+00'::jtimestamptz;
-- 22008: outside the range, also with a zone that would move it inside
SELECT '-0062-12-29 23:59:59.999999+00'::jtimestamptz;
SELECT '3178-01-01 00:00:00+00'::jtimestamptz;
SELECT '-0061-01-01 00:00:00+00'::jtimestamptz;   -- inside the Jalali range, not the safe range
SELECT '3177-12-29 23:59:59+00'::jtimestamptz;
SELECT '-0061-01-01 00:00:00+15:59'::jtimestamptz;
SELECT '1403-01-01 12:00 BC'::jtimestamptz;
-- 22009: a zone offset out of range; 22023: an unknown zone
SELECT '1403-01-01 12:00:00+16:00'::jtimestamptz;
SELECT '1403-01-01 12:00:00-16:00'::jtimestamptz;
SELECT '1403-01-01 12:00:00+17:00'::jtimestamptz;
SELECT '1403-01-01 12:00 Nowhere/Zone'::jtimestamptz;
\set VERBOSITY default
-- the message names our type
SELECT '1403-13-01 12:00'::jtimestamptz;
SELECT 'March 20, 2024 12:00+00'::jtimestamptz;
SELECT '1403-01-01 25:00'::jtimestamptz;
SELECT '1403-01-01 12:00 Nowhere/Zone'::jtimestamptz;

-- ---------------------------------------------------------------------
-- soft errors: pg_input_is_valid and pg_input_error_info (SQLSTATE only)
-- ---------------------------------------------------------------------
SELECT pg_input_is_valid('1403-05-15 12:00+03:30', 'jtimestamptz') AS valid,
       pg_input_is_valid('1403-05-15 12:00 +15:59:59', 'jtimestamptz') AS largest_offset,
       pg_input_is_valid('epoch', 'jtimestamptz') AS valid_epoch,
       pg_input_is_valid('allballs', 'jtimestamptz') AS allballs,
       pg_input_is_valid('1403-13-01 12:00', 'jtimestamptz') AS bad_date,
       pg_input_is_valid('1403-01-01 25:00', 'jtimestamptz') AS bad_time,
       pg_input_is_valid('3178-01-01', 'jtimestamptz') AS above_range,
       pg_input_is_valid('-0061-01-01 00:00:00+00', 'jtimestamptz') AS below_safe_range,
       pg_input_is_valid('1403-01-01 12:00 BC', 'jtimestamptz') AS bc;
SELECT s, (pg_input_error_info(s, 'jtimestamptz')).sql_error_code AS sqlstate
FROM (VALUES ('garbage'), ('1403-05-15 12:00+00 1403-05-16'), ('1403-13-01 12:00'),
             ('1403-01-01 25:00'), ('3178-01-01 00:00+00'), ('-0061-01-01 15:59:59.999999+00'),
             ('1403-01-01 12:00 BC'), ('1403-01-01 12:00 Nowhere/Zone'),
             ('1403-01-01 12:00+16:00'), ('1403-01-01 12:00+15:59:59')) v(s);
SELECT pg_input_is_valid('{"1403-01-01 12:00+03:30","1403-12-29 23:59:59Z"}', 'jtimestamptz[]') AS good_array,
       pg_input_is_valid('{"1403-01-01 12:00+03:30","1403-01-01 25:00"}', 'jtimestamptz[]') AS bad_element,
       pg_input_is_valid('{"1403-01-01 12:00+03:30","3178-01-01 00:00+00"}', 'jtimestamptz[]') AS range_element;

-- ---------------------------------------------------------------------
-- the range: first and last valid instant, and one microsecond beyond each,
-- under UTC and under the zones 15:59 east and west of Greenwich. The range
-- is checked on the instant, so a zone does not move it; what changes is
-- the local text that spells the instant.
-- ---------------------------------------------------------------------
-- UTC: the first valid instant is 16 hours into the first day
SET timezone = 'UTC';
SELECT '-0061-01-01 16:00:00+00'::jtimestamptz AS first_valid;
SELECT '3177-12-29 07:59:59.999999+00'::jtimestamptz AS last_valid;
SELECT pg_input_is_valid('-0061-01-01 15:59:59.999999+00', 'jtimestamptz') AS one_microsecond_before_first,
       pg_input_is_valid('-0061-01-01 16:00:00+00', 'jtimestamptz') AS first,
       pg_input_is_valid('3177-12-29 07:59:59.999999+00', 'jtimestamptz') AS last,
       pg_input_is_valid('3177-12-29 08:00:00+00', 'jtimestamptz') AS one_microsecond_after_last;
SELECT (pg_input_error_info('-0061-01-01 15:59:59.999999+00', 'jtimestamptz')).sql_error_code AS below_sqlstate,
       (pg_input_error_info('3177-12-29 08:00:00+00', 'jtimestamptz')).sql_error_code AS above_sqlstate;
\set VERBOSITY sqlstate
SELECT '-0061-01-01 15:59:59.999999+00'::jtimestamptz;
SELECT '3177-12-29 08:00:00+00'::jtimestamptz;
\set VERBOSITY default
-- an explicit offset in the text moves the same instants
SELECT pg_input_is_valid('-0061-01-01 16:00:00+00', 'jtimestamptz') AS first_utc,
       pg_input_is_valid('-0061-01-02 07:59:00+15:59', 'jtimestamptz') AS first_written_at_plus_1559,
       pg_input_is_valid('-0061-01-02 07:58:59.999999+15:59', 'jtimestamptz') AS before_first_at_plus_1559,
       pg_input_is_valid('-0061-01-01 00:01:00-15:59', 'jtimestamptz') AS first_written_at_minus_1559,
       pg_input_is_valid('-0061-01-01 00:00:59.999999-15:59', 'jtimestamptz') AS before_first_at_minus_1559;

-- session zone 15:59 east of Greenwich (POSIX spelling: the sign is inverted)
SET timezone = '<+15:59>-15:59';
SELECT '-0061-01-02 07:59:00'::jtimestamptz AS first_valid_plus_1559;
SELECT '3177-12-29 23:58:59.999999'::jtimestamptz AS last_valid_plus_1559;
SELECT pg_input_is_valid('-0061-01-02 07:58:59.999999', 'jtimestamptz') AS one_microsecond_before_first,
       pg_input_is_valid('-0061-01-02 07:59:00', 'jtimestamptz') AS first,
       pg_input_is_valid('3177-12-29 23:58:59.999999', 'jtimestamptz') AS last,
       pg_input_is_valid('3177-12-29 23:59:00', 'jtimestamptz') AS one_microsecond_after_last;
-- a valid instant shows a Jalali day in this zone too, at both edges
SELECT '3177-12-29 07:59:59.999999+00'::jtimestamptz AS last_valid_shown_plus_1559;
SELECT '-0061-01-01 16:00:00+00'::jtimestamptz AS first_valid_shown_plus_1559;
SELECT '1403-01-01 12:00:00+00'::jtimestamptz AS ordinary_shown_plus_1559;

-- session zone 15:59 west of Greenwich
SET timezone = '<-15:59>+15:59';
SELECT '-0061-01-01 00:01:00'::jtimestamptz AS first_valid_minus_1559;
SELECT '3177-12-28 16:00:59.999999'::jtimestamptz AS last_valid_minus_1559;
SELECT pg_input_is_valid('-0061-01-01 00:00:59.999999', 'jtimestamptz') AS one_microsecond_before_first,
       pg_input_is_valid('-0061-01-01 00:01:00', 'jtimestamptz') AS first,
       pg_input_is_valid('3177-12-28 16:00:59.999999', 'jtimestamptz') AS last,
       pg_input_is_valid('3177-12-28 16:01:00', 'jtimestamptz') AS one_microsecond_after_last;
SELECT '3177-12-29 07:59:59.999999+00'::jtimestamptz AS last_valid_shown_minus_1559;
SELECT '-0061-01-01 16:00:00+00'::jtimestamptz AS first_valid_shown_minus_1559;
SELECT '1403-01-01 12:00:00+00'::jtimestamptz AS ordinary_shown_minus_1559;

-- historic local mean time: before its first transition a zone keeps its earliest offset,
-- which for the first valid instant (year 560) can be 15:56:08 west (Asia/Manila) or
-- 15:13:42 east (America/Metlakatla) of Greenwich, with seconds
SET timezone = 'Asia/Manila';
SELECT '-0061-01-01 16:00:00+00'::jtimestamptz AS first_valid_manila;
SET timezone = 'America/Metlakatla';
SELECT '-0061-01-01 16:00:00+00'::jtimestamptz AS first_valid_metlakatla;
SET timezone = 'UTC';
-- the extreme offsets PostgreSQL accepts in the text, +/-15:59:59: the edge instants again
SELECT pg_input_is_valid('-0061-01-02 07:59:59+15:59:59', 'jtimestamptz') AS first_at_plus_155959,
       pg_input_is_valid('-0061-01-02 07:59:58.999999+15:59:59', 'jtimestamptz') AS before_first_at_plus_155959,
       pg_input_is_valid('3177-12-28 16:00:00.999999-15:59:59', 'jtimestamptz') AS last_at_minus_155959,
       pg_input_is_valid('3177-12-28 16:00:01-15:59:59', 'jtimestamptz') AS after_last_at_minus_155959;

-- ---------------------------------------------------------------------
-- typmod: jtimestamptz(p), p = 0..6, applied by the input function (COPY, array
-- input, pg_input_is_valid, a direct call); the scale cast that a cast or an
-- INSERT of a non-literal goes through comes with the other casts.
-- ---------------------------------------------------------------------
SELECT format_type('jtimestamptz'::regtype, NULL) AS no_typmod,
       format_type('jtimestamptz'::regtype, 0) AS p0,
       format_type('jtimestamptz'::regtype, 3) AS p3,
       format_type('jtimestamptz'::regtype, 6) AS p6;
SELECT to_regtype('jtimestamptz(3)') = 'jtimestamptz'::regtype AS typmod_is_not_part_of_the_oid;
\set VERBOSITY sqlstate
SELECT '1403-01-01 12:00:00'::jtimestamptz(7);
SET client_min_messages = error;
CREATE TABLE jt_io_tz_p7 (c jtimestamptz(7));
RESET client_min_messages;
SELECT atttypmod, format_type(atttypid, atttypmod) AS type
FROM pg_attribute WHERE attrelid = 'jt_io_tz_p7'::regclass AND attname = 'c';
SELECT '1403-01-01 12:00:00'::jtimestamptz(-1);
SELECT '1403-01-01 12:00:00'::jtimestamptz(1, 2);
\set VERBOSITY default
CREATE TABLE jt_io_tz_typmod (p0 jtimestamptz(0), p3 jtimestamptz(3), p6 jtimestamptz(6), pn jtimestamptz);
SELECT attname, format_type(atttypid, atttypmod) AS type, atttypmod
FROM pg_attribute WHERE attrelid = 'jt_io_tz_typmod'::regclass AND attnum > 0 ORDER BY attnum;
COPY jt_io_tz_typmod FROM STDIN;
1403-01-01 12:00:00.5+00	1403-01-01 12:00:00.1236+00	1403-01-01 12:00:00.1234567+00	1403-01-01 12:00:00.1234567+00
1403-01-01 12:00:00.4+00	1403-01-01 12:00:00.1234+00	1403-01-01 12:00:00.1234564+00	1403-01-01 12:00:00.9999999+00
1402-12-29 23:59:59.5+00	1402-12-29 23:59:59.9996+00	1402-12-29 23:59:59.9999996+00	1402-12-29 23:59:59.9999996+00
\.
SELECT * FROM jt_io_tz_typmod;
-- rounding to the typmod can carry past the last valid microsecond: 22008
\set VERBOSITY sqlstate
SELECT pg_input_is_valid('3177-12-29 07:59:59.4+00', 'jtimestamptz(0)') AS rounds_down_stays_valid,
       pg_input_is_valid('3177-12-29 07:59:59.5+00', 'jtimestamptz(0)') AS rounds_up_out_of_range,
       pg_input_is_valid('3177-12-29 07:59:59.9996+00', 'jtimestamptz(3)') AS rounds_up_p3,
       pg_input_is_valid('3177-12-29 07:59:59.999999+00', 'jtimestamptz(6)') AS p6_stays_valid;
SELECT (pg_input_error_info('3177-12-29 07:59:59.5+00', 'jtimestamptz(0)')).sql_error_code AS sqlstate;
CREATE TABLE jt_io_tz_edge (p0 jtimestamptz(0));
COPY jt_io_tz_edge FROM STDIN;
3177-12-29 07:59:59.5+00
\.
SELECT count(*) AS rows_after_rounding_past_the_edge FROM jt_io_tz_edge;
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
    RAISE INFO '%: % and %', s, '1403-05-02 12:34:56.5+03:30'::jtimestamptz,
               '1403-02-05 01:02:03+00'::jtimestamptz;
  END LOOP;
  PERFORM set_config('DateStyle', 'ISO, YMD', false);
END
$do$;
SET DateStyle = 'German';
SELECT '1403-05-02 12:34:56+00'::jtimestamptz, '1403-02-05 01:02:03+00'::jtimestamptz;
SET DateStyle = 'Postgres, MDY';
SELECT '1403-05-02 12:34:56+00'::jtimestamptz, '1403-02-05 01:02:03+00'::jtimestamptz;
SET DateStyle = 'SQL, DMY';
SELECT '1403-05-02 12:34:56+00'::jtimestamptz, 'infinity'::jtimestamptz;
SET DateStyle = 'ISO, YMD';

-- ---------------------------------------------------------------------
-- arrays
-- ---------------------------------------------------------------------
SELECT ARRAY['1403-01-01 10:00+03:30', '1403-12-29 23:59:59.5+00']::jtimestamptz[] AS arr;
SELECT '{"1403-01-01 10:00:00+00", NULL, "1403-12-29T23:59:59.5+03:30", infinity}'::jtimestamptz[] AS arr_literal;
SELECT ('{"1403-01-01 10:00:00+00","1403-12-29 23:59:59.5+00"}'::jtimestamptz[])[2] AS second_element;
SELECT pg_typeof(ARRAY['1403-01-01 10:00+00']::jtimestamptz[]) AS array_type;
\set VERBOSITY sqlstate
SELECT '{"1403-01-01 10:00:00+00","3178-01-01 00:00:00+00"}'::jtimestamptz[];
SELECT '{"1403-01-01 10:00:00+00","-0061-01-01 00:00:00+00"}'::jtimestamptz[];
SELECT '{"1403-01-01 10:00:00+00","garbage"}'::jtimestamptz[];
\set VERBOSITY default

-- ---------------------------------------------------------------------
-- the type in the catalog
-- ---------------------------------------------------------------------
SELECT typname, typlen, typbyval, typalign, typstorage, typcategory, typispreferred,
       typtype, typdelim, typinput::regproc AS input, typoutput::regproc AS output,
       typreceive::regproc AS receive, typsend::regproc AS send,
       typmodin::regproc AS typmodin, typmodout::regproc AS typmodout,
       typarray::regtype AS array_type
FROM pg_type WHERE typname = 'jtimestamptz';
-- the same layout as core's timestamptz, apart from the OIDs and function names
SELECT a.typlen = b.typlen AND a.typbyval = b.typbyval AND a.typalign = b.typalign
       AND a.typstorage = b.typstorage AND a.typcategory = b.typcategory AS same_layout_as_timestamptz,
       a.typispreferred AS jtimestamptz_preferred, b.typispreferred AS timestamptz_preferred
FROM pg_type a, pg_type b WHERE a.typname = 'jtimestamptz' AND b.typname = 'timestamptz';
SELECT typname, typelem::regtype AS element_type FROM pg_type WHERE typname = '_jtimestamptz';
-- volatility: input and output STABLE (zone, clock), the rest IMMUTABLE; all strict and parallel safe
SELECT proname, provolatile, proisstrict, proparallel, prorettype::regtype AS returns
FROM pg_proc
WHERE proname IN ('jtimestamptz_in', 'jtimestamptz_out', 'jtimestamptz_recv', 'jtimestamptz_send',
                  'jtimestamptz_typmodout', 'to_jtimestamptz')
ORDER BY proname;
-- jtimestamptz_typmodout prints "(p)" like the jtimestamp one
SELECT jtimestamptz_typmodout(3) AS p3, jtimestamptz_typmodout(-1) AS none;
-- so neither the text cast nor the text conversion can be used in an index; to_jtimestamptz
-- is IMMUTABLE and can (there is no operator class for the type yet, so index its bytea send form)
CREATE TABLE jt_io_tz_idx (s text, j jtimestamptz, e double precision);
\set VERBOSITY sqlstate
CREATE INDEX jt_io_tz_idx_from_text ON jt_io_tz_idx ((jtimestamptz_send(s::jtimestamptz)));
CREATE INDEX jt_io_tz_idx_to_text ON jt_io_tz_idx ((j::text));
\set VERBOSITY default
CREATE INDEX jt_io_tz_idx_epoch ON jt_io_tz_idx ((jtimestamptz_send(to_jtimestamptz(e))));
SELECT indexname FROM pg_indexes WHERE tablename = 'jt_io_tz_idx' ORDER BY indexname;
SELECT obj_description('jtimestamptz'::regtype, 'pg_type') IS NOT NULL AS has_comment;

-- ---------------------------------------------------------------------
-- binary: send is core's timestamptz wire format, recv checks the safe range
-- ---------------------------------------------------------------------
SET timezone = 'UTC';
CREATE TABLE jt_io_tz_vals (t jtimestamptz);
INSERT INTO jt_io_tz_vals VALUES
    ('1403-01-01 00:00:00+00'), ('-0061-01-01 16:00:00+00'), ('3177-12-29 07:59:59.999999+00'),
    ('1348-10-11 00:00:00+00'), ('infinity'), ('-infinity');
-- the same eight bytes as core's timestamptz of the same instant
SELECT j, g, encode(jtimestamptz_send(j::jtimestamptz), 'hex') AS wire,
       jtimestamptz_send(j::jtimestamptz) = timestamptz_send(g::timestamptz) AS same_as_timestamptz
FROM (VALUES ('1403-01-01 00:00:00+00', '2024-03-20 00:00:00+00'),
             ('-0061-01-01 16:00:00+00', '0560-03-20 16:00:00+00'),
             ('3177-12-29 07:59:59.999999+00', '3799-03-19 07:59:59.999999+00'),
             ('1348-10-11 00:00:00+00', '1970-01-01 00:00:00+00'),
             ('1403-01-01 12:00:00+03:30', '2024-03-20 08:30:00+00')) v(j, g)
ORDER BY j COLLATE "C";
SELECT t, encode(jtimestamptz_send(t), 'hex') AS wire,
       jtimestamptz_send(t) = timestamptz_send(g::timestamptz) AS same_as_timestamptz
FROM jt_io_tz_vals JOIN (VALUES ('infinity', 'infinity'), ('-infinity', '-infinity')) v(j, g)
  ON t::text = j
ORDER BY t::text COLLATE "C";
-- the wire format does not depend on the session zone
SET timezone = 'Asia/Tehran';
SELECT jtimestamptz_send('1403-01-01 12:00:00+00'::jtimestamptz) = timestamptz_send('2024-03-20 12:00:00+00'::timestamptz) AS same_in_tehran;
SET timezone = 'UTC';
\copy jt_io_tz_vals TO 'test/results/jt_io_tz_vals.bin' WITH (FORMAT binary)
CREATE TABLE jt_io_tz_back (t jtimestamptz);
\copy jt_io_tz_back FROM 'test/results/jt_io_tz_vals.bin' WITH (FORMAT binary)
SELECT t FROM jt_io_tz_back ORDER BY t::text COLLATE "C";
SELECT (SELECT array_agg(t::text ORDER BY t::text COLLATE "C") FROM jt_io_tz_vals)
     = (SELECT array_agg(t::text ORDER BY t::text COLLATE "C") FROM jt_io_tz_back) AS roundtrip_equal;
-- recv: a timestamptz that core accepts but the safe range does not (22008, nothing loaded)
CREATE TABLE jt_io_tz_core (t timestamptz);
CREATE TABLE jt_io_tz_target (t jtimestamptz);
CREATE TABLE jt_io_tz_target0 (t jtimestamptz(0));
\set VERBOSITY sqlstate
-- one microsecond below the first valid instant (0560-03-20 16:00 UTC)
INSERT INTO jt_io_tz_core VALUES ('0560-03-20 15:59:59.999999+00');
\copy jt_io_tz_core TO 'test/results/jt_io_tz_bad.bin' WITH (FORMAT binary)
\copy jt_io_tz_target FROM 'test/results/jt_io_tz_bad.bin' WITH (FORMAT binary)
SELECT count(*) AS rows_after_below_min FROM jt_io_tz_target;
-- the first instant of the first Jalali day: valid for jtimestamp, not for jtimestamptz
TRUNCATE jt_io_tz_core;
INSERT INTO jt_io_tz_core VALUES ('0560-03-20 00:00:00+00');
\copy jt_io_tz_core TO 'test/results/jt_io_tz_bad.bin' WITH (FORMAT binary)
\copy jt_io_tz_target FROM 'test/results/jt_io_tz_bad.bin' WITH (FORMAT binary)
SELECT count(*) AS rows_after_first_instant_of_first_day FROM jt_io_tz_target;
-- the first instant after the last valid one (3799-03-19 07:59:59.999999 UTC is the last)
TRUNCATE jt_io_tz_core;
INSERT INTO jt_io_tz_core VALUES ('3799-03-19 08:00:00+00');
\copy jt_io_tz_core TO 'test/results/jt_io_tz_bad.bin' WITH (FORMAT binary)
\copy jt_io_tz_target FROM 'test/results/jt_io_tz_bad.bin' WITH (FORMAT binary)
SELECT count(*) AS rows_after_above_max FROM jt_io_tz_target;
-- far outside core's own range is core's error, also 22008
TRUNCATE jt_io_tz_core;
INSERT INTO jt_io_tz_core VALUES ('0001-01-01 00:00:00+00 BC');
\copy jt_io_tz_core TO 'test/results/jt_io_tz_bad.bin' WITH (FORMAT binary)
\copy jt_io_tz_target FROM 'test/results/jt_io_tz_bad.bin' WITH (FORMAT binary)
SELECT count(*) AS rows_after_bc FROM jt_io_tz_target;
-- the typmod of the column is applied on receive, and the check comes after it
TRUNCATE jt_io_tz_core;
INSERT INTO jt_io_tz_core VALUES ('3799-03-19 07:59:59.5+00');
\copy jt_io_tz_core TO 'test/results/jt_io_tz_bad.bin' WITH (FORMAT binary)
\copy jt_io_tz_target0 FROM 'test/results/jt_io_tz_bad.bin' WITH (FORMAT binary)
SELECT count(*) AS rows_after_rounding_past_the_edge FROM jt_io_tz_target0;
\copy jt_io_tz_target FROM 'test/results/jt_io_tz_bad.bin' WITH (FORMAT binary)
SELECT t FROM jt_io_tz_target;
\set VERBOSITY default

-- ---------------------------------------------------------------------
-- to_jtimestamptz(double precision): the instant of a Unix timestamp
-- ---------------------------------------------------------------------
SELECT pg_typeof(to_jtimestamptz(0)) AS type;
SET timezone = 'UTC';
SELECT to_jtimestamptz(0) AS epoch_utc, to_jtimestamptz(1710000000.5) AS with_fraction,
       to_jtimestamptz(-1) AS one_second_before_epoch;
SET timezone = 'Asia/Tehran';
SELECT to_jtimestamptz(0) AS epoch_tehran, to_jtimestamptz(1710000000.5) AS with_fraction;
SET timezone = 'UTC';
-- the same bytes as core's to_timestamp, so the same rounding to microseconds
SELECT x, jtimestamptz_send(to_jtimestamptz(x)) = timestamptz_send(to_timestamp(x)) AS same_as_to_timestamp
FROM (VALUES (0::float8), (1710000000.5), (1710000000.1234567), (-1.5), (-0.0000006), (1403.6),
             (-11676096000.25), (4102444800)) v(x);
-- infinities
SELECT to_jtimestamptz('infinity') AS plus_infinity, to_jtimestamptz('-infinity') AS minus_infinity;
-- IMMUTABLE: the session zone does not change the instant
SET timezone = 'UTC';
SELECT jtimestamptz_send(to_jtimestamptz(1710000000)) AS wire_utc \gset
SET timezone = 'Pacific/Kiritimati';
SELECT jtimestamptz_send(to_jtimestamptz(1710000000)) = :'wire_utc'::bytea AS same_in_kiritimati;
SET timezone = 'UTC';
-- the edges: first and last valid instants (epoch of 0560-03-20 16:00 UTC and 3799-03-19 07:59:59 UTC)
SELECT to_jtimestamptz(-44488425600) AS first_valid;
SELECT to_jtimestamptz(57724387199) AS last_whole_second, to_jtimestamptz(57724387199.5) AS last_half_second;
\set VERBOSITY sqlstate
SELECT to_jtimestamptz(-44488425601);     -- one second below the first valid instant
SELECT to_jtimestamptz(-44488425600.5);   -- half a second below
SELECT to_jtimestamptz(57724387200);      -- the first instant above the last
SELECT to_jtimestamptz(-44488483200);     -- the first instant of the first day: in to_jdate's range, not in the safe range
SELECT to_jtimestamptz(57724444800);      -- the first instant after the last day
SELECT to_jtimestamptz('NaN');
SELECT to_jtimestamptz(1e18);
SELECT to_jtimestamptz(-1e18);
SELECT to_jtimestamptz(1e300);
\set VERBOSITY default
-- the same inputs are errors for to_jdate (or valid, where the safe range is the only difference)
SELECT to_jdate(-44488483200) AS to_jdate_first_instant, to_jdate(57724444800 - 1) AS to_jdate_last_instant;
\set VERBOSITY sqlstate
SELECT to_jdate('NaN');
\set VERBOSITY default
-- a jtimestamptz from an epoch reads back to the same instant
SELECT x, to_jtimestamptz(x)::text::jtimestamptz::text = to_jtimestamptz(x)::text AS reads_back
FROM (VALUES (0::float8), (1710000000.5), (-44488425600), (57724387199.5)) v(x);

-- ---------------------------------------------------------------------
-- clean up: extension_schema drops the extension, which needs no column of
-- its types left behind
-- ---------------------------------------------------------------------
DROP TABLE jt_io_typmod, jt_io_edge, jt_io_p7, jt_io_idx, jt_io_vals, jt_io_back,
           jt_io_core, jt_io_target, jt_io_target0;
DROP TABLE jt_io_tz_typmod, jt_io_tz_edge, jt_io_tz_p7, jt_io_tz_idx, jt_io_tz_vals,
           jt_io_tz_back, jt_io_tz_core, jt_io_tz_target, jt_io_tz_target0;
