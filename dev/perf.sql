-- Timing of the jdate family against core, run by dev/perf-report.sh inside a
-- scratch database that already has the extension. Prints one row per
-- operation as   name|core_ms|j_ms|ratio   (empty core_ms and ratio when there
-- is no core equivalent). Each statement runs :reps times, timed with
-- clock_timestamp(); the median is reported.
--
-- Three groups of rows, in this order:
--   1. jdate against date (names without a prefix);
--   2. jtimestamp against timestamp, then jtimestamptz against timestamptz
--      (names "jtimestamp: ...", "jtimestamptz: ...");
--   3. the range-check paths (names "check: ..."): the statements whose cost the
--      range checks (jdate_common.h, section "Range checks") are part of. They
--      have no core equivalent and are never gated; they exist to be run against
--      a normal build and a build with the checks switched off, and compared.
--      Run only those with  JDATE_PERF_ONLY='^check: '.
--
-- Variables from dev/perf-report.sh: rows (table size), reps (repeats), only (a
-- regular expression on the row name: only those rows run; empty runs all) and
-- bindir (a directory the server can write, for the binary COPY rows).
\set ON_ERROR_STOP on
\if :{?only}
\else
  \set only ''
\endif
\if :{?bindir}
\else
  \set bindir /tmp
\endif
SET max_parallel_workers_per_gather = 0;
SET work_mem = '128MB';
SET jit = off;
SET client_min_messages = warning;   -- DROP INDEX IF EXISTS in the cleanups
-- A named zone with a history (the jtimestamptz rows read it), fixed so that the
-- numbers do not depend on the cluster's setting.
SET timezone = 'Asia/Tehran';
-- psql does not substitute variables inside $$ bodies; pass them as settings.
SELECT set_config('perf.reps', :'reps', false) AS perf_reps,
       set_config('perf.only', :'only', false) AS perf_only \gset

-- One row per value, spread over 60000 distinct days from 1900 on; the time of
-- day (with milliseconds) follows from the day, so the timestamp columns have
-- as many distinct values as the date column. The *t columns are the text of the
-- value (input rows), ep is the Unix epoch of tstz (to_jtimestamptz).
CREATE TABLE perf_t AS
WITH base AS (
    SELECT i AS id,
           date '1900-01-01' + ((i::bigint * 7919) % 60000)::int AS d
      FROM generate_series(1, :rows) i),
stamped AS (
    SELECT id, d,
           d::timestamp
             + ((d - date '1900-01-01') % 86400) * interval '1 second'
             + ((d - date '1900-01-01') % 1000) * interval '1 millisecond' AS tsn
      FROM base),
wide AS (
    SELECT id, d, d::jdate AS j, d::timestamptz AS ts,
           tsn, tsn::jtimestamp AS jtsn,
           tsn::timestamptz AS tstz, tsn::timestamptz::jtimestamptz AS jtstz
      FROM stamped)
SELECT id, d, j, d::text AS dt, j::text AS jt, ts,
       tsn, jtsn, tstz, jtstz,
       tsn::text AS tsnt, jtsn::text AS jtsnt, tstz::text AS tstzt, jtstz::text AS jtstzt,
       extract(epoch FROM tstz)::float8 AS ep
  FROM wide;
VACUUM ANALYZE perf_t;

-- Binary COPY files for the recv rows: written once, outside the timing, by the
-- server (so the server must be able to write :bindir; perf-report.sh makes one).
\set f_jdate :bindir/jdate.bin
\set f_jtimestamp :bindir/jtimestamp.bin
\set f_jtimestamptz :bindir/jtimestamptz.bin
CREATE TEMP TABLE perf_bin_jdate (v jdate);
CREATE TEMP TABLE perf_bin_jtimestamp (v jtimestamp);
CREATE TEMP TABLE perf_bin_jtimestamptz (v jtimestamptz);
COPY perf_t (j) TO :'f_jdate' WITH (FORMAT binary);
COPY perf_t (jtsn) TO :'f_jtimestamp' WITH (FORMAT binary);
COPY perf_t (jtstz) TO :'f_jtimestamptz' WITH (FORMAT binary);

CREATE TEMP TABLE perf_ops (
    seq int GENERATED ALWAYS AS IDENTITY,
    phase int,         -- 1: timed first; 2: needs the btree indexes, timed after they exist
    name text,
    core_sql text,     -- NULL: no core equivalent
    j_sql text,
    cleanup text);     -- run, untimed, after every repetition
CREATE TEMP TABLE perf_res (seq int, name text, core_ms numeric, j_ms numeric);

-- Group 1: jdate against date.
INSERT INTO perf_ops (phase, name, core_sql, j_sql, cleanup) VALUES
 (1, 'text input',
  'SELECT count(dt::date) FROM perf_t',
  'SELECT count(jt::jdate) FROM perf_t', NULL),
 (1, 'text output',
  'SELECT sum(length(d::text)) FROM perf_t',
  'SELECT sum(length(j::text)) FROM perf_t', NULL),
 (1, '= filter (seq scan)',
  'SELECT count(*) FROM perf_t WHERE d = date ''1950-06-15''',
  'SELECT count(*) FROM perf_t WHERE j = ''1950-06-15''::date::jdate', NULL),
 (1, '< filter (seq scan)',
  'SELECT count(*) FROM perf_t WHERE d < date ''1950-06-15''',
  'SELECT count(*) FROM perf_t WHERE j < ''1950-06-15''::date::jdate', NULL),
 (1, 'sort',
  'SELECT d FROM perf_t ORDER BY d OFFSET ' || (:rows - 1) || ' LIMIT 1',
  'SELECT j FROM perf_t ORDER BY j OFFSET ' || (:rows - 1) || ' LIMIT 1', NULL),
 (1, 'hash aggregate',
  'SELECT count(*) FROM (SELECT d, count(*) FROM perf_t GROUP BY d) s',
  'SELECT count(*) FROM (SELECT j, count(*) FROM perf_t GROUP BY j) s', NULL),
 (1, '+ int',
  'SELECT count(d + (id % 100)) FROM perf_t',
  'SELECT count(j + (id % 100)) FROM perf_t', NULL),
 (1, 'EXTRACT(year)',
  'SELECT sum(extract(year FROM d)) FROM perf_t',
  'SELECT sum(extract(year FROM j)) FROM perf_t', NULL),
 (1, 'date_part / jdate_part (month)',
  'SELECT sum(date_part(''month'', d)) FROM perf_t',
  'SELECT sum(jdate_part(''month'', j)) FROM perf_t', NULL),
 (1, 'date_trunc / jdate_trunc (month)',
  'SELECT count(date_trunc(''month'', d)) FROM perf_t',
  'SELECT count(jdate_trunc(''month'', j)) FROM perf_t', NULL),
 (1, 'jdate_format (no date equivalent)',
  NULL,
  'SELECT sum(length(jdate_format(ts))) FROM perf_t', NULL),
 (1, 'btree build',
  'CREATE INDEX perf_d_idx ON perf_t (d)',
  'CREATE INDEX perf_j_idx ON perf_t (j)', 'DROP INDEX IF EXISTS perf_d_idx, perf_j_idx'),
 (2, 'btree range scan',
  'SELECT count(*) FROM perf_t WHERE d BETWEEN date ''1950-01-01'' AND date ''1952-09-27''',
  'SELECT count(*) FROM perf_t WHERE j BETWEEN ''1950-01-01''::date::jdate AND ''1952-09-27''::date::jdate', NULL);

-- Group 2: the timestamp types against their core types. The statements are
-- templates, expanded with format() for each pair; the arguments are
--   %1 core column   %2 j column   %3 core text column   %4 j text column
--   %5 core type     %6 j type     %7 last row offset
CREATE TEMP TABLE perf_pairs (ord int, c text, j text, ct text, jt text, cty text, jty text);
INSERT INTO perf_pairs VALUES
 (1, 'tsn',  'jtsn',  'tsnt',  'jtsnt',  'timestamp',   'jtimestamp'),
 (2, 'tstz', 'jtstz', 'tstzt', 'jtstzt', 'timestamptz', 'jtimestamptz');

CREATE TEMP TABLE perf_tmpl (ord int, phase int, name text, core_sql text, j_sql text, cleanup text);
INSERT INTO perf_tmpl VALUES
 (1, 1, '%6$s: text input',
  'SELECT count(%3$s::%5$s) FROM perf_t',
  'SELECT count(%4$s::%6$s) FROM perf_t', NULL),
 (2, 1, '%6$s: text output',
  'SELECT sum(length(%1$s::text)) FROM perf_t',
  'SELECT sum(length(%2$s::text)) FROM perf_t', NULL),
 (3, 1, '%6$s: = filter (seq scan)',
  'SELECT count(*) FROM perf_t WHERE %1$s = ''1950-06-15 12:00:00''::%5$s',
  'SELECT count(*) FROM perf_t WHERE %2$s = ''1950-06-15 12:00:00''::%5$s::%6$s', NULL),
 (4, 1, '%6$s: < filter (seq scan)',
  'SELECT count(*) FROM perf_t WHERE %1$s < ''1950-06-15 12:00:00''::%5$s',
  'SELECT count(*) FROM perf_t WHERE %2$s < ''1950-06-15 12:00:00''::%5$s::%6$s', NULL),
 (5, 1, '%6$s: sort',
  'SELECT %1$s FROM perf_t ORDER BY %1$s OFFSET %7$s LIMIT 1',
  'SELECT %2$s FROM perf_t ORDER BY %2$s OFFSET %7$s LIMIT 1', NULL),
 (6, 1, '%6$s: hash aggregate',
  'SELECT count(*) FROM (SELECT %1$s, count(*) FROM perf_t GROUP BY %1$s) s',
  'SELECT count(*) FROM (SELECT %2$s, count(*) FROM perf_t GROUP BY %2$s) s', NULL),
 (7, 1, '%6$s: btree build',
  'CREATE INDEX perf_%1$s_idx ON perf_t (%1$s)',
  'CREATE INDEX perf_%2$s_idx ON perf_t (%2$s)',
  'DROP INDEX IF EXISTS perf_%1$s_idx, perf_%2$s_idx'),
 (8, 2, '%6$s: btree range scan',
  'SELECT count(*) FROM perf_t WHERE %1$s BETWEEN ''1950-01-01''::%5$s AND ''1952-09-27''::%5$s',
  'SELECT count(*) FROM perf_t WHERE %2$s BETWEEN ''1950-01-01''::%5$s::%6$s AND ''1952-09-27''::%5$s::%6$s', NULL),
 (9, 1, '%6$s: + interval (1 day 02:00)',
  'SELECT count(%1$s + interval ''1 day 02:00'') FROM perf_t',
  'SELECT count(%2$s + interval ''1 day 02:00'') FROM perf_t', NULL),
 (10, 1, '%6$s: + interval (1 month)',
  'SELECT count(%1$s + interval ''1 month'') FROM perf_t',
  'SELECT count(%2$s + interval ''1 month'') FROM perf_t', NULL),
 (11, 1, '%6$s: EXTRACT(year)',
  'SELECT sum(extract(year FROM %1$s)) FROM perf_t',
  'SELECT sum(extract(year FROM %2$s)) FROM perf_t', NULL),
 (12, 1, '%6$s: date_trunc / jdate_trunc (month)',
  'SELECT count(date_trunc(''month'', %1$s)) FROM perf_t',
  'SELECT count(jdate_trunc(''month'', %2$s)) FROM perf_t', NULL),
 (13, 1, '%6$s: jday_format (no core equivalent)',
  NULL,
  'SELECT sum(length(jday_format(%2$s))) FROM perf_t', NULL);

INSERT INTO perf_ops (phase, name, core_sql, j_sql, cleanup)
SELECT t.phase,
       format(t.name, p.c, p.j, p.ct, p.jt, p.cty, p.jty),
       format(t.core_sql, p.c, p.j, p.ct, p.jt, p.cty, p.jty, (:rows - 1)::text),
       format(t.j_sql, p.c, p.j, p.ct, p.jt, p.cty, p.jty, (:rows - 1)::text),
       format(t.cleanup, p.c, p.j, p.ct, p.jt, p.cty, p.jty)
  FROM perf_pairs p CROSS JOIN perf_tmpl t
 ORDER BY p.ord, t.ord;

-- Group 3: the range-check paths. Every row is a statement over all :rows rows
-- whose per-row cost includes at least one range check, none has a core
-- equivalent. Rows named "(no check)" go through no check at all: they are the
-- noise floor of an on/off comparison.
INSERT INTO perf_ops (phase, name, j_sql) VALUES
 (1, 'check: jdate text input (no check)',
  'SELECT count(jt::jdate) FROM perf_t'),
 (1, 'check: jtimestamp text input',
  'SELECT count(jtsnt::jtimestamp) FROM perf_t'),
 (1, 'check: jtimestamptz text input',
  'SELECT count(jtstzt::jtimestamptz) FROM perf_t'),
 (1, 'check: jdate recv (COPY BINARY)',
  format('COPY perf_bin_jdate FROM %L WITH (FORMAT binary) WHERE false', :'f_jdate')),
 (1, 'check: jtimestamp recv (COPY BINARY)',
  format('COPY perf_bin_jtimestamp FROM %L WITH (FORMAT binary) WHERE false', :'f_jtimestamp')),
 (1, 'check: jtimestamptz recv (COPY BINARY)',
  format('COPY perf_bin_jtimestamptz FROM %L WITH (FORMAT binary) WHERE false', :'f_jtimestamptz')),
 -- casts into the types
 (1, 'check: cast timestamp -> jtimestamp',
  'SELECT count(tsn::jtimestamp) FROM perf_t'),
 (1, 'check: cast timestamptz -> jtimestamptz',
  'SELECT count(tstz::jtimestamptz) FROM perf_t'),
 (1, 'check: cast date -> jtimestamp',
  'SELECT count(d::jtimestamp) FROM perf_t'),
 (1, 'check: cast date -> jtimestamptz',
  'SELECT count(d::jtimestamptz) FROM perf_t'),
 (1, 'check: cast jdate -> jtimestamp (no check)',
  'SELECT count(j::jtimestamp) FROM perf_t'),
 (1, 'check: cast jdate -> jtimestamptz',
  'SELECT count(j::jtimestamptz) FROM perf_t'),
 (1, 'check: cast jtimestamp -> jtimestamptz',
  'SELECT count(jtsn::jtimestamptz) FROM perf_t'),
 (1, 'check: cast jtimestamptz -> jtimestamp',
  'SELECT count(jtstz::jtimestamp) FROM perf_t'),
 (1, 'check: cast jtimestamp -> jtimestamp(3) (scale)',
  'SELECT count(jtsn::jtimestamp(3)) FROM perf_t'),
 (1, 'check: cast jtimestamptz -> jtimestamptz(3) (scale)',
  'SELECT count(jtstz::jtimestamptz(3)) FROM perf_t'),
 -- casts into jdate, and out of the timestamp types into jdate
 (1, 'check: cast date -> jdate',
  'SELECT count(d::jdate) FROM perf_t'),
 (1, 'check: cast timestamp -> jdate',
  'SELECT count(tsn::jdate) FROM perf_t'),
 (1, 'check: cast timestamptz -> jdate',
  'SELECT count(tstz::jdate) FROM perf_t'),
 (1, 'check: cast jtimestamp -> jdate (no check)',
  'SELECT count(jtsn::jdate) FROM perf_t'),
 (1, 'check: cast jtimestamptz -> jdate (no check)',
  'SELECT count(jtstz::jdate) FROM perf_t'),
 -- + and - interval: without a month part (core's arithmetic, then the check)
 -- and with one (Jalali month arithmetic, local conversions, then the checks)
 (1, 'check: jtimestamp + interval (1 day 02:00)',
  'SELECT count(jtsn + interval ''1 day 02:00'') FROM perf_t'),
 (1, 'check: jtimestamp + interval (1 month)',
  'SELECT count(jtsn + interval ''1 month'') FROM perf_t'),
 (1, 'check: jtimestamp - interval (1 month 3 days)',
  'SELECT count(jtsn - interval ''1 month 3 days'') FROM perf_t'),
 (1, 'check: jtimestamptz + interval (1 day 02:00)',
  'SELECT count(jtstz + interval ''1 day 02:00'') FROM perf_t'),
 (1, 'check: jtimestamptz + interval (1 month)',
  'SELECT count(jtstz + interval ''1 month'') FROM perf_t'),
 (1, 'check: jtimestamptz - interval (1 month 3 days)',
  'SELECT count(jtstz - interval ''1 month 3 days'') FROM perf_t'),
 (1, 'check: jdate + interval (1 day 02:00)',
  'SELECT count(j + interval ''1 day 02:00'') FROM perf_t'),
 (1, 'check: jdate + interval (1 month)',
  'SELECT count(j + interval ''1 month'') FROM perf_t'),
 (1, 'check: jdate - interval (1 month 3 days)',
  'SELECT count(j - interval ''1 month 3 days'') FROM perf_t'),
 -- jdate_bin, AT TIME ZONE
 (1, 'check: jdate_bin (jtimestamp, 15 minutes)',
  'SELECT count(jdate_bin(interval ''15 minutes'', jtsn, ''1380-01-01''::jtimestamp)) FROM perf_t'),
 (1, 'check: jdate_bin (jtimestamptz, 15 minutes)',
  'SELECT count(jdate_bin(interval ''15 minutes'', jtstz, ''1380-01-01 00:00:00+00''::jtimestamptz)) FROM perf_t'),
 (1, 'check: jtimestamp AT TIME ZONE name',
  'SELECT count(jtsn AT TIME ZONE ''Asia/Tehran'') FROM perf_t'),
 (1, 'check: jtimestamptz AT TIME ZONE name',
  'SELECT count(jtstz AT TIME ZONE ''Asia/Tehran'') FROM perf_t'),
 (1, 'check: jtimestamp AT TIME ZONE interval',
  'SELECT count(jtsn AT TIME ZONE interval ''03:30'') FROM perf_t'),
 (1, 'check: jtimestamptz AT TIME ZONE interval',
  'SELECT count(jtstz AT TIME ZONE interval ''03:30'') FROM perf_t'),
 -- jgenerate_series: 20000 monthly (10000 daily) elements per call, :rows in all
 (1, 'check: jgenerate_series (jtimestamp, 1 month)',
  'SELECT count(*) FROM generate_series(1, greatest(1, ' || :rows || ' / 20000)) g, '
  || 'LATERAL jgenerate_series(''1000-01-01''::jtimestamp, ''2666-08-01''::jtimestamp, interval ''1 month'') s'),
 (1, 'check: jgenerate_series (jtimestamptz, 1 month)',
  'SELECT count(*) FROM generate_series(1, greatest(1, ' || :rows || ' / 20000)) g, '
  || 'LATERAL jgenerate_series(''1000-01-01''::jtimestamptz, ''2666-08-01''::jtimestamptz, interval ''1 month'') s'),
 (1, 'check: jgenerate_series (jdate, 1 day)',
  'SELECT count(*) FROM generate_series(1, greatest(1, ' || :rows || ' / 10000)) g, '
  || 'LATERAL jgenerate_series(''1300-01-01''::jdate, ''1300-01-01''::jdate + 9999, 1) s'),
 (1, 'check: to_jtimestamptz (epoch)',
  'SELECT count(to_jtimestamptz(ep)) FROM perf_t');

-- jdate_trunc of every unit (the Jalali ones and core's), for each type
INSERT INTO perf_ops (phase, name, j_sql)
SELECT 1, format('check: jdate_trunc(%L, %s)', u.unit, t.jty),
       format('SELECT count(jdate_trunc(%L, %s)) FROM perf_t', u.unit, t.col)
  FROM (VALUES (1, 'jtimestamp', 'jtsn'), (2, 'jtimestamptz', 'jtstz'), (3, 'jdate', 'j')) t(ord, jty, col)
  JOIN (VALUES (1, 'year'), (2, 'quarter'), (3, 'month'), (4, 'week'), (5, 'day'),
               (6, 'hour'), (7, 'minute'), (8, 'second'), (9, 'milliseconds'),
               (10, 'microseconds')) u(ord, unit)
    ON t.jty <> 'jdate' OR u.ord <= 5   -- jdate_trunc(jdate) knows no unit finer than a day
 ORDER BY t.ord, u.ord;
INSERT INTO perf_ops (phase, name, j_sql) VALUES
 (1, 'check: jdate_trunc(''month'', jtimestamptz, zone)',
  'SELECT count(jdate_trunc(''month'', jtstz, ''Asia/Tehran'')) FROM perf_t');

CREATE FUNCTION pg_temp.timed_median(q text, cleanup text, reps int) RETURNS numeric
LANGUAGE plpgsql AS $f$
DECLARE
    t0 timestamptz;
    ms numeric[] := '{}';
    i int;
    med numeric;
BEGIN
    FOR i IN 0..reps LOOP            -- iteration 0 is an untimed warm-up
        t0 := clock_timestamp();
        EXECUTE q;
        IF i > 0 THEN
            ms := ms || (extract(epoch FROM clock_timestamp() - t0) * 1000)::numeric;
        END IF;
        IF cleanup IS NOT NULL THEN EXECUTE cleanup; END IF;
    END LOOP;
    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY x)::numeric INTO med FROM unnest(ms) x;
    RETURN med;
END $f$;

-- Time the rows of one phase that the "only" filter selects.
CREATE FUNCTION pg_temp.run_phase(p int) RETURNS void
LANGUAGE plpgsql AS $f$
DECLARE r perf_ops%ROWTYPE;
        reps int := current_setting('perf.reps')::int;
BEGIN
    FOR r IN SELECT * FROM perf_ops
              WHERE phase = p AND name ~ current_setting('perf.only') ORDER BY seq LOOP
        INSERT INTO perf_res VALUES (r.seq, r.name,
            CASE WHEN r.core_sql IS NULL THEN NULL
                 ELSE pg_temp.timed_median(r.core_sql, r.cleanup, reps) END,
            pg_temp.timed_median(r.j_sql, r.cleanup, reps));
    END LOOP;
END $f$;

DO $$ BEGIN PERFORM pg_temp.run_phase(1); END $$;

-- Index range scans: they need the indexes, so build them once, outside the timing
-- (only when a range scan row is selected).
SELECT EXISTS (SELECT 1 FROM perf_ops WHERE phase = 2 AND name ~ :'only') AS need_idx \gset
\if :need_idx
CREATE INDEX perf_d_idx ON perf_t (d);
CREATE INDEX perf_j_idx ON perf_t (j);
CREATE INDEX perf_tsn_idx ON perf_t (tsn);
CREATE INDEX perf_jtsn_idx ON perf_t (jtsn);
CREATE INDEX perf_tstz_idx ON perf_t (tstz);
CREATE INDEX perf_jtstz_idx ON perf_t (jtstz);
ANALYZE perf_t;
DO $$ BEGIN PERFORM pg_temp.run_phase(2); END $$;
\endif

\pset format unaligned
\pset tuples_only on
\pset fieldsep '|'
SELECT name,
       coalesce(round(core_ms, 2)::text, ''),
       round(j_ms, 2),
       coalesce(round(j_ms / NULLIF(core_ms, 0), 2)::text, '')
  FROM perf_res ORDER BY seq;
