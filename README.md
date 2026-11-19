# jdate

[![CI](https://github.com/mmgghh/postgres-jdate/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/mmgghh/postgres-jdate/actions/workflows/ci.yml)

Native PostgreSQL types for the Jalali (Persian / Solar Hijri) calendar: `jdate`
(a date), `jtimestamp` (a timestamp without time zone), `jtimestamptz` (a
timestamp with time zone) and the range types `jdaterange`, `jtsrange` and
`jtstzrange` over them.

Unlike text-based Jalali helpers (this project supersedes
[`jalali_utils`](https://github.com/teamappir/jalali_utils)), `jdate` is a
real 4-byte base type, **binary-compatible with Postgres's own `date`**: it
stores the same 4 bytes (days since 2000-01-01), so `jdate -> date` is a free
cast, and comparisons, sorting, indexing, and `GROUP BY`/`DISTINCT` all reuse
Postgres's own hardened `date` machinery instead of re-parsing strings. The
other direction is checked, not free: `date` covers far more days than the
Jalali algorithm does, so `date -> jdate` validates the supported range (see
[Supported range](docs/SPECIFICATION.md#supported-range)).

`jtimestamp` and `jtimestamptz` do the same for `timestamp` and `timestamptz`:
8 bytes, core's representation and binary format, Jalali text input and output
(`1403-01-01 12:30:45`), core's hashing and ordering, and Jalali rules wherever the
calendar matters (month arithmetic, `year` / `month` fields, truncation, month and
day keys). The three types compare with each other, and there are no implicit casts
(see [The Jalali timestamp types](docs/SPECIFICATION.md#the-jalali-timestamp-types)).

Date math uses the algorithm published by Kazimierz M. Borkowski (*The Persian
calendar for 3000 years*, 1996), the same one used by
[`jalaali-js`](https://github.com/jalaali/jalaali-js): a table of break years
that corrects the 33-year leap cycle, published as exact for Jalali years `-61`
to `3177` (Gregorian 0560-03-20 to 3799-03-19), rather than a plain 33-year
rule (see [The calendar algorithm](docs/SPECIFICATION.md#the-calendar-algorithm)).

**Contents:**
[Install](#install) ·
[Versioning and upgrades](#versioning-and-upgrades) ·
[Backup and restore](#backup-and-restore) ·
[Usage](#usage) ·
[Timestamps](#jtimestamp-and-jtimestamptz) ·
[Time zones](#time-zones) ·
[jalali_utils](#coming-from-jalali_utils) ·
[Specification](#specification) ([full text](docs/SPECIFICATION.md)) ·
[Testing](#testing) ([full text](docs/TESTING.md)) ·
[Changelog](CHANGELOG.md) ·
[Credits](#credits)

## Install

```sh
make
sudo make install     # copies jdate.so + control/SQL files into your
                       # PostgreSQL installation -- like any C extension,
                       # this step needs filesystem access to the server
```

Building needs the server development files (on Debian/Ubuntu
`postgresql-server-dev-NN`) and `pg_config` on the `PATH`; `make
PG_CONFIG=/path/to/pg_config` picks a specific installation.

Then, connected to the target database, as a superuser (the script writes into
`pg_catalog`, and the control file does not mark the extension trusted):

```sql
CREATE EXTENSION jdate;
```

Requires PostgreSQL 16 or later (`make` stops with an error on PostgreSQL 12
to 15). Two features need more than that baseline: `pg_input_is_valid()` and
`pg_input_error_info()` work with `jdate` from 16, while `COPY ...
(ON_ERROR ignore)` skipping bad `jdate` values needs 17 (see
[Soft errors](docs/SPECIFICATION.md#soft-errors)). What has actually been run on which version is
listed under [Supported PostgreSQL versions](docs/SPECIFICATION.md#supported-postgresql-versions).

### Installing into a schema

The extension is **not relocatable**: choose its schema when you create it,
`CREATE EXTENSION jdate SCHEMA s`, and it stays there. Without `SCHEMA`, it
goes into the default creation schema (`public` in a default setup).

```sql
CREATE SCHEMA s;
CREATE EXTENSION jdate SCHEMA s;
```

The types, their operators, operator classes, aggregates and functions all go in
`s`, except nine functions. `EXTRACT(field FROM x)`, `x AT TIME ZONE z` and
`(a, b) OVERLAPS (c, d)` always resolve to `pg_catalog.extract`,
`pg_catalog.timezone` and `pg_catalog.overlaps`, so the overloads that make them
work for the extension's types (three `extract`, four `timezone`, two `overlaps`)
live in `pg_catalog`, and the server cannot move them along with the rest of the
extension. That is also why those syntaxes work whether or not `s` is on the
`search_path` (the types themselves then have to be written `s.jdate`).
`ALTER EXTENSION jdate SET SCHEMA ...` is refused (`extension "jdate" does not
support SET SCHEMA`, SQLSTATE `0A000`); to use a different schema, drop and
recreate the extension. `DROP EXTENSION` removes the nine functions again.

## Versioning and upgrades

Releases are tagged `vMAJOR.MINOR.PATCH` (see the [changelog](CHANGELOG.md)); the
extension version in `jdate.control` is the `MAJOR.MINOR` part, so `v1.0.0` is
extension version `1.0`. A patch release changes only the C library and the
documentation, not the SQL objects, so the extension version stays the same.

`1.0` is the first and only extension version: one script, `jdate--1.0.sql`, and no
upgrade scripts. If a later release changes the SQL objects, it ships a new
`jdate--1.0--X.Y.sql` update script and a new `default_version`, and an installed
database moves to it with `ALTER EXTENSION jdate UPDATE`. Check what a database has with
`SELECT extversion FROM pg_extension WHERE extname = 'jdate'`.

The stored data does not depend on the extension version: `jdate`, `jtimestamp` and
`jtimestamptz` are stored exactly as core's `date`, `timestamp` and `timestamptz`
(see the [specification](docs/SPECIFICATION.md#type-and-storage)), so an upgrade
does not need to rewrite stored data.

## Backup and restore

`pg_dump` writes `CREATE EXTENSION jdate` (with its schema, if it was not the
default) and the data and definitions that use the types; it does not dump the
extension's own objects. To restore:

- install the extension's files (`make install`, or your package) on the target
  server first, on PostgreSQL 16 or later, and use the same extension version or a
  newer one;
- restore as a superuser, because `CREATE EXTENSION jdate` needs one (the control
  file does not mark the extension trusted).

The round trip is tested for plain, plain `--inserts` and custom-format dumps, with
the extension in the default schema and in a custom one: every value, as text and as
its binary form, and the index, default, `CHECK`, partition and view definitions
come back identical (`dev/dump-roundtrip.sh`, run by CI on PostgreSQL 16, 17 and 18;
see [Testing](docs/TESTING.md)).

## Usage

Every result shown below was produced by running the statement on PostgreSQL
18 with `psql` defaults (`DateStyle` `ISO, MDY`), in order, in one database.

```sql
-- literals are year-month-day, in that order
SELECT '1403-01-01'::jdate;                 -- 1403-01-01 (Nowruz 1403)
SELECT 'infinity'::jdate, '-infinity'::jdate;  -- infinity | -infinity

-- jdate -> date is free: same day, same 4 bytes, different calendar
SELECT '1403-01-01'::jdate::date;           -- 2024-03-20
-- date -> jdate is the same day, but checked against the supported range
SELECT '2024-03-20'::date::jdate;           -- 1403-01-01
SELECT '9999-12-31'::date::jdate;           -- ERROR (SQLSTATE 22008): out of range

-- casts to/from timestamp / timestamptz (assignment-level: explicit
-- or in an INSERT/assignment context, not silently applied elsewhere).
-- Like date -> jdate, timestamp[tz] -> jdate is range-checked, and
-- timestamptz <-> jdate use the session's TimeZone
SET timezone = 'Asia/Tehran';
SELECT '1403-01-01'::jdate::timestamptz;                 -- 2024-03-20 00:00:00+03:30
SELECT timestamptz '2024-03-19 22:00:00+00'::jdate;      -- 1403-01-01
SELECT now()::jdate;                                     -- today's Jalali date (varies)

-- comparison, sorting, indexing all work natively (btree and hash operator
-- classes, so hash joins, hash indexes and PARTITION BY HASH work too)
CREATE TABLE events (happened_on jdate, name text);
INSERT INTO events VALUES ('1403-01-01', 'Nowruz'), ('1402-12-29', 'last day of 1402'),
                          ('1403-01-13', 'Sizdah Bedar');
CREATE INDEX ON events (happened_on);
SELECT name FROM events WHERE happened_on > '1402-12-29' ORDER BY happened_on DESC LIMIT 1;  -- Sizdah Bedar
SELECT min(happened_on), max(happened_on) FROM events;   -- 1402-12-29 | 1403-01-13

-- arithmetic: add or subtract days, or subtract two dates to get days
SELECT '1403-01-01'::jdate + 10;                    -- 1403-01-11
SELECT 10 + '1403-01-01'::jdate;                    -- 1403-01-11
SELECT '1403-01-11'::jdate - 10;                    -- 1403-01-01
SELECT '1403-01-10'::jdate - '1403-01-01'::jdate;   -- 9
-- a result outside the supported range is rejected when it is computed
SELECT '3177-12-29'::jdate + 1;                     -- ERROR (SQLSTATE 22008)

-- field access
SELECT jdate_part('year', '1403-05-15'::jdate);     -- 1403 (bigint)
SELECT jdate_part('quarter', '1403-05-15'::jdate);  -- 2
SELECT EXTRACT(month FROM '1403-05-15'::jdate);     -- 5 (numeric)
SELECT jdate_trunc('month', '1403-05-15'::jdate);   -- 1403-05-01
SELECT jdate_trunc('week', '1403-05-15'::jdate);    -- 1403-05-13 (weeks start on Saturday)
-- decade is a decade number (year / 10 rounded down, as in core: 202 for
-- 2024), not the first year of the decade: 1403 and 1400 are both 140, 1399
-- is 139, 0 is 0 and -1 is -1. A tool that reports the first year of the
-- decade (such as jalali_utils, which gives 1400) is not the same thing; use
-- jdate_part('decade', d) * 10 to get that
SELECT jdate_part('decade', '1403-05-15'::jdate);   -- 140

-- dow starts the week on Saturday (0 = Saturday .. 6 = Friday); dow + 1 is the
-- 1-based Saturday-first number. isodow is the ISO 8601 one (1 = Monday ..
-- 7 = Sunday) and equals core's answer for the same day, as does epoch.
-- 1403-01-01 is a Wednesday
SELECT jdate_part('dow', '1403-01-01'::jdate);      -- 4
SELECT jdate_part('isodow', '1403-01-01'::jdate);   -- 3

-- Unix epoch (seconds since 1970-01-01 UTC), same as date/timestamp
SELECT EXTRACT(epoch FROM '1403-01-01'::jdate);     -- 1710892800
SELECT to_jdate(1710892800);                        -- 1403-01-01

-- jdate_part returns bigint (exact, epoch included) and is NULL for every unit
-- on infinity; EXTRACT returns numeric and follows core's date (see Infinity
-- below): units that only grow give +/-Infinity, units that cycle give NULL
SELECT jdate_part('year', 'infinity'::jdate);       -- NULL
SELECT EXTRACT(year FROM 'infinity'::jdate);        -- Infinity
SELECT EXTRACT(century FROM '-infinity'::jdate);    -- -Infinity
SELECT EXTRACT(month FROM 'infinity'::jdate);       -- NULL

-- to_jdate() is the Jalali date of the UTC day that contains the timestamp.
-- The session TimeZone plays no part, so the answer is the same in every
-- zone and the function is IMMUTABLE (it can be used in an index). Going
-- through to_timestamp() instead gives the *local* day, which can differ.
SET timezone = 'America/New_York';
SELECT to_jdate(1710892800);                        -- 1403-01-01
SELECT to_timestamp(1710892800)::jdate;             -- 1402-12-29

-- Jalali date + local clock time for a core timestamptz, respecting the
-- session's TimeZone (the bridge from a core type; the native Jalali timestamp
-- types are in the next section)
SET timezone = 'UTC';
SELECT jdate_format(timestamptz '2024-03-20 12:03:41.482917+00');         -- 1403-01-01 12:03:41.482917
SELECT jdate_format(timestamptz '2024-03-20 12:03:41.482917+00', false);  -- 1403-01-01
SELECT jdate_format('infinity'::timestamptz);                             -- infinity
SELECT jdate_format('-infinity'::timestamptz, false);                     -- -infinity
SELECT jdate_format(now());                         -- the current moment (varies)

-- whitespace around infinity is accepted, like for the timestamp types
SELECT ' infinity'::jdate, E'\t-infinity\n'::jdate; -- infinity | -infinity
-- an untyped literal or parameter next to jdate + is ambiguous, as for date:
-- cast it (jdate + $1::int, jdate + interval '5 days')
SELECT '1403-01-01'::jdate + '5';                   -- ERROR (SQLSTATE 42725)
SELECT '1403-01-01'::jdate + interval '1 month';    -- 1403-02-01 00:00:00 (a jtimestamp)

-- Jalali month and day keys, for GROUP BY
SELECT jmonth_format('1403-05-15'::jdate);          -- 1403-05
SELECT jday_format('1403-05-15'::jdate, '/');       -- 1403/05/15
```

## jtimestamp and jtimestamptz

`jtimestamp` is a timestamp without time zone and `jtimestamptz` a timestamp with
time zone, both written with a Jalali date. Everything after the date is core's
time syntax, so `T` or a space, fractional seconds, `24:00:00`, `AM` / `PM` and,
for `jtimestamptz`, offsets, zone names and abbreviations all work. `DateStyle`
is ignored (output is always `YYYY-MM-DD HH:MM:SS[.ffffff]`). Every result below
was produced on PostgreSQL 18 with `psql` defaults, in order, in one database
(`DateStyle` `ISO, MDY`).

```sql
SET timezone = 'Asia/Tehran';
SELECT '1403-01-01 12:30:45.5'::jtimestamp;                 -- 1403-01-01 12:30:45.5
SELECT '1403-01-01 12:30:45.5+03:30'::jtimestamptz;         -- 1403-01-01 12:30:45.5+03:30
SELECT '1403-01-01 10:00:00+00'::jtimestamptz;              -- 1403-01-01 13:30:00+03:30 (same instant, session zone)
SELECT '1403-01-01T12:30'::jtimestamp(0);                   -- 1403-01-01 12:30:00
SELECT 'infinity'::jtimestamptz, ' epoch '::jtimestamp;     -- infinity | 1348-10-11 00:00:00
-- special words: infinity, -infinity, now, today, tomorrow, yesterday, epoch
-- (case-insensitive, whitespace around them allowed); no other word

-- binary compatible with timestamp / timestamptz: the free casts are the same
-- instant with Gregorian digits; the casts from core types are range-checked
SELECT '1403-01-01 12:30:45'::jtimestamp::timestamp;        -- 2024-03-20 12:30:45
SELECT '2024-03-20 12:30:45'::timestamp::jtimestamp;        -- 1403-01-01 12:30:45
SELECT '1403-05-15 10:30'::jtimestamp::jdate;               -- 1403-05-15
SELECT '1403-01-12'::jdate::jtimestamptz;                   -- 1403-01-12 00:00:00+03:30
SELECT '3178-01-01 00:00'::jtimestamp;                      -- ERROR (SQLSTATE 22008): out of range

-- the three types compare with each other (no cast to a core type is needed)
SELECT '1403-01-01'::jdate < '1403-01-01 10:00'::jtimestamp;      -- t
SELECT '1403-01-01 10:00+00'::jtimestamptz = '1403-01-01 13:30'::jtimestamp;  -- t (in Tehran)

-- interval arithmetic uses Jalali months: months first, then days, then time,
-- a day that does not exist in the target month is clamped to its last day
SELECT '1403-06-31 10:00'::jtimestamp + interval '1 month';   -- 1403-07-30 10:00:00 (Mehr has 30 days)
SELECT '1403-12-30 10:00'::jtimestamp + interval '1 year';    -- 1404-12-29 10:00:00 (1404 is not a leap year)
SELECT '1403-01-31 10:00'::jtimestamp + interval '1 month 1 day 2 hours';  -- 1403-03-01 12:00:00
SELECT ('1403-06-31'::jdate + interval '1 month') - interval '1 month';    -- 1403-06-30 00:00:00 (not invertible, as in core)
SELECT '3177-12-29 12:00'::jtimestamp + interval '1 month';   -- ERROR (SQLSTATE 22008)

-- fields: EXTRACT and jdate_part return numeric for these types
SELECT EXTRACT(year FROM '1403-05-15 10:30:45.123456'::jtimestamp);        -- 1403
SELECT jdate_part('second', '1403-05-15 10:30:45.123456'::jtimestamp);     -- 45.123456
SELECT jdate_trunc('month', '1403-05-15 10:30'::jtimestamp);               -- 1403-05-01 00:00:00
SELECT jdate_trunc('week', '1403-05-15 10:30'::jtimestamp);                -- 1403-05-13 00:00:00 (Saturday)

-- time zones: AT TIME ZONE converts between the two types
SELECT '1403-01-01 00:30+03:30'::jtimestamptz AT TIME ZONE 'UTC';           -- 1402-12-29 21:00:00
SELECT '1403-01-01 12:00'::jtimestamp AT TIME ZONE 'Asia/Tehran';           -- 1403-01-01 12:00:00+03:30

-- Jalali month series (the clamped day sticks, as in core) and fixed-stride bins
SELECT * FROM jgenerate_series('1403-01-31'::jdate, '1403-06-01'::jdate, interval '1 month');
--   1403-01-31, 1403-02-31, 1403-03-31, 1403-04-31, 1403-05-31 (00:00:00 each)
SELECT jdate_bin('1 day', '1403-01-01 15:00+00'::jtimestamptz, '1400-01-01 00:00+00'::jtimestamptz);
--   1403-01-01 03:30:00+03:30 (bins are elapsed time from the origin: UTC midnight here)

-- Jalali keys for reports and indexes (text YYYY-MM and YYYY-MM-DD)
SELECT jday_format('1403-05-03 10:00'::jtimestamp);                 -- 1403-05-03
SELECT jmonth_format('1403-05-03 10:00'::jtimestamp, '/');          -- 1403/05

-- ranges: jdaterange (discrete, canonical form), jtsrange, jtstzrange, multiranges
SELECT '[1403-01-01,1403-01-31]'::jdaterange;                        -- [1403-01-01,1403-02-01)
SELECT jtsrange('1403-01-01 10:00', '1403-01-02 10:00');             -- ["1403-01-01 10:00:00","1403-01-02 10:00:00")
```

Names differ from core's where overloading would make an untyped literal silently
mean the Gregorian calendar: `jgenerate_series` and `jdate_bin` (not
`generate_series` and `date_bin`), `jdate_trunc`, `jdate_part`, `jday_format`,
`jmonth_format`. `EXTRACT`, `AT TIME ZONE` and `OVERLAPS` keep their syntax. A
side effect, as with `date` in core: an untyped literal or parameter where
several overloads exist is ambiguous (SQLSTATE `42725`), for example
`jdate_trunc('month', '1403-05-15')` or `jdate + $1` in a prepared statement or
through a driver that sends untyped parameters. Cast it (`'1403-05-15'::jdate`,
`$1::int`); the [list](docs/SPECIFICATION.md#bare-literals-and-parameters) has every
case. A Gregorian instant cannot be written directly: the text is always Jalali
(`'2024-03-20 12:30'::timestamp::jtimestamp`).

Indexes on a `jtimestamptz` need a zone, because anything that reads the session
`TimeZone` is `STABLE`:

```sql
CREATE INDEX ON events (jday_format(created_at AT TIME ZONE 'Asia/Tehran'));  -- created_at is a jtimestamptz
CREATE INDEX ON events (((created_at AT TIME ZONE 'Asia/Tehran')::jdate));
CREATE INDEX ON events (jdate_trunc('month', created_at, 'Asia/Tehran'));
```

What is **not** covered: `age`, `to_char` and `make_jtimestamp`, a Jalali week of the
year (`EXTRACT(week ...)` is an error; `jdate_trunc('week', ...)` starts on
Saturday), window `RANGE ... PRECEDING` over these types, casts to and from core's
range types, and implicit casts between any Jalali and core type. The full list of
differences from core is in the
[specification](docs/SPECIFICATION.md#known-differences-from-core); one of them: a
`jgenerate_series` stops quietly at the last day of the supported range where core's
`generate_series` raises an error. `jtimestamptz` accepts instants from
`-0061-01-01 16:00` UTC to `3177-12-29 07:59:59.999999` UTC (the Jalali range less
16 hours at each end, so every stored value can be shown in every zone).

## Time zones

A `jdate` is a calendar day and has no time zone, and neither has a
`jtimestamp`. A time zone only matters where an instant (`timestamptz`,
`jtimestamptz`, a Unix epoch) meets a day or a wall clock. The table says which
zone each such place uses; nothing else in the extension looks at a zone.

| Zone used | Where |
| --- | --- |
| the session `TimeZone` | `timestamptz` to `jdate` and `jdate` to `timestamptz` casts, `jdate_format`, and `to_timestamp(e)::jdate`; every `jtimestamptz` input without an offset, output, cast to or from `jtimestamp`, `jdate` or `date`, interval arithmetic, `EXTRACT` / `jdate_part` / `jdate_trunc` / `jday_format` / `jmonth_format`, comparison with another type, `jgenerate_series` |
| a zone you name | `to_jdate(e, zone)`, `AT TIME ZONE zone`, `jdate_trunc(unit, tz, zone)`, `jgenerate_series(..., zone)` |
| none | `to_jdate(e)` (the UTC day), `EXTRACT(epoch FROM ...)`, `jtimestamp` in every operation, `jtimestamptz - jtimestamptz`, `jdate_bin`, `to_jtimestamptz`, every other function, operator and cast |

The knob is PostgreSQL's own `timezone` setting: set it per session with
`SET timezone`, or make it the default for a database or a role with
`ALTER DATABASE ... SET timezone` and `ALTER ROLE ... SET timezone`. There is
no extension-specific setting. Every result below was produced on PostgreSQL 18
with `psql` defaults, in order, in one database named `mydb` (the instant
`2024-03-19 22:00:00+00` is 01:30 on 2024-03-20 in Tehran, which is
1403-01-01):

```sql
-- the same instant is a different Jalali day in different session zones
SET timezone = 'UTC';
SELECT timestamptz '2024-03-19 22:00:00+00'::jdate;          -- 1402-12-29
SET timezone = 'Asia/Tehran';
SELECT timestamptz '2024-03-19 22:00:00+00'::jdate;          -- 1403-01-01
SELECT jdate_format(timestamptz '2024-03-19 22:00:00+00');   -- 1403-01-01 01:30:00
SELECT '1403-01-01'::jdate::timestamptz;                     -- 2024-03-20 00:00:00+03:30

-- to_jdate(e) is the UTC day, whatever the session zone is (1710885600 is the
-- same instant, as a Unix epoch); to_jdate(e, zone) takes the day in the zone
-- you name, whatever the session zone is
SELECT to_jdate(1710885600);                                 -- 1402-12-29
SELECT to_jdate(1710885600, 'Asia/Tehran');                  -- 1403-01-01
SELECT to_jdate(1710885600, 'America/New_York');             -- 1402-12-29
SELECT to_timestamp(1710885600)::jdate;                      -- 1403-01-01 (the session zone is Asia/Tehran)
SELECT to_jdate(1710885600, 'Asia/Tehran') = to_timestamp(1710885600)::jdate;  -- t

-- an unknown zone is core's error (SQLSTATE 22023), even for infinity
SELECT to_jdate(1710885600, 'No/Such_Zone');                 -- ERROR: time zone "No/Such_Zone" not recognized
SELECT to_jdate('infinity', 'No/Such_Zone');                 -- ERROR: time zone "No/Such_Zone" not recognized
SELECT to_jdate('infinity', 'Asia/Tehran');                  -- infinity

-- epochs never depend on the zone: an instant has one epoch, a jdate's epoch
-- is midnight UTC of that day
SELECT EXTRACT(epoch FROM '1403-01-01'::jdate);                       -- 1710892800
SELECT EXTRACT(epoch FROM timestamptz '2024-03-19 22:00:00+00');      -- 1710885600.000000

-- the default for a database or a role (new sessions pick it up; a database
-- setting is overridden by a role-in-database setting, and either by SET)
ALTER DATABASE mydb SET timezone = 'Asia/Tehran';
ALTER ROLE app_user IN DATABASE mydb SET timezone = 'America/New_York';
```

`to_jdate(e, zone)` is `IMMUTABLE`, like core's `timezone(text, timestamptz)`
that it is built on, so unlike the casts above it can be used in an index
expression (the answer depends on the time zone database, not on a setting that
can change between sessions). The full table, function by function, is in
[the specification](docs/SPECIFICATION.md#time-zones).

### Coming from jalali_utils

jalali_utils hardcodes `Asia/Tehran`. To get the same days here, either set
the zone once, `SET timezone = 'Asia/Tehran'` (or make it the default for the
database or role as above) and use the `timestamptz` casts, or name it on each
call with `to_jdate(e, 'Asia/Tehran')`. The one-argument `to_jdate(e)` is the
UTC day instead, which differs from the Tehran day for instants in the first
3 hours 30 minutes of each Tehran day (Tehran is at UTC+3:30; the example
above is 01:30 there).

jalali_utils has four functions (checked against its README):
`format_jalali(timestamptz, with_time boolean DEFAULT true)`,
`format_jalali(date)`, `jalali_part(text, timestamptz)` and
`jalali_part(text, date)`. The equivalents here:

| jalali_utils | here |
| --- | --- |
| `format_jalali(ts, with_time)` | `jdate_format(ts, with_time)` for a core `timestamptz`, or store the value as a `jtimestamptz` and print it (`x::text`, always Jalali) |
| `format_jalali(date)` | `'...'::jdate` printed (`d::jdate::text`), or `jday_format(d::jdate)` |
| `jalali_part(unit, timestamptz)` | `jdate_part(unit, x::jtimestamptz)` or `EXTRACT(unit FROM x::jtimestamptz)` (numeric; the zone is the session `TimeZone`, not a hardcoded one) |
| `jalali_part(unit, date)` | `jdate_part(unit, d::jdate)` (bigint) or `EXTRACT(unit FROM d::jdate)` |
| (no counterpart) | `jday_format(x [, sep])` and `jmonth_format(x [, sep])`, the text keys `YYYY-MM-DD` and `YYYY-MM` for `GROUP BY` and for indexes, on `jdate`, `jtimestamp` and `jtimestamptz` |

Set `timezone` to `Asia/Tehran` for the same days as jalali_utils gives, as
described above.

## Specification

The full specification is in [docs/SPECIFICATION.md](docs/SPECIFICATION.md): the
supported range, the calendar algorithm, text and binary I/O, every error and
its SQLSTATE, infinity, soft errors, operators, casts, functions, field names,
indexing, hashing and partitioning, volatility and parallel safety, the Jalali
timestamp types (safe range, interval arithmetic and daylight saving time,
series, bins, zones, fields, truncation, keys, index recipes, range types,
selectivity, the ambiguity list and the known differences from core), extension
properties and the supported PostgreSQL versions. Each statement in it was
checked against the sources, the tests, or a running cluster. The essentials
for `jdate` (the timestamp types have the rows below):

| | |
| --- | --- |
| Type | `jdate`, a base type (array type `jdate[]`); category `D` (date/time), not preferred |
| Storage | 4 bytes, passed by value, `int4` alignment, `STORAGE plain`; the same `int32` as `date` (days since 2000-01-01) |
| Supported days | 1,183,020: Jalali `-0061-01-01` to `3177-12-29` = Gregorian `0560-03-20` to `3799-03-19`; plus `infinity` and `-infinity` |
| Text I/O | `[-]YYYY-MM-DD`; independent of `DateStyle` and `TimeZone` |
| Binary I/O | `date`'s wire format (big-endian `int32`); receive validates the range |
| Comparison | `=` `<>` `<` `<=` `>` `>=`; default btree (`jdate_ops`) and hash (`jdate_hash_ops`) operator classes, and the same pair for the timestamp types (`jtimestamp_ops`, `jtimestamp_hash_ops`, `jtimestamptz_ops`, `jtimestamptz_hash_ops`); `min()`/`max()` |
| Arithmetic | `jdate + int`, `int + jdate`, `jdate - int`, `jdate - jdate` (days); `jdate`, `jtimestamp` and `jtimestamptz` with `interval` (Jalali months, clamped) and `time` |
| Casts | all assignment-level: `date`, `timestamp`, `timestamptz` to and from `jdate`; the timestamp types have their own matrix and no implicit casts |
| Fields | `EXTRACT(... FROM jdate)` (numeric), `jdate_part` (bigint, NULL on infinity), `jdate_trunc` (`year`, `quarter`, `month`, `week` from Saturday, `day`); `to_jdate(e)` (the UTC day), `to_jdate(e, zone)` (the day in a named zone), `jdate_format`; `dow` is Saturday-first (0 = Saturday .. 6 = Friday, `dow + 1` is 1-based), `isodow` is ISO 8601 (1 = Monday .. 7 = Sunday) |
| Errors | SQLSTATE `22007`, `22008`, `22009`, `22023`, `0A000`, `42725` for an ambiguous untyped literal (see [the tables](docs/SPECIFICATION.md#errors-and-sqlstates)) |
| Timestamp types | `jtimestamp`, `jtimestamptz`: 8 bytes, core's representation and wire format, Jalali text; `jtimestamptz` accepts the safe range (the Jalali range less 16 hours at each end); `+`/`-` interval with Jalali months, `jdate_bin`, `jgenerate_series`, `AT TIME ZONE`, `OVERLAPS`, `EXTRACT` / `jdate_part` (numeric), `jdate_trunc`, `jday_format`, `jmonth_format`, cross-type comparison in one btree family (`jdatetime_ops`), `min` / `max`, btree and hash classes |
| Range types | `jdaterange`, `jtsrange`, `jtstzrange` and their multiranges |
| Extension | version 1.0, **not relocatable**, superuser to install, nine overloads (`extract`, `timezone`, `overlaps`) live in `pg_catalog` |
| PostgreSQL | 16 or later; the regression suite runs in CI on 16, 17 and 18 (the local harness is 18 only) |

## Testing

There are five layers: a standalone C test of the calendar code, the
`pg_regress` suite (36 test files), a `pg_dump`/restore round trip, a `pgbench`
concurrency stress run and a performance report. CI (GitHub Actions,
`.github/workflows/ci.yml`) runs all of them on PostgreSQL 16, 17 and 18 for
every push to `develop` and every pull request. The local harness runs the
first three on PostgreSQL 18 only, without root:

```sh
dev/test-cluster.sh check
```

[docs/TESTING.md](docs/TESTING.md) covers the CI jobs, running the tests
locally, what each test proves, run times, and what is not covered.

## Credits

The Jalali↔Gregorian conversion is Kazimierz M. Borkowski's algorithm,
ported with reference to [`jalaali-js`](https://github.com/jalaali/jalaali-js)
(MIT, © Behrang Norouzinia).

## License

MIT — see [LICENSE](LICENSE).
