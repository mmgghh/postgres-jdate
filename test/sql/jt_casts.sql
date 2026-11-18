-- jtimestamp and jtimestamptz: every cast, on edge values and infinities, under
-- several time zones. Errors are shown as SQLSTATE only (\set VERBOSITY
-- sqlstate), never as message text.
--
-- The tables created here are dropped at the end: extension_schema runs
-- DROP EXTENSION, which needs no column of our types left behind.
SET DateStyle = 'ISO, YMD';
SET timezone = 'UTC';

-- ---------------------------------------------------------------------
-- the catalog: which casts exist, in which context, by which method
-- ---------------------------------------------------------------------
-- every cast that has one of the new types at either end (jdate and the core
-- types at the other). All ASSIGNMENT, apart from the two typmod (scale)
-- casts, which are IMPLICIT; the two casts to the core types of the same kind
-- are binary (b), the rest go through a function (f).
SELECT c.castsource::regtype AS source, c.casttarget::regtype AS target,
       c.castcontext AS context, c.castmethod AS method,
       p.proname AS function, p.provolatile AS volatility,
       p.proisstrict AS strict, p.proparallel AS parallel
FROM pg_cast c LEFT JOIN pg_proc p ON p.oid = c.castfunc
WHERE c.castsource IN ('jtimestamp'::regtype, 'jtimestamptz'::regtype)
   OR c.casttarget IN ('jtimestamp'::regtype, 'jtimestamptz'::regtype)
ORDER BY c.castsource::regtype::text COLLATE "C", c.casttarget::regtype::text COLLATE "C";

-- the summary the table above shows: no implicit cast between different types
SELECT count(*) AS casts,
       count(*) FILTER (WHERE c.castcontext = 'i' AND c.castsource <> c.casttarget) AS implicit_between_types,
       count(*) FILTER (WHERE c.castcontext = 'i' AND c.castsource = c.casttarget) AS implicit_scale,
       count(*) FILTER (WHERE c.castmethod = 'b') AS binary_casts
FROM pg_cast c
WHERE c.castsource IN ('jtimestamp'::regtype, 'jtimestamptz'::regtype)
   OR c.casttarget IN ('jtimestamp'::regtype, 'jtimestamptz'::regtype);

-- the scale functions take (value, typmod, explicit), as the parser expects
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
FROM pg_cast c JOIN pg_proc p ON p.oid = c.castfunc
WHERE c.castsource = c.casttarget AND c.castsource IN ('jtimestamp'::regtype, 'jtimestamptz'::regtype)
ORDER BY p.proname;

-- ---------------------------------------------------------------------
-- volatility of every cast function, against core's
-- ---------------------------------------------------------------------
-- A cast that reads the session time zone is STABLE, every other one is
-- IMMUTABLE. The oracle is core: each of our types is mapped to the core type
-- it mirrors (jdate to date, jtimestamp to timestamp, jtimestamptz to
-- timestamptz) and the core cast between the mapped types gives the volatility
-- expected. Where the mapping leaves one type (date -> jdate, timestamp ->
-- jtimestamp, timestamptz -> jtimestamptz) there is no core cast: the function
-- is a range check and reads no zone, so IMMUTABLE is expected (this includes
-- timestamptz -> jtimestamptz, unlike core's STABLE timestamp -> timestamptz).
-- The scale casts map to core's scale casts, which are IMMUTABLE.
WITH m(ours, core) AS (
  VALUES ('jdate'::regtype, 'date'::regtype),
         ('jtimestamp'::regtype, 'timestamp'::regtype),
         ('jtimestamptz'::regtype, 'timestamptz'::regtype)
)
SELECT c.castsource::regtype AS source, c.casttarget::regtype AS target,
       p.proname AS function, p.provolatile AS volatility,
       coalesce(cp.provolatile, 'i') AS expected,
       p.provolatile = coalesce(cp.provolatile, 'i') AS as_expected
FROM pg_cast c
JOIN pg_proc p ON p.oid = c.castfunc
LEFT JOIN m ms ON ms.ours = c.castsource
LEFT JOIN m mt ON mt.ours = c.casttarget
LEFT JOIN pg_cast cc ON cc.castsource = coalesce(ms.core, c.castsource)
                    AND cc.casttarget = coalesce(mt.core, c.casttarget)
LEFT JOIN pg_proc cp ON cp.oid = cc.castfunc
WHERE ms.ours IS NOT NULL OR mt.ours IS NOT NULL
ORDER BY c.castsource::regtype::text COLLATE "C", c.casttarget::regtype::text COLLATE "C";

-- the cast functions of the three types together: how many, and none that
-- differs from core's volatility
WITH m(ours, core) AS (
  VALUES ('jdate'::regtype, 'date'::regtype),
         ('jtimestamp'::regtype, 'timestamp'::regtype),
         ('jtimestamptz'::regtype, 'timestamptz'::regtype)
)
SELECT count(*) AS cast_functions,
       count(*) FILTER (WHERE p.provolatile = 's') AS stable,
       count(*) FILTER (WHERE p.provolatile = 'i') AS immutable,
       count(*) FILTER (WHERE p.provolatile = 'v') AS volatile,
       count(*) FILTER (WHERE p.provolatile <> coalesce(cp.provolatile, 'i')) AS differing_from_core
FROM pg_cast c
JOIN pg_proc p ON p.oid = c.castfunc
LEFT JOIN m ms ON ms.ours = c.castsource
LEFT JOIN m mt ON mt.ours = c.casttarget
LEFT JOIN pg_cast cc ON cc.castsource = coalesce(ms.core, c.castsource)
                    AND cc.casttarget = coalesce(mt.core, c.casttarget)
LEFT JOIN pg_proc cp ON cp.oid = cc.castfunc
WHERE ms.ours IS NOT NULL OR mt.ours IS NOT NULL;

-- the functions next to the casts that convert but are not casts: the epoch
-- conversions read no zone (to_jdate with a zone name takes the zone as an
-- argument, as core's timezone(text, timestamptz)), jdate_format on a
-- timestamptz reads the session zone
SELECT p.proname AS function, pg_get_function_identity_arguments(p.oid) AS args,
       p.provolatile AS volatility
FROM pg_proc p
WHERE p.proname IN ('to_jdate', 'to_jtimestamptz', 'jdate_format')
  AND p.oid IN (SELECT d.objid FROM pg_depend d
                WHERE d.classid = 'pg_proc'::regclass AND d.deptype = 'e'
                  AND d.refobjid = (SELECT oid FROM pg_extension WHERE extname = 'jdate'))
ORDER BY p.proname, pg_get_function_identity_arguments(p.oid) COLLATE "C";

-- ---------------------------------------------------------------------
-- Nowruz 1403 (1403-01-01 is 2024-03-20) in five zones
--
-- Every row is evaluated in its zone, with a fresh parse per statement (a
-- literal is read in the session zone when the statement is parsed). %1$s in an
-- expression is the UTC instant of local midnight of 2024-03-20 in that zone,
-- in the "expect" it is the offset suffix of the zone's text and %2$s the same
-- instant as a UTC clock time.
-- ---------------------------------------------------------------------
CREATE FUNCTION pg_temp.eval(zone text, q text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE r text;
BEGIN
  PERFORM set_config('TimeZone', zone, false);
  EXECUTE q INTO r;
  RETURN r;
EXCEPTION WHEN OTHERS THEN
  RETURN 'ERR ' || SQLSTATE;
END
$f$;

CREATE TEMP TABLE nz_zone (id int, zone text, off text, utc text);
INSERT INTO nz_zone VALUES
  (1, 'UTC',                '+00',    '2024-03-20 00:00:00'),
  (2, 'Asia/Tehran',        '+03:30', '2024-03-19 20:30:00'),
  (3, 'America/New_York',   '-04',    '2024-03-20 04:00:00'),
  (4, 'Pacific/Kiritimati', '+14',    '2024-03-19 10:00:00'),
  (5, 'Pacific/Pago_Pago',  '-11',    '2024-03-20 11:00:00');

-- expr is run with %1$s = the UTC clock time of local midnight, expect with
-- %1$s = the zone's offset suffix
CREATE TEMP TABLE nz_check (n int, what text, expr text, expect text);
INSERT INTO nz_check VALUES
  (1,  'jtimestamp -> timestamp',
       $$SELECT ('1403-01-01 00:00:00'::jtimestamp::timestamp)::text$$, '2024-03-20 00:00:00'),
  (2,  'timestamp -> jtimestamp',
       $$SELECT ('2024-03-20 00:00:00'::timestamp::jtimestamp)::text$$, '1403-01-01 00:00:00'),
  (3,  'jtimestamp -> jtimestamptz (local midnight)',
       $$SELECT ('1403-01-01 00:00:00'::jtimestamp::jtimestamptz)::text$$, '1403-01-01 00:00:00%1$s'),
  (4,  '  the same instant in UTC',
       $$SELECT (('1403-01-01 00:00:00'::jtimestamp::jtimestamptz)::timestamptz AT TIME ZONE 'UTC')::text$$, '%2$s'),
  (5,  'jtimestamptz -> jtimestamp',
       $$SELECT (('1403-01-01 00:00:00'::jtimestamp::jtimestamptz)::jtimestamp)::text$$, '1403-01-01 00:00:00'),
  (6,  'timestamptz -> jtimestamptz',
       $$SELECT ('%1$s+00'::timestamptz::jtimestamptz)::text$$, '1403-01-01 00:00:00%1$s'),
  (7,  'jtimestamptz -> timestamptz (binary)',
       $$SELECT (('1403-01-01 00:00:00'::jtimestamp::jtimestamptz)::timestamptz = '%1$s+00'::timestamptz)::text$$, 'true'),
  (8,  'date -> jtimestamp',
       $$SELECT (date '2024-03-20'::jtimestamp)::text$$, '1403-01-01 00:00:00'),
  (9,  'date -> jtimestamptz',
       $$SELECT (date '2024-03-20'::jtimestamptz)::text$$, '1403-01-01 00:00:00%1$s'),
  (10, 'jdate -> jtimestamp',
       $$SELECT ('1403-01-01'::jdate::jtimestamp)::text$$, '1403-01-01 00:00:00'),
  (11, 'jdate -> jtimestamptz',
       $$SELECT ('1403-01-01'::jdate::jtimestamptz)::text$$, '1403-01-01 00:00:00%1$s'),
  (12, '  the same instant in UTC',
       $$SELECT (('1403-01-01'::jdate::jtimestamptz)::timestamptz AT TIME ZONE 'UTC')::text$$, '%2$s'),
  (13, 'jtimestamp -> jdate',
       $$SELECT ('1403-01-01 23:59:59.999999'::jtimestamp::jdate)::text$$, '1403-01-01'),
  (14, 'jtimestamptz -> jdate at local midnight',
       $$SELECT ('%1$s+00'::timestamptz::jtimestamptz::jdate)::text$$, '1403-01-01'),
  (15, 'jtimestamptz -> jdate one microsecond before it',
       $$SELECT (('%1$s+00'::timestamptz - interval '1 microsecond')::jtimestamptz::jdate)::text$$, '1402-12-29'),
  (16, 'jtimestamptz -> jdate at the last microsecond of the day',
       $$SELECT (('%1$s+00'::timestamptz + interval '1 day' - interval '1 microsecond')::jtimestamptz::jdate)::text$$, '1403-01-01'),
  (17, 'function form jtimestamptz(jtimestamp)',
       $$SELECT jtimestamptz('1403-01-01 00:00:00'::jtimestamp)::text$$, '1403-01-01 00:00:00%1$s'),
  (18, 'function form jtimestamp(jtimestamptz)',
       $$SELECT jtimestamp('%1$s+00'::timestamptz::jtimestamptz)::text$$, '1403-01-01 00:00:00'),
  -- 1403 has 366 days; every one of them must round-trip in every zone
  (19, 'sweep 1403: jdate -> jtimestamp -> jdate, mismatches',
       $$SELECT count(*) FILTER (WHERE d::jtimestamp::jdate <> d)::text FROM (SELECT jdate '1403-01-01' + g AS d FROM generate_series(0, 365) g) s$$, '0'),
  (20, 'sweep 1403: jdate -> jtimestamptz -> jdate, mismatches',
       $$SELECT count(*) FILTER (WHERE d::jtimestamptz::jdate <> d)::text FROM (SELECT jdate '1403-01-01' + g AS d FROM generate_series(0, 365) g) s$$, '0'),
  (21, 'sweep 1403: jdate -> jtimestamp -> timestamp vs jdate -> date -> timestamp, mismatches',
       $$SELECT count(*) FILTER (WHERE d::jtimestamp::timestamp <> d::date::timestamp)::text FROM (SELECT jdate '1403-01-01' + g AS d FROM generate_series(0, 365) g) s$$, '0'),
  (22, 'sweep 1403: jdate -> jtimestamptz -> timestamptz vs jdate -> date -> timestamptz, mismatches',
       $$SELECT count(*) FILTER (WHERE d::jtimestamptz::timestamptz <> d::date::timestamptz)::text FROM (SELECT jdate '1403-01-01' + g AS d FROM generate_series(0, 365) g) s$$, '0'),
  (23, 'sweep 1403: jtimestamp -> jtimestamptz -> jtimestamp at 12:34:56.789, mismatches',
       $$SELECT count(*) FILTER (WHERE jtimestamp_send(t::jtimestamptz::jtimestamp) <> jtimestamp_send(t))::text FROM (SELECT ((date '2024-03-20' + g) + time '12:34:56.789')::jtimestamp AS t FROM generate_series(0, 365) g) s$$, '0');

-- the ok column is the comparison with what the zone has to give
SELECT z.zone, c.n, c.what, r.got,
       r.got = format(c.expect, z.off, z.utc) AS ok
FROM nz_zone z CROSS JOIN nz_check c,
     LATERAL (SELECT pg_temp.eval(z.zone, format(c.expr, z.utc)) AS got) r
ORDER BY z.id, c.n;
SET timezone = 'UTC';

-- ---------------------------------------------------------------------
-- edges of the range, without a zone: jtimestamp, and the core types
-- ---------------------------------------------------------------------
-- the Jalali range is -0061-01-01 .. 3177-12-29, Gregorian 0560-03-20 ..
-- 3799-03-19
SELECT '-0061-01-01 00:00:00'::jtimestamp::timestamp AS first_start,
       '3177-12-29 23:59:59.999999'::jtimestamp::timestamp AS last_microsecond;
SELECT timestamp '0560-03-20 00:00:00'::jtimestamp AS first_valid,
       timestamp '3799-03-19 23:59:59.999999'::jtimestamp AS last_valid;
SELECT date '0560-03-20'::jtimestamp AS first_date, date '3799-03-19'::jtimestamp AS last_date;
SELECT '-0061-01-01'::jdate::jtimestamp AS first_jdate, '3177-12-29'::jdate::jtimestamp AS last_jdate;
SELECT '-0061-01-01 00:00:00'::jtimestamp::jdate AS first_back,
       '3177-12-29 23:59:59.999999'::jtimestamp::jdate AS last_back;
\set VERBOSITY sqlstate
SELECT timestamp '0560-03-19 23:59:59.999999'::jtimestamp;   -- one microsecond below
SELECT timestamp '3799-03-20 00:00:00'::jtimestamp;          -- the first instant above
SELECT timestamp '0001-01-01 00:00:00'::jtimestamp;
SELECT timestamp '4714-11-24 00:00:00 BC'::jtimestamp;       -- core's own minimum
SELECT timestamp '294276-12-31 23:59:59.999999'::jtimestamp; -- core's own maximum
SELECT date '0560-03-19'::jtimestamp;
SELECT date '3799-03-20'::jtimestamp;
SELECT date '4714-11-24 BC'::jtimestamp;
SELECT date '5874897-12-31'::jtimestamp;                     -- beyond timestamp's range: core's own error
\set VERBOSITY default

-- ---------------------------------------------------------------------
-- edges of the range for jtimestamptz: the safe range, in fixed-offset zones
--
-- The valid instants are 0560-03-20 16:00:00+00 (the first day's start plus
-- 16 hours) up to, not including, 3799-03-19 08:00:00+00 (the last day's end
-- minus 16 hours). Fixed POSIX offsets are used, so no tzdata history matters:
-- <+14>-14 is Pacific/Kiritimati's offset, <-11>+11 Pacific/Pago_Pago's.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE edge (n int, zone text, what text, q text, expect text);
INSERT INTO edge (n, zone, what, q, expect) VALUES
  -- UTC: the first day starts 16 hours before the first valid instant
  (1,  'UTC', 'jdate first day',        $$SELECT ('-0061-01-01'::jdate::jtimestamptz)::text$$, 'ERR 22008'),
  (2,  'UTC', 'jdate second day',       $$SELECT ('-0061-01-02'::jdate::jtimestamptz)::text$$, '-0061-01-02 00:00:00+00'),
  (3,  'UTC', 'jdate last but one day', $$SELECT ('3177-12-28'::jdate::jtimestamptz)::text$$, '3177-12-28 00:00:00+00'),
  (4,  'UTC', 'jdate last day',         $$SELECT ('3177-12-29'::jdate::jtimestamptz)::text$$, '3177-12-29 00:00:00+00'),
  (5,  'UTC', 'date first day',         $$SELECT (date '0560-03-20'::jtimestamptz)::text$$, 'ERR 22008'),
  (6,  'UTC', 'date second day',        $$SELECT (date '0560-03-21'::jtimestamptz)::text$$, '-0061-01-02 00:00:00+00'),
  (7,  'UTC', 'date last day',          $$SELECT (date '3799-03-19'::jtimestamptz)::text$$, '3177-12-29 00:00:00+00'),
  (8,  'UTC', 'date after the last',    $$SELECT (date '3799-03-20'::jtimestamptz)::text$$, 'ERR 22008'),
  (9,  'UTC', 'jtimestamp first start', $$SELECT ('-0061-01-01 00:00:00'::jtimestamp::jtimestamptz)::text$$, 'ERR 22008'),
  (10, 'UTC', 'jtimestamp 15:59:59.999999 on the first day',
              $$SELECT ('-0061-01-01 15:59:59.999999'::jtimestamp::jtimestamptz)::text$$, 'ERR 22008'),
  (11, 'UTC', 'jtimestamp 16:00:00 on the first day',
              $$SELECT ('-0061-01-01 16:00:00'::jtimestamp::jtimestamptz)::text$$, '-0061-01-01 16:00:00+00'),
  (12, 'UTC', 'jtimestamp 07:59:59.999999 on the last day',
              $$SELECT ('3177-12-29 07:59:59.999999'::jtimestamp::jtimestamptz)::text$$, '3177-12-29 07:59:59.999999+00'),
  (13, 'UTC', 'jtimestamp 08:00:00 on the last day',
              $$SELECT ('3177-12-29 08:00:00'::jtimestamp::jtimestamptz)::text$$, 'ERR 22008'),
  (14, 'UTC', 'jtimestamp last microsecond',
              $$SELECT ('3177-12-29 23:59:59.999999'::jtimestamp::jtimestamptz)::text$$, 'ERR 22008'),
  (15, 'UTC', 'timestamptz first valid',
              $$SELECT ('0560-03-20 16:00:00+00'::timestamptz::jtimestamptz)::text$$, '-0061-01-01 16:00:00+00'),
  (16, 'UTC', 'timestamptz one microsecond below',
              $$SELECT ('0560-03-20 15:59:59.999999+00'::timestamptz::jtimestamptz)::text$$, 'ERR 22008'),
  (17, 'UTC', 'timestamptz last valid',
              $$SELECT ('3799-03-19 07:59:59.999999+00'::timestamptz::jtimestamptz)::text$$, '3177-12-29 07:59:59.999999+00'),
  (18, 'UTC', 'timestamptz first above',
              $$SELECT ('3799-03-19 08:00:00+00'::timestamptz::jtimestamptz)::text$$, 'ERR 22008'),
  (19, 'UTC', 'timestamptz core minimum',
              $$SELECT ('4714-11-24 00:00:00+00 BC'::timestamptz::jtimestamptz)::text$$, 'ERR 22008'),
  -- jtimestamptz back to jtimestamp and jdate at the valid edges: never an error
  (20, 'UTC', 'first valid -> jtimestamp',
              $$SELECT ('0560-03-20 16:00:00+00'::timestamptz::jtimestamptz::jtimestamp)::text$$, '-0061-01-01 16:00:00'),
  (21, 'UTC', 'last valid -> jtimestamp',
              $$SELECT ('3799-03-19 07:59:59.999999+00'::timestamptz::jtimestamptz::jtimestamp)::text$$, '3177-12-29 07:59:59.999999'),
  (22, 'UTC', 'first valid -> jdate',
              $$SELECT ('0560-03-20 16:00:00+00'::timestamptz::jtimestamptz::jdate)::text$$, '-0061-01-01'),
  (23, 'UTC', 'last valid -> jdate',
              $$SELECT ('3799-03-19 07:59:59.999999+00'::timestamptz::jtimestamptz::jdate)::text$$, '3177-12-29'),

  -- <+14>-14: local midnight is 14 hours before the UTC midnight
  (31, '<+14>-14', 'jdate first day',        $$SELECT ('-0061-01-01'::jdate::jtimestamptz)::text$$, 'ERR 22008'),
  (32, '<+14>-14', 'jdate second day',       $$SELECT ('-0061-01-02'::jdate::jtimestamptz)::text$$, 'ERR 22008'),
  (33, '<+14>-14', 'jdate third day',        $$SELECT ('-0061-01-03'::jdate::jtimestamptz)::text$$, '-0061-01-03 00:00:00+14'),
  (34, '<+14>-14', 'jdate last day',         $$SELECT ('3177-12-29'::jdate::jtimestamptz)::text$$, '3177-12-29 00:00:00+14'),
  (35, '<+14>-14', 'jtimestamp 05:59:59.999999 on the second day',
                   $$SELECT ('-0061-01-02 05:59:59.999999'::jtimestamp::jtimestamptz)::text$$, 'ERR 22008'),
  (36, '<+14>-14', 'jtimestamp 06:00:00 on the second day',
                   $$SELECT ('-0061-01-02 06:00:00'::jtimestamp::jtimestamptz)::text$$, '-0061-01-02 06:00:00+14'),
  (37, '<+14>-14', 'jtimestamp 21:59:59.999999 on the last day',
                   $$SELECT ('3177-12-29 21:59:59.999999'::jtimestamp::jtimestamptz)::text$$, '3177-12-29 21:59:59.999999+14'),
  (38, '<+14>-14', 'jtimestamp 22:00:00 on the last day',
                   $$SELECT ('3177-12-29 22:00:00'::jtimestamp::jtimestamptz)::text$$, 'ERR 22008'),
  (39, '<+14>-14', 'first valid -> jtimestamp',
                   $$SELECT ('0560-03-20 16:00:00+00'::timestamptz::jtimestamptz::jtimestamp)::text$$, '-0061-01-02 06:00:00'),
  (40, '<+14>-14', 'last valid -> jdate',
                   $$SELECT ('3799-03-19 07:59:59.999999+00'::timestamptz::jtimestamptz::jdate)::text$$, '3177-12-29'),

  -- <-11>+11: local midnight is 11 hours after the UTC midnight
  (51, '<-11>+11', 'jdate first day',        $$SELECT ('-0061-01-01'::jdate::jtimestamptz)::text$$, 'ERR 22008'),
  (52, '<-11>+11', 'jdate second day',       $$SELECT ('-0061-01-02'::jdate::jtimestamptz)::text$$, '-0061-01-02 00:00:00-11'),
  (53, '<-11>+11', 'jdate last but one day', $$SELECT ('3177-12-28'::jdate::jtimestamptz)::text$$, '3177-12-28 00:00:00-11'),
  (54, '<-11>+11', 'jdate last day',         $$SELECT ('3177-12-29'::jdate::jtimestamptz)::text$$, 'ERR 22008'),
  (55, '<-11>+11', 'date last day',          $$SELECT (date '3799-03-19'::jtimestamptz)::text$$, 'ERR 22008'),
  (56, '<-11>+11', 'jtimestamp 04:59:59.999999 on the first day',
                   $$SELECT ('-0061-01-01 04:59:59.999999'::jtimestamp::jtimestamptz)::text$$, 'ERR 22008'),
  (57, '<-11>+11', 'jtimestamp 05:00:00 on the first day',
                   $$SELECT ('-0061-01-01 05:00:00'::jtimestamp::jtimestamptz)::text$$, '-0061-01-01 05:00:00-11'),
  (58, '<-11>+11', 'jtimestamp 20:59:59.999999 on the last but one day',
                   $$SELECT ('3177-12-28 20:59:59.999999'::jtimestamp::jtimestamptz)::text$$, '3177-12-28 20:59:59.999999-11'),
  (59, '<-11>+11', 'jtimestamp 21:00:00 on the last but one day',
                   $$SELECT ('3177-12-28 21:00:00'::jtimestamp::jtimestamptz)::text$$, 'ERR 22008'),
  (60, '<-11>+11', 'first valid -> jtimestamp',
                   $$SELECT ('0560-03-20 16:00:00+00'::timestamptz::jtimestamptz::jtimestamp)::text$$, '-0061-01-01 05:00:00'),

  -- the extreme offsets PostgreSQL accepts, +/-15:59: a valid instant is
  -- always on a Jalali day, so jtimestamp and jdate never fail
  (71, '<+15:59>-15:59', 'first valid -> jtimestamp',
                   $$SELECT ('0560-03-20 16:00:00+00'::timestamptz::jtimestamptz::jtimestamp)::text$$, '-0061-01-02 07:59:00'),
  (72, '<+15:59>-15:59', 'first valid -> jdate',
                   $$SELECT ('0560-03-20 16:00:00+00'::timestamptz::jtimestamptz::jdate)::text$$, '-0061-01-02'),
  (73, '<+15:59>-15:59', 'last valid -> jtimestamp',
                   $$SELECT ('3799-03-19 07:59:59.999999+00'::timestamptz::jtimestamptz::jtimestamp)::text$$, '3177-12-29 23:58:59.999999'),
  (74, '<+15:59>-15:59', 'last valid -> jdate',
                   $$SELECT ('3799-03-19 07:59:59.999999+00'::timestamptz::jtimestamptz::jdate)::text$$, '3177-12-29'),
  (75, '<-15:59>+15:59', 'first valid -> jtimestamp',
                   $$SELECT ('0560-03-20 16:00:00+00'::timestamptz::jtimestamptz::jtimestamp)::text$$, '-0061-01-01 00:01:00'),
  (76, '<-15:59>+15:59', 'first valid -> jdate',
                   $$SELECT ('0560-03-20 16:00:00+00'::timestamptz::jtimestamptz::jdate)::text$$, '-0061-01-01'),
  (77, '<-15:59>+15:59', 'last valid -> jtimestamp',
                   $$SELECT ('3799-03-19 07:59:59.999999+00'::timestamptz::jtimestamptz::jtimestamp)::text$$, '3177-12-28 16:00:59.999999'),
  (78, '<-15:59>+15:59', 'last valid -> jdate',
                   $$SELECT ('3799-03-19 07:59:59.999999+00'::timestamptz::jtimestamptz::jdate)::text$$, '3177-12-28');

SELECT e.zone, e.what, r.got, r.got = e.expect AS ok
FROM edge e, LATERAL (SELECT pg_temp.eval(e.zone, e.q) AS got) r
ORDER BY e.n;
SET timezone = 'UTC';

-- ---------------------------------------------------------------------
-- infinities through every cast
-- ---------------------------------------------------------------------
SELECT label, pos, neg FROM (VALUES
  (1,  'timestamp -> jtimestamp',      ('infinity'::timestamp::jtimestamp)::text,        ('-infinity'::timestamp::jtimestamp)::text),
  (2,  'jtimestamp -> timestamp',      ('infinity'::jtimestamp::timestamp)::text,        ('-infinity'::jtimestamp::timestamp)::text),
  (3,  'timestamptz -> jtimestamptz',  ('infinity'::timestamptz::jtimestamptz)::text,    ('-infinity'::timestamptz::jtimestamptz)::text),
  (4,  'jtimestamptz -> timestamptz',  ('infinity'::jtimestamptz::timestamptz)::text,    ('-infinity'::jtimestamptz::timestamptz)::text),
  (5,  'jtimestamp -> jtimestamptz',   ('infinity'::jtimestamp::jtimestamptz)::text,     ('-infinity'::jtimestamp::jtimestamptz)::text),
  (6,  'jtimestamptz -> jtimestamp',   ('infinity'::jtimestamptz::jtimestamp)::text,     ('-infinity'::jtimestamptz::jtimestamp)::text),
  (7,  'date -> jtimestamp',           ('infinity'::date::jtimestamp)::text,             ('-infinity'::date::jtimestamp)::text),
  (8,  'date -> jtimestamptz',         ('infinity'::date::jtimestamptz)::text,           ('-infinity'::date::jtimestamptz)::text),
  (9,  'jdate -> jtimestamp',          ('infinity'::jdate::jtimestamp)::text,            ('-infinity'::jdate::jtimestamp)::text),
  (10, 'jdate -> jtimestamptz',        ('infinity'::jdate::jtimestamptz)::text,          ('-infinity'::jdate::jtimestamptz)::text),
  (11, 'jtimestamp -> jdate',          ('infinity'::jtimestamp::jdate)::text,            ('-infinity'::jtimestamp::jdate)::text),
  (12, 'jtimestamptz -> jdate',        ('infinity'::jtimestamptz::jdate)::text,          ('-infinity'::jtimestamptz::jdate)::text),
  (13, 'jtimestamp(0)',                ('infinity'::jtimestamp(0))::text,                ('-infinity'::jtimestamp(0))::text),
  (14, 'jtimestamptz(0)',              ('infinity'::jtimestamptz(0))::text,              ('-infinity'::jtimestamptz(0))::text)
) v(n, label, pos, neg) ORDER BY n;
-- the same in a zone with an offset: the infinities do not move
SET timezone = 'Pacific/Kiritimati';
SELECT ('infinity'::date::jtimestamptz)::text AS date_inf, ('-infinity'::jtimestamptz::jdate)::text AS neg_to_jdate,
       ('infinity'::jtimestamptz::jtimestamp)::text AS tz_to_ts;
SET timezone = 'UTC';

-- ---------------------------------------------------------------------
-- typmod (scale) casts: rounding, and the range checked after rounding
-- ---------------------------------------------------------------------
SELECT '1403-01-01 12:34:56.789'::jtimestamp(0) AS p0,
       '1403-01-01 12:34:56.789'::jtimestamp(1) AS p1,
       '1403-01-01 12:34:56.789'::jtimestamp(2) AS p2,
       '1403-01-01 12:34:56.789'::jtimestamp(3) AS p3,
       '1403-01-01 12:34:56.789012'::jtimestamp(6) AS p6;
SELECT '1403-01-01 12:34:56.789+00'::jtimestamptz(0) AS p0,
       '1403-01-01 12:34:56.789+00'::jtimestamptz(1) AS p1,
       '1403-01-01 12:34:56.789+00'::jtimestamptz(2) AS p2,
       '1403-01-01 12:34:56.789+00'::jtimestamptz(3) AS p3,
       '1403-01-01 12:34:56.789012+00'::jtimestamptz(6) AS p6;
-- rounding carries into the next minute, day and year
SELECT '1403-12-30 23:59:59.5'::jtimestamp(0) AS next_year,
       '1403-05-15 23:59:59.9996'::jtimestamp(3) AS next_day,
       '1403-05-15 12:59:59.5+00'::jtimestamptz(0) AS next_hour;
-- the explicit cast of a value that is not a literal, and the function form
SELECT j::jtimestamp(0) AS from_column, j::jtimestamp(1) AS one_digit
FROM (SELECT '1403-01-01 12:34:56.789'::jtimestamp AS j) s;
SELECT jtimestamp('1403-01-01 12:34:56.789'::jtimestamp, 0, true) AS function_form,
       jtimestamptz('1403-01-01 12:34:56.789+00'::jtimestamptz, 0, false) AS function_form_tz;
-- first valid value: rounding goes towards the day start, never below it
SELECT '-0061-01-01 00:00:00.4'::jtimestamp(0) AS first_down,
       '-0061-01-01 00:00:00.6'::jtimestamp(0) AS first_up,
       '-0061-01-01 00:00:00.5'::jtimestamp(0) AS first_half;
-- the last valid value survives its own precision, and nothing coarser
SELECT '3177-12-29 23:59:59.999999'::jtimestamp(6) AS last_p6,
       '3177-12-29 23:59:59.999499'::jtimestamp(3) AS last_rounds_down,
       '3177-12-29 07:59:59.999999+00'::jtimestamptz(6) AS tz_last_p6,
       '3177-12-29 07:59:59.4+00'::jtimestamptz(0) AS tz_last_down;
\set VERBOSITY sqlstate
SELECT '3177-12-29 23:59:59.999999'::jtimestamp(0);   -- 3178-01-01 00:00:00
SELECT '3177-12-29 23:59:59.999999'::jtimestamp(1);
SELECT '3177-12-29 23:59:59.999999'::jtimestamp(3);
SELECT '3177-12-29 23:59:59.999999'::jtimestamp(5);
SELECT '3177-12-29 23:59:59.9995'::jtimestamp(3);
SELECT '3177-12-29 07:59:59.999999+00'::jtimestamptz(0);   -- 08:00:00, the first instant above the safe range
SELECT '3177-12-29 07:59:59.999999+00'::jtimestamptz(3);
SELECT '3177-12-29 07:59:59.5+00'::jtimestamptz(0);
SELECT jtimestamp('3177-12-29 23:59:59.999999'::jtimestamp, 0, true);
SELECT jtimestamptz('3177-12-29 07:59:59.999999+00'::jtimestamptz, 0, false);
SELECT j::jtimestamp(0) FROM (SELECT '3177-12-29 23:59:59.999999'::jtimestamp AS j) s;
SELECT j::jtimestamptz(0) FROM (SELECT '3177-12-29 07:59:59.999999+00'::jtimestamptz AS j) s;
\set VERBOSITY default

-- ---------------------------------------------------------------------
-- INSERT and UPDATE: the assignment casts, and the column's typmod
-- ---------------------------------------------------------------------
CREATE TABLE jt_c_assign (
    id int GENERATED ALWAYS AS IDENTITY,
    j0 jtimestamp(0), j3 jtimestamp(3), z0 jtimestamptz(0), z3 jtimestamptz(3),
    j jtimestamp, z jtimestamptz, d jdate
);
-- literals take the column's typmod
INSERT INTO jt_c_assign (j0, j3, z0, z3)
VALUES ('1403-01-01 12:34:56.789', '1403-01-01 12:34:56.7896',
        '1403-01-01 12:34:56.789+00', '1403-01-01 12:34:56.7896+00');
-- core types in: timestamp -> jtimestamp(p), timestamptz -> jtimestamptz(p)
INSERT INTO jt_c_assign (j0, j3, z0, z3)
SELECT timestamp '2024-03-20 12:34:56.789', timestamp '2024-03-20 12:34:56.7896',
       timestamptz '2024-03-20 12:34:56.789+00', timestamptz '2024-03-20 12:34:56.7896+00';
-- jdate, date and the other timestamp type in
INSERT INTO jt_c_assign (j, z) SELECT jdate '1403-01-01', jdate '1403-01-01';
INSERT INTO jt_c_assign (j, z) SELECT date '2024-03-20', date '2024-03-20';
INSERT INTO jt_c_assign (z, j) SELECT jtimestamp '1403-01-01 12:00:00', jtimestamptz '1403-01-01 12:00:00+00';
-- and out: jtimestamp / jtimestamptz -> jdate, in the session zone
INSERT INTO jt_c_assign (d) SELECT jtimestamp '1403-01-01 23:59:59';
INSERT INTO jt_c_assign (d) SELECT jtimestamptz '1403-01-01 23:59:59+00';
SELECT id, j0, j3, z0, z3, j, z, d FROM jt_c_assign ORDER BY id;
-- UPDATE: the typmod of the target applies to a value of the same type
UPDATE jt_c_assign SET j0 = j3 WHERE id = 1;
UPDATE jt_c_assign SET z0 = z3 WHERE id = 1;
SELECT id, j0, j3, z0, z3 FROM jt_c_assign WHERE id = 1;
-- a jtimestamp(3) column read back into a jtimestamp(0): the explicit cast rounds
SELECT j3::jtimestamp(0) AS rounded FROM jt_c_assign WHERE id = 1;

\set VERBOSITY sqlstate
-- the edge rounds out of the range: the INSERT fails whole
INSERT INTO jt_c_assign (j0) VALUES ('3177-12-29 23:59:59.999999');
INSERT INTO jt_c_assign (j3) VALUES ('3177-12-29 23:59:59.9996');
INSERT INTO jt_c_assign (z0) VALUES ('3177-12-29 07:59:59.999999+00');
INSERT INTO jt_c_assign (j0) SELECT timestamp '3799-03-19 23:59:59.999999';
INSERT INTO jt_c_assign (z0) SELECT timestamptz '3799-03-19 07:59:59.999999+00';
-- a core value outside the Jalali range
INSERT INTO jt_c_assign (j) SELECT timestamp '0560-03-19 23:59:59.999999';
INSERT INTO jt_c_assign (j) SELECT date '3799-03-20';
INSERT INTO jt_c_assign (z) SELECT timestamptz '3799-03-19 08:00:00+00';
-- a jdate whose local midnight is outside the safe range, in a zone east of UTC
SET timezone = '<+14>-14';
INSERT INTO jt_c_assign (z) SELECT jdate '-0061-01-02';
INSERT INTO jt_c_assign (z) SELECT date '0560-03-21';
SET timezone = 'UTC';
\set VERBOSITY default
SELECT count(*) AS rows_after_the_failed_inserts FROM jt_c_assign;

-- arrays: the element cast, with and without typmod
SELECT ARRAY[timestamp '2024-03-20 12:00:00', timestamp '2024-03-21 00:00:00']::jtimestamp[] AS from_timestamp_array;
SELECT ARRAY[timestamptz '2024-03-20 12:00:00+00']::jtimestamptz[] AS from_timestamptz_array;
SELECT ARRAY['1403-01-01 12:34:56.789'::jtimestamp]::jtimestamp(0)[] AS rounded_array;
SELECT '{"1403-01-01 12:34:56.789"}'::jtimestamp(0)[] AS input_array_with_typmod;
\set VERBOSITY sqlstate
SELECT ARRAY['3177-12-29 23:59:59.999999'::jtimestamp]::jtimestamp(0)[];
SELECT ARRAY[timestamp '3799-03-20 00:00:00']::jtimestamp[];
\set VERBOSITY default

-- ---------------------------------------------------------------------
-- round trips through the core types: the same bits come back
-- ---------------------------------------------------------------------
CREATE TABLE jt_c_vals (j jtimestamp, z jtimestamptz);
INSERT INTO jt_c_vals (j) VALUES
    ('-infinity'), ('-0061-01-01 00:00:00'), ('0000-01-01 00:00:00'), ('1403-01-01 00:00:00'),
    ('1403-01-01 12:34:56.789012'), ('1403-12-29 23:59:59.999999'), ('3177-12-29 23:59:59.999999'),
    ('infinity');
INSERT INTO jt_c_vals (z) VALUES
    ('-infinity'), ('-0061-01-01 16:00:00+00'), ('0000-01-01 00:00:00+00'), ('1403-01-01 00:00:00+03:30'),
    ('1403-01-01 12:34:56.789012+00'), ('1403-12-29 23:59:59.999999-11'), ('3177-12-29 07:59:59.999999+00'),
    ('infinity');
-- jtimestamp -> timestamp -> jtimestamp, and jtimestamptz -> timestamptz -> jtimestamptz
SELECT count(j) AS jtimestamps, count(z) AS jtimestamptzs,
       count(*) FILTER (WHERE jtimestamp_send(j::timestamp::jtimestamp) <> jtimestamp_send(j)) AS jtimestamp_mismatches,
       count(*) FILTER (WHERE jtimestamptz_send(z::timestamptz::jtimestamptz) <> jtimestamptz_send(z)) AS jtimestamptz_mismatches
FROM jt_c_vals;
-- the Jalali value and the core value are the same bits: core's own send function agrees
SELECT count(*) FILTER (WHERE timestamp_send(j::timestamp) <> jtimestamp_send(j)) AS jtimestamp_send_mismatches,
       count(*) FILTER (WHERE timestamptz_send(z::timestamptz) <> jtimestamptz_send(z)) AS jtimestamptz_send_mismatches
FROM jt_c_vals;
-- core -> Jalali -> core
SELECT count(*) AS core_values,
       count(*) FILTER (WHERE t::jtimestamp::timestamp <> t) AS timestamp_mismatches
FROM (VALUES (timestamp '0560-03-20 00:00:00'), ('2024-03-20 00:00:00'), ('2024-03-20 12:34:56.789012'),
             ('3799-03-19 23:59:59.999999'), ('infinity'), ('-infinity')) v(t);
SELECT count(*) AS core_values,
       count(*) FILTER (WHERE t::jtimestamptz::timestamptz <> t) AS timestamptz_mismatches
FROM (VALUES (timestamptz '0560-03-20 16:00:00+00'), ('2024-03-19 20:30:00+00'), ('2024-03-20 12:34:56.789012+00'),
             ('3799-03-19 07:59:59.999999+00'), ('infinity'), ('-infinity')) v(t);
-- the day: jdate -> jtimestamp -> jdate, and the day of a core timestamp read through the types
SELECT count(*) AS days, count(*) FILTER (WHERE d::jtimestamp::jdate <> d) AS mismatches,
       count(*) FILTER (WHERE d::jtimestamp::timestamp::date::jdate <> d) AS through_core_mismatches
FROM (VALUES (jdate '-0061-01-01'), ('0000-01-01'), ('1402-12-29'), ('1403-01-01'), ('3177-12-29')) v(d);
-- ---------------------------------------------------------------------
-- what does not exist: no implicit cast, no cast to the core types by a chain
-- ---------------------------------------------------------------------
\set VERBOSITY sqlstate
-- no operators between a Jalali type and a core type (the Jalali types compare
-- with each other, see jt_crossops)
SELECT '1403-01-01'::jtimestamp = timestamp '2024-03-20';
SELECT timestamp '2024-03-20' = '1403-01-01'::jtimestamp;
SELECT '1403-01-01'::jtimestamptz = timestamptz '2024-03-20 00:00:00+00';
SELECT '1403-01-01'::jtimestamp = date '2024-03-20';
-- no function takes a jtimestamp where it wants a timestamp
SELECT date_trunc('day', '1403-01-01'::jtimestamp);
SELECT date_trunc('day', '1403-01-01 00:00:00+00'::jtimestamptz);
SELECT age('1403-01-01'::jtimestamp);
-- and the casts that are not defined directly
SELECT '1403-01-01'::jtimestamp::date;
SELECT '1403-01-01'::jtimestamp::timestamptz;
SELECT '1403-01-01 00:00:00+00'::jtimestamptz::timestamp;
SELECT '1403-01-01 00:00:00+00'::jtimestamptz::date;
SELECT '2024-03-20'::date::jtimestamp::timestamptz;
\set VERBOSITY default
-- through an explicit second step they do work
SELECT ('1403-01-01 00:00:00'::jtimestamp::timestamp)::date AS via_timestamp,
       ('1403-01-01 00:00:00+00'::jtimestamptz::timestamptz)::timestamp AS via_timestamptz;
-- jdate(timestamp) and jdate(timestamptz) still resolve, next to the new overloads
SELECT jdate(timestamp '2024-03-20 12:00:00') AS from_timestamp,
       jdate(timestamptz '2024-03-20 12:00:00+00') AS from_timestamptz,
       jdate('1403-01-01 12:00:00'::jtimestamp) AS from_jtimestamp,
       jdate('1403-01-01 12:00:00+00'::jtimestamptz) AS from_jtimestamptz;

-- ---------------------------------------------------------------------
-- clean up: extension_schema drops the extension, which needs no column of
-- its types left behind
-- ---------------------------------------------------------------------
DROP TABLE jt_c_assign, jt_c_vals;
