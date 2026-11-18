SELECT '1403-01-01'::jdate + 10 AS plus_ten;
SELECT '1403-01-11'::jdate - 10 AS minus_ten;
SELECT '1403-01-01'::jdate - 1 AS crosses_year_boundary;  -- expect 1402-12-29
SELECT '1403-01-10'::jdate - '1403-01-01'::jdate AS day_diff;
SELECT '1403-01-01'::jdate - '1403-02-01'::jdate AS negative_day_diff;

-- arithmetic results outside the supported Jalali range are rejected
-- immediately (SQLSTATE 22008), not lazily when first displayed. IS NOT
-- NULL keeps the error from coming from display. Edge cases and the
-- date/timestamp casts are covered in range.sql.
\set VERBOSITY sqlstate
SELECT ('3177-12-29'::jdate + 1) IS NOT NULL AS arithmetic_errors_eagerly;
SELECT '3177-12-29'::jdate + 1;
\set VERBOSITY default

-- int + jdate is the commutation of jdate + int: the same value, the same
-- range check (22008), infinity stays infinity.
SELECT 5 + '1403-01-01'::jdate AS int_plus_jdate;
SELECT '1403-01-01'::jdate + 5 AS jdate_plus_int;
SELECT (5 + '1403-01-01'::jdate) = ('1403-01-01'::jdate + 5) AS commutes;
SELECT -10 + '1403-01-11'::jdate AS negative_int_plus_jdate;
SELECT 1 + '1402-12-29'::jdate AS crosses_year_boundary;  -- expect 1403-01-01
SELECT 1 + '3177-12-28'::jdate AS reach_max, -1 + '-0061-01-02'::jdate AS reach_min;
SELECT 5 + 'infinity'::jdate AS plus_infinity, 5 + '-infinity'::jdate AS plus_minus_infinity;
SELECT d, n, n + d AS int_plus_column
FROM (VALUES ('1403-01-01'::jdate, 40), ('1403-12-29'::jdate, 1)) AS v(d, n);

\set VERBOSITY sqlstate
SELECT (5 + '3177-12-29'::jdate) IS NOT NULL AS past_max;
SELECT (-1 + '-0061-01-01'::jdate) IS NOT NULL AS past_min;
SELECT (2147483647 + '3177-12-29'::jdate) IS NOT NULL AS int_max_past_max;
SELECT (-2147483647 + '-0061-01-01'::jdate) IS NOT NULL AS int_min_past_min;
SELECT 5 + '3177-12-29'::jdate;
\set VERBOSITY default

-- the operator is a real one, not a shell left over from COMMUTATOR = + (this
-- covers every operator of jdate, the interval and time ones of jt_arith too),
-- and the two integer + operators are each other's commutator (the others are
-- listed in jt_arith)
SELECT count(*) AS shell_operators
FROM pg_operator WHERE oprcode = 0 AND 'jdate'::regtype IN (oprleft, oprright);
SELECT l.oprleft::regtype AS left_type, l.oprright::regtype AS right_type,
       l.oprcode::regproc AS implementation,
       c.oprleft::regtype AS com_left_type, c.oprright::regtype AS com_right_type,
       c.oprcom = l.oid AS com_points_back
FROM pg_operator l JOIN pg_operator c ON c.oid = l.oprcom
WHERE l.oprname = '+' AND 'jdate'::regtype IN (l.oprleft, l.oprright)
  AND 'integer'::regtype IN (l.oprleft, l.oprright)
ORDER BY l.oprleft::regtype::text;
