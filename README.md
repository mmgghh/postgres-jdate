# jdate

[![CI](https://github.com/mmgghh/postgres-jdate/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/mmgghh/postgres-jdate/actions/workflows/ci.yml)

A native PostgreSQL type for the Jalali (Persian / Solar Hijri) calendar.

Unlike text-based Jalali helpers (this project supersedes
[`jalali_utils`](https://github.com/teamappir/jalali_utils)), `jdate` is a
real 4-byte base type, **binary-compatible with Postgres's own `date`**: it
stores the same 4 bytes (days since 2000-01-01), so `jdate -> date` is a free
cast, and comparisons, sorting, indexing, and `GROUP BY`/`DISTINCT` all reuse
Postgres's own hardened `date` machinery instead of re-parsing strings. The
other direction is checked, not free: `date` covers far more days than the
Jalali algorithm does, so `date -> jdate` validates the supported range (see
[Supported range](docs/SPECIFICATION.md#supported-range)).

Date math uses the algorithm published by Kazimierz M. Borkowski (*The Persian
calendar for 3000 years*, 1996), the same one used by
[`jalaali-js`](https://github.com/jalaali/jalaali-js): a table of break years
that corrects the 33-year leap cycle, published as exact for Jalali years `-61`
to `3177` (Gregorian 0560-03-20 to 3799-03-19), rather than a plain 33-year
rule (see [The calendar algorithm](docs/SPECIFICATION.md#the-calendar-algorithm)).

**Contents:**
[Install](#install) ·
[Usage](#usage) ·
[Specification](#specification) ([full text](docs/SPECIFICATION.md)) ·
[Testing](#testing) ([full text](docs/TESTING.md)) ·
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

The type, its operators, operator classes, aggregates and functions all go in
`s`, except one function. `EXTRACT(field FROM x)` always resolves to
`pg_catalog.extract(text, ...)`, so the `extract(text, jdate)` overload that
makes `EXTRACT(... FROM jdate)` work lives in `pg_catalog`, and the server
cannot move it along with the rest of the extension. That is also why
`EXTRACT` works whether or not `s` is on the `search_path` (the type itself
then has to be written `s.jdate`). `ALTER EXTENSION jdate SET SCHEMA ...` is
refused (`extension "jdate" does not support SET SCHEMA`, SQLSTATE `0A000`);
to use a different schema, drop and recreate the extension. `DROP EXTENSION`
removes `pg_catalog.extract(text, jdate)` again.

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
SELECT jdate_part('year', '1403-05-15'::jdate);     -- 1403
SELECT jdate_part('quarter', '1403-05-15'::jdate);  -- 2
SELECT EXTRACT(month FROM '1403-05-15'::jdate);     -- 5
SELECT jdate_trunc('month', '1403-05-15'::jdate);   -- 1403-05-01
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

-- infinity follows core's date (see Infinity below): units that only grow
-- give +/-Infinity, units that cycle give NULL
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

-- Jalali date + local clock time for a timestamptz, respecting the
-- session's TimeZone (a bridge: there is no native Jalali timestamp type yet)
SET timezone = 'UTC';
SELECT jdate_format(timestamptz '2024-03-20 12:03:41.482917+00');         -- 1403-01-01 12:03:41.482917
SELECT jdate_format(timestamptz '2024-03-20 12:03:41.482917+00', false);  -- 1403-01-01
SELECT jdate_format('infinity'::timestamptz);                             -- infinity
SELECT jdate_format('-infinity'::timestamptz, false);                     -- -infinity
SELECT jdate_format(now());                         -- the current moment (varies)
```

## Specification

The full specification is in [docs/SPECIFICATION.md](docs/SPECIFICATION.md): the
supported range, the calendar algorithm, text and binary I/O, every error and
its SQLSTATE, infinity, soft errors, operators, casts, functions, field names,
indexing, hashing and partitioning, volatility and parallel safety, extension
properties and the supported PostgreSQL versions. Each statement in it was
checked against the sources, the tests, or a running cluster. The essentials:

| | |
| --- | --- |
| Type | `jdate`, a base type (array type `jdate[]`); category `D` (date/time), not preferred |
| Storage | 4 bytes, passed by value, `int4` alignment, `STORAGE plain`; the same `int32` as `date` (days since 2000-01-01) |
| Supported days | 1,183,020: Jalali `-0061-01-01` to `3177-12-29` = Gregorian `0560-03-20` to `3799-03-19`; plus `infinity` and `-infinity` |
| Text I/O | `[-]YYYY-MM-DD`; independent of `DateStyle` and `TimeZone` |
| Binary I/O | `date`'s wire format (big-endian `int32`); receive validates the range |
| Comparison | `=` `<>` `<` `<=` `>` `>=`; default btree and hash operator classes; `min()`/`max()` |
| Arithmetic | `jdate + int`, `int + jdate`, `jdate - int`, `jdate - jdate` (days) |
| Casts | all assignment-level: `date`, `timestamp`, `timestamptz` to and from `jdate` |
| Fields | `EXTRACT(... FROM jdate)`, `jdate_part`, `jdate_trunc`; `to_jdate`, `jdate_format`; `dow` is Saturday-first (0 = Saturday .. 6 = Friday, `dow + 1` is 1-based), `isodow` is ISO 8601 (1 = Monday .. 7 = Sunday) |
| Errors | SQLSTATE `22007`, `22008`, `22023`, `0A000` (see [the table](docs/SPECIFICATION.md#errors-and-sqlstates)) |
| Extension | version 1.0, **not relocatable**, superuser to install, `extract(text, jdate)` lives in `pg_catalog` |
| PostgreSQL | 16 or later; the regression suite runs in CI on 16, 17 and 18 (the local harness is 18 only) |

## Testing

There are five layers: a standalone C test of the calendar code, the
`pg_regress` suite (15 test files), a `pg_dump`/restore round trip, a `pgbench`
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
