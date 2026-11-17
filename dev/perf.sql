-- Timing of jdate against native date, run by dev/perf-report.sh inside a
-- scratch database that already has the extension. Prints one row per
-- operation as   name|date_ms|jdate_ms|ratio   (empty fields when there is no
-- `date` equivalent). Each statement runs :reps times inside a DO block, timed
-- with clock_timestamp(); the median is reported.
\set ON_ERROR_STOP on
SET max_parallel_workers_per_gather = 0;
SET work_mem = '128MB';
SET jit = off;
-- psql does not substitute variables inside $$ bodies; pass the repeat count as a setting.
SELECT set_config('perf.reps', :'reps', false) \gset

CREATE TABLE perf_t AS
SELECT i AS id,
       date '1900-01-01' + ((i::bigint * 7919) % 60000)::int AS d
  FROM generate_series(1, :rows) i;
ALTER TABLE perf_t ADD COLUMN j jdate, ADD COLUMN dt text, ADD COLUMN jt text, ADD COLUMN ts timestamptz;
UPDATE perf_t SET j = d::jdate, dt = d::text, ts = d::timestamptz;
UPDATE perf_t SET jt = j::text;
VACUUM ANALYZE perf_t;

CREATE TEMP TABLE perf_ops (
    seq int, name text,
    date_sql text,     -- NULL: no date equivalent
    jdate_sql text,
    cleanup text);     -- run, untimed, after every repetition
CREATE TEMP TABLE perf_res (seq int, name text, date_ms numeric, jdate_ms numeric);

INSERT INTO perf_ops VALUES
 (1, 'text input',
  'SELECT count(dt::date) FROM perf_t',
  'SELECT count(jt::jdate) FROM perf_t', NULL),
 (2, 'text output',
  'SELECT sum(length(d::text)) FROM perf_t',
  'SELECT sum(length(j::text)) FROM perf_t', NULL),
 (3, '= filter (seq scan)',
  'SELECT count(*) FROM perf_t WHERE d = date ''1950-06-15''',
  'SELECT count(*) FROM perf_t WHERE j = ''1950-06-15''::date::jdate', NULL),
 (4, '< filter (seq scan)',
  'SELECT count(*) FROM perf_t WHERE d < date ''1950-06-15''',
  'SELECT count(*) FROM perf_t WHERE j < ''1950-06-15''::date::jdate', NULL),
 (5, 'sort',
  'SELECT d FROM perf_t ORDER BY d OFFSET ' || (:rows - 1) || ' LIMIT 1',
  'SELECT j FROM perf_t ORDER BY j OFFSET ' || (:rows - 1) || ' LIMIT 1', NULL),
 (6, 'hash aggregate',
  'SELECT count(*) FROM (SELECT d, count(*) FROM perf_t GROUP BY d) s',
  'SELECT count(*) FROM (SELECT j, count(*) FROM perf_t GROUP BY j) s', NULL),
 (7, '+ int',
  'SELECT count(d + (id % 100)) FROM perf_t',
  'SELECT count(j + (id % 100)) FROM perf_t', NULL),
 (8, 'EXTRACT(year)',
  'SELECT sum(extract(year FROM d)) FROM perf_t',
  'SELECT sum(extract(year FROM j)) FROM perf_t', NULL),
 (9, 'date_part / jdate_part (month)',
  'SELECT sum(date_part(''month'', d)) FROM perf_t',
  'SELECT sum(jdate_part(''month'', j)) FROM perf_t', NULL),
 (10, 'date_trunc / jdate_trunc (month)',
  'SELECT count(date_trunc(''month'', d)) FROM perf_t',
  'SELECT count(jdate_trunc(''month'', j)) FROM perf_t', NULL),
 (11, 'jdate_format (no date equivalent)',
  NULL,
  'SELECT sum(length(jdate_format(ts))) FROM perf_t', NULL),
 (12, 'btree build',
  'CREATE INDEX perf_d_idx ON perf_t (d)',
  'CREATE INDEX perf_j_idx ON perf_t (j)', 'DROP INDEX IF EXISTS perf_d_idx, perf_j_idx');

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

DO $$
DECLARE r perf_ops%ROWTYPE;
        reps int := current_setting('perf.reps')::int;
BEGIN
    FOR r IN SELECT * FROM perf_ops ORDER BY seq LOOP
        INSERT INTO perf_res VALUES (r.seq, r.name,
            CASE WHEN r.date_sql IS NULL THEN NULL
                 ELSE pg_temp.timed_median(r.date_sql, r.cleanup, reps) END,
            pg_temp.timed_median(r.jdate_sql, r.cleanup, reps));
    END LOOP;
END $$;

-- Index range scan: needs the indexes, so build them once, outside the timing.
CREATE INDEX perf_d_idx ON perf_t (d);
CREATE INDEX perf_j_idx ON perf_t (j);
ANALYZE perf_t;
DO $$
DECLARE reps int := current_setting('perf.reps')::int;
BEGIN
    INSERT INTO perf_res VALUES (13, 'btree range scan',
        pg_temp.timed_median('SELECT count(*) FROM perf_t WHERE d BETWEEN date ''1950-01-01'' AND date ''1952-09-27''', NULL, reps),
        pg_temp.timed_median('SELECT count(*) FROM perf_t WHERE j BETWEEN ''1950-01-01''::date::jdate AND ''1952-09-27''::date::jdate', NULL, reps));
END $$;

\pset format unaligned
\pset tuples_only on
\pset fieldsep '|'
SELECT name,
       coalesce(round(date_ms, 2)::text, ''),
       round(jdate_ms, 2),
       coalesce(round(jdate_ms / NULLIF(date_ms, 0), 2)::text, '')
  FROM perf_res ORDER BY seq;
