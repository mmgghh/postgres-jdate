# jdate

A native PostgreSQL type for the Jalali (Persian / Solar Hijri) calendar.

Unlike text-based Jalali helpers (this project supersedes
[`jalali_utils`](https://github.com/teamappir/jalali_utils)), `jdate` is a
real 4-byte base type, **binary-compatible with Postgres's own `date`** —
casting between them is free, and comparisons, sorting, indexing, and
`GROUP BY`/`DISTINCT` all reuse Postgres's own hardened `date` machinery
instead of re-parsing strings.

Date math uses the astronomical algorithm published by Kazimierz M.
Borkowski (*The Persian calendar for 3000 years*, 1996), the same one
used by [`jalaali-js`](https://github.com/jalaali/jalaali-js) — exact for
Jalali years `-61` to `3177` (≈ Gregorian 560–3798), rather than the
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

-- free casts to/from date: same day, same 4 bytes, different calendar
SELECT '1403-01-01'::jdate::date;           -- 2024-03-20
SELECT '2024-03-20'::date::jdate;           -- 1403-01-01

-- casts to/from timestamp / timestamptz (assignment-level: explicit
-- or in an INSERT/assignment context, not silently applied elsewhere)
SELECT '1403-01-01'::jdate::timestamptz;
SELECT now()::jdate;

-- comparison, sorting, indexing all work natively
CREATE TABLE events (happened_on jdate, name text);
CREATE INDEX ON events (happened_on);
SELECT * FROM events WHERE happened_on > '1402-01-01'::jdate ORDER BY happened_on;
SELECT min(happened_on), max(happened_on) FROM events;

-- arithmetic
SELECT '1403-01-01'::jdate + 10;
SELECT '1403-01-10'::jdate - '1403-01-01'::jdate;   -- 9

-- field access
SELECT jdate_part('year', happened_on), jdate_part('quarter', happened_on) FROM events;
SELECT EXTRACT(year FROM happened_on) FROM events;   -- EXTRACT(...) works too
SELECT jdate_trunc('month', happened_on) FROM events;

-- Unix epoch (seconds since 1970-01-01 UTC), same as date/timestamp
SELECT EXTRACT(epoch FROM '1403-01-01'::jdate);      -- 1710892800
SELECT to_jdate(1710892800);                         -- 1403-01-01

-- Jalali date + local clock time for a timestamptz, respecting the
-- session's TimeZone (until a native jtimestamptz type ships -- see
-- docs/design/)
SELECT jdate_format(now());                  -- '1403-05-15 12:03:41'
SELECT jdate_format(now(), false);           -- '1403-05-15'
```

## Supported range

Jalali years `-61` through `3177` inclusive — the range Borkowski's
algorithm is exact for. Values outside it raise a clear error rather than
silently producing a wrong date.

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
