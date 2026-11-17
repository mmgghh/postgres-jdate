# Specification

Everything in this document was checked against `src/`, `jdate--1.0.sql`,
`jdate.control`, the tests, or by running the statement on the development
cluster. Where a behaviour is pinned by the regression suite, the test is
named; see [Testing](TESTING.md#testing) for what each test covers and what is not
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

## At a glance

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
| PostgreSQL | 16 or later; the regression suite runs in CI on 16, 17 and 18 (the local harness is 18 only) |

## Type and storage

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

## Supported range

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

## The calendar algorithm

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
[What is not covered](TESTING.md#what-is-not-covered) for what they cannot show about the
leap-year table itself.

## Text input

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

## Output

- **Text**: `[-]YYYY-MM-DD`, month and day with two digits and the year as a
  sign (only if negative) followed by at least four digits: `-0061-01-01`,
  `0000-01-01`, `0001-01-01`, `1403-01-01`. Infinite values print as
  `infinity` and `-infinity`. `jdate_format` prints dates the same way.
- **Binary** (`jdate_send` / `jdate_recv`): four bytes, a big-endian `int32`
  of days since 2000-01-01, exactly `date`'s format (`1403-01-01` is
  `0000228d`, 8845 days). `jdate_recv` rejects a finite value outside the range
  with `22008` and lets infinity through. It is a hard error: binary receive
  has no soft path.

## Errors and SQLSTATEs

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
`extension_schema` asserts `0A000`. The `22023`, `0A000` (units and the schema
move) and `42883` rows are pinned by SQLSTATE in `sqlstate`, which compares only
the code, never the message text, since core's messages change between major
versions and the codes do not (see
[Testing](TESTING.md#testing) for what each test covers).

## Infinity

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

## Soft errors

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

## Operators

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

## Casts

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

## Functions

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

## Fields: `EXTRACT` and `jdate_part`

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

## `jdate_trunc`

`jdate_trunc(unit, jdate) returns jdate` for `year` (Farvardin 1), `quarter`
(month 1, 4, 7 or 10, day 1), `month` (day 1) and `day` (unchanged). Any other
unit is `0A000` (an unknown name is `22023`). An infinite value is returned
unchanged for any recognised unit.

## `to_jdate`

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
[Usage](../README.md#usage).

## `jdate_format`

`jdate_format(timestamptz, with_time boolean DEFAULT true)` returns `text`: the
Jalali date of the timestamp as it reads in the session `TimeZone`, followed
(when `with_time`) by the local time of day, as `time_out` prints it
(`1403-01-01 12:03:41.482917`; fractional seconds only when non-zero; no time
zone offset). With `with_time = false` it is just the date, the same text as
`jdate_out`. It is `STABLE` because it depends on the `TimeZone`. Infinite
timestamps give `infinity` / `-infinity`; a day outside the Jalali range raises
`22008`. It is a bridge until a native Jalali timestamp type exists.

## Indexing, hashing and partitioning

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

## Function volatility and parallel safety

As declared in `jdate--1.0.sql` (and checked against `pg_proc`): all 29
functions are `STRICT` and `PARALLEL SAFE`, and the two aggregates are
`PARALLEL = SAFE` with a combine function. 26 functions are `IMMUTABLE`; the
three that depend on the session `TimeZone` are `STABLE`: `jdate(timestamptz)`, `timestamptz(jdate)`
and `jdate_format(timestamptz, boolean)`. In particular `to_jdate` is
`IMMUTABLE` (it is indexable), as are `jdate_part`, `extract(text, jdate)` and
`jdate_trunc`.

The `parallel` test checks the catalog (no function or aggregate of the
extension, nor an aggregate's transition function, is anything but `PARALLEL
SAFE`; `min(jdate)` and `max(jdate)` have `jdate_smaller` / `jdate_larger` as
combine function, and it is `PARALLEL SAFE`) and then forces parallel plans
(`parallel_setup_cost = 0`, `parallel_tuple_cost = 0`, two workers). It asserts
that a `Gather` node is chosen for ten kinds of query (a range filter,
`jdate + int`, `jdate_part`, `jdate_trunc`, `jdate_format`, `min`/`max`,
`min`/`max` grouped by an expression, `min`/`max` grouped by a column, `ORDER
BY` under a `Gather Merge`, and a hash join on `jdate`), that the plain and the
column-grouped `min`/`max` use a Partial and a Finalize aggregate, and that
each query returns the same rows with zero and with two workers. It found no
object that is not `PARALLEL SAFE`, so none had to be changed.

`min(jdate)` and `max(jdate)` are `PARALLEL = SAFE` and declare a
`COMBINEFUNC`: the same function as the transition function (`jdate_smaller`,
`jdate_larger`), as in core's `date` aggregates. Both are `STRICT`, so a
partial state that saw no rows (`NULL`) is skipped and the combine is just
"take the smaller" or "take the larger". The planner can therefore run a
Partial Aggregate in each worker below the `Gather` and a Finalize Aggregate
above it, instead of sending every row up to one serial `Aggregate`. Whether it
does is the planner's cost decision: with a grouping on an expression it may
still choose a serial `GroupAggregate` over a `Gather Merge`. Results are the
same either way.

## Extension properties

| | |
| --- | --- |
| Name, version | `jdate`, `1.0` (one script, `jdate--1.0.sql`, no upgrade scripts) |
| `relocatable` | `false` |
| Schema | chosen at install: `CREATE EXTENSION jdate SCHEMA s` (see [Installing into a schema](../README.md#installing-into-a-schema)) |
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

## Supported PostgreSQL versions

- **Declared: PostgreSQL 16 or later.** `src/jdate.c` includes `varatt.h`
  (split out of `postgres.h` in 16) and the soft-error API (`ereturn`,
  `nodes/miscnodes.h`, new in 16). `COPY ... (ON_ERROR ignore)` with `jdate`
  needs 17.
- **Makefile guard**: after the PGXS include, `make` fails with `jdate requires
  PostgreSQL 16 or later` for `MAJORVERSION` 12 to 15. Check it without a PG15
  install: `make -n MAJORVERSION=15`. There is no guard, and no support, for 11
  and older, and no `#if` code for 14 or 15.
- **What has actually been run**: continuous integration
  (`.github/workflows/ci.yml`) builds the extension and runs the whole
  regression suite, the dump round trip and the calendar test on PostgreSQL
  **16, 17 and 18**, so support for all three is demonstrated, not only
  declared. The one place where a server's own output differs is `softerr`,
  which has an alternate expected file `softerr_1.out` for PostgreSQL 16 (no
  `COPY ... ON_ERROR`). See [Testing](TESTING.md#testing).
- The local harness itself is PostgreSQL 18 only, because it relies on
  `extension_control_path`, new in 18; CI is what covers 16 and 17.
