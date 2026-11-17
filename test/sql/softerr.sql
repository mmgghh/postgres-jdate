-- jdate_in reports bad input softly (through the ErrorSaveContext), so
-- pg_input_is_valid, pg_input_error_info, array input and COPY ... ON_ERROR
-- ignore can handle it instead of aborting the statement.
--
-- Version note: pg_input_is_valid/pg_input_error_info need PostgreSQL 16+,
-- but COPY ... (ON_ERROR ignore) needs PostgreSQL 17+, so the COPY half of
-- this file does not run on 16.
SET DateStyle = 'ISO, YMD';
SET timezone = 'UTC';

-- pg_input_is_valid: false for bad input, true for good input
SELECT pg_input_is_valid('1403-05-15', 'jdate') AS valid;
SELECT pg_input_is_valid('infinity', 'jdate') AS valid_infinity;
SELECT pg_input_is_valid('garbage', 'jdate') AS syntax_error;
SELECT pg_input_is_valid('1403-13-01', 'jdate') AS invalid_month;
SELECT pg_input_is_valid('1404-12-30', 'jdate') AS non_leap_day_30;
SELECT pg_input_is_valid('3178-01-01', 'jdate') AS above_range;
SELECT pg_input_is_valid('-0062-12-29', 'jdate') AS below_range;
SELECT pg_input_is_valid('99999999999-01-01', 'jdate') AS int32_overflow;

-- pg_input_error_info: message and SQLSTATE (22007 syntax, 22008 range)
SELECT message, sql_error_code
  FROM pg_input_error_info('garbage', 'jdate');
SELECT message, sql_error_code
  FROM pg_input_error_info('1403-13-01', 'jdate');
SELECT message, sql_error_code
  FROM pg_input_error_info('3178-01-01', 'jdate');
SELECT message, sql_error_code
  FROM pg_input_error_info('99999999999-01-01', 'jdate');
-- good input has no error
SELECT message, sql_error_code
  FROM pg_input_error_info('1403-05-15', 'jdate');

-- array input: one bad element makes the whole literal invalid
SELECT pg_input_is_valid('{1403-01-01,1403-12-29}', 'jdate[]') AS good_array;
SELECT pg_input_is_valid('{1403-01-01,x}', 'jdate[]') AS bad_element;
SELECT pg_input_is_valid('{1403-01-01,3178-01-01}', 'jdate[]') AS range_element;
SELECT message, sql_error_code
  FROM pg_input_error_info('{1403-01-01,x}', 'jdate[]');

-- hard errors still raise, with the same SQLSTATEs
\set VERBOSITY sqlstate
SELECT 'garbage'::jdate;
SELECT '1403-13-01'::jdate;
SELECT '3178-01-01'::jdate;
SELECT '99999999999-01-01'::jdate;
\set VERBOSITY default

-- COPY ... ON_ERROR ignore skips bad rows and loads the good ones
CREATE TABLE softerr_t (id int, d jdate);
COPY softerr_t FROM STDIN (ON_ERROR ignore);
1	1403-01-01
2	garbage
3	1403-12-29
4	3178-01-01
5	99999999999-01-01
6	infinity
\.
SELECT id, d FROM softerr_t ORDER BY id;

-- the default, ON_ERROR stop, still aborts on the first bad row
TRUNCATE softerr_t;
\set VERBOSITY sqlstate
COPY softerr_t FROM STDIN (ON_ERROR stop);
1	1403-01-01
2	garbage
3	1403-12-29
\.
\set VERBOSITY default
SELECT count(*) AS rows_after_stop FROM softerr_t;

DROP TABLE softerr_t;
