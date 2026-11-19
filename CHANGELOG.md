# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases are tagged
`vMAJOR.MINOR.PATCH`. The extension version in `jdate.control` is the
`MAJOR.MINOR` part of the tag (tag `v1.0.0` is extension version `1.0`); see
[Versioning and upgrades](README.md#versioning-and-upgrades).

## [1.0.0] - 2026-11-19

The first release. One install script (`jdate--1.0.sql`), no upgrade scripts.
Requires PostgreSQL 16 or later; the regression suite runs in CI on 16, 17 and 18.

### Types

- `jdate`: a 4-byte base type for the Jalali (Persian / Solar Hijri) calendar,
  binary-compatible with `date`. Text I/O `YYYY-MM-DD`, `infinity` and
  `-infinity`, binary I/O in `date`'s wire format, an array type. Supported days
  are Jalali `-0061-01-01` to `3177-12-29` (Gregorian `0560-03-20` to
  `3799-03-19`), with the calendar algorithm of Kazimierz M. Borkowski (the one
  used by `jalaali-js`).
- `jtimestamp` and `jtimestamptz`: 8-byte types with the representation and
  binary format of `timestamp` and `timestamptz`, Jalali text input and output,
  optional fractional-second typmod. `jtimestamptz` accepts a safe range that is
  the Jalali range less 16 hours at each end.
- `jdaterange`, `jtsrange`, `jtstzrange` and their multirange types, with a
  canonical function that range-checks the bound (so the last supported day is
  the edge of `jdaterange`). Operators, `range_agg`, GiST and SP-GiST indexes and
  `EXCLUDE` constraints come from core's generic range code and are tested.

### Operators, indexing and casts

- Comparison operators, default btree and hash operator classes (`jdate_ops`,
  `jdate_hash_ops`, `jtimestamp_ops`, `jtimestamp_hash_ops`, `jtimestamptz_ops`,
  `jtimestamptz_hash_ops`), so sorting, `GROUP BY`, `DISTINCT`, hash joins, btree
  and hash indexes and `PARTITION BY HASH` work natively. `min()` and `max()`.
- Cross-type comparison of `jdate`, `jtimestamp` and `jtimestamptz` in one shared
  btree operator family.
- Restriction estimators for `<`, `<=`, `>` and `>=` that pair a lower and an upper
  bound, so a narrow `BETWEEN` on any of the three types is estimated like core's
  own types instead of at one row or a whole histogram bucket.
- Casts to and from `date`, `timestamp` and `timestamptz`, range-checked in the
  direction where core covers more days than the Jalali algorithm. There are no
  implicit casts between the timestamp types.

### Functions and arithmetic

- `jdate + int`, `jdate - int`, `jdate - jdate`; `+` and `-` with `interval` for
  all three types, using Jalali months (clamped to the month end) and, for
  `jtimestamptz`, daylight-saving rules; `jdate + time` and `jdate + timetz`.
- `EXTRACT` and `jdate_part` (Saturday-first `dow`, ISO `isodow`), `jdate_trunc`
  (week starts on Saturday), `jdate_bin`, `jgenerate_series` with Jalali month
  steps, `AT TIME ZONE`, `OVERLAPS`, `to_jdate`,
  `to_jtimestamptz`, `jdate_format` and the text keys `jday_format` and
  `jmonth_format` for `GROUP BY` and for indexes.
- Soft errors in text input (`pg_input_is_valid`, `pg_input_error_info`;
  `COPY ... (ON_ERROR ignore)` on PostgreSQL 17 and later). Whitespace around
  `infinity` is accepted, as in the core input functions.
- Volatility and parallel safety are declared per function and checked by the
  tests; `jtimestamptz` functions that read the session time zone are `STABLE`,
  and the index recipes that need a fixed zone are documented.

### Packaging

- Not relocatable: nine overloads of `extract`, `timezone` and `overlaps` live in
  `pg_catalog` so that the `EXTRACT`, `AT TIME ZONE` and `OVERLAPS` syntaxes
  work. Choose the schema at install: `CREATE EXTENSION jdate SCHEMA s`.
- Installing needs a superuser.

### Verification

- A standalone exhaustive test of the calendar code, 36 `pg_regress` files, a
  `pg_dump` / restore round trip (plain, `--inserts` and custom format, default
  and custom schema), a `pgbench` concurrency stress run, an every-day
  `jtimestamptz` sweep, a full-range sweep and a performance report. CI runs
  these on PostgreSQL 16, 17 and 18. See [docs/TESTING.md](docs/TESTING.md).

[1.0.0]: https://github.com/mmgghh/postgres-jdate/releases/tag/v1.0.0
