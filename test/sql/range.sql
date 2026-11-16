-- Every path that produces a jdate must reject values outside the
-- supported Jalali range (-0061-01-01 .. 3177-12-29, which is the
-- Gregorian range 0560-03-20 .. 3799-03-19) with SQLSTATE 22008,
-- instead of storing a value that can never be displayed again.
SET DateStyle = 'ISO, YMD';
SET timezone = 'UTC';
\set VERBOSITY sqlstate

-- the edge values themselves are valid
SELECT '-0061-01-01'::jdate AS min_day, '3177-12-29'::jdate AS max_day;
SELECT '3177-12-28'::jdate + 1 AS reach_max_by_plus;
SELECT '-0061-01-02'::jdate - 1 AS reach_min_by_minus;
SELECT '3177-12-29'::jdate + 0 AS max_plus_zero;
SELECT '-0061-01-01'::jdate - 0 AS min_minus_zero;
SELECT '3177-12-29'::jdate - 1 AS max_minus_one;
SELECT '-0061-01-01'::jdate + 1 AS min_plus_one;

-- Out-of-range results must fail when computed. They are tested with
-- IS NOT NULL so that the error cannot come from displaying the result
-- (jdate_out has always rejected an out-of-range value).

-- jdate +/- int past either edge
SELECT ('3177-12-29'::jdate + 1) IS NOT NULL;
SELECT ('-0061-01-01'::jdate - 1) IS NOT NULL;
SELECT ('3177-12-29'::jdate + 2147483647) IS NOT NULL;
SELECT ('-0061-01-01'::jdate - 2147483647) IS NOT NULL;
SELECT ('-0061-01-01'::jdate + -1) IS NOT NULL;
SELECT ('3177-12-29'::jdate - -1) IS NOT NULL;
SELECT ('1403-01-01'::jdate + 2147483647) IS NOT NULL;
SELECT ('1403-01-01'::jdate - 2147483647) IS NOT NULL;
SELECT ('1403-01-01'::jdate + (-2147483647 - 1)) IS NOT NULL;
SELECT ('1403-01-01'::jdate - (-2147483647 - 1)) IS NOT NULL;

-- infinities are never changed by arithmetic
SELECT 'infinity'::jdate + 1 AS inf_plus, 'infinity'::jdate - 1 AS inf_minus;
SELECT '-infinity'::jdate + 1 AS ninf_plus, '-infinity'::jdate - 1 AS ninf_minus;
SELECT 'infinity'::jdate + 2147483647 AS inf_plus_max;

-- date -> jdate: the Gregorian edges succeed, one day further fails
SELECT date '0560-03-20'::jdate AS min_from_date, date '3799-03-19'::jdate AS max_from_date;
SELECT (date '0560-03-19'::jdate) IS NOT NULL;
SELECT (date '3799-03-20'::jdate) IS NOT NULL;
SELECT (date '9999-12-31'::jdate) IS NOT NULL;
SELECT (date '0001-01-01'::jdate) IS NOT NULL;
SELECT (date '0001-01-01 BC'::jdate) IS NOT NULL;
SELECT (date '5874897-12-31'::jdate) IS NOT NULL;
SELECT (date '4714-11-24 BC'::jdate) IS NOT NULL;
SELECT 'infinity'::date::jdate AS inf_from_date, '-infinity'::date::jdate AS ninf_from_date;
SELECT jdate(date '1970-01-01') AS explicit_function_form;
SELECT (jdate(date '9999-12-31')) IS NOT NULL;

-- timestamp -> jdate
SELECT timestamp '0560-03-20 00:00:00'::jdate AS min_from_ts, timestamp '3799-03-19 23:59:59.999999'::jdate AS max_from_ts;
SELECT (timestamp '0560-03-19 23:59:59.999999'::jdate) IS NOT NULL;
SELECT (timestamp '3799-03-20 00:00:00'::jdate) IS NOT NULL;
SELECT (timestamp '9999-12-31 00:00:00'::jdate) IS NOT NULL;
SELECT (timestamp '0001-01-01 00:00:00'::jdate) IS NOT NULL;
SELECT 'infinity'::timestamp::jdate AS inf_from_ts, '-infinity'::timestamp::jdate AS ninf_from_ts;

-- timestamptz -> jdate (session timezone is UTC here)
SELECT timestamptz '0560-03-20 00:00:00+00'::jdate AS min_from_tstz, timestamptz '3799-03-19 23:59:59.999999+00'::jdate AS max_from_tstz;
SELECT (timestamptz '0560-03-19 23:59:59.999999+00'::jdate) IS NOT NULL;
SELECT (timestamptz '3799-03-20 00:00:00+00'::jdate) IS NOT NULL;
SELECT (timestamptz '9999-12-31 00:00:00+00'::jdate) IS NOT NULL;
SELECT (timestamptz '0001-01-01 00:00:00+00'::jdate) IS NOT NULL;
SELECT 'infinity'::timestamptz::jdate AS inf_from_tstz, '-infinity'::timestamptz::jdate AS ninf_from_tstz;

-- the date -> jdate cast validates; jdate -> date stays a free cast
SELECT castsource::regtype AS source, casttarget::regtype AS target,
       castfunc::regprocedure AS func, castcontext
FROM pg_cast WHERE 'jdate'::regtype IN (castsource, casttarget)
ORDER BY castsource::regtype::text COLLATE "C", casttarget::regtype::text COLLATE "C";
SELECT provolatile, proisstrict, proparallel
FROM pg_proc WHERE oid = 'jdate(date)'::regprocedure;
SELECT '3177-12-29'::jdate::date AS free_cast_back;

-- the original symptom: one stored out-of-range value made every later
-- SELECT on the table fail. The insert must fail instead, leaving the
-- table empty and still readable.
CREATE TABLE range_t (d jdate);
INSERT INTO range_t SELECT date '9999-12-31';
INSERT INTO range_t SELECT date '0001-01-01';
INSERT INTO range_t SELECT timestamp '9999-12-31 00:00:00';
INSERT INTO range_t SELECT timestamptz '9999-12-31 00:00:00+00';
INSERT INTO range_t VALUES ('3177-12-29'::jdate + 1);
INSERT INTO range_t SELECT d + 1 FROM (VALUES ('3177-12-29'::jdate)) AS v(d);
SELECT count(*) AS rows_after_failed_inserts FROM range_t;
SELECT * FROM range_t;

-- valid values (edges, infinities, a converted date) are stored and read back
INSERT INTO range_t SELECT date '3799-03-19';
INSERT INTO range_t SELECT date '0560-03-20';
INSERT INTO range_t SELECT 'infinity'::date;
INSERT INTO range_t VALUES ('1403-01-01'::jdate + 10);
SELECT * FROM range_t ORDER BY d;
SELECT count(*) AS readable_rows FROM range_t;

DROP TABLE range_t;
\set VERBOSITY default
