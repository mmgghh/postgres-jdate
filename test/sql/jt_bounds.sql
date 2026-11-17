-- jtimestamp and jtimestamptz: every producing path at both edges of both
-- types, in six time zones. A path is a way a value can come into existence:
-- text input, a cast from a core type, from jdate or from the other new type,
-- typmod rounding, to_jtimestamptz, an infinity. (The binary receive path has
-- its own file, jt_binary.)
--
-- The valid range of jtimestamp is -0061-01-01 00:00:00 ..
-- 3177-12-29 23:59:59.999999, Gregorian 0560-03-20 00:00:00 ..
-- 3799-03-19 23:59:59.999999. jtimestamptz keeps a safe range 16 hours
-- narrower at both ends (every stored instant must print in any zone up to
-- +/-15:59:59): the instants 0560-03-20 16:00:00+00 ..
-- 3799-03-19 07:59:59.999999+00, shown in Jalali as -0061-01-01 16:00:00+00 ..
-- 3177-12-29 07:59:59.999999+00.
--
-- Style of range.sql: every statement is `(expression) IS NOT NULL`, so a
-- failure comes from computing the value, never from displaying it, and
-- errors are SQLSTATEs only (22008 is shown as E, success as t).
--
-- Expectations never come from the code under test. Where the answer depends
-- on the zone (the local clock of an edge instant, the local midnight of an
-- edge day) the edge is built with core's own timestamptz arithmetic in that
-- zone, so the file does not depend on a zone's historic offsets (tzdata).
--
-- Only temporary tables are used, and none has a column of our types, so
-- extension_schema (which runs DROP EXTENSION) has nothing to clean up after.
SET DateStyle = 'ISO, YMD';
SET timezone = 'UTC';

-- evaluate a query in a zone, with a fresh parse: 'true', 'false' or ERR code
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

-- UTC, Asia/Tehran (+03:30, a historic +03:25:44), Pacific/Kiritimati (+14),
-- Pacific/Pago_Pago (-11) and the two longest POSIX offsets. A named zone
-- cannot give +/-15:59 and PostgreSQL refuses a session zone with seconds in
-- its offset, so those two are fixed POSIX zones (the sign is inverted).
CREATE TEMP TABLE bz (id int PRIMARY KEY, zone text);
INSERT INTO bz VALUES
  (1, 'UTC'), (2, 'Asia/Tehran'), (3, 'Pacific/Kiritimati'),
  (4, 'Pacific/Pago_Pago'), (5, '<+15:59>-15:59'), (6, '<-15:59>+15:59');

-- n: case number; show: print the pattern of results (only for cases whose
-- answer does not depend on tzdata); expr: the statement, which returns a
-- boolean; expect: a query that returns true when expr must succeed and
-- false when it must raise 22008.
CREATE TEMP TABLE bcase (n serial PRIMARY KEY, grp text, label text,
                         expr text, expect text, show boolean);

-- ---------------------------------------------------------------------
-- jtimestamp, paths that do not involve a zone: same answer in every zone
-- ---------------------------------------------------------------------
-- text input (Jalali): 'first valid' and 'last valid' are the edges
INSERT INTO bcase (grp, label, expr, expect, show)
SELECT 'ts', 'in: ' || e.label, format('SELECT (%L::jtimestamp) IS NOT NULL', e.v),
       'SELECT ' || e.ok, true
FROM (VALUES
  ('first valid',                        '-0061-01-01 00:00:00',        'true'),
  ('first valid, T separator',           '-0061-01-01T00:00:00',        'true'),
  ('below the first (-0062-12-29)',      '-0062-12-29 23:59:59.999999', 'false'),
  ('last valid',                         '3177-12-29 23:59:59.999999',  'true'),
  ('24:00:00 of the last day', '3177-12-29 24:00:00',     'false'),
  ('above the last (3178-01-01)',        '3178-01-01 00:00:00',         'false'),
  ('far above',                          '9999-01-01 00:00:00',         'false')
) AS e(label, v, ok);

-- cast from timestamp and from date (Gregorian edges: 0560-03-20 .. 3799-03-19)
INSERT INTO bcase (grp, label, expr, expect, show)
SELECT 'ts', e.label, format('SELECT (%s %L::jtimestamp) IS NOT NULL', e.typ, e.v),
       'SELECT ' || e.ok, true
FROM (VALUES
  ('timestamp -> jtimestamp, first valid',            'timestamp', '0560-03-20 00:00:00',        'true'),
  ('timestamp -> jtimestamp, 1 us below the first',   'timestamp', '0560-03-19 23:59:59.999999', 'false'),
  ('timestamp -> jtimestamp, last valid',             'timestamp', '3799-03-19 23:59:59.999999', 'true'),
  ('timestamp -> jtimestamp, 1 us above the last',    'timestamp', '3799-03-20 00:00:00',        'false'),
  ('timestamp -> jtimestamp, 9999-12-31',             'timestamp', '9999-12-31 00:00:00',        'false'),
  ('timestamp -> jtimestamp, 0001-01-01 BC',          'timestamp', '0001-01-01 00:00:00 BC',     'false'),
  ('date -> jtimestamp, first valid',                 'date',      '0560-03-20',                 'true'),
  ('date -> jtimestamp, 1 day below the first',       'date',      '0560-03-19',                 'false'),
  ('date -> jtimestamp, last valid',                  'date',      '3799-03-19',                 'true'),
  ('date -> jtimestamp, 1 day above the last',        'date',      '3799-03-20',                 'false'),
  ('date -> jtimestamp, 5874897-12-31',               'date',      '5874897-12-31',              'false')
) AS e(label, typ, v, ok);

-- from jdate: the day is always in range, so both edges succeed (nothing
-- below or above exists as a jdate)
INSERT INTO bcase (grp, label, expr, expect, show)
SELECT 'ts', 'jdate -> jtimestamp, ' || e.label,
       format('SELECT (%L::jdate::jtimestamp) IS NOT NULL', e.v), 'SELECT true', true
FROM (VALUES ('first day', '-0061-01-01'), ('last day', '3177-12-29')) AS e(label, v);

-- typmod rounding: the check runs after rounding, so the last microsecond
-- rounds up to the next day, which is out of range. Through the literal
-- (input, then the scale cast), through a value and from timestamp.
INSERT INTO bcase (grp, label, expr, expect, show)
SELECT 'ts', e.label, e.q, 'SELECT ' || e.ok, true
FROM (VALUES
  ('typmod (0), last us, literal',
   $$SELECT ('3177-12-29 23:59:59.999999'::jtimestamp(0)) IS NOT NULL$$, 'false'),
  ('typmod (3), last us, literal',
   $$SELECT ('3177-12-29 23:59:59.999999'::jtimestamp(3)) IS NOT NULL$$, 'false'),
  ('typmod (5), last us, literal',
   $$SELECT ('3177-12-29 23:59:59.999999'::jtimestamp(5)) IS NOT NULL$$, 'false'),
  ('typmod (6), last us, literal (no rounding)',
   $$SELECT ('3177-12-29 23:59:59.999999'::jtimestamp(6)) IS NOT NULL$$, 'true'),
  ('typmod (0), last second .4 rounds down',
   $$SELECT ('3177-12-29 23:59:59.4'::jtimestamp(0)) IS NOT NULL$$, 'true'),
  ('typmod (0), last second .5 rounds up',
   $$SELECT ('3177-12-29 23:59:59.5'::jtimestamp(0)) IS NOT NULL$$, 'false'),
  ('typmod (0), last us, through a value',
   $$SELECT (('3177-12-29 23:59:59.999999'::jtimestamp)::jtimestamp(0)) IS NOT NULL$$, 'false'),
  ('typmod (0), last us, through the scale function',
   $$SELECT (jtimestamp('3177-12-29 23:59:59.999999'::jtimestamp, 0, true)) IS NOT NULL$$, 'false'),
  ('typmod (0), last us, from timestamp',
   $$SELECT (timestamp '3799-03-19 23:59:59.999999'::jtimestamp(0)) IS NOT NULL$$, 'false'),
  ('typmod (3), last us, from timestamp',
   $$SELECT (timestamp '3799-03-19 23:59:59.999999'::jtimestamp(3)) IS NOT NULL$$, 'false'),
  ('typmod (0), first valid (nothing to round)',
   $$SELECT ('-0061-01-01 00:00:00'::jtimestamp(0)) IS NOT NULL$$, 'true'),
  ('typmod (0), first valid + .4 (rounds down to the first)',
   $$SELECT ('-0061-01-01 00:00:00.4'::jtimestamp(0)) IS NOT NULL$$, 'true'),
  ('typmod (3), first valid, from timestamp',
   $$SELECT (timestamp '0560-03-20 00:00:00'::jtimestamp(3)) IS NOT NULL$$, 'true')
) AS e(label, q, ok);

-- infinities are valid on every path
INSERT INTO bcase (grp, label, expr, expect, show)
SELECT 'ts', 'infinity: ' || e.label, e.q, 'SELECT true', true
FROM (VALUES
  ('in',            $$SELECT ('infinity'::jtimestamp) IS NOT NULL$$),
  ('in, negative',  $$SELECT ('-infinity'::jtimestamp) IS NOT NULL$$),
  ('in, typmod (0)', $$SELECT ('infinity'::jtimestamp(0)) IS NOT NULL$$),
  ('from timestamp', $$SELECT ('infinity'::timestamp::jtimestamp) IS NOT NULL$$),
  ('from timestamp, negative', $$SELECT ('-infinity'::timestamp::jtimestamp) IS NOT NULL$$),
  ('from date',     $$SELECT ('infinity'::date::jtimestamp) IS NOT NULL$$),
  ('from date, negative', $$SELECT ('-infinity'::date::jtimestamp) IS NOT NULL$$),
  ('from jdate',    $$SELECT ('infinity'::jdate::jtimestamp) IS NOT NULL$$),
  ('from jdate, negative', $$SELECT ('-infinity'::jdate::jtimestamp) IS NOT NULL$$),
  ('from jtimestamptz', $$SELECT ('infinity'::jtimestamptz::jtimestamp) IS NOT NULL$$),
  ('from jtimestamptz, negative', $$SELECT ('-infinity'::jtimestamptz::jtimestamp) IS NOT NULL$$)
) AS e(label, q);

-- from jtimestamptz at the first and last valid instant: it cannot fail in
-- any zone (the safe range is what makes this true)
INSERT INTO bcase (grp, label, expr, expect, show)
SELECT 'ts', 'jtimestamptz -> jtimestamp, ' || e.label,
       format('SELECT (%L::jtimestamptz::jtimestamp) IS NOT NULL', e.v), 'SELECT true', true
FROM (VALUES
  ('first valid instant', '-0061-01-01 16:00:00+00'),
  ('last valid instant',  '3177-12-29 07:59:59.999999+00')
) AS e(label, v);

-- ---------------------------------------------------------------------
-- jtimestamptz: text input with an offset in the text (the zone of the
-- session does not matter), instants given as UTC or as local clocks
-- ---------------------------------------------------------------------
INSERT INTO bcase (grp, label, expr, expect, show)
SELECT 'tz', 'in: ' || e.label, format('SELECT (%L::jtimestamptz) IS NOT NULL', e.v),
       'SELECT ' || e.ok, true
FROM (VALUES
  ('first valid instant, +00',              '-0061-01-01 16:00:00+00',               'true'),
  ('1 us below it, +00',                    '-0061-01-01 15:59:59.999999+00',        'false'),
  ('start of the first day, +00',           '-0061-01-01 00:00:00+00',               'false'),
  ('last valid instant, +00',               '3177-12-29 07:59:59.999999+00',         'true'),
  ('1 us above it, +00',                    '3177-12-29 08:00:00+00',                'false'),
  ('end of the last day, +00',              '3177-12-29 23:59:59.999999+00',         'false'),
  ('first valid instant, +03:30',           '-0061-01-01 19:30:00+03:30',            'true'),
  ('1 us below it, +03:30',                 '-0061-01-01 19:29:59.999999+03:30',     'false'),
  ('last valid instant, +03:30',            '3177-12-29 11:29:59.999999+03:30',      'true'),
  ('1 us above it, +03:30',                 '3177-12-29 11:30:00+03:30',             'false'),
  ('first valid instant, +15:59:59',        '-0061-01-02 07:59:59+15:59:59',         'true'),
  ('1 us below it, +15:59:59',              '-0061-01-02 07:59:58.999999+15:59:59',  'false'),
  ('last valid instant, -15:59:59',         '3177-12-28 16:00:00.999999-15:59:59',   'true'),
  ('1 us above it, -15:59:59',              '3177-12-28 16:00:01-15:59:59',          'false'),
  ('first valid instant, -05',              '-0061-01-01 11:00:00-05',               'true'),
  ('1 us below it, -05',                    '-0061-01-01 10:59:59.999999-05',        'false'),
  ('last valid instant, -05',               '3177-12-29 02:59:59.999999-05',         'true'),
  ('1 us above it, -05',                    '3177-12-29 03:00:00-05',                'false'),
  ('above the range by date',               '3178-01-01 12:00:00+00',                'false'),
  ('below the range by date',               '-0062-12-29 12:00:00+00',               'false')
) AS e(label, v, ok);

-- ---------------------------------------------------------------------
-- jtimestamptz paths that depend on the session zone. The four edge
-- instants come from core (timestamptz literals with +00); what the local
-- clock says in the session zone is computed by core's cast to timestamp.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE bpt (k text, lit text, ok boolean);
INSERT INTO bpt VALUES
  ('first valid instant',          $$timestamptz '0560-03-20 16:00:00+00'$$,        true),
  ('1 us below the first',         $$timestamptz '0560-03-20 15:59:59.999999+00'$$, false),
  ('last valid instant',           $$timestamptz '3799-03-19 07:59:59.999999+00'$$, true),
  ('1 us above the last',          $$timestamptz '3799-03-19 08:00:00+00'$$,        false);

-- timestamptz -> jtimestamptz: the instant is what counts, whatever the zone
INSERT INTO bcase (grp, label, expr, expect, show)
SELECT 'tz', 'timestamptz -> jtimestamptz, ' || k,
       format('SELECT (%s::jtimestamptz) IS NOT NULL', lit), 'SELECT ' || ok, true
FROM bpt;

-- text without an offset: read in the session zone. The local clock of each
-- edge instant in that zone, printed as Jalali text by the jtimestamp type
-- and read back by jtimestamptz.
INSERT INTO bcase (grp, label, expr, expect, show)
SELECT 'tz', 'in, no offset: local clock of the ' || k,
       format('SELECT ((%s)::timestamp::jtimestamp::text::jtimestamptz) IS NOT NULL', lit),
       'SELECT ' || ok, false
FROM bpt;

-- jtimestamp -> jtimestamptz: the local clock of the same instants
INSERT INTO bcase (grp, label, expr, expect, show)
SELECT 'tz', 'jtimestamp -> jtimestamptz: local clock of the ' || k,
       format('SELECT ((%s)::timestamp::jtimestamp::jtimestamptz) IS NOT NULL', lit),
       'SELECT ' || ok, false
FROM bpt;
-- ... and the same through the function form
INSERT INTO bcase (grp, label, expr, expect, show)
SELECT 'tz', 'jtimestamptz(jtimestamp): local clock of the ' || k,
       format('SELECT (jtimestamptz((%s)::timestamp::jtimestamp)) IS NOT NULL', lit),
       'SELECT ' || ok, false
FROM bpt;

-- the first microsecond of the first day and the last of the last day are
-- never valid as a local clock: that would need an offset beyond +/-16:00
INSERT INTO bcase (grp, label, expr, expect, show)
SELECT 'tz', 'jtimestamp -> jtimestamptz, ' || e.label,
       format('SELECT (%L::jtimestamp::jtimestamptz) IS NOT NULL', e.v), 'SELECT false', true
FROM (VALUES
  ('start of the first day', '-0061-01-01 00:00:00'),
  ('end of the last day',    '3177-12-29 23:59:59.999999')
) AS e(label, v);

-- date and jdate -> jtimestamptz: the local midnight of a day near either
-- edge. Valid when core's own local midnight of that date is inside the safe
-- range (which edge days pass depends on the zone's offset).
INSERT INTO bcase (grp, label, expr, expect, show)
SELECT 'tz', e.typ || ' -> jtimestamptz, ' || e.label,
       format('SELECT (%s %L::jtimestamptz) IS NOT NULL', e.typ, e.v),
       format($$SELECT (date %L)::timestamptz >= timestamptz '0560-03-20 16:00:00+00'
                   AND (date %L)::timestamptz <  timestamptz '3799-03-19 08:00:00+00'$$, e.d, e.d),
       false
FROM (VALUES
  ('date',  '1 day below the first day', '0560-03-19', '0560-03-19'),
  ('date',  'first day',                '0560-03-20', '0560-03-20'),
  ('date',  'second day',               '0560-03-21', '0560-03-21'),
  ('date',  'third day',                '0560-03-22', '0560-03-22'),
  ('date',  'day before the last',      '3799-03-18', '3799-03-18'),
  ('date',  'last day',                 '3799-03-19', '3799-03-19'),
  ('date',  '1 day above the last day', '3799-03-20', '3799-03-20'),
  ('jdate', 'first day',                '-0061-01-01', '0560-03-20'),
  ('jdate', 'second day',               '-0061-01-02', '0560-03-21'),
  ('jdate', 'third day',                '-0061-01-03', '0560-03-22'),
  ('jdate', 'day before the last',      '3177-12-28', '3799-03-18'),
  ('jdate', 'last day',                 '3177-12-29', '3799-03-19')
) AS e(typ, label, v, d);

-- typmod rounding at the edges of the safe range
INSERT INTO bcase (grp, label, expr, expect, show)
SELECT 'tz', e.label, e.q, 'SELECT ' || e.ok, true
FROM (VALUES
  ('typmod (0), last instant, literal',
   $$SELECT ('3177-12-29 07:59:59.999999+00'::jtimestamptz(0)) IS NOT NULL$$, 'false'),
  ('typmod (3), last instant, literal',
   $$SELECT ('3177-12-29 07:59:59.999999+00'::jtimestamptz(3)) IS NOT NULL$$, 'false'),
  ('typmod (5), last instant, literal',
   $$SELECT ('3177-12-29 07:59:59.999999+00'::jtimestamptz(5)) IS NOT NULL$$, 'false'),
  ('typmod (6), last instant, literal (no rounding)',
   $$SELECT ('3177-12-29 07:59:59.999999+00'::jtimestamptz(6)) IS NOT NULL$$, 'true'),
  ('typmod (0), last second .4 rounds down',
   $$SELECT ('3177-12-29 07:59:59.4+00'::jtimestamptz(0)) IS NOT NULL$$, 'true'),
  ('typmod (0), last second .5 rounds up',
   $$SELECT ('3177-12-29 07:59:59.5+00'::jtimestamptz(0)) IS NOT NULL$$, 'false'),
  ('typmod (0), last instant, through a value',
   $$SELECT (('3177-12-29 07:59:59.999999+00'::jtimestamptz)::jtimestamptz(0)) IS NOT NULL$$, 'false'),
  ('typmod (0), last instant, from timestamptz',
   $$SELECT (timestamptz '3799-03-19 07:59:59.999999+00'::jtimestamptz(0)) IS NOT NULL$$, 'false'),
  ('typmod (0), first instant (nothing to round)',
   $$SELECT ('-0061-01-01 16:00:00+00'::jtimestamptz(0)) IS NOT NULL$$, 'true'),
  ('typmod (0), first instant + .4 (rounds down to the first)',
   $$SELECT ('-0061-01-01 16:00:00.4+00'::jtimestamptz(0)) IS NOT NULL$$, 'true'),
  ('typmod (3), first instant, from timestamptz',
   $$SELECT (timestamptz '0560-03-20 16:00:00+00'::jtimestamptz(3)) IS NOT NULL$$, 'true'),
  -- the literal is read at typmod -1 first, so a value just below the
  -- first instant is out of range before the scale cast could round it up
  ('typmod (0), first instant - .4 s, literal',
   $$SELECT ('-0061-01-01 15:59:59.6+00'::jtimestamptz(0)) IS NOT NULL$$, 'false')
) AS e(label, q, ok);

-- the same value through the input function with the typmod (what COPY and
-- array input do): it is rounded up into the range, then checked, so it is
-- valid there. pg_input_is_valid calls the input function with the typmod.
SELECT pg_input_is_valid('-0061-01-01 15:59:59.6+00', 'jtimestamptz(0)') AS rounds_into_the_range_in_input,
       pg_input_is_valid('-0061-01-01 15:59:59.4+00', 'jtimestamptz(0)') AS rounds_down_stays_below,
       pg_input_is_valid('3177-12-29 07:59:59.5+00', 'jtimestamptz(0)') AS rounds_out_at_the_top,
       pg_input_is_valid('3177-12-29 07:59:59.4+00', 'jtimestamptz(0)') AS rounds_down_at_the_top;

-- to_jtimestamptz: epoch seconds of the same four instants (whole seconds,
-- because a double of this size cannot hold a microsecond)
INSERT INTO bcase (grp, label, expr, expect, show)
SELECT 'tz', 'to_jtimestamptz: ' || e.k,
       format('SELECT (to_jtimestamptz(%s)) IS NOT NULL', e.v), 'SELECT ' || e.ok, true
FROM (VALUES
  ('first valid instant',  $$extract(epoch from timestamptz '0560-03-20 16:00:00+00')::float8$$,       'true'),
  ('1 s below it',         $$extract(epoch from timestamptz '0560-03-20 15:59:59+00')::float8$$,       'false'),
  ('last whole second',    $$extract(epoch from timestamptz '3799-03-19 07:59:59+00')::float8$$,       'true'),
  ('1 s above it',         $$extract(epoch from timestamptz '3799-03-19 08:00:00+00')::float8$$,       'false'),
  ('first Jalali day start (below the safe range)',
                           $$extract(epoch from timestamptz '0560-03-20 00:00:00+00')::float8$$,       'false'),
  ('last Jalali day end (above the safe range)',
                           $$extract(epoch from timestamptz '3799-03-19 23:59:59+00')::float8$$,       'false'),
  ('NaN',                  $$'NaN'::float8$$,                                                         'false'),
  ('infinity is accepted', $$'infinity'::float8$$,                                                    'true'),
  ('-infinity is accepted',$$'-infinity'::float8$$,                                                   'true')
) AS e(k, v, ok);

-- infinities are valid on every path
INSERT INTO bcase (grp, label, expr, expect, show)
SELECT 'tz', 'infinity: ' || e.label, e.q, 'SELECT true', true
FROM (VALUES
  ('in',            $$SELECT ('infinity'::jtimestamptz) IS NOT NULL$$),
  ('in, negative',  $$SELECT ('-infinity'::jtimestamptz) IS NOT NULL$$),
  ('in, typmod (0)', $$SELECT ('infinity'::jtimestamptz(0)) IS NOT NULL$$),
  ('from timestamptz', $$SELECT ('infinity'::timestamptz::jtimestamptz) IS NOT NULL$$),
  ('from timestamptz, negative', $$SELECT ('-infinity'::timestamptz::jtimestamptz) IS NOT NULL$$),
  ('from jtimestamp', $$SELECT ('infinity'::jtimestamp::jtimestamptz) IS NOT NULL$$),
  ('from jtimestamp, negative', $$SELECT ('-infinity'::jtimestamp::jtimestamptz) IS NOT NULL$$),
  ('from date',     $$SELECT ('infinity'::date::jtimestamptz) IS NOT NULL$$),
  ('from date, negative', $$SELECT ('-infinity'::date::jtimestamptz) IS NOT NULL$$),
  ('from jdate',    $$SELECT ('infinity'::jdate::jtimestamptz) IS NOT NULL$$),
  ('from jdate, negative', $$SELECT ('-infinity'::jdate::jtimestamptz) IS NOT NULL$$),
  ('to_jtimestamptz', $$SELECT (to_jtimestamptz('infinity')) IS NOT NULL$$),
  ('to_jtimestamptz, negative', $$SELECT (to_jtimestamptz('-infinity')) IS NOT NULL$$)
) AS e(label, q);

-- from jtimestamptz to jdate: always works, even at the edges, in every zone
INSERT INTO bcase (grp, label, expr, expect, show)
SELECT 'tz', 'jtimestamptz -> jdate, ' || e.label,
       format('SELECT (%L::jtimestamptz::jdate) IS NOT NULL', e.v), 'SELECT true', true
FROM (VALUES
  ('first valid instant', '-0061-01-01 16:00:00+00'),
  ('last valid instant',  '3177-12-29 07:59:59.999999+00')
) AS e(label, v);

-- ---------------------------------------------------------------------
-- run every case in every zone
-- ---------------------------------------------------------------------
CREATE TEMP TABLE bres AS
SELECT c.n, z.id AS zid,
       CASE r.got WHEN 'true' THEN 't' WHEN 'ERR 22008' THEN 'E' ELSE r.got END AS got,
       CASE r.want WHEN 'true' THEN 't' WHEN 'false' THEN 'E' ELSE r.want END AS want
FROM bcase c CROSS JOIN bz z,
     LATERAL (SELECT pg_temp.eval(z.zone, c.expr) AS got,
                     pg_temp.eval(z.zone, c.expect) AS want) r;
SET timezone = 'UTC';

-- coverage: a quick look that the run is not vacuous
SELECT count(*) AS cases,
       (SELECT count(*) FROM bz) AS zones,
       count(*) * (SELECT count(*) FROM bz) AS runs
FROM bcase;
SELECT count(*) FILTER (WHERE got = 't') > 0 AS has_success,
       count(*) FILTER (WHERE got = 'E') > 0 AS has_range_error,
       count(*) FILTER (WHERE got NOT IN ('t', 'E')) AS other_outcomes,
       count(*) FILTER (WHERE want NOT IN ('t', 'E')) AS bad_expectations,
       count(*) FILTER (WHERE got <> want) AS mismatches
FROM bres;

-- cases that do not depend on a zone: the pattern of results in the six
-- zones (zone order: UTC, Tehran, Kiritimati, Pago_Pago, +15:59, -15:59),
-- t = success, E = 22008. The same letter six times, as expected.
SELECT c.n, c.grp, c.label,
       string_agg(r.got, '' ORDER BY r.zid) AS got,
       bool_and(r.got = r.want) AS as_expected
FROM bcase c JOIN bres r USING (n)
WHERE c.show
GROUP BY c.n, c.grp, c.label
ORDER BY c.n;

-- cases that depend on the zone: only whether the result is what core's
-- arithmetic in that zone predicts, in each of the six zones
SELECT c.n, c.grp, c.label,
       bool_and(r.got = r.want) AS as_expected
FROM bcase c JOIN bres r USING (n)
WHERE NOT c.show
GROUP BY c.n, c.grp, c.label
ORDER BY c.n;

-- Any case that did not give the expected result in some zone (none)
SELECT c.n, z.zone, c.label, r.got, r.want
FROM bcase c JOIN bres r USING (n) JOIN bz z ON z.id = r.zid
WHERE r.got <> r.want
ORDER BY c.n, z.id;

-- Negative control: the comparison above must be able to fail. With every
-- expectation inverted it reports a mismatch for every run.
SELECT count(*) = (SELECT count(*) FROM bres) AS control_inverted_expectations_all_fail
FROM bres
WHERE got <> CASE want WHEN 't' THEN 'E' ELSE 't' END;

-- zone-dependent edges, spelled out for the three zones whose offsets are
-- fixed (no tzdata history involved): which of the first and last days
-- convert to jtimestamptz at local midnight (t) and which do not (E).
-- The first day never does; the second does for zones up to +8h; the last
-- day does for zones down to -8h.
CREATE TEMP TABLE bfix (id int, zone text);
INSERT INTO bfix VALUES (1, 'UTC'), (2, '<+14>-14'), (3, '<-11>+11'),
                        (4, '<+15:59>-15:59'), (5, '<-15:59>+15:59');
SELECT d.label,
       string_agg(CASE pg_temp.eval(f.zone, format('SELECT (jdate %L::jtimestamptz) IS NOT NULL', d.v))
                    WHEN 'true' THEN 't' WHEN 'ERR 22008' THEN 'E' ELSE '?' END,
                  '' ORDER BY f.id) AS utc_p14_m11_p1559_m1559
FROM (VALUES ('first day', '-0061-01-01'), ('second day', '-0061-01-02'),
             ('day before the last', '3177-12-28'), ('last day', '3177-12-29')) AS d(label, v),
     bfix f
GROUP BY d.label, d.v
ORDER BY d.v;
SET timezone = 'UTC';

-- ... and the first valid instant and the last one, shown as a local clock
-- (jtimestamptz -> jtimestamp) in the extreme zones: they still print
SELECT f.zone,
       pg_temp.eval(f.zone, $$SELECT ('-0061-01-01 16:00:00+00'::jtimestamptz)::jtimestamp::text$$) AS first_instant_local,
       pg_temp.eval(f.zone, $$SELECT ('3177-12-29 07:59:59.999999+00'::jtimestamptz)::jtimestamp::text$$) AS last_instant_local
FROM bfix f WHERE f.id IN (4, 5) ORDER BY f.id;
SET timezone = 'UTC';
