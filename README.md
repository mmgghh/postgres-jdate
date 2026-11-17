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

Date math uses the algorithm published by Kazimierz M. Borkowski (*The Persian
calendar for 3000 years*, 1996), the same one used by
[`jalaali-js`](https://github.com/jalaali/jalaali-js): a table of break years
that corrects the 33-year leap cycle, published as exact for Jalali years `-61`
to `3177` (Gregorian 0560-03-20 to 3799-03-19), rather than a plain 33-year
rule (see [The calendar algorithm](#the-calendar-algorithm)).

**Contents:**
[Install](#install) ·
[Usage](#usage) ·
[Specification](#specification) ·
[Testing](#testing) ·
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
[Soft errors](#soft-errors)). What has actually been run on which version is
listed under [Supported PostgreSQL versions](#supported-postgresql-versions).

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
-- decade is year / 10 rounded down, as in core (202 for 2024), not the
-- first year of the decade
SELECT jdate_part('decade', '1403-05-15'::jdate);   -- 140

-- dow (0 = Sunday), isodow (1 = Monday .. 7 = Sunday) and epoch do not depend
-- on the calendar, so they equal core's answer for the same day
SELECT jdate_part('dow', '1403-01-01'::jdate);      -- 3
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

Everything in this section was checked against `src/`, `jdate--1.0.sql`,
`jdate.control`, the tests, or by running the statement on the development
cluster. Where a behaviour is pinned by the regression suite, the test is
named; see [Testing](#testing) for what each test covers and what is not
covered.

- [At a glance](#at-a-glance)
- [Type and storage](#type-and-storage)
- [Supported range](#supported-range) and [The calendar algorithm](#the-calendar-algorithm)
- [Text input](#text-input), [Output](#output) and [Errors and SQLSTATEs](#errors-and-sqlstates)
- [Infinity](#infinity) and [Soft errors](#soft-errors)
- [Operators](#operators) and [Casts](#casts)
- [Functions](#functions), [Fields: `EXTRACT` and `jdate_part`](#fields-extract-and-jdate_part),
  [`jdate_trunc`](#jdate_trunc), [`to_jdate`](#to_jdate) and [`jdate_format`](#jdate_format)
- [Indexing, hashing and partitioning](#indexing-hashing-and-partitioning)
- [Function volatility and parallel safety](#function-volatility-and-parallel-safety)
- [Extension properties](#extension-properties)
- [Supported PostgreSQL versions](#supported-postgresql-versions)

### At a glance

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
| Fields | `EXTRACT(... FROM jdate)`, `jdate_part`, `jdate_trunc`; `to_jdate`, `jdate_format` |
| Errors | SQLSTATE `22007`, `22008`, `22023`, `0A000` (see [the table](#errors-and-sqlstates)) |
| Extension | version 1.0, **not relocatable**, superuser to install, `extract(text, jdate)` lives in `pg_catalog` |
| PostgreSQL | 16 or later; runtime tests run on 18 only |

### Type and storage

`jdate` is declared with `INTERNALLENGTH = 4`, `PASSEDBYVALUE`,
`ALIGNMENT = int4`, `STORAGE = plain`, category `D`. A value is the same
`int32` that `date` stores: the number of days since 2000-01-01 (negative
before it). The Jalali range is the stored values `-525870` to `657149`.
`infinity` and `-infinity` are stored as `date`'s own infinity values.

What binary compatibility means for the casts:

- `jdate -> date` is `WITHOUT FUNCTION`: not a byte is touched, so it is free
  and cannot fail, and the result is the same day with Gregorian digits.
- `date -> jdate` is **not** free. `date` covers 4714 BC to 5874897 AD, the
  Jalali algorithm only 0560 to 3799, and a stored out-of-range value could
  never be displayed again, so the cast runs the function `jdate(date)`, which
  raises `22008` outside the range.
- The wire format is `date`'s: a binary `COPY` file written from a `jdate`
  column can be loaded into a `date` column, and the reverse works as long as
  every day is in the Jalali range (`jdate_send(d) = date_send(d::date)`).
- Sort order is chronological, identical to the order of the same days as
  `date`.

### Supported range

| | Jalali | Gregorian (proleptic, as in `date`) | Stored value | Julian Day Number |
| --- | --- | --- | --- | --- |
| First day | `-0061-01-01` | `0560-03-20` | `-525870` | `1925675` |
| Last day | `3177-12-29` | `3799-03-19` | `657149` | `3108694` |

That is Jalali years `-61` through `3177` inclusive: 3,239 years and
1,183,020 days, 785 of the years leap (366 days) and 2,454 common. Year `3177`
is a common year, so its last day is Esfand 29 and `3177-12-30` does not
exist. Years are numbered astronomically: there is a year `0000`
(`0000-01-01` is valid). `infinity` and `-infinity` are always valid. Values
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
`io`, `binary`, `arithmetic`, `range` and `casts` pin each of these paths.

### The calendar algorithm

`src/jalaali.c` converts between a Jalali date and a Julian Day Number (the
stored value is the JDN minus 2451545, the JDN of 2000-01-01). It is
Borkowski's algorithm as ported in `jalaali-js`: a table of 20 break years
(`-61, 9, 38, ..., 3178`) between which leap years follow a 33-year cycle (8
leap years per 33); per Borkowski this reproduces the astronomical calendar
for the supported years. In this range:

- months 1 to 6 have 31 days, months 7 to 11 have 30, and month 12 (Esfand)
  has 29 days, or 30 in a leap year, so a year has 365 or 366 days;
- Farvardin 1 (Nowruz) falls on 20, 21 or 22 March of year `y + 621`;
- the day of the year (`doy`) runs 1 to 366.

The two range endpoints are computed once and cached. The tests check this
implementation for self-consistency and against core's Gregorian calendar; see
[What is not covered](#what-is-not-covered) for what they cannot show about the
leap-year table itself.

### Text input

The accepted form is `Y-M-D`: three decimal integers separated by dashes.

- Each field may carry a sign (`+1403-01-01`; a leading `-` is a negative
  year, `-0061-01-01`), may have any number of leading zeros, and need not be
  zero-padded (`1403-1-1`, `1-1-1` is `0001-01-01`).
- Whitespace is allowed around the whole string and around each dash
  (`' 1403 - 01 - 01 '`).
- `infinity` and `-infinity` are accepted in any letter case, with no
  surrounding whitespace.
- `DateStyle` is not consulted.

Rejected, with SQLSTATE `22007` (syntax): other separators (`1403/01/01`), no
separators (`14030101`), a time part (`1403-01-01 00:00:00`), trailing text,
missing fields, an empty string, and special words other than infinity (`inf`,
`epoch`, `today`, `now`). Rejected, with `22008` (range): a month outside 1 to
12, a day beyond the month's length (including `30` in Esfand of a common
year), a year outside `-61` to `3177`, and any field that does not fit in a
32-bit integer.

### Output

- **Text**: `[-]YYYY-MM-DD`, month and day with two digits and the year as a
  sign (only if negative) followed by at least four digits: `-0061-01-01`,
  `0000-01-01`, `0001-01-01`, `1403-01-01`. Infinite values print as
  `infinity` and `-infinity`. `jdate_format` prints dates the same way.
- **Binary** (`jdate_send` / `jdate_recv`): four bytes, a big-endian `int32`
  of days since 2000-01-01, exactly `date`'s format (`1403-01-01` is
  `0000228d`, 8845 days). `jdate_recv` rejects a finite value outside the range
  with `22008` and lets infinity through. It is a hard error: binary receive
  has no soft path.

### Errors and SQLSTATEs

| SQLSTATE | Condition | Raised by | Soft? |
| --- | --- | --- | --- |
| `22007` `invalid_datetime_format` | text that is not `Y-M-D` or infinity | `jdate_in` | yes |
| `22008` `datetime_value_out_of_range` | month or day out of range, year outside `-61`..`3177`, a field overflowing 32 bits | `jdate_in` | yes |
| `22008` | a finite day outside the Jalali range: binary receive, `jdate ± int`, `date`/`timestamp`/`timestamptz` casts, `to_jdate` (including `NaN` and epochs outside the range), `jdate_format` of such a day. Message: `jdate value is outside the supported Jalali range (years -61 to 3177)` | | no |
| `22008` | `jdate - jdate` with an infinite operand (`cannot subtract infinite dates`), and a day count that overflows 32 bits (`date out of range`): core's own `date` errors | core | no |
| `22023` `invalid_parameter_value` | a unit name core does not recognise: `jdate_part`, `EXTRACT`, `jdate_trunc` | | no |
| `0A000` `feature_not_supported` | a recognised but unsupported unit (`jdate_part`/`EXTRACT`: `week`, `millennium`, `julian`, `isoyear`, `timezone`, `timezone_hour`, `timezone_minute`; `jdate_trunc`: everything but `year`, `quarter`, `month`, `day`) | | no |
| `0A000` | `ALTER EXTENSION jdate SET SCHEMA` | the server | no |
| `42883` `undefined_function` | an operator or function the type does not define, such as `jdate = date`, `jdate + interval`, `jdate + bigint`, `date_part('year', jdate)` | the server | no |
| `42501` `insufficient_privilege` | `CREATE EXTENSION jdate` by a non-superuser | the server | no |

The `22007`/`22008` split for input and the `22008` paths are asserted by
SQLSTATE in `io`, `range`, `binary`, `casts`, `softerr` and `format`;
`extension_schema` asserts `0A000`. The `22023`, `0A000` (units) and `42883`
rows are pinned by message at most (see
[What is not covered](#what-is-not-covered)).

### Infinity

`infinity` and `-infinity` are valid `jdate` values, with no calendar date to
convert, so they are valid on every path (text, binary, the casts to and from
`date`, `timestamp` and `timestamptz`, `to_jdate(±Infinity)`), sort after and
before every finite day, and are unchanged by `jdate ± int`. `jdate - jdate`
raises `22008` for an infinite operand, as core's `date` does. The field
functions answer the same way core's `date` does. This applies to
`jdate_part(unit, x)` (a `double precision`) and to `EXTRACT(unit FROM x)` (a
`numeric`):

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

### Soft errors

Text input reports bad values as *soft* errors (the PostgreSQL 16 error
saving API), so a bad value can be tested for or skipped instead of aborting
the statement:

```sql
SELECT pg_input_is_valid('1403-13-01', 'jdate');                    -- f
SELECT pg_input_is_valid('{1403-01-01,x}', 'jdate[]');              -- f
SELECT message, sql_error_code FROM pg_input_error_info('3178-01-01', 'jdate');  -- date out of range for type jdate: "3178-01-01" | 22008

-- PostgreSQL 17+: load the good rows, skip the bad ones
CREATE TABLE imported (happened_on jdate, name text);
COPY imported (happened_on, name) FROM STDIN (FORMAT csv, ON_ERROR ignore);
1403-01-01,Nowruz
1403-13-01,not a date
1403-01-13,Sizdah Bedar
\.
-- NOTICE:  1 row was skipped due to data type incompatibility
SELECT count(*) FROM imported;                      -- 2
```

The errors keep their SQLSTATEs (`22007` for text that cannot be read as a
date, `22008` for a value out of range), and a bad value still raises an
ordinary error where nothing asks for soft handling: `'garbage'::jdate`, and
`COPY` with the default `ON_ERROR stop`, which stops at the first bad row and
loads nothing. Only text input is soft. Binary input, arithmetic and the casts
from `date`, `timestamp` and `timestamptz` always raise. `pg_input_is_valid`
and `pg_input_error_info` need PostgreSQL 16, `COPY ... ON_ERROR ignore` needs
17, and one bad element makes a whole array literal invalid.

### Operators

| Operator | Operands | Result | Notes |
| --- | --- | --- | --- |
| `=` `<>` `<` `<=` `>` `>=` | `jdate`, `jdate` | `boolean` | delegate to `date`'s; `=` is hashable and mergejoinable; commutators and negators declared |
| `+` | `jdate`, `integer` and `integer`, `jdate` | `jdate` | each is the other's commutator; range-checked (`22008`); infinity unchanged |
| `-` | `jdate`, `integer` | `jdate` | range-checked; infinity unchanged |
| `-` | `jdate`, `jdate` | `integer` | days between; `22008` if an operand is infinite |

Not defined: `jdate ± interval`, `jdate - date`, and comparison with `date`,
`timestamp` or `timestamptz` (`operator does not exist`, because the casts are
assignment-level, below). A `numeric` or `bigint` day count finds no operator
either; a `smallint` is promoted to `integer`. `min(jdate)` and `max(jdate)`
are aggregates of their own, returning `jdate`.

### Casts

All six casts are `ASSIGNMENT`, never `IMPLICIT`: a `jdate` and a `date` can be
the same day with completely different digits, so silently converting one to
the other inside an ordinary comparison would be surprising. An explicit
`::` cast or an assignment (`INSERT`, `UPDATE`) converts; anything else, such as
`jdate = date`, fails.

| Cast | Function | Volatility | Validates? |
| --- | --- | --- | --- |
| `jdate -> date` | none (binary coercible) | n/a | no, free, cannot fail |
| `date -> jdate` | `jdate(date)` | `IMMUTABLE` | **yes**, `22008` outside the range |
| `jdate -> timestamp` | `"timestamp"(jdate)` | `IMMUTABLE` | no, cannot fail; midnight of that day |
| `jdate -> timestamptz` | `timestamptz(jdate)` | `STABLE` | no, cannot fail; midnight of that day in the session `TimeZone` |
| `timestamp -> jdate` | `jdate(timestamp)` | `IMMUTABLE` | **yes**, `22008`; keeps the date, drops the time |
| `timestamptz -> jdate` | `jdate(timestamptz)` | `STABLE` | **yes**, `22008`; the date in the session `TimeZone` |

Assignment-only also keeps `min(jdate)`/`max(jdate)` on `jdate`'s own
aggregates: an implicit `jdate -> timestamptz` cast would let the planner
satisfy them through core's `timestamptz` aggregates instead. The cast
functions can be called directly (`jdate(date '1970-01-01')`). Casting to and
from `text` is core's generic I/O conversion (`'1403-01-01'::jdate::text`).

### Functions

| Function | Returns | Volatility | See |
| --- | --- | --- | --- |
| `jdate_part(text, jdate)` | `double precision` | `IMMUTABLE` | [Fields](#fields-extract-and-jdate_part) |
| `pg_catalog.extract(text, jdate)` (the target of `EXTRACT(field FROM x)`) | `numeric` | `IMMUTABLE` | [Fields](#fields-extract-and-jdate_part) |
| `jdate_trunc(text, jdate)` | `jdate` | `IMMUTABLE` | [`jdate_trunc`](#jdate_trunc) |
| `to_jdate(double precision)` | `jdate` | `IMMUTABLE` | [`to_jdate`](#to_jdate) |
| `jdate_format(timestamptz, with_time boolean DEFAULT true)` | `text` | `STABLE` | [`jdate_format`](#jdate_format) |
| `jdate(date)`, `jdate(timestamp)`, `jdate(timestamptz)`, `"timestamp"(jdate)`, `timestamptz(jdate)` | | see [Casts](#casts) | the cast functions |
| `min(jdate)`, `max(jdate)` | `jdate` | aggregates | [Indexing](#indexing-hashing-and-partitioning) |

The rest of what `\df` lists (`jdate_in`, `jdate_out`, `jdate_recv`,
`jdate_send`, `jdate_eq` ... `jdate_cmp`, `jdate_hash`, `jdate_hash_extended`,
`jdate_pli`, `integer_pl_jdate`, `jdate_mii`, `jdate_mi`, `jdate_smaller`,
`jdate_larger`) are the support functions behind the type, operators, operator
classes and aggregates.

There are no `jdate` overloads of `date_part`, `date_trunc`, `to_char`,
`generate_series` or `make_date`, no Jalali timestamp type and no range type:
`date_part('year', jdate)` is `undefined_function`; use `jdate_part`.

### Fields: `EXTRACT` and `jdate_part`

`jdate_part(unit, x)` returns `double precision`; `EXTRACT(unit FROM x)` calls
`pg_catalog.extract(text, jdate)` and returns `numeric`, with the same value.
Unit names are decoded by core's unit table, so they are case-insensitive and
core's abbreviations work (`y`, `mon`, `d`, `ms`); leading and trailing spaces
are not trimmed. For a finite day:

| Unit | Value | Computed from |
| --- | --- | --- |
| `year` | the Jalali year (negative for `-61`..`-1`) | Jalali date |
| `month` | 1 to 12 | Jalali date |
| `day` | 1 to 31 | Jalali date |
| `quarter` | 1 to 4: months 1-3, 4-6, 7-9, 10-12 | Jalali date |
| `doy` | 1 to 366, the day of the Jalali year (Farvardin 1 is 1) | Jalali date |
| `decade` | the year divided by 10, rounded down (like core: `202` for 2024): years 1400 to 1409 are `140`, 0 to 9 are `0`, -10 to -1 are `-1`, and `-61` is `-7` | Jalali year |
| `century` | years 1 to 100 are `1`, 1401 to 1500 are `15`, and years `-61` to `0` are `-1`; there is no century 0 (core's numbering) | Jalali year |
| `dow` | 0 (Sunday) to 6 | the day number, **calendar-agnostic** |
| `isodow` | 1 (Monday) to 7 (Sunday) | the day number, **calendar-agnostic** |
| `epoch` | seconds from 1970-01-01 00:00:00 UTC to the start of that day (negative before 1970), a multiple of 86400, exact in a `double` | the day number, **calendar-agnostic** |
| `hour`, `minute`, `second`, `milliseconds`, `microseconds` | `0` | |

`dow`, `isodow` and `epoch` equal core's answer (`date_part(unit, d::date)`)
for every day in the range, and, because they never go through the Jalali
conversion, they also work where that conversion cannot: for infinity they
give the same results as core (see [Infinity](#infinity)). `week`, `millennium`,
`julian`, `isoyear`, `timezone`, `timezone_hour` and `timezone_minute` raise
`0A000`; a name core does not know raises `22023`.

### `jdate_trunc`

`jdate_trunc(unit, jdate) returns jdate` for `year` (Farvardin 1), `quarter`
(month 1, 4, 7 or 10, day 1), `month` (day 1) and `day` (unchanged). Any other
unit is `0A000` (an unknown name is `22023`). An infinite value is returned
unchanged for any recognised unit.

### `to_jdate`

`to_jdate(double precision)` is the inverse of `EXTRACT(epoch FROM jdate)`,
mirroring `to_timestamp(double precision)`: the Jalali date of the **UTC day**
that contains the Unix timestamp. It is pure arithmetic on the epoch, so the
session `TimeZone` is irrelevant and the function is `IMMUTABLE` and can be
used in an index expression. Fractions of a second do not move the day and the
division floors, so `to_jdate(-0.5)` is the day before the Unix epoch
(`1348-10-10`; `to_jdate(0)` is `1348-10-11`). The accepted epochs run from
`-44488483200` (the first instant of `-0061-01-01`) up to but not including
`57724444800` (the instant after `3177-12-29`); anything else and `NaN` raise
`22008`, and `±Infinity` gives `±infinity`. The contrast with
`to_timestamp(x)::jdate`, which takes the day in the session zone, is in
[Usage](#usage).

### `jdate_format`

`jdate_format(timestamptz, with_time boolean DEFAULT true)` returns `text`: the
Jalali date of the timestamp as it reads in the session `TimeZone`, followed
(when `with_time`) by the local time of day, as `time_out` prints it
(`1403-01-01 12:03:41.482917`; fractional seconds only when non-zero; no time
zone offset). With `with_time = false` it is just the date, the same text as
`jdate_out`. It is `STABLE` because it depends on the `TimeZone`. Infinite
timestamps give `infinity` / `-infinity`; a day outside the Jalali range raises
`22008`. It is a bridge until a native Jalali timestamp type exists.

### Indexing, hashing and partitioning

| Operator class | Access method | Default? | Contains |
| --- | --- | --- | --- |
| `jdate_ops` | btree | yes | `<` `<=` `=` `>=` `>`; support function 1 `jdate_cmp` |
| `jdate_hash_ops` | hash | yes | `=`; support function 1 `jdate_hash` (`hashint4`) and 2 `jdate_hash_extended` (`hashint4extended`, seeded, 64-bit) |

Because both exist, `jdate` columns work with btree and hash indexes, merge and
hash joins, `HashAggregate`, `GROUP BY`/`DISTINCT`, `ORDER BY`, and `PARTITION
BY HASH` (which needs the extended hash function). `amvalidate` accepts both
classes. `=` is declared `HASHES, MERGES` with `eqsel`/`eqjoinsel`; the
ordering operators use the `scalar*sel` estimators. `min`/`max` declare
`SORTOP`. There are no GiST, GIN, BRIN or SP-GiST operator classes.

### Function volatility and parallel safety

As declared in `jdate--1.0.sql` (and checked against `pg_proc`): all 29
functions are `STRICT` and `PARALLEL SAFE`, and the two aggregates are
`PARALLEL = SAFE`. 26 functions are `IMMUTABLE`; the three that depend on the
session `TimeZone` are `STABLE`: `jdate(timestamptz)`, `timestamptz(jdate)`
and `jdate_format(timestamptz, boolean)`. In particular `to_jdate` is
`IMMUTABLE` (it is indexable), as are `jdate_part`, `extract(text, jdate)` and
`jdate_trunc`.

### Extension properties

| | |
| --- | --- |
| Name, version | `jdate`, `1.0` (one script, `jdate--1.0.sql`, no upgrade scripts) |
| `relocatable` | `false` |
| Schema | chosen at install: `CREATE EXTENSION jdate SCHEMA s` (see [Installing into a schema](#installing-into-a-schema)) |
| Privileges | superuser: the control file does not mark it trusted, and the script creates a function in `pg_catalog` |
| `requires` | nothing |
| Library | `$libdir/jdate` |

Why it is not relocatable: `EXTRACT(field FROM x)` desugars to a
schema-qualified call to `pg_catalog.extract(text, sourcetype)`, so the
`extract(text, jdate)` overload must be created in `pg_catalog` to take part in
`EXTRACT(... FROM jdate)`. That one function is outside the extension's schema,
so the server cannot move the extension (`ALTER EXTENSION ... SET SCHEMA`),
and the control file says `relocatable = false`. Every other object follows the
schema given at `CREATE EXTENSION`. `pg_dump` writes `CREATE EXTENSION jdate`
(with its schema) rather than the objects, and the dump round trip covers both
the default schema and a custom one.

### Supported PostgreSQL versions

- **Declared: PostgreSQL 16 or later.** `src/jdate.c` includes `varatt.h`
  (split out of `postgres.h` in 16) and the soft-error API (`ereturn`,
  `nodes/miscnodes.h`, new in 16). `COPY ... (ON_ERROR ignore)` with `jdate`
  needs 17.
- **Makefile guard**: after the PGXS include, `make` fails with `jdate requires
  PostgreSQL 16 or later` for `MAJORVERSION` 12 to 15. Check it without a PG15
  install: `make -n MAJORVERSION=15`. There is no guard, and no support, for 11
  and older, and no `#if` code for 14 or 15.
- **What has actually been run**: the whole regression suite, the dump round
  trip and the calendar test on **PostgreSQL 18.6 only**. On **PostgreSQL 17**
  the sources have only been *compiled* (syntax check, no warnings; see
  [Testing](#testing)). **PostgreSQL 16 has never been built or run**; its
  support is declared from the API it needs, not demonstrated.
- The local harness itself is PostgreSQL 18 only, because it relies on
  `extension_control_path`, new in 18.

## Testing

There are three layers: a standalone C test of the calendar code, the
`pg_regress` suite (12 test files), and a `pg_dump`/restore round trip. The
last two run on a local, self-owned PostgreSQL instance, so none of it needs
root. One command runs all three and fails if any does:

```sh
dev/test-cluster.sh check
```

### Running the tests

```sh
dev/test-cluster.sh check              # setup, start, build, then all three layers
dev/test-cluster.sh check io fields    # only the named regression tests (the
                                       # dump round trip and calendar test still run)
dev/test-cluster.sh test [name ...]    # only pg_regress (starts and builds; run `setup` or `check` once first)
dev/test-cluster.sh tests              # print the regression test names
dev/test-cluster.sh dumptest           # only the pg_dump/restore round trip (same prerequisite)
dev/test-cluster.sh jalaali            # only the calendar test, same as `make test-jalaali`
dev/test-cluster.sh stop               # stop the local cluster
make test-jalaali                      # the calendar test on its own, no cluster at all
```

Installing a C extension normally needs root (writing into the server's
`pkglibdir`/`sharedir`). `dev/test-cluster.sh` avoids that by running a
self-owned PostgreSQL 18 instance in `.dev/` that points
`extension_control_path` and `dynamic_library_path` at a directory the script
fully controls. `check` is idempotent and runs, in this order:

1. `pg_regress` over every entry of `REGRESS` in the `Makefile`, the single list
   the script reads (or only the names given). Output lands in `test/results/`,
   and a failure writes `test/regression.diffs`.
2. `dev/dump-roundtrip.sh` (`dumptest`), described below.
3. `make test-jalaali`, described below.

Runs are serialised with a lock (`.dev/harness.lock`), so two invocations queue
instead of clobbering the shared database. `pg_regress` forces
`PGTZ=PST8PDT` and a non-ISO `DateStyle`, so a test whose output depends on
either sets `timezone` and `DateStyle` itself first. A failure shows as a
`not ok` line plus `test/regression.diffs` (regression), `dump-roundtrip:
FAIL: ...` and exit status 1 (dump), or an assertion message (calendar).

The first `setup` needs network access, `curl` and `dpkg-deb`: it downloads the
PostgreSQL 18 server development package from `apt.postgresql.org` and unpacks it
under `.dev/` (nothing is installed system-wide), and it expects the PostgreSQL 18
server binaries in `/usr/lib/postgresql/18/bin`. The cluster listens on port
`55439` (override with `JDATE_DEV_PORT`) and keeps running after `check`; use
`stop` when you are done.

Two checks are not wired into any script:

```sh
# PostgreSQL 17 compile check (needs the 17 server headers; prints nothing when clean)
gcc -fsyntax-only -Wall -Wextra -I/usr/include/postgresql/17/server \
    -I/usr/include/postgresql/internal -Isrc src/jdate.c src/jalaali.c

# the Makefile's version guard
make -n MAJORVERSION=15      # Makefile:23: *** jdate requires PostgreSQL 16 or later.  Stop.
```

`make installcheck` is also set up (`REGRESS` and `REGRESS_OPTS` in the
`Makefile`), for a normal installation after `make install`. The harness does
not use it and it has not been run here: the development machine has no
PostgreSQL 18 server headers installed system-wide to build and install against.

### What each test proves

Every row below runs on PostgreSQL 18.6 (the regression files in the order of
`REGRESS`, then the dump round trip and the calendar test).

| Test | What it proves | Bug classes it guards |
| --- | --- | --- |
| `io` (also runs `CREATE EXTENSION`) | valid dates, both Esfand lengths, both range edges and `infinity` (any case) round-trip as text; each malformed or out-of-range text is rejected with the right SQLSTATE (`22007` vs `22008`), including month 13, day 32, day 30 in a common year, one past each end; int32 overflow in the year, month or day is `22008`, never wrapped; leading zeros, whitespace, `+` signs are accepted | wrapped integers (`'4294968699-01-01'` once read as 1403-01-01), wrong error class, grammar drift, negative-year text |
| `casts` | `jdate` to and from `date`, `timestamp`, `timestamptz` (UTC); no implicit comparison with `date`; `to_jdate` gives the UTC day under America/New_York, Asia/Tehran, Pacific/Kiritimati and UTC for 11 epoch probes (negative, day boundaries) and for both range edges; `NaN`, `1e15`..`1e300`, `±9.3e18` are `22008`; `±Infinity` maps to infinity; `to_jdate` is `IMMUTABLE` (usable in `CREATE INDEX`) | timezone-dependent `to_jdate`, truncation instead of floor on negative epochs, double-to-int overflow, wrong volatility |
| `operators` | the six comparisons, `ORDER BY`, a btree index used for `=` and ranges (`EXPLAIN`), `GROUP BY`/`DISTINCT`, `min`/`max` return `jdate` | missing operator class, `min`/`max` resolving through the `timestamptz` cast |
| `arithmetic` | `jdate ± int`, `jdate - jdate`; a result past either edge is `22008` when computed, not when displayed; `int + jdate` equals `jdate + int`, is range-checked, keeps infinity; no shell operator in `pg_operator`, the two `+` are each other's commutator | `5 + jdate` failing as a shell operator, lazy out-of-range error |
| `fields` | every unit of `jdate_part`/`EXTRACT`; `decade` for every year `-61`..`3177` against core and `floor(year/10)`, negative years included; `dow`, `isodow`, `epoch` against core for boundary dates and every day of the range (also through `EXTRACT`); ten units (`dow`, `isodow`, `epoch`, `year`, `month`, `day`, `quarter`, `doy`, `decade`, `century`) on `±infinity` against core, through `jdate_part` and `EXTRACT`; time-of-day units (`NULL` on infinity); `week` rejected; `jdate_trunc`, including infinity | decade as first year (1400 for 1403), calendar-dependent `dow`/`epoch` failing on infinity, `EXTRACT` for `date`/`timestamp` disturbed by the overload |
| `format` | `jdate_format` under Asia/Tehran and UTC (crossing midnight, with and without time); negative years print `-0061` not `-061` (years `-61`, `-10`, `-1`, `0`, `1`, `1403`, `3177`); it equals `d::text` for the first 23,000 days of the range (all the negative years and year 0) plus every 101st day of the whole range; `±infinity` in UTC and Tehran; `22008` past either edge | sign-padding in the year, infinity errors, unchecked out-of-range days |
| `range` | every path that produces a `jdate` rejects out-of-range values with `22008` and accepts both edges: `jdate ± int` (including `±2147483647`), the three casts from `date`/`timestamp`/`timestamptz` (also year 1, 9999, BC, core's own limits 4714 BC and 5874897 AD); infinity passes everywhere; the cast catalog (six casts, assignment, `jdate(date)` immutable/strict/parallel safe); a failed `INSERT` leaves the table empty and readable | the stored-but-unreadable value (one `'9999-12-31'::date` made `SELECT *` and `pg_dump -t` fail), a hole in any one path |
| `binary` | `jdate_send` equals `date_send` for six values; `COPY (FORMAT binary)` round trip; the same file reads as `date`; `jdate_recv` rejects below min, above max, 9999, year 1, core's min and max, and a bad row among good ones (`22008`, nothing loaded); both edges and both infinities are accepted | unvalidated binary receive, wire-format drift from `date` |
| `hash` | both support functions registered, `amvalidate` true; extended hash agrees with the plain hash at seed 0 (low 32 bits) and depends on the seed; `PARTITION BY HASH` with three partitions (every row lands, rows spread, pruning scans one partition, runtime pruning finds every row); a hash index is chosen and returns the right rows; Hash Join/HashAggregate give the same results as merge/nested-loop/sort | missing support function 2 (partitioning failed), wrong or inconsistent hashing, infinity in hashes |
| `fullrange` | all 1,183,020 days: text round trip and text shape, `jdate_send` = `date_send`, successive days contiguous, month and year lengths, 785 leap years, Esfand 30 only in 366-day years, Nowruz on 20-22 March of `y+621`, month starts in a fixed Gregorian window, each day's Gregorian year, `dow`/`epoch`/`doy`/`jdate_trunc` against core, text digits against `jdate_part`; three negative controls prove the checks can fail | an off-by-one or drift anywhere in the conversion, checked against *core's* Gregorian calendar rather than `jalaali.c`'s own, so an error cannot cancel itself out |
| `softerr` | `pg_input_is_valid` and `pg_input_error_info` (message and `22007`/`22008`) for good, syntax, month, day, range and overflow inputs; array input; `COPY ... (ON_ERROR ignore)` loads the good rows, skips three bad ones and emits the NOTICE; `ON_ERROR stop` still aborts | `ereport` instead of `ereturn` in `jdate_in`; hard errors that should be soft (needs 17 for the `COPY` half) |
| `extension_schema` (drops and recreates the extension, so it is last) | `extrelocatable` is false; install into schema `jdate_s`; every object is in it except `pg_catalog.extract`; `EXTRACT` works with the schema off `search_path`; `ALTER EXTENSION ... SET SCHEMA` fails with `0A000` and leaves the extension intact; `DROP EXTENSION` removes `extract` and the types; the default schema is restored | a relocatable flag that lies, objects leaking outside the schema, a dangling `pg_catalog.extract` |
| `dev/dump-roundtrip.sh` | a source database with boundary days, a negative year, `0000`, both infinities, `NULL`, a `jdate[]` column, a default and a `CHECK`, btree/hash/partial indexes, a 3-partition `PARTITION BY HASH` table and a view over `EXTRACT`/`jdate_trunc`; dumped as plain SQL, plain `--inserts` and custom + `pg_restore` into fresh databases; each restore matches the source on every value (text and binary), defaults, constraints, partition bounds, index and view definitions, type properties; `pg_dump -t` of three tables exits 0. The whole run repeats with `CREATE EXTENSION jdate SCHEMA jdate_s` | dump/restore losing or corrupting values, partition placement changing, the extension schema not surviving a restore, the original `pg_dump -t` failure |
| `src/test_jalaali.c` (`make test-jalaali`) | standalone and server-free, built with `assert()` and no `NDEBUG`: all 1,183,020 days convert to a Jalali date and back; consecutive days are consecutive, month and year lengths hold; `jalaali.c`'s Gregorian conversions agree in both directions with an independent Gregorian implementation (Fliegel and Van Flandern) and with a walk of the Gregorian calendar; the range edges (one day past either end is rejected, `min_jdn`/`max_jdn`); every year's leap value is `0..3` and `is_leap` is `leap == 0`; Nowruz and leap years for seven known dates and five years | calendar-core regressions, in milliseconds and without a server, including `jalaali.c`'s own Gregorian helpers that the SQL tests do not reach |

Measured run times (one run each on the development machine, PostgreSQL 18.6;
they will vary): `fullrange` 6.8 s and `fields` 2.5 s, which both scan the whole
range, `format` 0.2 s, `hash` 0.1 s, every other regression test under 0.03 s;
the dump round trip 2.2 s; `make test-jalaali` 0.5 s including the compile; the
whole `dev/test-cluster.sh check` about 12.5 s.

### What is not covered

- **PostgreSQL 16 and 17 at runtime.** Only 18.6 runs the suite; 17 is a compile
  check and 16 is neither built nor run. The expected files are written
  against 18, so planner output (`EXPLAIN` lines in `operators` and `hash`) or
  messages could differ on another major, and the `COPY ... ON_ERROR` half of
  `softerr` cannot run on 16 at all.
- **Time zones beyond the ones named above.** `to_jdate` is tested under four
  zones and `jdate_format` under UTC and Asia/Tehran; the `timestamptz`
  casts are tested under UTC only, and every other test either sets UTC or
  involves no time-zone-dependent operation. No test targets a daylight-saving
  change.
- **An independent check of the calendar's leap-year table.** The tests prove
  self-consistency (round trips, contiguity, month and year lengths),
  agreement with core's Gregorian calendar, Nowruz within a 20-22 March window,
  and seven known Nowruz dates and five known leap/common years. The count of
  785 leap years is pinned from the implementation's own output, and no test
  compares each year's leap status with a second Persian-calendar
  implementation or with astronomical data. The break table is trusted from
  Borkowski and `jalaali-js`.
- **Some error classes by SQLSTATE.** `22023` (unknown unit) is not tested at
  all; the `0A000` for an unsupported unit and the `42883` for mixed types are
  pinned by message only; `jdate - jdate` with an infinite operand, the
  non-superuser `CREATE EXTENSION` failure and the `text -> jdate` cast are
  not tested (their behaviour above was checked by hand on the dev cluster).
- **Finite `century`, `quarter` and `jdate_trunc('quarter')`.** Only a handful
  of values are pinned (`century` at 1403 and, against core, for infinity). The
  all-years century agreement with core was checked by a one-off query, not by
  the suite.
- **Concurrency.** Everything runs in a single session. No test uses several
  sessions, locks, or a parallel plan (the functions are marked `PARALLEL SAFE`
  but no test forces a parallel query).
- **Performance.** There are no benchmarks and no assertion on speed; the
  timings above are test runtimes only.
- **Other platforms.** The harness is a bash script using Debian/PGDG paths
  (`/usr/lib/postgresql/18`, `dpkg-deb`), and every run so far was on amd64
  Linux; Windows, macOS and other architectures have not been tried.
- **Dump and upgrade variations.** The round trip covers plain, `--inserts`
  and custom formats from and to PostgreSQL 18, not the directory or tar
  format, parallel dump, `pg_upgrade`, or a dump taken on another major
  version. The binary protocol is exercised through binary `COPY` only, not
  through `libpq` binary parameters. There is a single extension version
  (`1.0`), so no `ALTER EXTENSION ... UPDATE` path exists to test.

## Credits

The Jalali↔Gregorian conversion is Kazimierz M. Borkowski's algorithm,
ported with reference to [`jalaali-js`](https://github.com/jalaali/jalaali-js)
(MIT, © Behrang Norouzinia).

## License

MIT — see [LICENSE](LICENSE).
