# Testing

There are five layers: a standalone C test of the calendar code, the
`pg_regress` suite (36 test files), a `pg_dump`/restore round trip, a `pgbench`
concurrency stress run and a performance report. CI runs all of them on
PostgreSQL 16, 17 and 18. The local harness (`dev/test-cluster.sh`) runs the
first three on **PostgreSQL 18 only**; it needs no root, but it cannot test
16 or 17, so CI is what covers those two. One local command runs the three
layers it knows and fails if any does:

```sh
dev/test-cluster.sh check
```

The behaviour these tests pin down is described in [SPECIFICATION.md](SPECIFICATION.md).

## Continuous integration

The workflow is [`.github/workflows/ci.yml`](../.github/workflows/ci.yml); the
runs are listed on the
[Actions page](https://github.com/mmgghh/postgres-jdate/actions). It runs on a
push to `develop` and on every pull request (a push to any other branch does
not start it), and a newer push to the same ref cancels the run in progress. It
has three jobs, each a matrix over PostgreSQL 16, 17 and 18 on `ubuntu-24.04`
with the server and development packages from `apt.postgresql.org`
(`.github/actions/setup-postgres`). The matrix is not fail-fast, so a red 16
does not hide 17 and 18.

| Job | Steps | Artifact |
| --- | --- | --- |
| `test` | `make`, `sudo make install`, `make installcheck` (the 36 `pg_regress` tests), `dev/dump-roundtrip.sh`, `make test-jalaali` | `regress-pg16`, `regress-pg17`, `regress-pg18`: `test/results`, `test/regression.diffs`, `test/regression.out`, uploaded even on failure |
| `stress` | build and install, `dev/stress.sh`, the exhaustive every-day `jtimestamptz` sweep (`dev/fullrange-sweep.sh`), then `dev/stress.sh --selftest` | none |
| `perf` | build and install, `dev/perf-report.sh` | `perf-pg16`, `perf-pg17`, `perf-pg18`: `perf-report.md` (also written to the job summary) |

On a failure the `test` job also prints `test/regression.diffs` into the log.
The `stress` self-test step passes only when `dev/stress.sh --selftest` exits
with status 3, which is how the script reports that it corrupted its own ledger
on purpose and the verifier noticed; exit 0 (not noticed) or any other status
fails the step.

Watching a run, from a checkout of the branch you pushed:

```sh
git push origin develop
RUN=$(gh run list --branch develop --json databaseId,headSha \
        -q "map(select(.headSha == \"$(git rev-parse HEAD)\"))[0].databaseId")
gh run watch "$RUN" --exit-status
gh run view "$RUN" --log-failed         # only the failed steps
gh run download "$RUN" -D /tmp/run      # artifacts: regress-pg*, perf-pg*
```

### Expected files and alternates

A new regression test is written and reviewed locally, on the PostgreSQL 18
harness, and CI then confirms it on 16 and 17. The procedure:

1. Write `test/sql/NAME.sql` (new tests of the Jalali timestamp types are named
   `jt_*`), register NAME on the **one-line** `REGRESS` in the `Makefile` (after the
   existing names; `extension_schema` stays last, it drops the extension), and
   create an empty `test/expected/NAME.out` (`pg_regress` stops when the file is
   missing).
2. Run it: `dev/test-cluster.sh test NAME`. It fails and leaves
   `test/results/NAME.out`.
3. Read that file **line by line**, and check each result by hand against the
   behaviour you expect (not merely against what the server printed); only then
   copy it to `test/expected/NAME.out`. Never regenerate an expected file blindly,
   and when an existing test changes, read the diff and make sure only the
   intended lines moved.
4. Run the whole suite, then `dev/test-cluster.sh check`.

Rules that keep an expected file valid on every major version and every
database: print SQLSTATEs (`\set VERBOSITY sqlstate`, or a `plpgsql` block that
catches and returns `SQLSTATE`) and booleans, never server message text or
`EXPLAIN` text; set `DateStyle` and `timezone` explicitly (`pg_regress` forces
`PGTZ=PST8PDT`); put `COLLATE "C"` on every text sort key that can contain
punctuation, spaces, mixed case or digits next to letters (the local cluster is
`C.UTF-8`, an ICU or `en_US` cluster sorts differently, and CI found one such test);
use fixed POSIX zones (`<+15:59>-15:59`) for edge cases, so no historic tzdata
offset is baked in; create tables as temporary or drop them at the end, because
`extension_schema` runs `DROP EXTENSION`; and raise the function-count guard in
`parallel.sql` whenever a task adds functions (never lower it). The tests that write
or read binary files (`jt_io`, `jt_binary`, `jt_rangetypes`) put them in
`test/results/*.bin`, which is git-ignored.

`pg_regress` tries `NAME.out`, then `NAME_1.out`, and accepts whichever matches.
There are two alternates, both for PostgreSQL 16 (no `COPY ... (ON_ERROR ignore)`,
new in 17): `test/expected/softerr_1.out` and `test/expected/jt_softerr_1.out`. In
each, only the `COPY ... ON_ERROR` statements differ (`option "on_error" not
recognized`, and `42601` for `ON_ERROR stop`). `jt_softerr_1.out` was taken from a
CI run on 16, read line by line, and patched by hand once since for the
`jdate_in` infinity rows (the same hunk as in `softerr_1.out`); if a later CI run
on 16 shows a difference, replace it with the real output after reading it, never
write it by hand. A test needs an alternate only when the server's own output
differs between majors; prefer making the test output stable over adding one.

Where a difference between majors is still plausible, and so where an alternate (or
a replacement of a fixed zone by an offset) may be needed after a first CI run on
16 or 17, in the order of how likely it is:

- **tzdata**: the tests that name zones with history (`jt_zone`, `jt_dst`,
  `jt_series`, `jt_trunc`, `jt_sweep3`, `jt_consistency`, `jt_fields`,
  `jt_casts`, `jt_bin`) depend on facts such as Tehran's daylight saving time until
  2021 and Paris's changes of 2024; each grid prints a boolean that the offset
  really changes, so a tzdata difference shows there first. The historic-zone rows
  (Tehran 1200, Manila 1843) can be replaced by fixed offsets such as `+15:59:59`.
- **planner booleans** (a plan node chosen, an index usable): `jt_ops`,
  `jt_hash`, `jt_crossops`, `jt_rangetypes` (GiST, SP-GiST, btree plans),
  `jt_selectivity`, `parallel`.
- **range input**: the `pg_input_is_valid` query on range and multirange input in
  `jt_rangetypes` relies on core's `range_in` passing its error context to the
  canonical function; read, not run, on 16.
- **infinite intervals**: the rows in `jt_arith`, `jt_dst`, `jt_series` and `jt_bin`
  accept `22007` where the interval literal does not exist (16); `jt_series` also
  accepts `22023` or `42883` for the four-argument core `generate_series` on 16.
- **`jt_softerr_1.out`** staying equal to the 16 output after later changes.

## Running the tests locally

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
fully controls. That is why the harness is PostgreSQL 18 only:
`extension_control_path` is new in 18. `check` is idempotent and runs, in this
order:

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

The local cluster is created with `initdb --locale=C.UTF-8`, so a test whose row
order depends on the database collation fails here the way it does on CI (an
`en_US.UTF-8` cluster hid one); `setup` says which locale an existing cluster
has and warns if it is not `C.UTF-8` (to recreate it: `stop`, delete `.dev/pgdata`, `setup`).

`dev/test-cluster.sh check` is the gate for every change (the whole `REGRESS`
list, the dump round trip and the calendar test, green, with no compiler warning
in the harness build, which uses `gcc -Wall -Wextra`). Checks that are not wired
into any script:

```sh
# PostgreSQL 17 compile check, for every change to C (needs the 17 server headers;
# prints nothing when clean)
gcc -fsyntax-only -Wall -Wextra -I/usr/include/postgresql/17/server \
    -I/usr/include/postgresql/internal -Isrc $(ls src/*.c | grep -v test_jalaali)

# the same against the 16 headers, which have to be fetched (apt download of
# postgresql-server-dev-16, unpacked, not installed, as the harness does for 18)
gcc -fsyntax-only -Wall -Wextra -I<unpacked>/usr/include/postgresql/16/server \
    -I/usr/include/postgresql/internal -Isrc $(ls src/*.c | grep -v test_jalaali)

# the Makefile's version guard
make -n MAJORVERSION=15      # Makefile:23: *** jdate requires PostgreSQL 16 or later.  Stop.
```

The PostgreSQL 17 suite can also be run on a scratch server (a copy of the
system install with the extension installed into the copy, a throwaway data
directory and a free port, removed afterwards; never the project cluster); there
is nothing local for 16. The whole `REGRESS` list takes about 71 s on a cold 17.11
scratch server (`jt_arith` 26 s there), about 50 s on the harness.

CI runs `make installcheck` (`REGRESS` and `REGRESS_OPTS` in the `Makefile`)
against an installed extension, as a normal installation would. The local
harness does not use it.

## What each test proves

Every row below runs in CI on PostgreSQL 16, 17 and 18 and locally on 18 (the
regression files in the order of `REGRESS`, then the dump round trip and the
calendar test). The `stress` and `perf` layers have their own sections after the
table.

| Test | What it proves | Bug classes it guards |
| --- | --- | --- |
| `io` (also runs `CREATE EXTENSION`) | valid dates, both Esfand lengths, both range edges and `infinity` (any case) round-trip as text; each malformed or out-of-range text is rejected with the right SQLSTATE (`22007` vs `22008`), including month 13, day 32, day 30 in a common year, one past each end; int32 overflow in the year, month or day is `22008`, never wrapped; leading zeros, whitespace, `+` signs are accepted; whitespace (space, tab, newline) around `infinity` / `-infinity` is accepted while `'- infinity'` and `'infinity 1403-01-01'` stay `22007` | wrapped integers (`'4294968699-01-01'` once read as 1403-01-01), wrong error class, grammar drift, negative-year text |
| `casts` | `jdate` to and from `date`, `timestamp`, `timestamptz` (UTC); no implicit comparison with `date`; `to_jdate` gives the UTC day under America/New_York, Asia/Tehran, Pacific/Kiritimati and UTC for 11 epoch probes (negative, day boundaries) and for both range edges; `NaN`, `1e15`..`1e300`, `±9.3e18` are `22008`; `±Infinity` maps to infinity; `to_jdate` is `IMMUTABLE` (usable in `CREATE INDEX`) | timezone-dependent `to_jdate`, truncation instead of floor on negative epochs, double-to-int overflow, wrong volatility |
| `operators` | the six comparisons, `ORDER BY`, a btree index used for `=` and ranges (`EXPLAIN`), `GROUP BY`/`DISTINCT`, `min`/`max` return `jdate`; `jdate_ops` is the default class of the `jdatetime_ops` family with support functions 1, 2 (`date_sortsupport`) and 4 (`btequalimage`), 6 (`date_skipsupport`) exactly on PG 18, and `amvalidate` accepts it; a 4,000-row sort with duplicates, negative years, both edges and both infinities is ordered and equals the order of the `date` cast; a deduplicated index over 20,000 rows is smaller than a non-deduplicated one and index scans equal sequential scans | missing operator class, `min`/`max` resolving through the `timestamptz` cast, missing or wrong sort support or equalimage, a sort that mishandles negative days or infinity |
| `arithmetic` | `jdate ± int`, `jdate - jdate`; a result past either edge is `22008` when computed, not when displayed; `int + jdate` equals `jdate + int`, is range-checked, keeps infinity; no shell operator in `pg_operator`, the two `+` are each other's commutator | `5 + jdate` failing as a shell operator, lazy out-of-range error |
| `fields` | every unit of `jdate_part`/`EXTRACT`; the return types pinned with `pg_typeof` (`jdate_part` is `bigint`, `EXTRACT` is `numeric`, for finite dates and for infinity) and the volatility (`IMMUTABLE`) and parallel safety of both functions in `pg_proc`; `decade` for every year `-61`..`3177` against core and `floor(year/10)`, negative years included; `dow` (Saturday-first: core's `(dow + 1) % 7`), `isodow` and `epoch` against core for boundary dates and every day of the range (also through `EXTRACT`); `epoch` exact as an integer at both range edges and on negative values; one full Saturday-to-Friday week across a month boundary and one across the year `-1`/`0` boundary, `dow` and `isodow` side by side with core's weekday name; ten units (`dow`, `isodow`, `epoch`, `year`, `month`, `day`, `quarter`, `doy`, `decade`, `century`) on `±infinity`: `jdate_part` is `NULL` for all of them, `EXTRACT` agrees with core (`±Infinity` for the units that only grow); time-of-day units (`NULL` on infinity); the per-call-site unit cache (20 units from a table column, with repeats, mixed case and switches back and forth, an invalid or over-long unit in the middle of the stream, in `jdate_part`, `EXTRACT` and `jdate_trunc`, each compared with constant-unit results); `jdate_trunc` (`week` truncation, Saturday start: a full Saturday-to-Friday week across a month boundary, across the year `1402`/`1403` and across `-1`/`0`, previous month and year starts, mixed-case unit, both infinities, both range edges including the `22008` error for the first two days of the range), including infinity | decade as first year (1400 for 1403), calendar-dependent `dow`/`epoch` failing on infinity, `dow` reverting to core's Sunday-first numbering or `isodow` being shifted along with it, `jdate_part` or `EXTRACT` changing type, a float rounding in `epoch`, a stale cached unit returning the previous row's field, `EXTRACT` for `date`/`timestamp` disturbed by the overload |
| `format` | `jdate_format` under Asia/Tehran and UTC (crossing midnight, with and without time); negative years print `-0061` not `-061` (years `-61`, `-10`, `-1`, `0`, `1`, `1403`, `3177`); it equals `d::text` for the first 23,000 days of the range (all the negative years and year 0) plus every 101st day of the whole range; `±infinity` in UTC and Tehran; `22008` past either edge | sign-padding in the year, infinity errors, unchecked out-of-range days |
| `range` | every path that produces a `jdate` rejects out-of-range values with `22008` and accepts both edges: `jdate ± int` (including `±2147483647`), the three casts from `date`/`timestamp`/`timestamptz` (also year 1, 9999, BC, core's own limits 4714 BC and 5874897 AD); infinity passes everywhere; the cast catalog (six casts, assignment, `jdate(date)` immutable/strict/parallel safe); a failed `INSERT` leaves the table empty and readable | the stored-but-unreadable value (one `'9999-12-31'::date` made `SELECT *` and `pg_dump -t` fail), a hole in any one path |
| `binary` | `jdate_send` equals `date_send` for six values; `COPY (FORMAT binary)` round trip; the same file reads as `date`; `jdate_recv` rejects below min, above max, 9999, year 1, core's min and max, and a bad row among good ones (`22008`, nothing loaded); both edges and both infinities are accepted | unvalidated binary receive, wire-format drift from `date` |
| `hash` | both support functions registered, `amvalidate` true; extended hash agrees with the plain hash at seed 0 (low 32 bits) and depends on the seed; `PARTITION BY HASH` with three partitions (every row lands, rows spread, pruning scans one partition, runtime pruning finds every row); a hash index is chosen and returns the right rows; Hash Join/HashAggregate give the same results as merge/nested-loop/sort | missing support function 2 (partitioning failed), wrong or inconsistent hashing, infinity in hashes |
| `fullrange` | all 1,183,020 days: text round trip and text shape, `jdate_send` = `date_send`, successive days contiguous, month and year lengths, 785 leap years, Esfand 30 only in 366-day years, Nowruz on 20-22 March of `y+621`, month starts in a fixed Gregorian window, each day's Gregorian year, `dow` (shifted to a Saturday start)/`epoch`/`doy`/`jdate_trunc` (including `week`, with exactly 2 days before the range's first Saturday) against core, text digits against `jdate_part`; three negative controls prove the checks can fail | an off-by-one or drift anywhere in the conversion, checked against *core's* Gregorian calendar rather than `jalaali.c`'s own, so an error cannot cancel itself out |
| `softerr` | `pg_input_is_valid` and `pg_input_error_info` (message and `22007`/`22008`) for good, syntax, month, day, range and overflow inputs; array input; `COPY ... (ON_ERROR ignore)` loads the good rows, skips three bad ones and emits the NOTICE; `ON_ERROR stop` still aborts; `pg_input_is_valid` is true for `infinity` with whitespace around it (space, tab, newline) and false for `'- infinity'` and `' infinity 1403-01-01'`. Has an alternate expected file, `softerr_1.out`, for PostgreSQL 16, which has no `ON_ERROR` | `ereport` instead of `ereturn` in `jdate_in`; hard errors that should be soft (needs 17 for the `COPY` half) |
| `tz_casts` | the `timestamptz` casts under six session zones (UTC, Asia/Tehran, America/New_York, Pacific/Kiritimati at +14, Pacific/Pago_Pago at -11, Pacific/Auckland), with instants built from local clock times so a probe means the same in every session zone: midnight probes and the Nowruz instant (the same instant is 1403-01-01 in Tehran, Kiritimati and Auckland and 1402-12-29 in UTC, New York and Pago_Pago); the assignment cast on `INSERT`; `timestamptz(jdate)` is local midnight; a 366-day round trip of 1403 and every hour of 2024 and of Tehran 2020 (no mismatch); daylight-saving days (New York 23 and 25 hours, Auckland 25 and 23, Tehran's 2020 summer time against winter); `jdate_format` with time of day; both range edges in the +14 and -11 zones, and one instant past each edge is `22008`; then `to_jdate(e, zone)` with the session set to a zone that is none of the ones asked for: UTC, `Asia/Tehran` and `America/New_York` around Nowruz 1403, the one-argument form equal to zone `'UTC'`, New York's 23- and 25-hour days, negative epochs (floor, never toward zero), a probe every half hour across 1403 in five zones against core's `AT TIME ZONE`, the session zone irrelevant, infinity and `NULL`, the range edges (the epoch and the local day are both checked), an unknown or empty zone (`22023`, also with `±Infinity` and `NaN`, which must not skip the zone check, while a good zone still gives infinity), and volatility and parallel safety equal to core's `timezone(text, timestamptz)` | timezone leaking into the date (an off-by-one day near midnight), a wrong day across a daylight-saving change, a range check done in UTC instead of in the session zone, `to_jdate(e, zone)` reading the session zone or ignoring a DST change |
| `sqlstate` | 120 statements (the first 31 for `jdate`, 89 added for the timestamp types: both types x `22007` / `22008` / `22009` / `22023`, 15 spellings that must succeed, casts, typmod rounding and `to_jtimestamptz`), each run in a `plpgsql` block that catches the error, compared by SQLSTATE only (never message text, which changes between majors): `22023` for an unknown unit in `jdate_part`, `EXTRACT` and `jdate_trunc`; `0A000` for the recognised but unsupported units (`week`, `millennium`, `julian`, `isoyear`, the three `timezone` units, `jdate_trunc` of `decade` and `hour`) and for `ALTER EXTENSION ... SET SCHEMA` into a throwaway schema; `42883` for `jdate = date`, `jdate + jdate`, `jdate + bigint` and `date_part('year', jdate)`; `22008` for subtracting an infinite date and for a `jdate_trunc('week')` whose start is below the first day; the `22007`/`22008` input errors as a sanity check; units that must succeed (`epoch`, `year`, `month`) so the codes are not just "everything fails"; finally, the extension is still in its schema | an error class changed by a refactor (`22023` becoming `0A000`), an operator added by accident, `ereport` code swapped while the message stays the same |
| `parallel` | every function and aggregate the extension owns has `proparallel = 's'` (catalog check, with a guard that it looked at the 6 aggregates and at least 181 functions; the bound rises with every function the extension adds), and the six `min` / `max` aggregates have their `smaller` / `larger` function as a `PARALLEL SAFE` `aggcombinefn`; with `parallel_setup_cost`, `parallel_tuple_cost` and the minimum scan sizes at 0 and two workers allowed, the planner puts a `Gather` under each of ten queries on 200,000 rows (a range filter, `+ int`, `jdate_part`, `jdate_trunc`, `jdate_format`, `min`/`max` plain, grouped by an expression and grouped by a column, an `ORDER BY` that must show `Gather Merge`, and a join that must show `Hash Join`; and for `jtimestamp` and `jtimestamptz` a filter, an `ORDER BY` under `Gather Merge` and `min` / `max` plain and by column, the `min` / `max` ones with Partial and Finalize aggregates), and a checksum of the result is the same with 0 workers as with 2; only booleans are printed, never `EXPLAIN` text. The plain and the column-grouped `min`/`max` must plan as a Partial Aggregate under the `Gather` and a Finalize Aggregate above it (the expression-grouped one is only checked for equal results, since the planner prefers a serial aggregate there) | a function wrongly marked parallel safe or restricted, a parallel plan giving a different answer, an aggregate no longer usable in parallel, a lost `COMBINEFUNC` |
| `jt_io` | text I/O of both timestamp types: the Jalali date prefix with core's time syntax, both Esfand lengths and range edges, fractional rounding, `24:00:00`, AM/PM, zones in the text (`jtimestamp` parses and ignores them, `jtimestamptz` honours them), `22007` / `22008` / `22009` / `22023` for each kind of bad input including a `BC` token and a duplicate date; the exact seven-word special list (`allballs` and Gregorian spellings are `22007`) with whitespace around the words accepted and whitespace inside them not; typmod through the input function, array literals, `INSERT`, `pg_input_is_valid`; send/recv; the unknown-zone and displacement cases; tables are dropped at the end | a Gregorian reading of a Jalali date, special words resolved by core's wider parser, wrong error class, a message naming `timestamp` instead of the type |
| `jt_casts` | the 14 casts of the timestamp types, including the zone-dependent edge days (first, second and last day to `jtimestamptz` in fixed `+14` / `-11` zones and in the Nowruz matrix), a 366-day sweep of 1403, typmod rounding and re-check through scale casts, `INSERT` / `UPDATE` / array casts, the casts that must not exist (`42846`), a computed volatility check of every cast function against core's own cast between the mapped core types (17 functions, 7 `STABLE`) | a cast with the wrong volatility, a missing range check after rounding, an implicit cast creeping in |
| `jt_bounds` | 132 cases in each of six zones (UTC, Tehran, Kiritimati, Pago Pago, `+15:59`, `-15:59`) through every producing path (text, casts from every type, typmod rounding, `to_jtimestamptz`, infinities), mapped to `t` or `22008`, each case's expectation built from core's own arithmetic in that zone (no tzdata history in the expected file), with a negative control that inverts every expectation; the one pinned asymmetry (literal with typmod `22008`, input function with typmod accepted) | an unchecked path, a range check done in UTC instead of the safe range, a hole at either edge |
| `jt_softerr` (alternate `jt_softerr_1.out` for 16) | `pg_input_is_valid` and the SQLSTATE of `pg_input_error_info` for 29 inputs on each type (good, syntax, month, day, range, BC, overflow, time field, zone, displacement), typmod rounding, array input, hard errors, `COPY ... (ON_ERROR ignore)` (6 rows skipped, 3 loaded) and `ON_ERROR stop` | a core failure that raises instead of being soft, `ereport` instead of `ereturn` |
| `jt_binary` | `send` equals core's `timestamp_send` / `timestamptz_send` and the bytes from core's epoch arithmetic; `COPY BINARY` round trip (arrays, NULLs, in Tehran, read back as the core types); out-of-range files built byte by byte (`lo_from_bytea`, `\lo_export`, so no core check sits in between): `22008` below and above both types, far values, `int8` limits, a bad row among good ones, typmod on receive; core-written files | unvalidated binary receive, wire drift from core |
| `jt_fullrange` | every day of the range for `jtimestamp` at `00:00:00` and `23:59:59.999999` (text equals the `jdate` text plus the time, the Gregorian date equals `jdate::date`, equal to core's timestamps, contiguity, back to `jdate`), `jtimestamptz` in UTC and Tehran on a sample (every 23rd day, the first and last five, every day 1976 to 2022 so every Tehran clock change is in it), four negative controls; the exhaustive every-day sweep for `jtimestamptz` is `dev/fullrange-sweep.sh` in the CI `stress` job | drift anywhere in the conversion or the safe range, checked against core's Gregorian calendar |
| `jt_ops` | the six comparison operators of both types: catalog (estimators, flags, commutators, negators, volatility), truth tables over edges, infinities and equal values written differently (also in other zones) against core's operators and a rank oracle; the same matrix in four session zones; 4,000-row sorts in both directions equal to core's order; btree build and deduplication with 20 distinct values in 20,000 rows; the planner's natural choices; hash functions equal core's (the oracle is version independent: `pg_amproc` of the `timestamptz` hash class, so no PG 18-only function is named); hash, merge and nested-loop joins and aggregates agree; family catalog (support functions 1, 2, 4 per type, 6 present exactly on PG 18); a control that must fail | wrong ordering, a missing support function, an index or join answer that differs from a sequential scan |
| `jt_hash` | hash opclass catalog and `amvalidate`; extended hash at seed 0 equals the plain hash and depends on the seed; hash equals `hashint8` / `hashint8extended` of the `int64` microseconds computed from the epoch; equal values written differently hash equal; `PARTITION BY HASH` (insert, spread, pruning scans 3 / 1 / 1 partitions, runtime pruning finds all 1,004 rows); a hash index is chosen and right; `min` / `max` (catalog, empty and all-NULL input, `FILTER`, window, infinities, edges, agreement with `ORDER BY ... LIMIT 1` and core's aggregate, a `SORTOP` index scan with no `Aggregate` node) | missing or inconsistent hashing, partitioning failures, a lost `SORTOP` or combine function |
| `jt_crossops` | the 36 cross-type operators and 42 functions (catalog: flags, estimators, commutators, volatility rule), the 45-row family and `amvalidate` true for all three classes; a value matrix (9 `jdate`, 13 `jtimestamp`, 16 `jtimestamptz` values) through all six ordered pairs in seven session zones: zero mismatches against core's operators on the Gregorian twins, an exact epoch oracle and the algebra (opposites, trichotomy, commutators) over 6,566 value pairs per zone; zone independence of `jdate` / `jtimestamp`, zone dependence of the pairs with `jtimestamptz`; three negative controls; merge joins for all six pairs, no hash join; index scans with cross-type predicates in both operand orders; 13 operators against core types are `42883` | a cross-type comparison that reads the wrong zone, a missing commutator, an index that cannot serve a cross-type predicate |
| `jt_arith` | Jalali month arithmetic on `jtimestamp` and `jdate`: the 15-row table (clamping, leap Esfand, `+60` months), months before days before time, non-invertibility, `1 year` = 12 months, infinity and `-2147483648` fields, a month step that leaves the range even when a negative day part would come back, day-only intervals equal to core's on the Gregorian twins, an independent SQL model of the month rule over 621,640 cases (last and first day of every month of every year, 8 month counts) with a negative control; `jdate + interval`, `jdate + time` / `timetz` (7 operators mirrored from core's `pg_operator`: result type, volatility, commutator), differences, generated columns and an index; bare literals (`jdate + '5'` is `42725`, `jdate - '5'` is `22007`, as core's); the slowest test (about 9 s locally, 26 s on a cold PG 17) | a Gregorian month length, an off-by-one clamp, a lost commutator |
| `jt_dst` | `jtimestamptz` arithmetic against core's `timestamptz` in Paris, Tehran, Sao Paulo and Kolkata: 53 hand-computed rows (each as `+`, flipped and negated `-`), 15-minute grids within two days of every offset change 2018 to 2024 (found from the zone data): no-month steps equal core's, month steps equal an independent model (core `AT TIME ZONE` + the `jtimestamp` month rule + core's day and time step); the second occurrence of an ambiguous wall time and a gap moving forward; the same statement in three zones; `CREATE INDEX` on a `STABLE` expression is `42P17`; differences in zones (a midnight in a gap); 44 edge rows in zones `+15:59` and `-15:59`; extreme intervals; negative controls (Gregorian month, a day as 24 hours) | a wall time resolved to the wrong occurrence, a day step that is not a wall-clock step, an edge row accepted outside the safe range |
| `jt_series` | `jgenerate_series` (five forms): hand rows (months from `1403-01-31`, years from the leap Esfand 30, negative steps, DST day steps in Paris, gap and overlap, the zone argument, both range ends, wrong-direction steps `22008`, zero, infinite, `NULL` and unknown zone, bare literals `42725`, `LATERAL` and `WITH ORDINALITY`); comparisons with core's `generate_series` for steps without months in five zones, the four-argument form against the session-zone form, and an independent model (`+` one element at a time) over 2,924 cases of every day of 1403 and 1404; "gap cases" with a witness that some series really move through a gap; negative controls (Gregorian months, "start plus n steps" without drift) | drift not matching core, a series that loses its last element or fails at the edge |
| `jt_bin` | `jdate_bin` against core's `date_bin` (flags equal; 15 hand rows; error and infinity table; the `0559-08-16` below-the-minimum example is `22008`; 12 edge rows for `jtimestamp`, 10 for `jtimestamptz`; sweeps of 1,008 cases each in four session zones with 0 mismatches and a negative control; the Tehran and Paris elapsed-time examples across both clock changes); generated column and expression indexes (used) | a bin start below the range accepted, a stride read as local days |
| `jt_zone` | `AT TIME ZONE` (four forms) and `OVERLAPS` (two forms): catalog (flags equal core's, no `AT LOCAL`, no interval-end form), hand rows both ways in Tehran, Kolkata, Kathmandu, Paris (gap and overlap, the instants of both clock changes), UTC, `EST` and interval zones, 18 edge rows plus 6 beyond 16 hours, infinity / `NULL` / unknown and empty zone, a grid of 17,410 wall clocks x 5 zones x both directions with 0 mismatches against core (witnesses that the windows contain offset changes), both round trips over 18,262 days each, 22 `OVERLAPS` rows for `jtimestamp` also run through core on the Gregorian twins, a 6,561-combination grid for each type with `NULL` and both infinities | a different rule for gaps and overlaps than core's, a zone sign inverted, a lost `NULL` handling in `overlaps` |
| `jt_sweep3` | the J3 oracle sweeps against a Gregorian oracle that uses no helper of the extension (real `jdate`, core's `AT TIME ZONE`, `interval '1 day'`, `date_bin`, `generate_series`): every hour of 2024 and of 2020 for `+/- 1 day` and `+/- 1 month` in Tehran, Paris and Kathmandu, month ends of 1399 to 1412 for months and years on three types in UTC and Tehran, every local day for `jdate + interval`, range-edge sweeps in five zones, series and `jdate_bin` over the same hours, witnesses that the hourly grid reaches a gap and an overlap through the month step, eight negative controls, and a volatility catalog of the 32 J3 functions (found = listed = 32) | an arithmetic or zone error that the hand rows do not reach; mutation-tested (Esfand always 30 days, and a wrong range for `jtimestamptz`) |
| `jt_fields` | `EXTRACT` and `jdate_part` of both types: catalog; all 15 units of one value by hand (`doy` 139, `epoch` 1722853845.123456); the top of the range `57724444799.999999` equal to core's; date fields against `::jdate`, time fields and `epoch` against core's `extract` on the Gregorian twin; `jtimestamptz` hand rows in 7 zones (Tehran, Kolkata, Kathmandu, St. John's, UTC, `<-03:30>`, `<+15:59>`); sweeps of more than 25,000 `jtimestamp` and 15,000 `jtimestamptz` values in 8 zones with 0 mismatches; negative controls; the infinity matrix; the `0A000` / `22023` matrix including infinity, with the unit and the type named in the message; bare literals `42725`; index on `extract(year FROM ts)` and `jdate_part('month', ts)` works for `jtimestamp` and is `42P17` for `jtimestamptz` | a wrong field in a half-hour zone, an epoch rounded through `double precision`, a unit not rejected on infinity |
| `jt_trunc` | `jdate_trunc` of both types and the zone form: catalog and core's volatilities; every unit of one value by hand; the Saturday week (including the leap day and the year boundary); a sweep of 2,719 `jtimestamp` values (day and finer equal to core's `date_trunc`, year to week equal to `jdate_trunc(u, v::jdate)`, never above the input, idempotent) and 1,880 instants in 8 session zones with 0 differences; the Tehran gap day (`1399-01-02`) and Sao Paulo against core; the explicit zone in 14 specs (names, `EST`, `PST8PDT`, `+03:30`, `<+15:59>`) against core's three-argument `date_trunc`; edge matrix of 390 (zone, unit, edge instant) cases against an oracle built from core (262 valid, 128 `22008`); infinity matrix; messages naming the type; index on `jdate_trunc('month', ts)` used, session-zone form `42P17` | a period start that leaves the range unnoticed, a midnight in a gap not moved to the first valid instant |
| `jt_format` | `jday_format` / `jmonth_format` on the three types: catalog, the report's values, negative years (`-0061-05-03`), separators (`''`, `/`, `%s%d`, 1,000 characters, `NULL`), the same instant in six zones, day/month/year boundaries crossed by a zone, the range edges, the infinity matrix, `GROUP BY jmonth_format` over a generated table (36 groups), agreement with `left(x::text, 10)` / `left(x::text, 7)` over a 34,486-value sweep and, for `jtimestamptz`, 34,359 instants in 10 zones, bare literals `42725`, core types `42883`, indexes (`jdate` and `jtimestamp` fine, `jtimestamptz` `42P17`, the `AT TIME ZONE` recipe fine and used) and generated columns | a sign padded into the year, a zone leaking into the key, an index recipe that stops working |
| `jt_consistency` | the J4 consistency sweep: every half hour across Nowruz 1403 and 1404 (a common year end and a leap year end) in Tehran, Kolkata, Kathmandu, Paris and UTC: 53 kinds of check, 111,554 comparisons per zone, tie `x::text`, `EXTRACT` (18 units), `jdate_part`, `jdate_trunc` (10 units, session, explicit-zone and wall-clock forms), `jday_format` / `jmonth_format`, `jdate_format` and core's `extract` / `date_trunc`; the same for `jtimestamp` in three session zones (one md5 signature across them); four negative controls; hand rows of the first and last instants of a year; the infinity matrix over every J4 function; index recipes (nine indexes built, used, and answering hand-computed counts; the six session-zone forms are `42P17`); the bare-literal ambiguity list (56 calls with their SQLSTATE); a catalog of 16 functions with a computed "as documented" volatility | disagreement between two functions that must agree (a field and its truncation and its text), a recipe that stops being indexable |
| `jt_rangetypes` | `jdaterange`, `jtsrange`, `jtstzrange` and the multiranges: catalog (types, `pg_range`, support-function volatility, 19 functions all `PARALLEL SAFE`, extension membership), literals and canonical forms, accessors, operators, the canonical edge (`[..,3177-12-29]` and `(3177-12-29,)` are `22008`, soft for `pg_input_is_valid`), three zones for `jtstzrange` and the safe-range edges, `range_agg`, `range_intersect_agg`, arrays and `= ANY`, a core-types oracle over every ordered pair of 44 ranges (ten boolean operators, union, intersection, difference, ordering, aggregates) with 0 mismatches for all three, GiST and SP-GiST plan booleans and answers against an index-free oracle, btree on a range, `EXCLUDE` (`23P01`), primary key (`23505`), no casts to core's range types (0 `pg_cast` rows, `42846`), `COPY BINARY` round trip and core-written files, `DEFAULT` / `CHECK` / generated column, a view | a bound at the edge accepted, an operator differing from core's range code, a lost canonical function |
| `jt_selectivity` | the range-selectivity fix: 100,000 rows (1,440 a day, histogram target 10), seven windows (the 1-day and 3-day ones inside one bucket) x eight predicate shapes (`>= <`, `> <=`, `BETWEEN`, commuted, mixed, an `OR` of two pairs, one-sided, cross-type) x six types (core's types are the control): the estimate within a factor of two of the real count (measured ratios 0.93 to 1.00); generic-plan and expression cases equal the core type's estimate. Mutation check: with the operators set back to core's `scalar*sel` the Jalali columns print `f` in every two-sided form | a regression to the one-row or whole-bucket estimates |
| `extension_schema` (drops and recreates the extension, so it is last) | `extrelocatable` is false; install into schema `jdate_s`; every object is in it except the nine `pg_catalog` overloads (three `extract`, four `timezone`, two `overlaps`), counted before and after the drop; the six range and multirange types, their arrays and 19 functions are in it, a range is usable schema-qualified and the canonical edge works there; `EXTRACT` works with the schema off `search_path`; `ALTER EXTENSION ... SET SCHEMA` fails with `0A000` and leaves the extension intact; `DROP EXTENSION` removes the nine functions and all the types; the default schema is restored | a relocatable flag that lies, objects leaking outside the schema, a dangling `pg_catalog` function |
| `dev/dump-roundtrip.sh` | a source database with boundary days, a negative year, `0000`, both infinities, `NULL`, a `jdate[]` column, a default and a `CHECK`, btree/hash/partial indexes, a 3-partition `PARTITION BY HASH` table and a view over `EXTRACT`/`jdate_trunc`; for the new types, tables of `jtimestamp` and `jtimestamptz` (both edges, negative years, infinities, `NULL`, offsets, `(0)` / `(3)` typmods, arrays, `DEFAULT`s and `CHECK`s, with Tehran as the session zone so the edge instants print with a seconds offset), btree, hash and partial indexes and expression indexes (`jday_format`, `jdate_trunc`, `EXTRACT`, `AT TIME ZONE`), hash-partitioned tables (every row found again through the parent), views over `EXTRACT`, `jdate_part`, `jdate_trunc`, `jday_format`, `jmonth_format` and `AT TIME ZONE`, and tables of the range and multirange types (compared as text and as per-value `range_send` bytes, with `EXCLUDE USING gist`, GiST and btree indexes); dumped as plain SQL, plain `--inserts` and custom + `pg_restore` into fresh databases; each restore matches the source on every value (text and binary), defaults, constraints, partition bounds, index and view definitions, type properties; `pg_dump -t` of each table exits 0. The whole run repeats with `CREATE EXTENSION jdate SCHEMA jdate_s` | dump/restore losing or corrupting values, partition placement changing, the extension schema not surviving a restore, the original `pg_dump -t` failure |
| `src/test_jalaali.c` (`make test-jalaali`) | standalone and server-free, built with `assert()` and no `NDEBUG`: all 1,183,020 days convert to a Jalali date and back; consecutive days are consecutive, month and year lengths hold; `jalaali.c`'s Gregorian conversions agree in both directions with an independent Gregorian implementation (Fliegel and Van Flandern) and with a walk of the Gregorian calendar; the range edges (one day past either end is rejected, `min_jdn`/`max_jdn`); every year's leap value is `0..3` and `is_leap` is `leap == 0`; Nowruz and leap years for seven known dates and five years | calendar-core regressions, in milliseconds and without a server, including `jalaali.c`'s own Gregorian helpers that the SQL tests do not reach |

### Concurrency stress

`dev/stress.sh` (CI job `stress`) is not part of `make installcheck` and is not
called by `dev/test-cluster.sh`. It creates a scratch database with
`jd_stress(id, d jdate, owner)`, a btree and a hash index on `d`, and a per-client
ledger `jd_ledger(owner, n)`. Then 16 `pgbench` clients on 4 threads run the
three scripts in `dev/pgbench/` at the same time, weighted 4:4:2: `stress-write.sql`
(insert, update and delete of the client's own rows, the ledger updated in the same
transaction), `stress-read.sql` (range scans, `GROUP BY`, `min`/`max`, `jdate_part`,
`jdate_trunc` and `jdate_format` under a per-client `TimeZone`) and
`stress-mixed.sql` (a write and reads, one run in twenty with a forced parallel
plan). The run is repeated under `pgbench -M simple`, `-M extended` and
`-M prepared`, 20 seconds each (`JDATE_STRESS_SECONDS`).

After each run it fails on the first of: a `pgbench` error, `FATAL` or aborted
client, or no transactions; `count(*)` differing from the sum of the ledger, in
total or for any owner; a stored day outside `-0061-01-01 .. 3177-12-29`; an
`amcheck` `bt_index_check(index, true)` failure on the btree; or a btree or hash
index scan that returns different rows from a sequential scan for sampled ranges
and values (the `EXPLAIN` plan is checked to really use the index under test).

A checker that never fails proves nothing, so `dev/stress.sh --selftest` runs
briefly, adds one to a ledger row on purpose (owner 0) and requires the verifier to
notice. It exits 3 when it did, the expected outcome (CI requires exactly 3), 0
if the corruption went unnoticed, and anything else for a setup problem.

The pgbench scripts cast every parameter that sits next to a `jdate` operator
(`jdate + :day::int`): under `-M extended` and `-M prepared` the parameter is
untyped, and since `jdate + interval` and `jdate + time` exist, `jdate + $1` is
ambiguous (`42725`), as `date + $1` is in core (CI found this: every client aborted
in the extended phase). `run_pgbench` adds `--exit-on-abort` when `pgbench --help`
lists it (17 and later), and on 16 the check of the output (`ERROR`, `FATAL`,
`aborted`) still fails the run.

The stress job also runs `dev/fullrange-sweep.sh`, which runs
`test/sql/jt_fullrange_stress.sql` in a scratch database: every one of the
1,183,020 days at its first and last microsecond as a `jtimestamptz`, under UTC and
Asia/Tehran (the same checks as `jt_fullrange`, against core's Gregorian calendar,
`timestamptz` and zone code; each zone is one `DO` block that raises if any
violation is counted; the first day's local midnight and the last day's last
microsecond are outside the safe range and are skipped; the next-midnight check is
UTC only). It ends with a negative control, the same counting over thinned, shifted
data, which must find violations (a silent control fails the script). It takes about
23 s per zone locally, about 70 s with the control. Exit status: 0 passed, 1 a check
failed, 2 setup problem. It is not part of `make installcheck`.

Both stress scripts take their server from `PGBIN`, `PGHOST`, `PGPORT` and
`PGUSER`, with defaults that match the local harness cluster, but nothing runs them
locally by default; CI is the supported way (a local run is done on a throwaway
server with its own data directory, never against the project cluster's data).

### Performance report

`dev/perf-report.sh` with `dev/perf.sql` (CI job `perf`) times the three Jalali types
against the native `date`, `timestamp` and `timestamptz` on a 1,000,000-row table
(`JDATE_PERF_ROWS`): 5 repeats per statement (`JDATE_PERF_REPS`), the median,
`clock_timestamp()` inside `DO` blocks, parallel query and JIT off, session zone
`Asia/Tehran` fixed in the script. It prints a Markdown table (operation, core ms,
Jalali ms, ratio), writes it to `perf-report.md` and to the job summary, and is
uploaded as the `perf-pg*` artifact. It is a report, not a benchmark suite: the
only gate is a failure when some ratio exceeds `JDATE_PERF_MAX_RATIO` (default
50, not raised), and operations with no core equivalent are shown in absolute time
and never gated. `JDATE_PERF_ONLY` (a regular expression on the row name) runs only
the matching rows.

The rows come in three groups, in this order. (1) `jdate` against `date`: text
input and output, `=` and `<` filters, sort, hash aggregate, `+ int`,
`EXTRACT(year)`, `date_part` / `jdate_part`, `date_trunc` / `jdate_trunc` (month),
`jdate_format`, btree build, btree range scan. (2) `jtimestamp: ...` against
`timestamp` and `jtimestamptz: ...` against `timestamptz`: text input and output, `=`
and `<` filters, sort, hash aggregate, btree build, btree range scan, `+ interval`
(1 day 02:00 and 1 month), `EXTRACT(year)`, `jdate_trunc` month against `date_trunc`,
and `jday_format` (no core equivalent). (3) The 66 `check: ...` rows, the
[range-check paths](#what-the-range-checks-cost): they have no core equivalent and
are never gated.

Observed on the CI runners before `jdate_ops` got `date_sortsupport` and `btequalimage`
(so the sort and btree rows are higher than a current build gives: the local run below shows
1.00x for the sort and 0.97x for the btree build), two runs on each of 16.16, 17.12 and 18.7, as the
range of the ratio (jdate time divided by `date` time) across all six reports.
Absolute times differ noticeably between runs and between versions, and the
ratios move less; treat everything below as an order of magnitude, not a
benchmark.

| Operation | jdate / date |
| --- | ---: |
| text input | 0.63x - 0.76x |
| text output | 1.39x - 1.73x |
| `=` filter (seq scan) | 1.04x - 1.12x |
| `<` filter (seq scan) | 1.07x - 1.10x |
| sort | 1.62x - 1.92x |
| hash aggregate | 1.02x - 1.10x |
| `+ int` | 1.10x - 1.24x |
| `EXTRACT(year)` | 1.20x - 1.42x |
| `date_part` / `jdate_part` (month) | 1.07x - 1.32x |
| `date_trunc` / `jdate_trunc` (month) | 0.60x - 0.73x |
| btree build | 1.42x - 2.03x |
| btree range scan | 1.30x - 1.85x |
| `jdate_format` (no `date` equivalent) | 317 - 539 ms per million rows |

The three field rows (`EXTRACT(year)`, `jdate_part`, `jdate_trunc`) were not
re-measured on the CI runners after `jdate_part` became `bigint` and the unit
cache was added; they are the spread of six runs on PostgreSQL 18.6 on the
development machine (`dev/perf-report.sh`, which does not match the CI runners
in absolute time and was noisy: on a busy machine two further runs gave
`EXTRACT(year)` 2.4x - 2.6x, which is why that row is the spread of the quiet
runs only). Before those two changes the same rows were 2.98x - 3.50x
(`EXTRACT(year)`, whose time was the `float8` to `numeric` conversion, now an
`int64` to `numeric` one), 1.24x - 1.32x and 0.82x - 0.93x. Text input and
`jdate_trunc` came out faster than `date`'s. The slowest operations are now the
sort, the text output and the btree build, which reached 2.03x in one run;
nothing is near the 50x gate.

The rows of groups 1 and 2 for the timestamp types were measured on the development
machine only (PostgreSQL 18.6, 1,000,000 rows, median of 5, one run, so noisy; the
CI runners have not reported them yet). The whole report, including the `jdate`
rows, in that run (ratio = Jalali time divided by core time):

| Operation | core ms | Jalali ms | ratio |
| --- | ---: | ---: | ---: |
| text input | 315.21 | 197.64 | 0.63x |
| text output | 177.10 | 296.17 | 1.67x |
| = filter (seq scan) | 64.67 | 68.32 | 1.06x |
| < filter (seq scan) | 75.19 | 78.85 | 1.05x |
| sort | 177.91 | 178.48 | 1.00x |
| hash aggregate | 176.39 | 172.19 | 0.98x |
| + int | 121.76 | 134.74 | 1.11x |
| EXTRACT(year) | 220.08 | 261.90 | 1.19x |
| date_part / jdate_part (month) | 165.70 | 169.94 | 1.03x |
| date_trunc / jdate_trunc (month) | 351.76 | 205.09 | 0.58x |
| jdate_format (no date equivalent) | n/a | 696.48 | n/a |
| btree build | 503.57 | 488.32 | 0.97x |
| btree range scan | 1.15 | 1.16 | 1.01x |
| jtimestamp: text input | 661.43 | 961.35 | 1.45x |
| jtimestamp: text output | 273.30 | 563.71 | 2.06x |
| jtimestamp: = filter (seq scan) | 89.99 | 123.53 | 1.37x |
| jtimestamp: < filter (seq scan) | 117.39 | 124.31 | 1.06x |
| jtimestamp: sort | 233.75 | 230.32 | 0.99x |
| jtimestamp: hash aggregate | 209.76 | 229.18 | 1.09x |
| jtimestamp: btree build | 438.18 | 466.75 | 1.07x |
| jtimestamp: btree range scan | 1.15 | 1.16 | 1.01x |
| jtimestamp: + interval (1 day 02:00) | 196.33 | 209.17 | 1.07x |
| jtimestamp: + interval (1 month) | 178.29 | 345.42 | 1.94x |
| jtimestamp: EXTRACT(year) | 241.03 | 393.73 | 1.63x |
| jtimestamp: date_trunc / jdate_trunc (month) | 206.45 | 253.02 | 1.23x |
| jtimestamp: jday_format (no core equivalent) | n/a | 439.65 | n/a |
| jtimestamptz: text input | 711.70 | 1012.10 | 1.42x |
| jtimestamptz: text output | 408.70 | 677.04 | 1.66x |
| jtimestamptz: = filter (seq scan) | 97.57 | 148.79 | 1.53x |
| jtimestamptz: < filter (seq scan) | 147.18 | 150.52 | 1.02x |
| jtimestamptz: sort | 255.37 | 265.94 | 1.04x |
| jtimestamptz: hash aggregate | 224.29 | 233.74 | 1.04x |
| jtimestamptz: btree build | 467.67 | 462.19 | 0.99x |
| jtimestamptz: btree range scan | 1.15 | 1.16 | 1.01x |
| jtimestamptz: + interval (1 day 02:00) | 282.95 | 290.14 | 1.03x |
| jtimestamptz: + interval (1 month) | 258.27 | 447.09 | 1.73x |
| jtimestamptz: EXTRACT(year) | 315.75 | 475.87 | 1.51x |
| jtimestamptz: date_trunc / jdate_trunc (month) | 293.69 | 465.23 | 1.58x |
| jtimestamptz: jday_format (no core equivalent) | n/a | 528.87 | n/a |

The largest ratios there are `jtimestamp` text output (2.06x), `jtimestamp: + interval
(1 month)` (1.94x, the Jalali month arithmetic against core's own), `jtimestamptz:
+ interval (1 month)` (1.73x), `jtimestamp` and `jtimestamptz` `EXTRACT(year)` (1.63x
and 1.51x) and the two `=` filters on the new types (1.37x and 1.53x). Text input of the new
types is 1.4x slower than core's (the date prefix is converted and core parses the
rest), `jdate` text input is faster than `date`'s. In the earlier measurement of the
range-check cost (below) the full report had its largest ratios at 1.97x (`jdate`
text output) and 1.80x (`jtimestamp: EXTRACT(year)`).

#### What the range checks cost

No check is removed, weakened or made optional; this measures what each costs. Two
builds of the same sources were timed with the `check: ...` rows: the normal one, and
a throwaway local build (never committed) in which every helper of the "Range
checks" section of `src/jdate_common.h` (`jdate_in_range`, `jdate_check_range`,
`jtimestamp_in_range`, `jtimestamp_check_range`, `jtimestamptz_in_range`,
`jtimestamptz_check_range`, `jdate_epoch_in_range`) does nothing; all other checks
go through those helpers. Still on in the off build: the display check in
`jdate_to_jalaali` (not a producing-path check) and the structural refusals that are
not helper calls (`jalaali_from_jdn`, `jdate_add_months` returning false). Each
build was made with `dev/test-cluster.sh build`; every perf run starts a new backend,
which loads the `jdate.so` that was moved over `.dev/extdir/jdate.so`. The
statements: `JDATE_PERF_ONLY='^check: ' JDATE_PERF_REPS=15 JDATE_PERF_ROWS=1000000
dev/perf-report.sh`, PostgreSQL 18.6, 6 rounds (each round one invocation per
build, the order flipping every round so slow drift hits both builds alike), so 90
timed runs per path per build. The table gives the median over the 6 round medians
(ms for 1,000,000 rows, so 1 ms is about 1 ns per row); "difference" is on minus
off. Rows marked "(no check)" go through no check at all and are the noise floor.

| path | ms on | ms off | difference ms | difference % of the path |
| --- | ---: | ---: | ---: | ---: |
| jdate text input (no check) | 249.9 | 248.3 | +1.6 | +0.6% |
| jtimestamp text input | 992.0 | 974.7 | +17.3 | +1.7% |
| jtimestamptz text input | 1019.8 | 1003.7 | +16.1 | +1.6% |
| jdate recv (COPY BINARY) | 78.7 | 76.6 | +2.1 | +2.6% |
| jtimestamp recv (COPY BINARY) | 116.5 | 110.3 | +6.2 | +5.3% |
| jtimestamptz recv (COPY BINARY) | 179.0 | 174.6 | +4.4 | +2.5% |
| cast timestamp -> jtimestamp | 108.5 | 104.5 | +4.0 | +3.7% |
| cast timestamptz -> jtimestamptz | 123.6 | 113.3 | +10.3 | +8.3% |
| cast date -> jtimestamp | 99.7 | 96.3 | +3.5 | +3.5% |
| cast date -> jtimestamptz | 161.5 | 152.7 | +8.8 | +5.5% |
| cast jdate -> jtimestamp (no check) | 93.3 | 95.0 | -1.7 | -1.9% |
| cast jdate -> jtimestamptz | 160.8 | 151.4 | +9.3 | +5.8% |
| cast jtimestamp -> jtimestamptz | 189.2 | 184.9 | +4.3 | +2.3% |
| cast jtimestamptz -> jtimestamp | 231.7 | 227.6 | +4.1 | +1.8% |
| cast jtimestamp -> jtimestamp(3) (scale) | 136.2 | 126.3 | +9.9 | +7.3% |
| cast jtimestamptz -> jtimestamptz(3) (scale) | 145.3 | 141.0 | +4.3 | +3.0% |
| cast date -> jdate | 91.3 | 89.9 | +1.4 | +1.5% |
| cast timestamp -> jdate | 144.1 | 141.7 | +2.4 | +1.7% |
| cast timestamptz -> jdate | 226.1 | 214.4 | +11.7 | +5.2% |
| cast jtimestamp -> jdate (no check) | 143.6 | 144.1 | -0.5 | -0.4% |
| cast jtimestamptz -> jdate (no check) | 223.2 | 220.7 | +2.5 | +1.1% |
| jtimestamp + interval (1 day 02:00) | 174.6 | 169.2 | +5.4 | +3.1% |
| jtimestamp + interval (1 month) | 279.7 | 270.6 | +9.1 | +3.2% |
| jtimestamp - interval (1 month 3 days) | 356.8 | 354.9 | +1.9 | +0.5% |
| jtimestamptz + interval (1 day 02:00) | 299.3 | 282.7 | +16.7 | +5.6% |
| jtimestamptz + interval (1 month) | 461.3 | 446.9 | +14.3 | +3.1% |
| jtimestamptz - interval (1 month 3 days) | 631.3 | 612.0 | +19.2 | +3.0% |
| jdate + interval (1 day 02:00) | 161.2 | 152.6 | +8.6 | +5.3% |
| jdate + interval (1 month) | 266.7 | 261.5 | +5.2 | +1.9% |
| jdate - interval (1 month 3 days) | 350.3 | 337.6 | +12.7 | +3.6% |
| jdate_bin (jtimestamp, 15 minutes) | 141.9 | 129.9 | +11.9 | +8.4% |
| jdate_bin (jtimestamptz, 15 minutes) | 156.9 | 144.1 | +12.8 | +8.2% |
| jtimestamp AT TIME ZONE name | 462.0 | 450.3 | +11.8 | +2.6% |
| jtimestamptz AT TIME ZONE name | 509.6 | 486.3 | +23.2 | +4.6% |
| jtimestamp AT TIME ZONE interval | 119.1 | 113.3 | +5.8 | +4.8% |
| jtimestamptz AT TIME ZONE interval | 134.7 | 126.0 | +8.7 | +6.4% |
| jgenerate_series (jtimestamp, 1 month) | 58.7 | 57.6 | +1.1 | +1.9% |
| jgenerate_series (jtimestamptz, 1 month) | 60.1 | 59.2 | +0.9 | +1.5% |
| jgenerate_series (jdate, 1 day) | 52.6 | 51.0 | +1.6 | +3.1% |
| to_jtimestamptz (epoch) | 157.6 | 140.5 | +17.1 | +10.9% |
| jdate_trunc('year', jtimestamp) | 260.3 | 255.5 | +4.8 | +1.8% |
| jdate_trunc('quarter', jtimestamp) | 262.4 | 252.3 | +10.2 | +3.9% |
| jdate_trunc('month', jtimestamp) | 267.6 | 257.1 | +10.5 | +3.9% |
| jdate_trunc('week', jtimestamp) | 374.8 | 360.9 | +13.9 | +3.7% |
| jdate_trunc('day', jtimestamp) | 215.6 | 206.5 | +9.1 | +4.2% |
| jdate_trunc('hour', jtimestamp) | 223.3 | 209.5 | +13.8 | +6.2% |
| jdate_trunc('minute', jtimestamp) | 221.2 | 216.4 | +4.8 | +2.2% |
| jdate_trunc('second', jtimestamp) | 223.2 | 211.4 | +11.9 | +5.3% |
| jdate_trunc('milliseconds', jtimestamp) | 223.0 | 226.0 | -3.0 | -1.3% |
| jdate_trunc('microseconds', jtimestamp) | 236.1 | 219.0 | +17.1 | +7.2% |
| jdate_trunc('year', jtimestamptz) | 442.4 | 428.2 | +14.2 | +3.2% |
| jdate_trunc('quarter', jtimestamptz) | 431.4 | 423.0 | +8.5 | +2.0% |
| jdate_trunc('month', jtimestamptz) | 443.1 | 428.5 | +14.6 | +3.3% |
| jdate_trunc('week', jtimestamptz) | 550.6 | 553.0 | -2.4 | -0.4% |
| jdate_trunc('day', jtimestamptz) | 327.2 | 330.4 | -3.1 | -1.0% |
| jdate_trunc('hour', jtimestamptz) | 313.9 | 297.7 | +16.1 | +5.1% |
| jdate_trunc('minute', jtimestamptz) | 305.2 | 300.2 | +5.0 | +1.6% |
| jdate_trunc('second', jtimestamptz) | 304.5 | 291.2 | +13.3 | +4.4% |
| jdate_trunc('milliseconds', jtimestamptz) | 315.9 | 302.0 | +13.9 | +4.4% |
| jdate_trunc('microseconds', jtimestamptz) | 307.8 | 300.8 | +7.0 | +2.3% |
| jdate_trunc('year', jdate) | 220.7 | 211.3 | +9.4 | +4.2% |
| jdate_trunc('quarter', jdate) | 214.5 | 214.8 | -0.3 | -0.2% |
| jdate_trunc('month', jdate) | 210.8 | 211.7 | -0.9 | -0.4% |
| jdate_trunc('week', jdate) | 181.5 | 171.1 | +10.4 | +5.7% |
| jdate_trunc('day', jdate) | 213.8 | 215.6 | -1.8 | -0.8% |
| jdate_trunc('month', jtimestamptz, zone) | 980.5 | 967.7 | +12.8 | +1.3% |

Reading it: the noise floor (the rows with no check: `jdate` text input, three casts,
and `jdate_trunc` of year, quarter, month and day on a `jdate`) is between -1.9% and
+4.2%, so a difference below about 4% on one row cannot be told from noise. The
pattern over the table is what counts: 55 of the 58 rows that do check are above 0,
and 36 of them have the checked build slower in 5 or 6 of the 6 rounds. Every check
is a few percent of its path or less, at most about 11%: the largest by percentage
are `to_jtimestamptz` (+10.9%, 17 ms), `jdate_bin` (+8.4% and +8.2%), the cast
`timestamptz -> jtimestamptz` (+8.3%), the `jtimestamp` scale cast (+7.3%) and
`jdate_trunc('microseconds', jtimestamp)` (+7.2%): the cheap paths of 100 to 160 ms
per million rows, where a fixed per-row cost shows most. The largest in absolute
terms are `jtimestamptz AT TIME ZONE name` (+23 ms), `jtimestamptz - interval (1
month 3 days)` (+19 ms), `jtimestamp` text input, `to_jtimestamptz` and
`jtimestamptz + interval (1 day 02:00)` (+17 ms each). Text input is dominated by
parsing (+1.6% to +1.7% for both new types), `recv` costs +2.5% to +5.3%. One check
is 10 to 20 ns per row, more than two compares: `jalaali_min_jdn()` and
`jalaali_max_jdn()` are out-of-line functions in `src/jalaali.c` (a cached value
behind a call through the PLT of a shared object) and each helper calls both, so each
check is two calls plus the compares; that is where to look first if the checks are
ever to be made cheaper without skipping any. Whether any path should skip its check
is a separate decision.

To replay: apply a patch that turns the seven helper bodies into `return true;` /
nothing, `dev/test-cluster.sh build`, copy `.dev/extdir/jdate.so` aside, revert the
patch, rebuild, and run the `check: ` rows against each `.so` as above.

## Run times

Local, `dev/test-cluster.sh check` with the cluster already set up and running
(PostgreSQL 18.6, `C.UTF-8` cluster, the development machine): about 61 s for all 36
tests, the dump round trip and the calendar test; the 36 `pg_regress` tests alone take
about 50 s. The slow ones: `jt_arith` 9.5 s, `jt_sweep3` 7.6 s, `fullrange` 7.1 s,
`jt_fullrange` 4.9 s, `jt_dst` 4.4 s, `jt_fields` 3.8 s, `parallel` 3.7 s,
`jt_format` 2.5 s, `jt_series` 2.1 s, `fields` 1.5 s, `jt_zone` 1.4 s, `jt_selectivity`
1.4 s, `jt_consistency` 1.7 s; every other test is 0.4 s or less (`jt_ops` 0.39 s,
`jt_crossops` 0.35 s, `jt_hash` 0.24 s, `jt_rangetypes` 0.21 s). On a cold scratch
PostgreSQL 17.11 server the whole list took about 71 s, of which `jt_arith` took 26 s.
The exhaustive `jtimestamptz` sweep takes about 70 s (about 23 s per zone and a
negative control), the perf report about 4 minutes locally (1,000,000 rows, 5 repeats,
all rows) and the range-check measurement (6 rounds x 2 builds x 15 repeats of the 66
`check:` rows) is a long run of its own.

Measured in CI on 16, 17 and 18 when the suite had 15 tests (the ranges are the spread
across the three versions in one all-green run; they will vary, and the numbers for the
36-test suite have not been read yet): `fullrange` 4.3 to 5.1 s and `fields` 1.6 to
2.0 s, which both scan the whole range, `parallel` 2.3 to 2.8 s, `format` 0.14 to
0.18 s, `hash` 0.08 to 0.54 s, `tz_casts` 0.04 to 0.06 s, every other regression test
about 0.2 s or less; the whole `pg_regress` step about 10 to 11 s, the dump round trip
about 2 s and `make test-jalaali` about 0.4 s including the compile. The `stress` step
takes about 61 s (three 20-second runs plus the verification after each) and its
self-test about 3 s; the `perf` step about 32 s with the `jdate` rows only. A whole CI
run, with the jobs in parallel and about half a minute of package installation each,
finished in under two minutes then; installation of the PostgreSQL packages has been
seen to take much longer on a slow mirror.

## What is not covered

- **An independent check of the calendar's leap-year table.** The tests prove
  self-consistency (round trips, contiguity, month and year lengths),
  agreement with core's Gregorian calendar, Nowruz within a 20-22 March window,
  and seven known Nowruz dates and five known leap/common years. The count of
  785 leap years is pinned from the implementation's own output, and no test
  compares each year's leap status with a second Persian-calendar
  implementation or with astronomical data. The break table is trusted from
  Borkowski and `jalaali-js`.
- **Finite `century`, `quarter` and `jdate_trunc('quarter')`.** Only a handful
  of values are pinned (`century` at 1403 and, against core, for infinity). The
  all-years century agreement with core was checked by a one-off query, not by
  the suite.
- **Two behaviours checked by hand only.** The non-superuser `CREATE EXTENSION`
  failure (`42501`) and the `text -> jdate` cast have no test.
- **The limits of the stress and performance runs.** The pgbench stress run is a
  60-second smoke test on one `jdate` table with one btree and one hash index (the
  timestamp types are covered by the exhaustive sweep and the regression tests, not by
  concurrent load): it does not cover crash recovery, replication or very long runs.
  The performance numbers come from shared CI runners and are noisy, and nothing fails
  on a slowdown below 50x.
- **PostgreSQL 16 and tzdata.** Nothing runs on 16 locally; its behaviour is covered by
  the CI run and by a compile check against its headers. Tests that name zones with
  history depend on the tzdata of the machine (see
  [Expected files and alternates](#expected-files-and-alternates)); the edge cases use
  fixed offsets so that they do not.
- **Other platforms.** The local harness is a bash script using Debian/PGDG
  paths (`/usr/lib/postgresql/18`, `dpkg-deb`), and CI runs on `ubuntu-24.04`
  (amd64); Windows, macOS and other architectures have not been tried.
- **Dump and upgrade variations.** The round trip covers plain, `--inserts`
  and custom formats from and to the same PostgreSQL version, not the directory
  or tar format, parallel dump, `pg_upgrade`, or a dump taken on another major
  version. The binary protocol is exercised through binary `COPY` only, not
  through `libpq` binary parameters. There is a single extension version
  (`1.0`), so no `ALTER EXTENSION ... UPDATE` path exists to test.
