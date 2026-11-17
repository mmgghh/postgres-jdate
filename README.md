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

Then, connected to the target database:

```sql
CREATE EXTENSION jdate;
```

Requires PostgreSQL 14 or later.

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

-- Unix epoch (seconds since 1970-01-01 UTC), same as date/timestamp
SELECT EXTRACT(epoch FROM '1403-01-01'::jdate);      -- 1710892800
SELECT to_jdate(1710892800);                         -- 1403-01-01

-- to_jdate() is the Jalali date of the UTC day that contains the timestamp.
-- The session TimeZone plays no part, so the answer is the same in every
-- zone and the function is IMMUTABLE (it can be used in an index). Going
-- through to_timestamp() instead gives the *local* day, which can differ.
SET timezone = 'America/New_York';
SELECT to_jdate(1710892800);                         -- 1403-01-01
SELECT to_timestamp(1710892800)::jdate;              -- 1402-12-29

-- Jalali date + local clock time for a timestamptz, respecting the
-- session's TimeZone (until a native jtimestamptz type ships -- see
-- docs/design/)
SELECT jdate_format(now());                  -- '1403-05-15 12:03:41.482917'
SELECT jdate_format(now(), false);           -- '1403-05-15'
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

## Testing without root

Installing a C extension normally needs root (writing into the server's
`pkglibdir`/`sharedir`). `dev/test-cluster.sh` avoids that by running a
self-owned PostgreSQL 18 instance that points `extension_control_path`
and `dynamic_library_path` (PG18+) at a directory it fully controls:

```sh
dev/test-cluster.sh check   # fetches PG18 headers once, initdb's a local
                             # cluster, builds jdate.so, runs the full
                             # pg_regress suite -- no root, ever
```

This is for local development/testing only; the `Makefile`/`make install`
path above is the normal, standard way to install the extension for real
use.

## Credits

The Jalali↔Gregorian conversion is Kazimierz M. Borkowski's algorithm,
ported with reference to [`jalaali-js`](https://github.com/jalaali/jalaali-js)
(MIT, © Behrang Norouzinia).

## License

MIT — see [LICENSE](LICENSE).
