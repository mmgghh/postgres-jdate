# jdate

A native PostgreSQL type for the Jalali (Persian / Solar Hijri) calendar.

Unlike text-based Jalali helpers (this project supersedes
[`jalali_utils`](https://github.com/teamappir/jalali_utils)), `jdate` is a
real 4-byte base type, **binary-compatible with Postgres's own `date`**: it
stores the same 4 bytes (days since 2000-01-01), so `jdate -> date` is a free
cast, and comparisons, sorting, indexing, and `GROUP BY`/`DISTINCT` all reuse
Postgres's own hardened `date` machinery instead of re-parsing strings. The
other direction is checked, not free: `date` covers far more days than the
Jalali algorithm does, so `date -> jdate` validates the supported range (see
[Supported range](#supported-range)).

Date math uses the astronomical algorithm published by Kazimierz M.
Borkowski (*The Persian calendar for 3000 years*, 1996), the same one
used by [`jalaali-js`](https://github.com/jalaali/jalaali-js) — exact for
Jalali years `-61` to `3177` (Gregorian 560–3799), rather than the
33-year-cycle approximation older tools rely on.

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

Then, connected to the target database:

```sql
CREATE EXTENSION jdate;
```

Requires PostgreSQL 16 or later (`make` stops with an error on PostgreSQL 12
to 15). Two features need more than that baseline: `pg_input_is_valid()` and
`pg_input_error_info()` work with `jdate` from 16, while `COPY ...
(ON_ERROR ignore)` skipping bad `jdate` values needs 17 (see
[Soft errors](#soft-errors)).

### Installing into a schema

The extension is **not relocatable**: choose its schema when you create it,
`CREATE EXTENSION jdate SCHEMA s`, and it stays there.

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
to use a different schema, drop and recreate the extension.

## Usage

```sql
-- literals, ISO-ordered
SELECT '1403-01-01'::jdate;                 -- 1403-01-01 (Nowruz 1403)
SELECT 'infinity'::jdate, '-infinity'::jdate;

-- jdate -> date is free: same day, same 4 bytes, different calendar
SELECT '1403-01-01'::jdate::date;           -- 2024-03-20
-- date -> jdate is the same day, but checked against the supported range
SELECT '2024-03-20'::date::jdate;           -- 1403-01-01
SELECT '9999-12-31'::date::jdate;           -- ERROR (SQLSTATE 22008): out of range

-- casts to/from timestamp / timestamptz (assignment-level: explicit
-- or in an INSERT/assignment context, not silently applied elsewhere).
-- Like date -> jdate, timestamp[tz] -> jdate is range-checked, and
-- timestamptz -> jdate takes the date in the session's TimeZone
SELECT '1403-01-01'::jdate::timestamptz;
SELECT now()::jdate;

-- comparison, sorting, indexing all work natively (btree and hash operator
-- classes, so hash joins, hash indexes and PARTITION BY HASH work too)
CREATE TABLE events (happened_on jdate, name text);
CREATE INDEX ON events (happened_on);
SELECT * FROM events WHERE happened_on > '1402-01-01'::jdate ORDER BY happened_on;
SELECT min(happened_on), max(happened_on) FROM events;

-- arithmetic: add or subtract days, or subtract two dates to get days
SELECT '1403-01-01'::jdate + 10;                    -- 1403-01-11
SELECT 10 + '1403-01-01'::jdate;                    -- 1403-01-11 (int + jdate too)
SELECT '1403-01-11'::jdate - 10;                    -- 1403-01-01
SELECT '1403-01-10'::jdate - '1403-01-01'::jdate;   -- 9
-- a result outside the supported range is rejected when it is computed
SELECT '3177-12-29'::jdate + 1;                     -- ERROR (SQLSTATE 22008)

-- field access
SELECT jdate_part('year', happened_on), jdate_part('quarter', happened_on) FROM events;
SELECT EXTRACT(year FROM happened_on) FROM events;   -- EXTRACT(...) works too
SELECT jdate_trunc('month', happened_on) FROM events;
-- decade is year / 10 rounded down, as in core (202 for 2024), not the
-- first year of the decade
SELECT jdate_part('decade', '1403-05-15'::jdate);    -- 140

-- dow (0 = Sunday), isodow (1 = Monday .. 7 = Sunday) and epoch do not depend
-- on the calendar, so they equal core's answer for the same day
SELECT jdate_part('dow', '1403-01-01'::jdate);       -- 3 (a Wednesday)
SELECT jdate_part('isodow', '1403-01-01'::jdate);    -- 3

-- Unix epoch (seconds since 1970-01-01 UTC), same as date/timestamp
SELECT EXTRACT(epoch FROM '1403-01-01'::jdate);      -- 1710892800
SELECT to_jdate(1710892800);                         -- 1403-01-01

-- infinity follows core's date (see Infinity below): units that only grow
-- give +/-Infinity, units that cycle give NULL
SELECT EXTRACT(year FROM 'infinity'::jdate);         -- Infinity
SELECT EXTRACT(century FROM '-infinity'::jdate);     -- -Infinity
SELECT EXTRACT(month FROM 'infinity'::jdate);        -- NULL

-- to_jdate() is the Jalali date of the UTC day that contains the timestamp.
-- The session TimeZone plays no part, so the answer is the same in every
-- zone and the function is IMMUTABLE (it can be used in an index). Going
-- through to_timestamp() instead gives the *local* day, which can differ.
SET timezone = 'America/New_York';
SELECT to_jdate(1710892800);                         -- 1403-01-01
SELECT to_timestamp(1710892800)::jdate;              -- 1402-12-29

-- Jalali date + local clock time for a timestamptz, respecting the
-- session's TimeZone (a bridge: there is no native Jalali timestamp type yet)
SELECT jdate_format(now());                  -- '1403-05-15 12:03:41.482917'
SELECT jdate_format(now(), false);           -- '1403-05-15'
SELECT jdate_format('infinity'::timestamptz);        -- 'infinity'
SELECT jdate_format('-infinity'::timestamptz, false); -- '-infinity'
```

## Supported range

Jalali years `-61` through `3177` inclusive, that is `-0061-01-01` to
`3177-12-29` (Gregorian `0560-03-20` to `3799-03-19`) — the range Borkowski's
algorithm is exact for. `infinity` and `-infinity` are always valid. Values
outside the range raise a clear error rather than silently producing a wrong
date.

The range is enforced on every path that produces a `jdate`, so a value that
could never be displayed can never be stored:

- text input, including a year, month or day too large for a 32-bit integer
  (which is an error, not a wrapped value);
- binary input (`COPY ... (FORMAT binary)`, binary-protocol parameters);
- arithmetic: `jdate + int`, `int + jdate` and `jdate - int`;
- the `date`, `timestamp` and `timestamptz` casts to `jdate`;
- `to_jdate(double precision)`, which also rejects `NaN`.

Each raises SQLSTATE `22008` (`datetime_value_out_of_range`) and the statement
stores nothing; text that cannot be read as a year-month-day triple at all
raises `22007` (`invalid_datetime_format`). `jdate -> date` and the casts to
`timestamp`/`timestamptz` cannot fail, since every `jdate` is a valid `date`.

## Infinity

`infinity` and `-infinity` are valid `jdate` values, with no calendar date to
convert, so the field functions answer the same way core's `date` does. This
applies to `jdate_part(unit, x)` (a `double precision`) and to
`EXTRACT(unit FROM x)` (a `numeric`):

| unit | `infinity` | `-infinity` |
| --- | --- | --- |
| `year`, `decade`, `century`, `epoch` | `Infinity` | `-Infinity` |
| `month`, `day`, `quarter`, `doy`, `dow`, `isodow` | `NULL` | `NULL` |
| `hour`, `minute`, `second`, `milliseconds`, `microseconds` | `NULL` | `NULL` |

The units that only grow with time are infinite, the ones that cycle have no
value. The time-of-day units are `0` for every finite `jdate`, but `NULL` for
infinity. A unit `jdate_part` does not support (such as `week`) is still an
error for infinity, as for any other value. `jdate_trunc` returns an infinite
value unchanged, and `jdate_format(timestamptz)` returns `'infinity'` or
`'-infinity'` (with or without the time, in any `TimeZone`), the same text
`jdate_out` produces.

## Soft errors

Text input reports bad values as *soft* errors (the PostgreSQL 16 error
saving API), so a bad value can be tested for or skipped instead of aborting
the statement:

```sql
SELECT pg_input_is_valid('1403-13-01', 'jdate');                    -- false
SELECT pg_input_is_valid('{1403-01-01,x}', 'jdate[]');              -- false (one bad element)
SELECT message, sql_error_code FROM pg_input_error_info('3178-01-01', 'jdate');
--   date out of range for type jdate: "3178-01-01" | 22008

-- PostgreSQL 17+: load the good rows, skip the bad ones
COPY events (happened_on, name) FROM STDIN (FORMAT csv, ON_ERROR ignore);
1403-01-01,Nowruz
1403-13-01,not a date
1403-01-13,Sizdah Bedar
\.
```

The errors keep their SQLSTATEs (`22007` for text that cannot be read as a
date, `22008` for a value out of range), and a bad value still raises an
ordinary error where nothing asks for soft handling: `'garbage'::jdate`, and
`COPY` with the default `ON_ERROR stop`, which stops at the first bad row and
loads nothing. Only text input is soft. Binary input, arithmetic and the casts
from `date`, `timestamp` and `timestamptz` always raise.

## Testing

There are three layers: a standalone C test of the calendar code, the
`pg_regress` suite, and a `pg_dump`/restore round trip. The last two run on a
local, self-owned PostgreSQL instance, so none of it needs root.

### The calendar code on its own

```sh
make test-jalaali
```

Compiles `src/jalaali.c` and `src/test_jalaali.c` with the plain C compiler
(no server and no PostgreSQL headers; `pg_config` must still be on the `PATH`
because the `Makefile` includes PGXS) and runs the result in about a second.
It walks all 1,183,020 days of the supported range: converting a day number
to a Jalali date and back returns the same day, consecutive days are
consecutive, and the Jalali and Gregorian conversions agree in both directions
with an independent Gregorian implementation written in the test itself. It
also checks the range boundaries (one day past either end is rejected) and the
Nowruz dates. It uses `assert()`, so it refuses to build with `NDEBUG`; it
aborts on the first failed check and prints a one-line summary when everything
holds.

### The regression suite and the dump round trip

Installing a C extension normally needs root (writing into the server's
`pkglibdir`/`sharedir`). `dev/test-cluster.sh` avoids that by running a
self-owned PostgreSQL 18 instance in `.dev/` that points
`extension_control_path` and `dynamic_library_path` at a directory the script
fully controls:

```sh
dev/test-cluster.sh check              # setup, start, build, then all three test
                                       # layers below -- no root, ever
dev/test-cluster.sh check io fields    # the same, but only the named regression tests
dev/test-cluster.sh tests              # print the regression test names
dev/test-cluster.sh dumptest           # only the pg_dump/restore round trip
dev/test-cluster.sh jalaali            # only `make test-jalaali`
dev/test-cluster.sh stop               # stop the local cluster
```

`check` is idempotent and runs, in this order:

1. `pg_regress` over every entry of `REGRESS` in the `Makefile`, the single list
   the script reads (or only the names given). Output lands in `test/results/`,
   and a failure writes `test/regression.diffs`.
2. `dev/dump-roundtrip.sh` (`dumptest`). It builds a database of boundary days,
   a negative year, year `0000`, both infinities, a `jdate[]` column, a column
   default and `CHECK`, btree and hash indexes, a `PARTITION BY HASH` table and
   a view over `EXTRACT`. It dumps that three ways (plain, plain with
   `--inserts`, and custom format with `pg_restore`), restores each into a
   fresh database and compares every value (as text and as its binary form),
   index, default, constraint, partition bound and view definition with the
   source. `pg_dump -t <table>` must also succeed. The whole thing runs twice,
   with the extension in the default schema and with `CREATE EXTENSION jdate
   SCHEMA ...`.
3. `make test-jalaali`, described above.

The regression tests are `io` (also runs `CREATE EXTENSION`), `casts`,
`operators`, `arithmetic`, `fields`, `format`, `range` (every path that can
produce a `jdate`, with SQLSTATEs), `binary`, `hash` (the hash operator class,
including `PARTITION BY HASH`), `fullrange`, `softerr` and `extension_schema`.
`fullrange` is the exhaustive one: it covers all 1,183,020 days and
cross-checks the Jalali fields against core's own Gregorian date machinery
rather than against `src/jalaali.c`, so a conversion bug cannot cancel itself
out. `extension_schema` drops and recreates the extension, so it stays last.

The first `setup` needs network access, `curl` and `dpkg-deb`: it downloads the
PostgreSQL 18 server development package from `apt.postgresql.org` and unpacks it
under `.dev/` (nothing is installed system-wide), and it expects the PostgreSQL 18
server binaries in `/usr/lib/postgresql/18/bin`. The cluster listens on port
`55439` (override with `JDATE_DEV_PORT`) and keeps running after `check`; use
`stop` when you are done.

The harness needs PostgreSQL 18, because `extension_control_path` is new in
18, while the extension itself supports 16 and later. Only the 18 harness runs
the suite; other majors are not exercised here. One test needs more than the
baseline: the `COPY ... (ON_ERROR ignore)` cases in `softerr` need PostgreSQL
17, so on 16 that one file's output would differ.

The `Makefile`/`make install` path above remains the normal way to install the
extension for real use; the harness is for local development and testing.

## Credits

The Jalali↔Gregorian conversion is Kazimierz M. Borkowski's algorithm,
ported with reference to [`jalaali-js`](https://github.com/jalaali/jalaali-js)
(MIT, © Behrang Norouzinia).

## License

MIT — see [LICENSE](LICENSE).
