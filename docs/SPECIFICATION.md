# Specification

This is the specification of the `jdate` extension: the `jdate` type (a Jalali
date), the Jalali timestamp types `jtimestamp` and `jtimestamptz`, and the range
types over them. Everything in this document was checked against `src/`,
`jdate--1.0.sql`, `jdate.control`, the tests, or by running the statement on the
development cluster (PostgreSQL 18). Where a behaviour is pinned by the
regression suite, the test is named; see [Testing](TESTING.md#testing) for what
each test covers and what is not covered.

- [At a glance](#at-a-glance)
- [Type and storage](#type-and-storage)
- [Supported range](#supported-range) and [The calendar algorithm](#the-calendar-algorithm)
- [Text input](#text-input), [Output](#output) and [Errors and SQLSTATEs](#errors-and-sqlstates)
- [Infinity](#infinity) and [Soft errors](#soft-errors)
- [Operators](#operators) and [Casts](#casts)
- [Functions](#functions), [Fields: `EXTRACT` and `jdate_part`](#fields-extract-and-jdate_part),
  [`jdate_trunc`](#jdate_trunc), [`to_jdate`](#to_jdate) and [`jdate_format`](#jdate_format)
- [Time zones](#time-zones)
- [Indexing, hashing and partitioning](#indexing-hashing-and-partitioning)
- [Function volatility and parallel safety](#function-volatility-and-parallel-safety)
- [The Jalali timestamp types](#the-jalali-timestamp-types):
  [range and safe range](#range-and-the-safe-range-of-jtimestamptz),
  [text input](#text-input-of-the-timestamp-types), [output](#output-of-the-timestamp-types),
  [typmod](#typmod), [errors](#errors-of-the-timestamp-types), [special words and infinity](#special-words-and-infinity),
  [soft errors](#soft-errors-of-the-timestamp-types), [casts](#casts-of-the-timestamp-types),
  [comparison and the shared operator family](#comparison-and-the-shared-operator-family),
  [hashing, `min` and `max`](#hashing-min-and-max), [interval arithmetic](#interval-arithmetic),
  [daylight saving time](#daylight-saving-time), [`jdate_bin`](#jdate_bin),
  [`jgenerate_series`](#jgenerate_series), [`AT TIME ZONE` and `OVERLAPS`](#at-time-zone-and-overlaps),
  [fields](#fields-of-the-timestamp-types), [`jdate_trunc`](#jdate_trunc-of-the-timestamp-types),
  [`jday_format` and `jmonth_format`](#jday_format-and-jmonth_format), [index recipes](#index-recipes),
  [range and multirange types](#range-and-multirange-types),
  [time zones](#time-zones-and-the-timestamp-types),
  [bare literals and parameters](#bare-literals-and-parameters), [selectivity](#range-selectivity),
  [volatility and parallel safety](#volatility-and-parallel-safety-of-the-timestamp-types),
  [known differences from core](#known-differences-from-core) and [what is not provided](#what-is-not-provided)
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
| Fields | `EXTRACT(... FROM jdate)` (numeric), `jdate_part` (bigint), `jdate_trunc`; `to_jdate(e)`, `to_jdate(e, zone)`, `jdate_format`, `jday_format`, `jmonth_format` |
| Errors | SQLSTATE `22007`, `22008`, `22023`, `0A000` (see [the table](#errors-and-sqlstates)) |
| Timestamp types | `jtimestamp` (like `timestamp`) and `jtimestamptz` (like `timestamptz`): 8 bytes, core's representation and binary format, Jalali text I/O, the same operations as the core types with Jalali calendar rules (see [The Jalali timestamp types](#the-jalali-timestamp-types)) |
| Range types | `jdaterange`, `jtsrange`, `jtstzrange` and their multiranges (see [Range and multirange types](#range-and-multirange-types)) |
| Extension | version 1.0, **not relocatable**, superuser to install; `extract`, `timezone` and `overlaps` overloads live in `pg_catalog` |
| PostgreSQL | 16 or later; the regression suite runs in CI on 16, 17 and 18 (the local harness is 18 only) |

Counts, as installed on PostgreSQL 18: 9 types (3 base, 3 range, 3 multirange) and
their 9 array types, 185 functions (131 `IMMUTABLE`, 54 `STABLE`, all `PARALLEL SAFE`),
6 aggregates, 77 operators, 23 casts and 6 operator classes (a default btree and a default
hash class for each base type) in 4 operator families. The sections up to
[Function volatility and parallel safety](#function-volatility-and-parallel-safety)
describe `jdate` as it was first released; the same sections say where a statement
now covers the other types too.

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
- `to_jdate(double precision)` and `to_jdate(double precision, text)`, which also reject `NaN`.

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
- `infinity` and `-infinity` are accepted in any letter case, with whitespace
  before and after the word (`' infinity'`, `E'\t-infinity\n'`), as the
  `jtimestamp` and `jtimestamptz` inputs accept it around their special words.
  The word itself is matched exactly, so whitespace inside it (`'- infinity'`)
  or any other word with or without whitespace (`' inf '`, `' epoch'`) is
  still `22007` (`io` and `softerr` pin both sides).
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
| `22008` | a finite day outside the Jalali range: binary receive, `jdate ± int`, `date`/`timestamp`/`timestamptz` casts, `to_jdate` (including `NaN` and epochs outside the range), `jdate_trunc('week')` for a week that starts before the first day, `jdate_format` of such a day. Message: `jdate value is outside the supported Jalali range (years -61 to 3177)` | | no |
| `22008` | `jdate - jdate` with an infinite operand (`cannot subtract infinite dates`), and a day count that overflows 32 bits (`date out of range`): core's own `date` errors | core | no |
| `22023` `invalid_parameter_value` | a unit name core does not recognise: `jdate_part`, `EXTRACT`, `jdate_trunc`; a time zone name core does not recognise: `to_jdate(e, zone)`, even for `±Infinity` and `NaN` | | no |
| `0A000` `feature_not_supported` | a recognised but unsupported unit (`jdate_part`/`EXTRACT`: `week`, `millennium`, `julian`, `isoyear`, `timezone`, `timezone_hour`, `timezone_minute`; `jdate_trunc`: everything but `year`, `quarter`, `month`, `week`, `day`) | | no |
| `0A000` | `ALTER EXTENSION jdate SET SCHEMA` | the server | no |
| `42883` `undefined_function` | an operator or function the type does not define, such as `jdate = date`, `jdate + jdate`, `jdate + bigint`, `date_part('year', jdate)` | the server | no |
| `42501` `insufficient_privilege` | `CREATE EXTENSION jdate` by a non-superuser | the server | no |

The table is for `jdate`. The timestamp types raise the same codes and a few
more, listed in [Errors of the timestamp types](#errors-of-the-timestamp-types).

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
functions answer differently for the two result types. `EXTRACT(unit FROM x)`
(a `numeric`, which can hold infinity) answers the same way core's `date` does.
`jdate_part(unit, x)` returns a `bigint`, which has no infinity, so it is
`NULL` for every unit:

| unit | `EXTRACT` of `infinity` | `EXTRACT` of `-infinity` | `jdate_part` |
| --- | --- | --- | --- |
| `year`, `decade`, `century`, `epoch` | `Infinity` | `-Infinity` | `NULL` |
| `month`, `day`, `quarter`, `doy`, `dow`, `isodow` | `NULL` | `NULL` | `NULL` |
| `hour`, `minute`, `second`, `milliseconds`, `microseconds` | `NULL` | `NULL` | `NULL` |

For `EXTRACT`, the units that only grow with time are infinite, the ones that
cycle have no value. The time-of-day units are `0` for every finite `jdate`, but `NULL` for
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
| `+` | `jdate`, `interval` and `interval`, `jdate` | `jtimestamp` | the day is its midnight, then the `jtimestamp` rules (months are Jalali months, clamped to the last day of a shorter month; then days; then time); `22008` outside the range; `IMMUTABLE` |
| `-` | `jdate`, `interval` | `jtimestamp` | as above with the negated interval |
| `+` | `jdate`, `time` and `time`, `jdate` | `jtimestamp` | `time '24:00'` on the last day is `22008` |
| `+` | `jdate`, `timetz` and `timetz`, `jdate` | `jtimestamptz` | the instant of that wall time in the `timetz`'s own offset; `22008` outside the safe range of `jtimestamptz` |
| `-` | `jdate`, `jtimestamp` and `jtimestamp`, `jdate` | `interval` | the day is its midnight; days and time of day, never months |
| `-` | `jdate`, `jtimestamptz` and `jtimestamptz`, `jdate` | `interval` | the day is its midnight in the session zone (`STABLE`) |
| `=` `<>` `<` `<=` `>` `>=` | `jdate` against `jtimestamp` or `jtimestamptz`, either order | `boolean` | cross-type comparison in the shared operator family (see [Comparison](#comparison-and-the-shared-operator-family)); against `jtimestamptz` it is `STABLE` |

These are the `date` operators with `interval`, `time` and `timetz` that core has, and no others. A bare literal next to a
`jdate` with `+` is ambiguous (`42725`), as it is for `date`: write `jdate + 5` or `jdate + interval '5 days'`; a
parameter needs the same cast (`jdate + $1::int`, see
[Bare literals and parameters](#bare-literals-and-parameters)).

Not defined: `jdate - date`, and comparison with `date`,
`timestamp` or `timestamptz` (`operator does not exist`, because the casts are
assignment-level, below). A `numeric` or `bigint` day count finds no operator
either; a `smallint` is promoted to `integer`. `min(jdate)` and `max(jdate)`
are aggregates of their own, returning `jdate`.

## Casts

The six casts between `jdate` and core's date types are all `ASSIGNMENT`,
never `IMPLICIT` (the casts to and from the timestamp types are in
[Casts of the timestamp types](#casts-of-the-timestamp-types)): a `jdate` and a `date` can be
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

`jdate` also casts to and from `jtimestamp` and `jtimestamptz`; those four are
in the [timestamp cast matrix](#casts-of-the-timestamp-types).

Assignment-only also keeps `min(jdate)`/`max(jdate)` on `jdate`'s own
aggregates: an implicit `jdate -> timestamptz` cast would let the planner
satisfy them through core's `timestamptz` aggregates instead. The cast
functions can be called directly (`jdate(date '1970-01-01')`). Casting to and
from `text` is core's generic I/O conversion (`'1403-01-01'::jdate::text`).

## Functions

| Function | Returns | Volatility | See |
| --- | --- | --- | --- |
| `jdate_part(text, jdate)` | `bigint` | `IMMUTABLE` | [Fields](#fields-extract-and-jdate_part) |
| `pg_catalog.extract(text, jdate)` (the target of `EXTRACT(field FROM x)`) | `numeric` | `IMMUTABLE` | [Fields](#fields-extract-and-jdate_part) |
| `jdate_trunc(text, jdate)` | `jdate` | `IMMUTABLE` | [`jdate_trunc`](#jdate_trunc) |
| `to_jdate(double precision)` | `jdate` | `IMMUTABLE` | [`to_jdate`](#to_jdate) |
| `to_jdate(double precision, zone text)` | `jdate` | `IMMUTABLE` | [`to_jdate`](#to_jdate) |
| `jdate_format(timestamptz, with_time boolean DEFAULT true)` | `text` | `STABLE` | [`jdate_format`](#jdate_format) |
| `jday_format(jdate, sep text DEFAULT '-')`, `jmonth_format(jdate, sep text DEFAULT '-')` | `text` | `IMMUTABLE` | [`jday_format` and `jmonth_format`](#jday_format-and-jmonth_format) |
| `jdate(date)`, `jdate(timestamp)`, `jdate(timestamptz)`, `"timestamp"(jdate)`, `timestamptz(jdate)` | | see [Casts](#casts) | the cast functions |
| `min(jdate)`, `max(jdate)` | `jdate` | aggregates | [Indexing](#indexing-hashing-and-partitioning) |

The rest of what `\df` lists (`jdate_in`, `jdate_out`, `jdate_recv`,
`jdate_send`, `jdate_eq` ... `jdate_cmp`, `jdate_hash`, `jdate_hash_extended`,
`jdate_pli`, `integer_pl_jdate`, `jdate_mii`, `jdate_mi`, `jdate_smaller`,
`jdate_larger`) are the support functions behind the type, operators, operator
classes and aggregates.

There are no `jdate` overloads of `date_part`, `date_trunc`, `to_char`,
`generate_series` or `make_date`: `date_part('year', jdate)` is
`undefined_function`; use `jdate_part`. The functions for the Jalali timestamp
types are in [The Jalali timestamp types](#the-jalali-timestamp-types); the
names `jdate_part`, `jdate_trunc`, `extract`, `jday_format` and `jmonth_format`
are shared with `jdate` (overloaded on the argument type).

## Fields: `EXTRACT` and `jdate_part`

`jdate_part(unit, x)` returns `bigint`: every field of a finite day is an exact
integer, and every unit is `NULL` for infinity. `EXTRACT(unit FROM x)` calls
`pg_catalog.extract(text, jdate)` and returns `numeric`, with the same value for
a finite day (an exact integer, no rounding); for infinity it keeps core's
`Infinity` / `-Infinity` for the units that only grow (see
[Infinity](#infinity)). Both are `IMMUTABLE`, `STRICT` and `PARALLEL SAFE`.
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
| `decade` | the decade **number**, not the first year of the decade: the year divided by 10, rounded down (like core: `202` for 2024). 1403 is `140`, 1400 is `140`, 1399 is `139`, 0 is `0`, -1 is `-1`; years 1400 to 1409 are `140`, 0 to 9 are `0`, -10 to -1 are `-1`, and `-61` is `-7`. A "first year of the decade" value such as jalali_utils' `1400` is `decade * 10`, and is not what this returns | Jalali year |
| `century` | years 1 to 100 are `1`, 1401 to 1500 are `15`, and years `-61` to `0` are `-1`; there is no century 0 (core's numbering) | Jalali year |
| `dow` | 0 (Saturday) to 6 (Friday): the week starts on Saturday, so this is core's `dow` (Sunday 0) plus one, modulo 7; add 1 for a 1-based Saturday-first number | the day number, **calendar-agnostic** |
| `isodow` | 1 (Monday) to 7 (Sunday): the ISO 8601 number, unchanged and equal to core's | the day number, **calendar-agnostic** |
| `epoch` | seconds from 1970-01-01 00:00:00 UTC to the start of that day (negative before 1970), a multiple of 86400, an exact `bigint` (and an exact `numeric` through `EXTRACT`) | the day number, **calendar-agnostic** |
| `hour`, `minute`, `second`, `milliseconds`, `microseconds` | `0` | |

`isodow` and `epoch` equal core's answer (`date_part(unit, d::date)`) for every
day in the range, and `dow` equals core's shifted to a Saturday start,
`(date_part('dow', d::date)::int + 1) % 7`. `dow` is Saturday-first and
`isodow` is the ISO one, so the two numbers differ on every day: 1403-01-01 is a
Wednesday, `dow` 4 (core's is 3) and `isodow` 3. Because `dow`, `isodow` and
`epoch` never go through the Jalali conversion, they also work where that
conversion cannot: for infinity `EXTRACT` gives the same results as core (see
[Infinity](#infinity)). In `jdate_part` and `EXTRACT`, `week`, `millennium`,
`julian`, `isoyear`, `timezone`, `timezone_hour` and `timezone_minute` raise
`0A000` (`week` is supported by [`jdate_trunc`](#jdate_trunc)); a name core does not know raises `22023`.

## `jdate_trunc`

`jdate_trunc(unit, jdate) returns jdate` for `year` (Farvardin 1), `quarter`
(month 1, 4, 7 or 10, day 1), `month` (day 1), `week` (the Saturday on or
before the day) and `day` (unchanged). Any other unit is `0A000` (an unknown
name is `22023`). An infinite value is returned unchanged for any recognised
unit.

Weeks start on Saturday, consistent with the Saturday-first `dow`: the start of
the week is the day minus its `dow`, so a Saturday truncates to itself and a
Friday to the Saturday six days earlier. The start may fall in the previous
month or year. For the first days of the range (-0061-01-01 and -0061-01-02,
before the first Saturday) the week start is below the minimum `jdate` and is
the same out-of-range error (`22008`) as other arithmetic past the edge; there
is no clamping. The top edge needs no special case.

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

`to_jdate(double precision, zone text)` takes the day in a zone you name
instead: the instant is converted to local time in `zone` by core's
`timestamptz` `AT TIME ZONE` conversion, the local calendar day is taken, and it is
range-checked. The session `TimeZone` plays no part. It is `IMMUTABLE`, `STRICT`
and `PARALLEL SAFE`, the same as core's `timezone(text, timestamptz)` in
`pg_catalog` (checked in `pg_proc`; the `tz_casts` test compares them). Order of
checks: the zone is looked up first, so an unknown zone raises core's `22023`
(`time zone "..." not recognized`) for every epoch, including `±Infinity`, `NaN`
and epochs outside the range. With a valid zone, `±Infinity` gives `±infinity`;
`NaN` and an epoch outside the range above are `22008`, judged on the UTC
instant, before the zone is applied; so the first second of `-0061-01-01`
UTC fails in `America/New_York` (its local day is before the range) and the
last second of `3177-12-29` UTC fails in `Pacific/Kiritimati` (UTC+14, its
local day is after the range), and a finite epoch just outside the range fails
even where the local day would fit. A `NULL` argument gives `NULL`. For
ordinary instants it agrees with `(to_timestamp(e) AT TIME ZONE zone)::date`
converted to `jdate` (the `tz_casts` test compares them over a year in five zones).

## `jdate_format`

`jdate_format(timestamptz, with_time boolean DEFAULT true)` returns `text`: the
Jalali date of the timestamp as it reads in the session `TimeZone`, followed
(when `with_time`) by the local time of day, as `time_out` prints it
(`1403-01-01 12:03:41.482917`; fractional seconds only when non-zero; no time
zone offset). With `with_time = false` it is just the date, the same text as
`jdate_out`. It is `STABLE` because it depends on the `TimeZone`. Infinite
timestamps give `infinity` / `-infinity`; a day outside the Jalali range raises
`22008`. It is the bridge from a core `timestamptz`; for the native types use
`jtimestamptz` and [`jday_format`](#jday_format-and-jmonth_format).

## Time zones

A `jdate` is a day and has no zone. The zone matters only where an instant
(`timestamptz` or a Unix epoch) is turned into a day or a day into an instant.
Which zone each function or cast uses (the table is for `jdate`; the timestamp
types are in [Time zones and the timestamp types](#time-zones-and-the-timestamp-types)):

| Function or cast | Zone used | Result |
| --- | --- | --- |
| `timestamptz -> jdate` (`jdate(timestamptz)`) | session `TimeZone` | the local day |
| `jdate -> timestamptz` (`timestamptz(jdate)`) | session `TimeZone` | local midnight of that day |
| `jdate_format(timestamptz, boolean)` | session `TimeZone` | the local day and (optionally) local time of day |
| `to_timestamp(e)::jdate` (core's function, then the cast) | session `TimeZone` | the local day |
| `to_jdate(e, zone)` | the zone named in the argument | the day in that zone |
| `to_jdate(e)` | none: UTC | the UTC day |
| `EXTRACT(epoch FROM jdate)`, `jdate_part('epoch', jdate)` | none: UTC | midnight UTC of the day, a multiple of 86400 |
| `EXTRACT(epoch FROM timestamptz)` (core) | none | the instant's epoch; the same in every zone |
| `jdate -> timestamp`, `timestamp -> jdate`, `date -> jdate`, `jdate -> date` | none | the same calendar day; a `timestamp` has no zone and its time of day is dropped or set to midnight |
| `jdate_part`, `EXTRACT` (every other field), `jdate_trunc` | none | fields of the day itself; `hour` and smaller are `0` |
| text input and output, binary I/O, operators, arithmetic, `jdate - jdate`, `min`, `max`, hashing | none | |

The setting that controls "session `TimeZone`" is PostgreSQL's `timezone`
(`TimeZone`) parameter. It can be set per session (`SET timezone = ...`), or as
the default for a database or a role (`ALTER DATABASE ... SET timezone = ...`,
`ALTER ROLE ... [IN DATABASE ...] SET timezone = ...`); the usual precedence
applies (a `SET` in the session, then a role-in-database setting, a role
setting, a database setting, and the server's `postgresql.conf`). There is no
extension-specific zone setting and no default zone for `to_jdate`.

Because of that dependency, `jdate(timestamptz)`, `timestamptz(jdate)` and
`jdate_format` are `STABLE`; every function in the "none" and "named zone" rows
is `IMMUTABLE` (see [Function volatility](#function-volatility-and-parallel-safety)).
Worked examples, each run on the development cluster, are in the README's
[Time zones](../README.md#time-zones): the instant `2024-03-19 22:00:00+00`
(Unix epoch `1710885600`) is `1402-12-29` in `UTC` and in `America/New_York`
and `1403-01-01` (01:30) in `Asia/Tehran`; `to_jdate(1710885600)` is
`1402-12-29`, `to_jdate(1710885600, 'Asia/Tehran')` is `1403-01-01`, and
`to_timestamp(1710885600)::jdate` is whichever the session zone says.

## Indexing, hashing and partitioning

| Operator class | Access method | Default? | Contains |
| --- | --- | --- | --- |
| `jdate_ops` | btree | yes | `<` `<=` `=` `>=` `>`; support function 1 `jdate_cmp`, 2 `date_sortsupport`, 4 `btequalimage` (core's own functions) and, on PostgreSQL 18 only, 6 `date_skipsupport` |
| `jdate_hash_ops` | hash | yes | `=`; support function 1 `jdate_hash` (`hashint4`) and 2 `jdate_hash_extended` (`hashint4extended`, seeded, 64-bit) |

`jdate_ops` is one of three btree classes of the operator family `jdatetime_ops`
(the other two are `jtimestamp_ops` and `jtimestamptz_ops`), which also holds the
cross-type comparison operators between the three types; see
[Comparison and the shared operator family](#comparison-and-the-shared-operator-family).

Because both exist, `jdate` columns work with btree and hash indexes, merge and
hash joins, `HashAggregate`, `GROUP BY`/`DISTINCT`, `ORDER BY`, and `PARTITION
BY HASH` (which needs the extended hash function). `amvalidate` accepts both
classes. `=` is declared `HASHES, MERGES` with `eqsel`/`eqjoinsel`; the
ordering operators use the `jdatetime_{lt,le,gt,ge}sel` estimators (core's
`scalar*sel` with the operands relabelled to the core type, and the pairing of
a lower and an upper bound done in the estimator; `src/jselectivity.c`).
`min`/`max` declare `SORTOP`. The range types have their own GiST and SP-GiST
support, which comes from core's generic range operator classes (see
[Range and multirange types](#range-and-multirange-types)); `jdate` itself has no
GiST, GIN, BRIN or SP-GiST operator class.

`jdate` is a 4-byte day count with the same representation as `date`, so
`jdate_ops` reuses core's `date_sortsupport` (support function 2, faster sorts
and index builds on the integer value) and `btequalimage` (support function 4,
always true: equal `jdate` values are bitwise identical, so btree
deduplication of duplicate keys is allowed). Both functions exist on PostgreSQL
16, 17 and 18. Skip support (function 6, `date_skipsupport`) exists only on
PostgreSQL 18: the script adds it through a `DO` block that runs only when
`server_version_num` is 180000 or more, so on 16 and 17 the class simply has no
function 6.

## Function volatility and parallel safety

As declared in `jdate--1.0.sql` (and checked against `pg_proc`), for the whole
extension: all 185 functions are `PARALLEL SAFE` and the six aggregates are
`PARALLEL = SAFE` with a combine function. 177 functions are `STRICT`; the eight
that are not are the six range constructors (a `NULL` bound means unbounded) and
the two `OVERLAPS` functions (which decide `NULL` ends themselves, as core's
do). 131 functions are `IMMUTABLE` and 54 are `STABLE`; a function is `STABLE`
exactly when it reads the session `TimeZone` (or, for the cross-type
comparisons, places a value on the time line with it). The table for the
timestamp types is in
[Volatility and parallel safety of the timestamp types](#volatility-and-parallel-safety-of-the-timestamp-types).

For `jdate` alone (the 30 functions of the first release): 27 are `IMMUTABLE`;
the three that depend on the session `TimeZone` are `STABLE`:
`jdate(timestamptz)`, `timestamptz(jdate)` and `jdate_format(timestamptz,
boolean)`. In particular both `to_jdate` functions are `IMMUTABLE` (they are
indexable), as are `jdate_part` (`bigint`), `extract(text, jdate)` (`numeric`)
and `jdate_trunc`; the `fields` test pins the return types with `pg_typeof` and
the volatility and parallel safety of both field functions in `pg_proc`.

The `parallel` test checks the catalog (no function or aggregate of the
extension, nor an aggregate's transition function, is anything but `PARALLEL
SAFE`; all six `min` and `max` aggregates have their `smaller` / `larger`
function as combine function, and it is `PARALLEL SAFE`) and then forces
parallel plans (`parallel_setup_cost = 0`, `parallel_tuple_cost = 0`, two
workers). It asserts that a `Gather` node is chosen for ten kinds of query on
`jdate` (a range filter, `jdate + int`, `jdate_part`, `jdate_trunc`,
`jdate_format`, `min`/`max`, `min`/`max` grouped by an expression, `min`/`max`
grouped by a column, `ORDER BY` under a `Gather Merge`, and a hash join) and
for the filter, the ordered scan and the `min`/`max` of `jtimestamp` and of
`jtimestamptz`, that the plain and the column-grouped `min`/`max` use a Partial
and a Finalize aggregate, and that each query returns the same rows with zero
and with two workers. It found no object that is not `PARALLEL SAFE`, so none
had to be changed; its function-count guard rises with every function the
extension adds, never falls.

`min(jdate)` and `max(jdate)` (and the same two for each timestamp type) are `PARALLEL = SAFE` and declare a
`COMBINEFUNC`: the same function as the transition function (`jdate_smaller`,
`jdate_larger`), as in core's `date` aggregates. Both are `STRICT`, so a
partial state that saw no rows (`NULL`) is skipped and the combine is just
"take the smaller" or "take the larger". The planner can therefore run a
Partial Aggregate in each worker below the `Gather` and a Finalize Aggregate
above it, instead of sending every row up to one serial `Aggregate`. Whether it
does is the planner's cost decision: with a grouping on an expression it may
still choose a serial `GroupAggregate` over a `Gather Merge`. Results are the
same either way.

## The Jalali timestamp types

`jtimestamp` mirrors `timestamp` (no zone) and `jtimestamptz` mirrors
`timestamptz`. They are base types of their own with Jalali text input and
output, but their storage, binary format, comparison, hashing and most of the
arithmetic are core's: the extension calls core's functions and adds the
Jalali calendar rules and the range checks. Everything that depends on the
calendar (the date prefix of the text, month arithmetic, `year` / `month` /
`quarter` / `doy` / `decade` / `century` fields, truncation to a Jalali period,
the day and month keys) is Jalali; everything else behaves as the core type.

| | `jtimestamp` | `jtimestamptz` |
| --- | --- | --- |
| Mirrors | `timestamp` | `timestamptz` |
| Storage | 8 bytes, passed by value, `double` alignment, `STORAGE plain`; category `D`, not preferred (core's `timestamptz` stays the preferred type of the category); array types `jtimestamp[]`, `jtimestamptz[]` | same |
| Representation | `int64` microseconds since 2000-01-01 00:00:00, infinities are `INT64_MIN` / `INT64_MAX`: core's | the same count of microseconds, as an instant (UTC) |
| Binary format | core's `timestamp_send` / `timestamp_recv` (big-endian `int64`) | core's `timestamptz_send` / `timestamptz_recv` |
| Valid values | `-0061-01-01 00:00:00` to `3177-12-29 23:59:59.999999`, plus `infinity` and `-infinity` | the instants from `-0061-01-01 16:00:00` UTC to `3177-12-29 07:59:59.999999` UTC (the safe range, below), plus the infinities |
| Text I/O | Jalali date, then core's time syntax; `[-]YYYY-MM-DD HH:MM:SS[.ffffff]` | the same plus the zone offset in the session `TimeZone` |

### Range and the safe range of `jtimestamptz`

`jtimestamp` accepts every microsecond from the first moment of the first
Jalali day to the last microsecond of the last one: the stored values
`-45435168000000000` to `56777759999999999` (Gregorian `0560-03-20 00:00:00`
to `3799-03-19 23:59:59.999999`). That range lies far inside core's
(`4714-11-24 BC` to `294276-12-31`), so core's limits never bind; only the Jalali
check does.

A `jtimestamptz` is an instant, and the same instant shows a different local day
in different session zones, by up to the largest offset PostgreSQL can produce
(`TZDISP_LIMIT`, 16 hours: offsets up to `15:59:59`, and named zones with
historic offsets such as `-15:56:08` for Asia/Manila before 1844). To keep the
invariant that `jdate` keeps (a stored value can always be shown), `jtimestamptz`
accepts only the **safe range**: the Jalali range narrowed by 16 hours at both
ends, the stored values `-45435110400000000` to `56777702399999999`. Every
stored instant therefore shows as a valid Jalali date and time in every zone,
and the check needs no zone (it is `IMMUTABLE`). The price is 32 hours at the far
ends: `'-0061-01-01 00:00+00'::jtimestamptz` and `'-0061-01-01 15:59:59.999999+00'`
are `22008`, and `'-0061-01-01 16:00:00+00'` is the first valid instant.

The range is enforced on every path that produces a value; each raises `22008`
and stores nothing:

| Path | Check |
| --- | --- |
| text input, `COPY` and array input | after core has parsed and applied the typmod |
| binary receive (`recv`, binary `COPY`, binary-protocol parameters) | after core's own receive checks; infinity passes |
| casts from `timestamp`, `timestamptz`, `date`, `jdate` and between the two new types | the result is checked (see [Casts](#casts-of-the-timestamp-types)); the zone shift can push a result out of range, so the edge days convert in some zones and not in others |
| typmod coercion (`jtimestamp(0)` and so on) | after rounding: `'3177-12-29 23:59:59.999999'::jtimestamp(0)` rounds to the next day and is `22008` |
| `+` and `-` with an interval, `jdate + interval` / `time` / `timetz` | the month step first, then core's day and time step, then the final result |
| `to_jtimestamptz(double precision)` | the epoch bounds of `to_jdate`, then the safe range |
| `jdate_bin` | the bin start (a source before the origin gives a start below the source) |
| `jdate_trunc`, every unit | the result (a period start of an in-range value can lie below the first day) |
| `AT TIME ZONE`, both directions | the result |
| `jgenerate_series` | every element; a series that reaches the edge on its finishing side ends quietly, see [Known differences](#known-differences-from-core) |

Not checked, because they cannot leave the range: casts to the core types and
to `jdate` (a `jtimestamptz` always shows a valid day), `min` and `max`, the
comparison and hash functions, range constructors (the canonical function of
`jdaterange` checks its bounds).

One edge case is kept as it is and pinned in `jt_bounds` and `jt_softerr`:
`'-0061-01-01 15:59:59.6+00'::jtimestamptz(0)` is `22008` (the literal is read
without the typmod first, and is out of range), while the same text through the
input function with the typmod (`pg_input_is_valid(..., 'jtimestamptz(0)')`,
`COPY`, array input) or its wire value through `recv` rounds up to the first valid
instant and is accepted.

### Text input of the timestamp types

The text is a Jalali date, then whatever core's timestamp input accepts:

1. optional whitespace, then the date `[+-]Y-M-D`, scanned with the same lenient
   rules as `jdate` (a sign, leading zeros, no zero padding needed, whitespace
   around the dashes, a field that does not fit 32 bits is `22008`; the date
   must exist, so month 13, `1404-12-30` and `1403-07-31` are `22008`);
2. the date is converted to Gregorian `YYYY-MM-DD` and the converted text plus the
   rest of the string, unchanged, goes to core's `timestamp_in` or
   `timestamptz_in` with the typmod;
3. the result is range-checked.

So the rest may be anything core accepts there: a `T` or a space as separator,
a time with fractional seconds (rounded to the microsecond: `.1234567` is
`.123457`), `24:00:00` (the next day's midnight), `AM` / `PM`, and for
`jtimestamptz` a zone as `Z`, `+03:30`, `+03:30:15`, a name (`Asia/Tehran`) or an
abbreviation; without a zone the session `TimeZone` applies. A date alone is
midnight. `jtimestamp` parses a zone in the text and ignores it, like `timestamp`.
`DateStyle` is not consulted (the generated Gregorian text is unambiguous ISO).
Examples, in `Asia/Tehran`:

```sql
SELECT '1403-01-01 12:30:45.5'::jtimestamp;            -- 1403-01-01 12:30:45.5
SELECT '1403-01-01 12:30:45.5+03:30'::jtimestamptz;    -- 1403-01-01 12:30:45.5+03:30
SELECT '1403-01-01T12:30'::jtimestamp(0);               -- 1403-01-01 12:30:00
SELECT '1403-01-01 10:00:00+00'::jtimestamptz;          -- 1403-01-01 13:30:00+03:30
```

What is not accepted, all `22007` unless noted: text without a Jalali date prefix
that is not one of the [special words](#special-words-and-infinity) (so Gregorian
spellings such as `March 20, 2024 12:00` do not get in through core's parser),
garbage after the date, a second date (`'1403-01-01 12:00 1403-01-02'`), and
core's `allballs`. An era token: `AD` is harmless, `BC` makes the Gregorian year
fall before 560 and is `22008`. A time field out of range (`25:00`, minute 60) is
`22008`, a zone offset beyond `15:59:59` (`+17:00`) is `22009`, an unknown zone
name is `22023`: all core's codes.

### Output of the timestamp types

- `jtimestamp`: `[-]YYYY-MM-DD HH:MM:SS[.ffffff]`: the Jalali date as `jdate_out`
  prints it (at least four digits in the year, a sign only when negative), core's
  time of day with trailing zeros of the fraction dropped, and `infinity` /
  `-infinity`.
- `jtimestamptz`: the same, in the session `TimeZone`, followed by the numeric
  offset `+HH`, `+HH:MM` or `+HH:MM:SS` (`+03:30`, `+00`, and `+03:25:44` for a
  historic local mean time). `jtimestamptz_out` is therefore `STABLE`, and so is
  `jtimestamptz::text`.
- `DateStyle` is ignored: the output is always the ISO form, as for `jdate`.

Output is core's `EncodeDateTime` on the Gregorian fields with the first ten
characters replaced by the Jalali date, so core's time and zone formatting is
reused as is.

### Typmod

`jtimestamp(p)` and `jtimestamptz(p)` take a precision `p` from 0 to 6 through
core's typmod input; a precision above 6 gives core's warning and is clamped to
6. `format_type` prints `jtimestamp(3)` and `jtimestamptz(3)` (the extension has
its own typmod output; core's would print `(3) without time zone`). The scale cast
rounds to the precision, is `IMPLICIT` as core's, and re-checks the range after
rounding. An `INSERT` into a `jtimestamp(0)` column, `UPDATE` from a column of
another precision, array casts and the literal `'...'::jtimestamp(0)` all round
and re-check.

### Errors of the timestamp types

Core's SQLSTATEs are kept, re-raised under the type's name (`... for type
jtimestamp: "text"`), and the extension adds its own `22008`:

| SQLSTATE | Condition | Soft? |
| --- | --- | --- |
| `22007` | text that is not a Jalali date plus core's syntax, nor a special word; a duplicate date; trailing garbage | yes (text input) |
| `22008` | an invalid Jalali date, a 32-bit overflow in the date, a time field out of range, a `BC` token, and every range violation above (message `jdate value is outside the supported Jalali range (years -61 to 3177)`, the same text for all three types) | text input: yes; every other path: no |
| `22009` | a zone offset out of range in the text (`+17:00`) | yes |
| `22023` | an unknown zone name or an unknown unit (the message names the type: `unit "x" not recognized for type jtimestamp`); `jgenerate_series` with a zero step, an infinite start or stop (and an infinite step on 17+); `AT TIME ZONE` with an interval zone that has days or months | no |
| `0A000` | a recognised but unsupported unit; `jdate_bin` with a stride of months or years; `ALTER EXTENSION ... SET SCHEMA`; a window `RANGE BETWEEN n PRECEDING` over a timestamp type | no |
| `42725` | a bare literal or a parameter next to the overloads, see [Bare literals](#bare-literals-and-parameters) | |
| `42883` | an operator or function with no match: `jtimestamp = timestamp`, `jtimestamp + jdate`, `date_trunc('day', jtimestamp)`, `age(jtimestamp)`, `to_char(jtimestamp, ...)`, `generate_series(jtimestamp, ...)`, `jday_format(now())` | |
| `42846` | a cast that does not exist (`jtimestamp -> date`, `jtimestamptz -> timestamp`, between range types and core's) | |
| `42P17` | `CREATE INDEX` or a generated column on a `STABLE` expression (every session-zone form of a `jtimestamptz`) | |

`sqlstate`, `jt_bounds`, `jt_softerr`, `jt_io` and the test of each function pin
these by SQLSTATE only.

### Special words and infinity

Seven special words are accepted instead of a date, in any letter case, with
whitespace before and after: `infinity`, `-infinity`, `now`, `today`,
`tomorrow`, `yesterday` and `epoch`. The list is exact: `allballs` (a `time`
word) and every other word without a Jalali date prefix is `22007`, and so is
whitespace inside a word, two words, or a word followed by a date, time or zone
(`epoch 12:00`). `epoch` is `1970-01-01 00:00:00` UTC, which is Jalali
`1348-10-11`: `'epoch'::jtimestamp` is `1348-10-11 00:00:00`, and the text of
`'epoch'::jtimestamptz` depends on the session zone (`1348-10-11 03:30:00+03:30`
in Tehran). `now`, `today`, `tomorrow` and `yesterday` read the clock, so
`jtimestamp_in` and `jtimestamptz_in` are `STABLE` and a text-to-type cast is not
allowed in an index expression. (`jdate_in` accepts only the two infinity words,
with the same whitespace rule.)

Infinity is valid on every path and sorts after and before every finite value.
`jtimestamp 'infinity' + interval '1 month'` is `infinity`; on PostgreSQL 17 and
later an infinite interval is also valid, on 16 the interval literal does not
exist. The field functions follow core and `jdate` (table in
[Fields](#fields-of-the-timestamp-types)); `jdate_trunc` returns infinity
unchanged; `jday_format` and `jmonth_format` return `infinity` / `-infinity`.

### Soft errors of the timestamp types

Text input reports bad values softly, as `jdate` does: `pg_input_is_valid`,
`pg_input_error_info`, array input and `COPY ... (ON_ERROR ignore)` (17 and later)
all work, including for the errors that come from core's parser (`22007`,
`22008`, `22009`, `22023`; core's soft errors in `timestamp_in` and
`timestamptz_in` exist on 16). Binary receive, casts and arithmetic always
raise. The error message of a core failure names the extension's type and the
text as the user typed it.

### Casts of the timestamp types

No cast is `IMPLICIT` except the typmod scale casts, as for `jdate`: core's own
`date -> timestamp -> timestamptz` chain is implicit, but the cross-type
operators below make implicit casts unnecessary and they would let a Gregorian
and a Jalali reading of the same text mix silently.

| Cast | Function | Context | Volatility | Checked? |
| --- | --- | --- | --- | --- |
| `jtimestamp -> timestamp` | none (binary coercible) | assignment | | no |
| `jtimestamptz -> timestamptz` | none (binary coercible) | assignment | | no |
| `timestamp -> jtimestamp` | `jtimestamp(timestamp)` | assignment | `IMMUTABLE` | yes |
| `timestamptz -> jtimestamptz` | `jtimestamptz(timestamptz)` | assignment | `IMMUTABLE` (no zone is read, it only checks) | yes, the safe range |
| `date -> jtimestamp` | `jtimestamp(date)` | assignment | `IMMUTABLE` | yes |
| `date -> jtimestamptz` | `jtimestamptz(date)` | assignment | `STABLE` (local midnight in the session zone) | yes |
| `jdate -> jtimestamp` | `jtimestamp(jdate)` | assignment | `IMMUTABLE` | no, midnight of a valid day |
| `jdate -> jtimestamptz` | `jtimestamptz(jdate)` | assignment | `STABLE` | yes |
| `jtimestamp -> jdate` | `jdate(jtimestamp)` | assignment | `IMMUTABLE` | no, drops the time |
| `jtimestamptz -> jdate` | `jdate(jtimestamptz)` | assignment | `STABLE` | no, the local day cannot leave the range |
| `jtimestamp -> jtimestamptz` | `jtimestamptz(jtimestamp)` | assignment | `STABLE` (reads the session zone) | yes |
| `jtimestamptz -> jtimestamp` | `jtimestamp(jtimestamptz)` | assignment | `STABLE` | yes (it cannot fail) |
| `jtimestamp -> jtimestamp(p)` | `jtimestamp(jtimestamp, integer, boolean)` | implicit | `IMMUTABLE` | after rounding |
| `jtimestamptz -> jtimestamptz(p)` | `jtimestamptz(jtimestamptz, integer, boolean)` | implicit | `IMMUTABLE` | after rounding |

Casts that do not exist: `jtimestamp -> date`, `jtimestamp -> timestamptz`,
`jtimestamptz -> timestamp`, `jtimestamptz -> date` (SQLSTATE `42846`; go
through `jdate`, or through the free `jtimestamp -> timestamp` cast for a Gregorian reading), and any cast between `jdaterange`,
`jtsrange`, `jtstzrange` and core's range types: a range datum embeds its own
type, so it would need a function, and none is provided (convert bound by bound).
Casting to and from `text` is core's generic I/O conversion and uses the Jalali
text. The casts that read the zone are `STABLE`, so none of them can be used in an
index expression or a generated column; `timestamptz -> jtimestamptz` and the scale
casts can.

The edge days: `jdate -> jtimestamptz` of the first day is `22008` in every zone,
of the second day in zones east of about `+8h`, of the last day in zones west of
about `-8h` (local midnight minus the offset falls outside the safe range); the
same zone-dependent edges apply to `jtimestamp -> jtimestamptz`. In the other
direction the first and last valid instants never fail, even in the `+15:59` and
`-15:59` zones.

### Comparison and the shared operator family

Each type has the six comparison operators on itself, `=` hashable and
mergejoinable, with commutators and negators, implemented by core's `timestamp_*`
functions (core's `timestamptz` functions are the `timestamp` ones). The three
types also compare with each other, so `jdate`, `jtimestamp` and `jtimestamptz`
have **36 cross-type operators** (six ordered pairs, six operators each) in one
btree operator family, **`jdatetime_ops`**, the way core's `datetime_ops` holds
`date`, `timestamp` and `timestamptz`:

- the family has 45 operators in it (the five btree strategies for each of the
  nine ordered type pairs: three same-type and six cross-type); `<>` is outside
  the family, nine operators;
- each type's default btree class (`jdate_ops`, `jtimestamp_ops`,
  `jtimestamptz_ops`) is in the family with support function 1 (the comparison),
  2 (`date_sortsupport` for `jdate`, `timestamp_sortsupport` for the other two),
  4 (`btequalimage`) and, on PostgreSQL 18 only, 6 (`date_skipsupport` /
  `timestamp_skipsupport`, added by a `DO` block that checks `server_version_num`);
  each cross-type pair has support function 1 only, so the family has 18 support
  functions on 18 and 15 on 16 and 17; `amvalidate` accepts all three classes;
- a cross-type comparison with a `jtimestamptz` and another type places the other
  value on the time line with the session zone (a `jtimestamp` is read as a local
  wall clock, a `jdate` as local midnight), so those pairs are `STABLE`; `jdate`
  against `jtimestamp` is `IMMUTABLE`;
- `=` between different types is `MERGES` but not `HASHES` (core has no
  cross-type hash either): a cross-type equality join uses a merge join or a
  nested loop, and an index on one type serves a cross-type predicate such as
  `jtimestamp_col < '1403-05-01'::jdate`;
- there is no operator against core's types: `jdate = date`, `jtimestamp =
  timestamp` and the like are `42883`. A bare literal still resolves to the
  same-type operator (`jdate = '1403-01-01'`, `jtimestamp < '1403-01-01 10:00'`).

There is no btree support function 3 (`in_range`), so a window `RANGE BETWEEN n
PRECEDING` over any of the three types stays `0A000` (core's would apply
Gregorian month arithmetic to a Jalali type).

### Hashing, `min` and `max`

Each type has a default hash class (`jtimestamp_hash_ops`, `jtimestamptz_hash_ops`)
with support function 1 and the seeded 64-bit function 2, on core's `timestamp`
hash functions. The hash is that of the `int64` microsecond count (in the test,
`hashint8` of the value computed from the epoch), so equal values written
differently hash equal, and hash indexes, hash joins, `HashAggregate`, `DISTINCT`
and `PARTITION BY HASH` work (pinned by `jt_hash`, `jt_ops` and the dump round
trip, which also checks that every row of a hash-partitioned table is still
found through the parent after a restore).

`min` and `max` exist for both types, with `SORTOP`, `PARALLEL = SAFE` and a
combine function, as `min(jdate)`: a plain `min(ts)` over an indexed column is an
index probe, and without an index a parallel plan uses a Partial and a Finalize
aggregate.

### Interval arithmetic

| Operator | Result | Volatility | Notes |
| --- | --- | --- | --- |
| `jtimestamp + interval`, `interval + jtimestamp`, `jtimestamp - interval` | `jtimestamp` | `IMMUTABLE` | months are Jalali months |
| `jtimestamptz + interval`, `interval + jtimestamptz`, `jtimestamptz - interval` | `jtimestamptz` | `STABLE` | months and days on the local wall clock in the session zone, the time part as elapsed time |
| `jtimestamp - jtimestamp` | `interval` | `IMMUTABLE` | days and time, never months (`10 days 12:00:00`) |
| `jtimestamptz - jtimestamptz` | `interval` | `IMMUTABLE` | zone independent |
| `jdate - jtimestamp`, `jtimestamp - jdate` | `interval` | `IMMUTABLE` | the day is its midnight |
| `jdate - jtimestamptz`, `jtimestamptz - jdate` | `interval` | `STABLE` | the day is its midnight in the session zone (a midnight in a gap is core's) |

`jdate + interval`, `jdate + time` and `jdate + timetz` are in the
[operator table](#operators). Core has no `timestamp + time` operator of its own;
`jtimestamp + time '02:00'` works as core's does, through the implicit `time ->
interval` cast, and `jtimestamp + jdate`, `jtimestamp + integer` and a core type
next to a Jalali one are `42883`.

The rules are core's, with Jalali month lengths (months 1 to 6 have 31 days, 7 to
11 have 30, Esfand has 29 or 30):

1. **Order**: months first, then days, then the time part. `1403-01-31 10:00 +
   interval '1 month 1 day 2 hours'` is `1403-03-01 12:00:00` (Ordibehesht 31,
   plus a day, plus two hours).
2. **Clamping**: a month step lands on the same day number, or the last day of a
   shorter target month. With `n` months from year `y`, month `m`: `t = y*12 +
   (m-1) + n`, year `floor(t/12)`, month `t mod 12 + 1`, day `min(day,
   month_length)`. `1 year` is 12 months.
3. **Not invertible**, as in core: `(1403-06-31 + 1 month) - 1 month` is `1403-06-30`.
   More rows, from the tests:

   | Start | Step | Result |
   | --- | --- | --- |
   | `1403-06-31` | `+ 1 month` | `1403-07-30` (Mehr has 30 days) |
   | `1403-06-31` | `+ 6 months` | `1403-12-30` (1403 is leap) |
   | `1403-07-30` | `- 1 month` | `1403-06-30` |
   | `1403-12-30` | `+ 1 year` | `1404-12-29` (1404 is not leap) |
   | `1403-12-30` | `+ 5 years` | `1408-12-30` (1408 is leap) |
   | `1403-12-30` | `- 12 months` | `1402-12-29` |
   | `1403-11-30` | `+ 1 month` | `1403-12-30` |
   | `0001-01-30` | `- 1 month` | `0000-12-30` (year 0 is leap) |
   | `3177-12-29` | `- 1 month` | `3177-11-29` |
   | `3177-12-29` | `+ 1 month` | `22008` |

4. **Range**: the month step is range-checked on its own. A month step whose
   result lies outside the supported years is `22008` even when a negative day
   part would bring the final result back inside (`3177-12-29 12:00 + interval
   '1 month -40 days'`); for `jtimestamptz` the narrower safe range applies to
   that intermediate step too. An interval field of `-2147483648` is `22008`
   (core's `interval_um`).
5. **Infinity** and, from 17, infinite intervals go straight to core's answer.

A day is not 24 hours for a `jtimestamptz` (see below), and `jtimestamp` has no
zone, so its days are always 24 hours.

### Daylight saving time

For a `jtimestamptz`, a month or day step is applied to the local wall clock in
the session zone and the result is turned back into an instant by core's own
`DetermineTimeZoneOffset`, so gaps and overlaps behave exactly as in core:

- a wall time **in a gap** (it does not exist) moves forward by the length of the
  gap: in Europe/Paris `2024-03-30 02:30 + 1 day` is `2024-03-31 03:30+02`;
- an **ambiguous** wall time (it occurs twice when the clocks go back) takes its
  **second** occurrence, the offset after the change: Paris `2024-10-27 02:30`
  is `02:30+01`, not `02:30+02`. This is core's rule and the rule of
  `timestamp AT TIME ZONE zone`, `timestamptz + interval '1 day'` and every
  place in this extension that turns a wall clock into an instant (`+`, `-`,
  `AT TIME ZONE`, `jdate_trunc`, `jgenerate_series`);
- `+ interval '1 day'` keeps the wall time and `+ interval '24 hours'` is elapsed
  time: across the Paris change of 2024-03-31 (Jalali `1403-01-12`), `12:00+01`
  plus 1 day is `12:00+02` and plus 24 hours is `13:00+02`;
- a midnight that does not exist (Tehran `2020-03-21`, Jalali `1399-01-02`, where
  the clocks went from 00:00 to 01:00) is the first valid instant of the day
  for `jdate_trunc('day', ...)`, `jdate_trunc('week', ...)` and the like, as core's
  `date_trunc('day', ...)`; year and month starts that fall on a normal day are
  unaffected.

Half-hour and 45-minute zones (Tehran, Kolkata, Kathmandu) are exercised
everywhere, because truncation to an hour is local, not aligned to UTC. `jt_dst`,
`jt_zone`, `jt_series`, `jt_trunc` and the `jt_sweep3` oracle sweeps pin all of
this against core on the Gregorian twin of each value.

### `jdate_bin`

`jdate_bin(stride interval, source, origin)` exists for `jtimestamp` and
`jtimestamptz` and is core's `date_bin` (`IMMUTABLE`, `STRICT`, `PARALLEL SAFE`),
followed by the range check. It is calendar independent: **strides are fixed
lengths of elapsed time counted from the origin instant**, not local days. A
stride with months or years is `0A000`, a zero or negative one `22008`, an infinite
origin `22008`, an infinite source gives infinity. For a `jtimestamptz` that
means a daily bin is a local day only in a fixed-offset zone with an origin at
local midnight: in Tehran, `jdate_bin('1 day', '1403-01-01 15:00+00'::jtimestamptz,
'1400-01-01 00:00+00'::jtimestamptz)` is `1403-01-01 03:30:00+03:30` (UTC
midnight), and in Paris, across a clock change with a local-midnight origin, the
bin edge moves by an hour. Use [`jdate_trunc`](#jdate_trunc-of-the-timestamp-types)
for local days, months and years. A source before the origin gets a bin start up
to one stride below it, which can be below the first Jalali day: `22008` (core's
`date_bin('365 days', '0560-03-20', '3000-01-01')` is `0559-08-16`).

### `jgenerate_series`

| Function | Returns | Volatility |
| --- | --- | --- |
| `jgenerate_series(jtimestamp, jtimestamp, interval)` | `SETOF jtimestamp` | `IMMUTABLE` |
| `jgenerate_series(jtimestamptz, jtimestamptz, interval)` | `SETOF jtimestamptz` | `STABLE` |
| `jgenerate_series(jtimestamptz, jtimestamptz, interval, zone text)` | `SETOF jtimestamptz` | `IMMUTABLE` |
| `jgenerate_series(jdate, jdate, interval)` | `SETOF jtimestamp` (the midnights) | `IMMUTABLE` |
| `jgenerate_series(jdate, jdate, step integer DEFAULT 1)` | `SETOF jdate` | `IMMUTABLE` |

All are `STRICT` and `PARALLEL SAFE`. The series is generated by the extension's
own code on every major version, with Jalali month steps: element `n + 1` is
element `n` plus the step, so a clamped day **sticks** (drift), as in core:
starting at `1403-01-31` by `1 month` gives `1403-01-31`, `02-31`, `03-31`,
`04-31`, `05-31`, `06-31`, `07-30`, `08-30`, ... `1404-02-30`; from the leap
Esfand 30 of 1403 by `1 year`, the 30th does not come back in the leap 1408
(`1404-12-29 ... 1408-12-29`). A day step on a `jtimestamptz` keeps the local
wall time (gap and overlap as above); the zone argument and the session zone are
read as core reads them (names, abbreviations, POSIX rules; unknown zone `22023`
even for an empty series). A zero step is `22023`, as in core, and so is a step that is
zero by core's comparison (`1 month -30 days`). The `jdate` day form never
overflows (steps of `±2147483647` give one row). The planner's row estimate of
core's function is not carried over (the default estimate of 1000 rows applies).

Core's `generate_series` does not accept the new types (no implicit casts), and
it is not overloaded: the extension uses a distinct name so that an unknown
literal can never resolve to core's function and silently read `'1403-01-01'` as
Gregorian year 1403 (see [Bare literals](#bare-literals-and-parameters)).
`jgenerate_series('1403-01-01', '1403-01-05')` resolves to the `jdate` day series.

### `AT TIME ZONE` and `OVERLAPS`

`x AT TIME ZONE zone` desugars to `pg_catalog.timezone(zone, x)` and `(a, b)
OVERLAPS (c, d)` to `pg_catalog.overlaps`, so the extension creates overloads
there (that is part of why it is not relocatable):

- `timezone(text, jtimestamp) -> jtimestamptz`, `timezone(interval, jtimestamp)
  -> jtimestamptz`, `timezone(text, jtimestamptz) -> jtimestamp` and
  `timezone(interval, jtimestamptz) -> jtimestamp`: core's four functions, then
  the range check; `IMMUTABLE`, `STRICT`, `PARALLEL SAFE`, as core's. The
  `jtimestamp -> jtimestamptz` direction can fail at both edges for ordinary
  zones; a `jtimestamptz -> jtimestamp` conversion cannot fail with a named zone
  or an offset under 16 hours, but core accepts any interval offset
  (`interval '20:00'`), and one beyond 16 hours at the edge is `22008`.
  `ts AT TIME ZONE z AT TIME ZONE z` is the identity outside gaps, and the other
  round trip is the identity outside overlaps.
- The zone text is read as in core: a literal `'03:30'` is the POSIX zone
  UTC-3:30, so write `interval '03:30'` for +03:30, and a named zone for
  anything with daylight saving time. The one-argument `AT LOCAL` forms are not
  provided.
- `overlaps(x4)` for `jtimestamp` and for `jtimestamptz`: core's function,
  `IMMUTABLE`, `PARALLEL SAFE` and **not** `STRICT` (it decides NULL ends itself),
  with core's half-open semantics. The forms with an `interval` end are not
  provided (`42883`; core's work).
- With only bare literals the call still resolves to core's `timestamptz`
  function: `'2024-03-20 12:00:00' AT TIME ZONE 'UTC'` is core's, and a typed
  `jtimestamp` or `jtimestamptz` operand picks the extension's.

### Fields of the timestamp types

`EXTRACT(unit FROM x)` calls `pg_catalog.extract(text, x)` and `jdate_part(unit,
x)` is the same value; **both return `numeric`** for the timestamp types
(`jdate_part` on a `jdate` stays `bigint`), so seconds and the epoch keep their
fractions exactly (core's `date_part` returns `double precision`, which loses
the microseconds of an epoch near the top of the range). `jtimestamp` is
`IMMUTABLE`, `jtimestamptz` is `STABLE` (it reads the session zone); both are
`STRICT` and `PARALLEL SAFE`, the unit decoder is core's (case-insensitive,
abbreviations) and its result is cached per call site. For a `jtimestamptz` the
fields are those of the local clock in the session zone.

| Unit | Value |
| --- | --- |
| `year`, `month`, `day`, `quarter`, `doy`, `decade`, `century` | as for `jdate`, from the (local) Jalali date |
| `dow` (0 = Saturday .. 6 = Friday), `isodow` (1 = Monday .. 7 = Sunday) | as for `jdate`: calendar independent, `dow` Saturday-first |
| `hour`, `minute` | the time of day |
| `second` | seconds with six decimals (`45.123456`) |
| `milliseconds`, `microseconds` | `45123.456` and `45123456` |
| `epoch` | seconds since 1970-01-01 00:00:00 UTC with six decimals, exact: for `jtimestamp` as if the value were UTC (as core's `timestamp`), for `jtimestamptz` the instant's own. `57724444799.999999` at the top of the range |
| `timezone`, `timezone_hour`, `timezone_minute` | `jtimestamptz` only: the offset east of UTC in seconds, and its hour and minute parts, truncated toward zero as core does (`12600`, `3`, `30` in Tehran; `+15:59` gives `15` and `59`) |

`week`, `isoyear`, `millennium`, `julian` (and the `timezone*` units on a
`jtimestamp`) are `0A000`: a Jalali week of the year has no standard
definition, and core's `week` is ISO. An unknown unit is `22023`. `0A000` is
raised even for infinity. For infinity, `EXTRACT` gives core's answers: `year`,
`decade`, `century` and `epoch` are `Infinity` / `-Infinity`, every other
supported unit is `NULL` (the `timezone*` units of a `jtimestamptz` as well);
`jdate_part` is `NULL` for every supported unit on infinity. In a call with a
bare literal (`EXTRACT(year FROM '1403-05-15 10:00')`,
`jdate_part('year', '1403-05-15')`) the overloads are ambiguous, `42725`.

### `jdate_trunc` of the timestamp types

`jdate_trunc(unit, jtimestamp)` (`IMMUTABLE`), `jdate_trunc(unit, jtimestamptz)`
(`STABLE`) and `jdate_trunc(unit, jtimestamptz, zone text)` (`IMMUTABLE`):

- `year`, `quarter`, `month` and `week` give the Jalali period start at local
  midnight. The week is the Saturday on or before the day (the Saturday-first
  `dow`), so a Saturday truncates to itself and the start may fall in the previous
  month or year. The local date comes from the time zone, the result goes back
  through core's `DetermineTimeZoneOffset` (so a midnight in a gap is the first
  valid instant).
- `day`, `hour`, `minute`, `second`, `milliseconds` and `microseconds` are core's
  truncation (`timestamp_trunc`, `timestamptz_trunc`, `timestamptz_trunc_zone`), in
  the session zone or the zone given: the hour of a `jtimestamptz` is a local hour,
  so it is not UTC aligned in a half-hour zone.
- Every other known unit (`decade`, `century`, `millennium`, `epoch`, `dow`,
  `doy`, `isodow`, `isoyear`, `julian`, `timezone*`) is `0A000` (message names the
  unit and the type), an unknown one `22023`.
- Infinity is returned unchanged for **every unit that decodes**, supported or
  not, as core's `date_trunc` does (unlike `EXTRACT`, which raises `0A000` for an
  unsupported unit even on infinity). With a zone argument the zone is looked up
  first, so an unknown zone is `22023` even for infinity.
- The result is range-checked for every unit. For a `jtimestamp` only `week`
  can fail: `-0061-01-01` and `-0061-01-02` (before the first Saturday) are
  `22008`. For a `jtimestamptz` any unit whose result falls below the safe range
  fails: in a UTC session the year, quarter, month, day or week start of an
  instant in the first period is a local midnight before `-0061-01-01 16:00`
  UTC; `hour` of the first safe instant is fine in UTC and `22008` in a
  `+15:59` zone; `minute` and finer never fail.
- The zone argument is read as core reads it (a POSIX offset `+03:30` means
  UTC-3:30).

`jdate_trunc('month', '1403-05-15')` with a bare literal is `42725` now that the
function is overloaded on three types; cast the argument.

### `jday_format` and `jmonth_format`

`jday_format(x, sep text DEFAULT '-')` returns the text key `YYYY-MM-DD` and
`jmonth_format(x, sep text DEFAULT '-')` the key `YYYY-MM`, for `x` a `jdate`, a
`jtimestamp` or a `jtimestamptz` (the local day in the session zone). The year
has four digits with the sign outside the padding (`-0061-05-03`), `sep` is any
text (`'/'` gives `1403/05/03`, `''` gives `14030503`), a `NULL` separator gives
`NULL`, infinity gives `infinity` / `-infinity` whatever the separator. They are
`STRICT`, `PARALLEL SAFE`, `IMMUTABLE` for `jdate` and `jtimestamp` and `STABLE`
for `jtimestamptz`. They are written in C because a SQL-language wrapper over
`jdate_part` fails inside `CREATE INDEX` (index builds run with a restricted
`search_path`). There is no explicit-zone variant: use `AT TIME ZONE`.
`jday_format(now())`, with a core type, is `42883`, and a bare literal is `42725`.

```sql
SELECT jday_format('1403-05-03 10:00'::jtimestamp);       -- 1403-05-03
SELECT jmonth_format('1403-05-03'::jdate, '/');           -- 1403/05
SELECT jday_format('1403-05-03'::jdate, '');              -- 14030503
-- a monthly report in the Tehran calendar
SELECT jmonth_format(created_at AT TIME ZONE 'Asia/Tehran') AS month, count(*)
  FROM orders GROUP BY 1 ORDER BY 1;     -- created_at is a jtimestamptz
```

### Index recipes

A function that is `STABLE` cannot be indexed (`42P17`), so every session-zone
form of a `jtimestamptz` is out: `jday_format(tz)`, `jmonth_format(tz)`,
`jdate_trunc('month', tz)`, `extract(year FROM tz)`, `jdate_part`, and `tz::jdate`.
Convert to a zone-free value first. These work, build, and are used by the
planner (pinned in `jt_consistency`, `jt_zone`, `jt_format`, `jt_fields`):

```sql
-- the wall clock in a fixed zone is a jtimestamp, which is zone free
CREATE INDEX ON events ((tz AT TIME ZONE 'Asia/Tehran'));
CREATE INDEX ON events (jday_format(tz AT TIME ZONE 'Asia/Tehran'));
CREATE INDEX ON events (jmonth_format(tz AT TIME ZONE 'Asia/Tehran', '/'));
CREATE INDEX ON events (((tz AT TIME ZONE 'Asia/Tehran')::jdate));
-- the explicit-zone truncation is IMMUTABLE
CREATE INDEX ON events (jdate_trunc('month', tz, 'Asia/Tehran'));
-- on a jtimestamp column, directly
CREATE INDEX ON t (jday_format(ts));
CREATE INDEX ON t (extract(year FROM ts));
CREATE INDEX ON t (jdate_trunc('week', ts));
-- a stored generated column, the same way
ALTER TABLE events ADD COLUMN day jdate
    GENERATED ALWAYS AS ((tz AT TIME ZONE 'Asia/Tehran')::jdate) STORED;
```

`jdate_bin(interval '1 hour', ts, origin)` on a `jtimestamp` is indexable too.
Queries must use the same expression. The zone is a name, and the usual tzdata
caveat for an index on a zone expression applies.

### Range and multirange types

Three range types, each with its multirange type (created automatically, and
their arrays), in the extension's schema:

| Range type | Subtype | Multirange | Notes |
| --- | --- | --- | --- |
| `jdaterange` | `jdate` | `jdatemultirange` | discrete, with a canonical function; `upper - lower` is an integer |
| `jtsrange` | `jtimestamp` | `jtsmultirange` | continuous; `upper - lower` is an `interval` |
| `jtstzrange` | `jtimestamptz` | `jtstzmultirange` | continuous; prints in the session zone |

The subtype difference functions are C wrappers over core's `daterange_subdiff`,
`tsrange_subdiff` and `tstzrange_subdiff`, and the operators, accessors,
`range_agg`, `range_intersect_agg`, GiST and SP-GiST indexes, btree ordering,
`EXCLUDE` constraints, arrays and binary I/O all come from core's generic range
code, which is type agnostic; a core-types oracle over every ordered pair of 44
ranges (ten boolean operators, union, intersection, difference, ordering,
aggregates) matches daterange, tsrange and tstzrange with no mismatch
(`jt_rangetypes`). Constructors `jdaterange(a, b [, bounds])` and so on are not
`STRICT` (a `NULL` bound is unbounded), as core's.

`jdaterange` is discrete, so core's canonicalisation turns `[a, b]` into `[a,
b + 1)`: `'[1403-01-01,1403-01-31]'` is `[1403-01-01,1403-02-01)`. The canonical
function range-checks the bound it computes, so **the last day is the edge**:
`'[1403-01-01,3177-12-29]'` (an inclusive upper bound on the last day, which would
become `3177-12-30`) and `'(3177-12-29,)'` (an exclusive lower bound there) are
`22008`, soft for `pg_input_is_valid`, while `'[3177-12-29,)'`,
`'[...,3177-12-29)'` and bounds at the date `infinity` are fine (`upper_inf` is
false for a bound at `infinity`, as in core).

There are no casts to or from core's range types (`42846`). A GiST or SP-GiST index
over a range, a multirange index and an `EXCLUDE USING gist` over `jdaterange`
work and are used by the planner.

### Time zones and the timestamp types

The timestamp types add the following rows to the zone table of
[Time zones](#time-zones); nothing else reads a zone.

| Function, cast or operator | Zone used |
| --- | --- |
| `jtimestamptz` text input without an offset, and its output | session `TimeZone` |
| casts between `jtimestamp`, `jtimestamptz`, `jdate` that involve a `jtimestamptz` or add a zone (`jtimestamp -> jtimestamptz`, `jtimestamptz -> jtimestamp`, `jdate -> jtimestamptz`, `jtimestamptz -> jdate`, `date -> jtimestamptz`) | session `TimeZone` |
| `jtimestamptz` arithmetic with an interval, cross-type comparison with a `jtimestamptz` and another type, `jdate - jtimestamptz`, `jgenerate_series(jtimestamptz, ...)` | session `TimeZone` |
| `EXTRACT`, `jdate_part`, `jdate_trunc`, `jday_format`, `jmonth_format` of a `jtimestamptz` | session `TimeZone` |
| `jdate_trunc(unit, tz, zone)`, `jgenerate_series(..., zone)`, `x AT TIME ZONE zone` | the zone you name |
| `jtimestamp` in every operation, `jtimestamptz - jtimestamptz`, `jdate_bin`, `to_jtimestamptz`, comparison and hashing of one type | none |

The knob is PostgreSQL's `timezone` setting, per session, database or role, as
for `jdate`. A `jtimestamptz` literal needs the Jalali date even for a Gregorian
instant: the instant `2024-03-19 21:00 UTC` is written `1402-12-29 21:00+00`.

### Bare literals and parameters

The new overloads make a call with an untyped literal (or an untyped `$1`
parameter, as a prepared statement, a driver or `pgbench -M extended` sends) ambiguous,
`42725`, in the places where a single candidate used to resolve. This is the
same situation as `date` in core, and it is deliberate. Add a cast or a typed
value:

| Fails with `42725` | Works |
| --- | --- |
| `jdate + '5'`, `'5' + jdate`, `jdate + '1 day'`, `jdate + $1` | `jdate + 5`, `jdate + interval '5 days'`, `jdate + $1::int` |
| `jdate_part('year', '1403-05-15')` and `jdate_part('year', '1403-05-15 10:00')` | `jdate_part('year', '1403-05-15'::jdate)` |
| `jdate_trunc('month', '1403-05-15')` and the `jtimestamp` form | `jdate_trunc('month', '1403-05-15'::jdate)`; with a zone argument one candidate remains, `jdate_trunc('month', '1403-05-15 10:00+00', 'UTC')` |
| `EXTRACT(year FROM '1403-05-15')` (as in core without the extension) | `EXTRACT(year FROM '1403-05-15'::jdate)` |
| `jday_format('1403-05-03')`, `jday_format(NULL)`, `jmonth_format('1403-05-03 10:00')`, `PREPARE ... jday_format($1)` | `jday_format('1403-05-03'::jdate)` |
| `jgenerate_series('1403-01-01', '1403-03-01', interval '1 month')`, and with a bare third argument | `jgenerate_series('1403-01-01'::jdate, '1403-03-01', interval '1 month')`; the two-argument and `(.., 1)` forms resolve to the `jdate` day series |
| `jdate_bin('1 day', '1403-01-01', '1403-01-01')` | one typed argument decides |
| `('1403-01-01', '1403-01-10') OVERLAPS (...)` (as in core) | a typed first element |

Calls that still resolve (so no change in behaviour): `jdate = '1403-01-01'`,
`jtimestamp < '...'` and the cross-type comparisons; `jtimestamp + '1 day'` (one
candidate); `jdate - '5'` and `jtimestamp - '1 day'` are read as the difference of
two values and fail with `22007`, as in core. Calls with a core type are
`42883`, not ambiguous, because there are no implicit casts: `jday_format(now())`,
`jdate_trunc('day', now())`, `jdate_part('year', now())`, `jdate = date`, `jtimestamp
= timestamp`, `date_trunc('day', jtimestamp)`, `generate_series(jtimestamp, ...)`,
`age(jtimestamp)`, `to_char(jtimestamp, ...)`. Core's `extract('year', now())` and
the other core calls are untouched. The core names that `EXTRACT`, `AT TIME ZONE`
and `OVERLAPS` desugar to are overloaded; `generate_series` and `date_bin` are not,
which is why the extension's functions are `jgenerate_series` and `jdate_bin`.

### Range selectivity

Core's range-predicate estimator can only interpolate inside a histogram bucket
for built-in types, so a narrow `BETWEEN` on an extension type was estimated at
one row, or at a whole bucket (about 20,000 of 2,000,000 rows) instead of about
10,000. This affected `jdate` as well. It is fixed: the `<`, `<=`, `>` and `>=`
operators of all three types and of the six cross-type pairs use the restriction
estimators `jdatetime_ltsel`, `jdatetime_lesel`, `jdatetime_gtsel` and
`jdatetime_gesel` (`src/jselectivity.c`; the join estimators are still core's). Each
relabels its operands to the core type that has the same representation (`date`,
`timestamp`, `timestamptz`) and calls core's `scalarltsel` and its siblings, so
core interpolates, and then does the pairing of a lower and an upper bound itself,
which core only does for its own estimator functions. On a 2,000,000-row table
(1440 rows a day) every 7-day window of 13 test windows is estimated exactly as
the core type estimates it (worst case 1.11 times the real 10,080 rows). Limits:
only the first lower and first upper bound of an `AND` group are paired (more
bounds multiply as independent), a pair is not recognised when the bounds are not
pseudo-constants (join clauses, as in core), an upper bound estimated alone while
its lower partner is in the same group gets the smaller conditional estimate, and
extended statistics cannot help a single-column range predicate (core needs two
columns). `jt_selectivity` pins it with booleans (the estimate within a factor of
two of the real count, for seven windows, eight predicate shapes and all six
types, core's as the control).

### Volatility and parallel safety of the timestamp types

Every function is `STRICT` (except the range constructors and `overlaps`) and
`PARALLEL SAFE`. The rule: a function is `STABLE` exactly when it reads the
session `TimeZone` or the clock; everything else is `IMMUTABLE`.

| Group | `IMMUTABLE` | `STABLE` |
| --- | --- | --- |
| I/O | `jtimestamp_out`, all `recv`, `send` and typmod functions | `jtimestamp_in`, `jtimestamptz_in` (the special words and the missing zone), `jtimestamptz_out` |
| Casts | `timestamp -> jtimestamp`, `timestamptz -> jtimestamptz`, `date -> jtimestamp`, `jdate -> jtimestamp`, `jtimestamp -> jdate`, the two scale casts | `date`, `jdate` and `jtimestamp -> jtimestamptz`, `jtimestamptz -> jtimestamp`, `jtimestamptz -> jdate` |
| Comparison, hash, `min`, `max` | everything of one type; cross-type pairs of `jdate` and `jtimestamp` | cross-type pairs that involve `jtimestamptz` and another type |
| Arithmetic | `jtimestamp +/- interval`, `jtimestamptz - jtimestamptz`, `jdate +/- interval`, `jdate + time` / `timetz`, `jdate - jtimestamp` | `jtimestamptz +/- interval`, `jdate - jtimestamptz` |
| Zone | `AT TIME ZONE` (all four), `jdate_bin`, `jgenerate_series(..., zone)`, `jdate_trunc(unit, tz, zone)`, `to_jtimestamptz` | `jgenerate_series(jtimestamptz, ...)` |
| Fields, formats | `extract`, `jdate_part`, `jdate_trunc`, `jday_format`, `jmonth_format` of `jtimestamp` | the same of `jtimestamptz` |

`jdate_format(timestamptz)` stays `STABLE`; `to_jdate` and `to_jtimestamptz` are
`IMMUTABLE` (no zone is read). The consequence: an expression index or a
generated column over a `jtimestamptz` needs an explicit zone (see the recipes),
and `jtimestamptz` literals cannot be used in index expressions at all.
Volatility is pinned against core's equivalent function in `jt_casts` (a computed
expectation for every cast function), `jt_dst`, `jt_sweep3` (32 functions),
`jt_consistency` (the field, truncation and format functions) and the `parallel`
catalog check.

### Known differences from core

- **`jgenerate_series` stops quietly at the Jalali range edge** where core raises
  an error. When the next element of a series would fall outside the range on the
  finishing side, the series ends after the current element; core's
  `generate_series('294276-12-30'::timestamp, '294276-12-31'::timestamp, '1 day')`
  raises `22008` (`timestamp out of range`) and loses the last row, because it
  computes the next element before returning the current one. An element outside
  the range on the other side of the series (a step whose month and day parts point
  in opposite directions) is `22008`, as is an overflow of the day part.
  `jgenerate_series` also refuses an infinite start or stop (`22023`), where core
  generates until it overflows. This choice is deliberate: no value that the
  type can hold is ever lost, and no spurious error is raised for a series that
  ends exactly at the last representable day.
- **No implicit casts and no operators against core's types**: core's
  `date` / `timestamp` / `timestamptz` chain is implicit and its operators mix them;
  here `jdate = date` and `jtimestamp = timestamp` do not exist.
- **Window `RANGE ... PRECEDING`** over a Jalali type is `0A000`.
- **Text input is Jalali only**: a Gregorian literal needs a cast through the core
  type (`'2024-03-20'::timestamp::jtimestamp`).
- **Names that differ from core's**: `jgenerate_series`, `jdate_bin`, `jdate_part`,
  `jdate_trunc`, `jday_format`, `jmonth_format`, `jdate_format`; `extract`, `timezone`
  and `overlaps` keep core's names because the syntax desugars to them.
- **`jdate_part`** returns `numeric` for the timestamp types (core's `date_part` is
  `double precision`) and `bigint` for `jdate`.
- **Week**: truncation to `week` starts on Saturday; `EXTRACT(week ...)` is
  `0A000`.
- **Ambiguity** with untyped literals, see above.
- **Safe range of `jtimestamptz`**: 32 hours shorter than the Jalali range, see
  above.

### What is not provided

`age`, `to_char`, `make_jtimestamp` (and `make_date`), a Jalali week of the year,
`EXTRACT(week | isoyear | millennium | julian)`, window `RANGE ... PRECEDING`,
`generate_series` and `date_bin` under core's names, `AT LOCAL`, `OVERLAPS` with
an interval end, `jday_format` with an explicit zone argument, casts to and from
core's range types, and implicit casts. `date_trunc('day', jtimestamp)`, `to_char(jtimestamp,
...)` and `age(jtimestamp)` are `42883`; going through the free `jtimestamp ->
timestamp` cast gives the Gregorian reading and core's functions.

## Extension properties

| | |
| --- | --- |
| Name, version | `jdate`, `1.0` (one script, `jdate--1.0.sql`, no upgrade scripts) |
| `relocatable` | `false` |
| Schema | chosen at install: `CREATE EXTENSION jdate SCHEMA s` (see [Installing into a schema](../README.md#installing-into-a-schema)) |
| Privileges | superuser: the control file does not mark it trusted, and the script creates functions in `pg_catalog` |
| `requires` | nothing |
| Library | `$libdir/jdate` |

Why it is not relocatable: `EXTRACT(field FROM x)`, `x AT TIME ZONE z` and
`(a, b) OVERLAPS (c, d)` desugar to schema-qualified calls to
`pg_catalog.extract`, `pg_catalog.timezone` and `pg_catalog.overlaps`, so the
overloads for the extension's types must be created in `pg_catalog` to take
part in those syntaxes. There are nine of them: `extract(text, jdate)`,
`extract(text, jtimestamp)`, `extract(text, jtimestamptz)`, the four
`timezone` functions (`text` or `interval` zone, `jtimestamp` or
`jtimestamptz`) and the two `overlaps` functions. They are outside the
extension's schema, so the server cannot move the extension (`ALTER EXTENSION
... SET SCHEMA`), and the control file says `relocatable = false`. Every other
object, including the range and multirange types, follows the schema given at
`CREATE EXTENSION`; `DROP EXTENSION` removes the nine again. `pg_dump` writes `CREATE EXTENSION jdate`
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
  **16, 17 and 18**. Locally, every change was run on 18 with the harness;
  17 was run on a scratch server (the whole suite, the last time 35 of 35
  tests, and the dump round trip); 16 has no local server, only a compile check
  against the 16.16 headers (silent), so a run on 16 is what CI is for. The
  places where a server's own output differs have alternate expected files
  for PostgreSQL 16 (no `COPY ... ON_ERROR`): `softerr_1.out` and
  `jt_softerr_1.out`. See [Testing](TESTING.md#testing).
- **Behaviour that depends on the major version** (everything else is the
  same on 16, 17 and 18):

  | Feature | 16 | 17 | 18 |
  | --- | --- | --- | --- |
  | `pg_input_is_valid`, `pg_input_error_info` and soft errors in the text input of `jdate`, `jtimestamp` and `jtimestamptz` (core's `timestamp_in` reports softly on 16, shown by CI) | yes | yes | yes |
  | the same for range and multirange input with an out-of-range bound (`jdaterange_canonical`) | by reading core's code only | yes | yes |
  | `COPY ... (ON_ERROR ignore)` skipping bad values | no (`42601`) | yes | yes |
  | infinite intervals (`+ interval 'infinity'`, an infinite step in `jgenerate_series` / `jdate_bin`): the interval literal | `22007` (no such literal) | accepted | accepted |
  | btree skip support (function 6) in `jdatetime_ops` | no | no | yes (added by a `DO` block) |
  | core's `timestamptz_hash` SQL function (only a test needed it) | no | no | yes |

  The infinite-interval code is guarded with `PG_VERSION_NUM >= 170000`; the
  tests that touch it accept the error where the literal does not exist, so one
  expected file serves all three versions.
- The local harness itself is PostgreSQL 18 only, because it relies on
  `extension_control_path`, new in 18; CI is what covers 16 and 17.
