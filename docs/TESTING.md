# Testing

There are five layers: a standalone C test of the calendar code, the
`pg_regress` suite (15 test files), a `pg_dump`/restore round trip, a `pgbench`
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
| `test` | `make`, `sudo make install`, `make installcheck` (the 15 `pg_regress` tests), `dev/dump-roundtrip.sh`, `make test-jalaali` | `regress-pg16`, `regress-pg17`, `regress-pg18`: `test/results`, `test/regression.diffs`, `test/regression.out`, uploaded even on failure |
| `stress` | build and install, `dev/stress.sh`, then `dev/stress.sh --selftest` | none |
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

A new regression test cannot be written blind: its `test/expected/NAME.out` is
produced by CI. Register the test in `REGRESS` (the `Makefile`) with an empty
expected file, push, and the `test` job fails with the diff. Read the output in
`regress-pg18/test/results/NAME.out`, check by hand that every line is the
correct behaviour (not merely what the server printed), then copy it to
`test/expected/NAME.out` and push again. `tz_casts`, `sqlstate` and `parallel`
were made this way: their results were byte-identical on 16, 17 and 18, so each
has a single expected file.

`pg_regress` tries `NAME.out`, then `NAME_1.out`, and accepts whichever matches.
The only alternate is `test/expected/softerr_1.out`, for PostgreSQL 16, which has
no `COPY ... (ON_ERROR ignore)`: the `COPY` half of `softerr` reports a syntax
error there. A test needs an alternate only when the server's own output
differs between majors; prefer making the test output stable (print booleans
and counts rather than `EXPLAIN` text, set `DateStyle` and `timezone`
explicitly) over adding one.

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

Two checks are not wired into any script:

```sh
# PostgreSQL 17 compile check (needs the 17 server headers; prints nothing when clean)
gcc -fsyntax-only -Wall -Wextra -I/usr/include/postgresql/17/server \
    -I/usr/include/postgresql/internal -Isrc src/jdate.c src/jalaali.c

# the Makefile's version guard
make -n MAJORVERSION=15      # Makefile:23: *** jdate requires PostgreSQL 16 or later.  Stop.
```

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
| `io` (also runs `CREATE EXTENSION`) | valid dates, both Esfand lengths, both range edges and `infinity` (any case) round-trip as text; each malformed or out-of-range text is rejected with the right SQLSTATE (`22007` vs `22008`), including month 13, day 32, day 30 in a common year, one past each end; int32 overflow in the year, month or day is `22008`, never wrapped; leading zeros, whitespace, `+` signs are accepted | wrapped integers (`'4294968699-01-01'` once read as 1403-01-01), wrong error class, grammar drift, negative-year text |
| `casts` | `jdate` to and from `date`, `timestamp`, `timestamptz` (UTC); no implicit comparison with `date`; `to_jdate` gives the UTC day under America/New_York, Asia/Tehran, Pacific/Kiritimati and UTC for 11 epoch probes (negative, day boundaries) and for both range edges; `NaN`, `1e15`..`1e300`, `±9.3e18` are `22008`; `±Infinity` maps to infinity; `to_jdate` is `IMMUTABLE` (usable in `CREATE INDEX`) | timezone-dependent `to_jdate`, truncation instead of floor on negative epochs, double-to-int overflow, wrong volatility |
| `operators` | the six comparisons, `ORDER BY`, a btree index used for `=` and ranges (`EXPLAIN`), `GROUP BY`/`DISTINCT`, `min`/`max` return `jdate` | missing operator class, `min`/`max` resolving through the `timestamptz` cast |
| `arithmetic` | `jdate ± int`, `jdate - jdate`; a result past either edge is `22008` when computed, not when displayed; `int + jdate` equals `jdate + int`, is range-checked, keeps infinity; no shell operator in `pg_operator`, the two `+` are each other's commutator | `5 + jdate` failing as a shell operator, lazy out-of-range error |
| `fields` | every unit of `jdate_part`/`EXTRACT`; the return types pinned with `pg_typeof` (`jdate_part` is `bigint`, `EXTRACT` is `numeric`, for finite dates and for infinity) and the volatility (`IMMUTABLE`) and parallel safety of both functions in `pg_proc`; `decade` for every year `-61`..`3177` against core and `floor(year/10)`, negative years included; `dow` (Saturday-first: core's `(dow + 1) % 7`), `isodow` and `epoch` against core for boundary dates and every day of the range (also through `EXTRACT`); `epoch` exact as an integer at both range edges and on negative values; one full Saturday-to-Friday week across a month boundary and one across the year `-1`/`0` boundary, `dow` and `isodow` side by side with core's weekday name; ten units (`dow`, `isodow`, `epoch`, `year`, `month`, `day`, `quarter`, `doy`, `decade`, `century`) on `±infinity`: `jdate_part` is `NULL` for all of them, `EXTRACT` agrees with core (`±Infinity` for the units that only grow); time-of-day units (`NULL` on infinity); the per-call-site unit cache (20 units from a table column, with repeats, mixed case and switches back and forth, an invalid or over-long unit in the middle of the stream, in `jdate_part`, `EXTRACT` and `jdate_trunc`, each compared with constant-unit results); `week` rejected; `jdate_trunc`, including infinity | decade as first year (1400 for 1403), calendar-dependent `dow`/`epoch` failing on infinity, `dow` reverting to core's Sunday-first numbering or `isodow` being shifted along with it, `jdate_part` or `EXTRACT` changing type, a float rounding in `epoch`, a stale cached unit returning the previous row's field, `EXTRACT` for `date`/`timestamp` disturbed by the overload |
| `format` | `jdate_format` under Asia/Tehran and UTC (crossing midnight, with and without time); negative years print `-0061` not `-061` (years `-61`, `-10`, `-1`, `0`, `1`, `1403`, `3177`); it equals `d::text` for the first 23,000 days of the range (all the negative years and year 0) plus every 101st day of the whole range; `±infinity` in UTC and Tehran; `22008` past either edge | sign-padding in the year, infinity errors, unchecked out-of-range days |
| `range` | every path that produces a `jdate` rejects out-of-range values with `22008` and accepts both edges: `jdate ± int` (including `±2147483647`), the three casts from `date`/`timestamp`/`timestamptz` (also year 1, 9999, BC, core's own limits 4714 BC and 5874897 AD); infinity passes everywhere; the cast catalog (six casts, assignment, `jdate(date)` immutable/strict/parallel safe); a failed `INSERT` leaves the table empty and readable | the stored-but-unreadable value (one `'9999-12-31'::date` made `SELECT *` and `pg_dump -t` fail), a hole in any one path |
| `binary` | `jdate_send` equals `date_send` for six values; `COPY (FORMAT binary)` round trip; the same file reads as `date`; `jdate_recv` rejects below min, above max, 9999, year 1, core's min and max, and a bad row among good ones (`22008`, nothing loaded); both edges and both infinities are accepted | unvalidated binary receive, wire-format drift from `date` |
| `hash` | both support functions registered, `amvalidate` true; extended hash agrees with the plain hash at seed 0 (low 32 bits) and depends on the seed; `PARTITION BY HASH` with three partitions (every row lands, rows spread, pruning scans one partition, runtime pruning finds every row); a hash index is chosen and returns the right rows; Hash Join/HashAggregate give the same results as merge/nested-loop/sort | missing support function 2 (partitioning failed), wrong or inconsistent hashing, infinity in hashes |
| `fullrange` | all 1,183,020 days: text round trip and text shape, `jdate_send` = `date_send`, successive days contiguous, month and year lengths, 785 leap years, Esfand 30 only in 366-day years, Nowruz on 20-22 March of `y+621`, month starts in a fixed Gregorian window, each day's Gregorian year, `dow` (shifted to a Saturday start)/`epoch`/`doy`/`jdate_trunc` against core, text digits against `jdate_part`; three negative controls prove the checks can fail | an off-by-one or drift anywhere in the conversion, checked against *core's* Gregorian calendar rather than `jalaali.c`'s own, so an error cannot cancel itself out |
| `softerr` | `pg_input_is_valid` and `pg_input_error_info` (message and `22007`/`22008`) for good, syntax, month, day, range and overflow inputs; array input; `COPY ... (ON_ERROR ignore)` loads the good rows, skips three bad ones and emits the NOTICE; `ON_ERROR stop` still aborts. Has an alternate expected file, `softerr_1.out`, for PostgreSQL 16, which has no `ON_ERROR` | `ereport` instead of `ereturn` in `jdate_in`; hard errors that should be soft (needs 17 for the `COPY` half) |
| `tz_casts` | the `timestamptz` casts under six session zones (UTC, Asia/Tehran, America/New_York, Pacific/Kiritimati at +14, Pacific/Pago_Pago at -11, Pacific/Auckland), with instants built from local clock times so a probe means the same in every session zone: midnight probes and the Nowruz instant (the same instant is 1403-01-01 in Tehran, Kiritimati and Auckland and 1402-12-29 in UTC, New York and Pago_Pago); the assignment cast on `INSERT`; `timestamptz(jdate)` is local midnight; a 366-day round trip of 1403 and every hour of 2024 and of Tehran 2020 (no mismatch); daylight-saving days (New York 23 and 25 hours, Auckland 25 and 23, Tehran's 2020 summer time against winter); `jdate_format` with time of day; both range edges in the +14 and -11 zones, and one instant past each edge is `22008`; then `to_jdate(e, zone)` with the session set to a zone that is none of the ones asked for: UTC, `Asia/Tehran` and `America/New_York` around Nowruz 1403, the one-argument form equal to zone `'UTC'`, New York's 23- and 25-hour days, negative epochs (floor, never toward zero), a probe every half hour across 1403 in five zones against core's `AT TIME ZONE`, the session zone irrelevant, infinity and `NULL`, the range edges (the epoch and the local day are both checked), an unknown or empty zone (`22023`), and volatility and parallel safety equal to core's `timezone(text, timestamptz)` | timezone leaking into the date (an off-by-one day near midnight), a wrong day across a daylight-saving change, a range check done in UTC instead of in the session zone, `to_jdate(e, zone)` reading the session zone or ignoring a DST change |
| `sqlstate` | 30 statements, each run in a `plpgsql` block that catches the error, compared by SQLSTATE only (never message text, which changes between majors): `22023` for an unknown unit in `jdate_part`, `EXTRACT` and `jdate_trunc`; `0A000` for the recognised but unsupported units (`week`, `millennium`, `julian`, `isoyear`, the three `timezone` units, `jdate_trunc` of `week` and `hour`) and for `ALTER EXTENSION ... SET SCHEMA` into a throwaway schema; `42883` for `jdate = date`, `jdate + interval`, `jdate + bigint` and `date_part('year', jdate)`; `22008` for subtracting an infinite date; the `22007`/`22008` input errors as a sanity check; units that must succeed (`epoch`, `year`, `month`) so the codes are not just "everything fails"; finally, the extension is still in its schema | an error class changed by a refactor (`22023` becoming `0A000`), an operator added by accident, `ereport` code swapped while the message stays the same |
| `parallel` | every function and aggregate the extension owns has `proparallel = 's'` (catalog check, with a guard that it looked at the 2 aggregates and more than 20 functions), and `min(jdate)`/`max(jdate)` have `jdate_smaller`/`jdate_larger` as a `PARALLEL SAFE` `aggcombinefn`; with `parallel_setup_cost`, `parallel_tuple_cost` and the minimum scan sizes at 0 and two workers allowed, the planner puts a `Gather` under each of ten queries on 200,000 rows (a range filter, `+ int`, `jdate_part`, `jdate_trunc`, `jdate_format`, `min`/`max` plain, grouped by an expression and grouped by a column, an `ORDER BY` that must show `Gather Merge`, and a join that must show `Hash Join`), and a checksum of the result is the same with 0 workers as with 2; only booleans are printed, never `EXPLAIN` text. The plain and the column-grouped `min`/`max` must plan as a Partial Aggregate under the `Gather` and a Finalize Aggregate above it (the expression-grouped one is only checked for equal results, since the planner prefers a serial aggregate there) | a function wrongly marked parallel safe or restricted, a parallel plan giving a different answer, an aggregate no longer usable in parallel, a lost `COMBINEFUNC` |
| `extension_schema` (drops and recreates the extension, so it is last) | `extrelocatable` is false; install into schema `jdate_s`; every object is in it except `pg_catalog.extract`; `EXTRACT` works with the schema off `search_path`; `ALTER EXTENSION ... SET SCHEMA` fails with `0A000` and leaves the extension intact; `DROP EXTENSION` removes `extract` and the types; the default schema is restored | a relocatable flag that lies, objects leaking outside the schema, a dangling `pg_catalog.extract` |
| `dev/dump-roundtrip.sh` | a source database with boundary days, a negative year, `0000`, both infinities, `NULL`, a `jdate[]` column, a default and a `CHECK`, btree/hash/partial indexes, a 3-partition `PARTITION BY HASH` table and a view over `EXTRACT`/`jdate_trunc`; dumped as plain SQL, plain `--inserts` and custom + `pg_restore` into fresh databases; each restore matches the source on every value (text and binary), defaults, constraints, partition bounds, index and view definitions, type properties; `pg_dump -t` of three tables exits 0. The whole run repeats with `CREATE EXTENSION jdate SCHEMA jdate_s` | dump/restore losing or corrupting values, partition placement changing, the extension schema not surviving a restore, the original `pg_dump -t` failure |
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

Both scripts take their server from `PGBIN`, `PGHOST`, `PGPORT` and `PGUSER`,
with defaults that match the local harness cluster, but nothing runs them
locally by default; CI is the supported way.

### Performance report

`dev/perf-report.sh` with `dev/perf.sql` (CI job `perf`) times `jdate` against the
native `date` on a 1,000,000-row table (`JDATE_PERF_ROWS`): 5 repeats per
statement (`JDATE_PERF_REPS`), the median, `clock_timestamp()` inside `DO` blocks,
parallel query and JIT off. It prints a Markdown table (operation, `date` ms,
`jdate` ms, ratio), writes it to `perf-report.md` and to the job summary, and is
uploaded as the `perf-pg*` artifact. It is a report, not a benchmark suite: the
only gate is a failure when some ratio exceeds `JDATE_PERF_MAX_RATIO` (default
50), and operations with no `date` equivalent are shown in absolute time and
never gated.

Observed on the CI runners, two runs on each of 16.16, 17.12 and 18.7, as the
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

## Run times

Measured in CI on 16, 17 and 18 (the ranges are the spread across the three
versions in one all-green run; they will vary): `fullrange` 4.3 to 5.1 s and
`fields` 1.6 to 2.0 s, which both scan the whole range, `parallel` 2.3 to 2.8 s,
`format` 0.14 to 0.18 s, `hash` 0.08 to 0.54 s, `tz_casts` 0.04 to 0.06 s, every
other regression test about 0.2 s or less; the whole `pg_regress` step about 10
to 11 s, the dump round trip about 2 s and `make test-jalaali` about 0.4 s
including the compile. The `stress` step takes about 61 s (three 20-second runs
plus the verification after each) and its self-test about 3 s; the `perf` step
about 32 s. A whole CI run, with the jobs in parallel and about half a minute of
package installation each, finishes in under two minutes.

The local `dev/test-cluster.sh check` (all 15 tests, the dump round trip and the
calendar test, with the cluster already set up and running) took about 22 s on
the development machine (PostgreSQL 18.6); in it `fullrange` took about 7 s,
`parallel` 5.3 s and `fields` 1.6 s, and `tz_casts` 0.15 s.

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
- **The limits of the stress and performance runs.** The stress run is a
  60-second smoke test on one table with one btree and one hash index: it does
  not cover crash recovery, replication or very long runs. The performance numbers come from shared CI runners and
  are noisy, and nothing fails on a slowdown below 50x.
- **Other platforms.** The local harness is a bash script using Debian/PGDG
  paths (`/usr/lib/postgresql/18`, `dpkg-deb`), and CI runs on `ubuntu-24.04`
  (amd64); Windows, macOS and other architectures have not been tried.
- **Dump and upgrade variations.** The round trip covers plain, `--inserts`
  and custom formats from and to the same PostgreSQL version, not the directory
  or tar format, parallel dump, `pg_upgrade`, or a dump taken on another major
  version. The binary protocol is exercised through binary `COPY` only, not
  through `libpq` binary parameters. There is a single extension version
  (`1.0`), so no `ALTER EXTENSION ... UPDATE` path exists to test.
