#!/usr/bin/env bash
# pg_dump / restore round trip for the jdate extension.
#
# Builds a source database that exercises everything a dump has to carry
# (boundary days, a negative year, year 0000, +/-infinity, a jdate[] column,
# a column default and a CHECK, btree and hash indexes, a PARTITION BY HASH
# table, a view that uses EXTRACT and jdate_trunc; for jtimestamp and
# jtimestamptz: edge values, infinities, a NULL, jtimestamp(0)/(3) typmod
# columns, array columns, a DEFAULT and a CHECK), dumps it in three forms
# (plain, plain with --inserts, custom + pg_restore) into fresh databases and
# compares what comes back with the source: every value as text and as its
# binary send form, in order, plus the index, default, CHECK, partition-bound
# and view definitions; timestamptz-based values are compared as text under a
# pinned TimeZone and DateStyle. `pg_dump -t <table>` must also exit 0 (the original
# symptom). The whole thing runs twice: once with the extension in the default
# schema and once with `CREATE EXTENSION jdate SCHEMA jdate_s`, where only
# EXTRACT support (pg_catalog.extract) lives outside that schema.
#
# Exit status is 0 only if every comparison and every dump/restore step
# succeeded. The temporary databases and files are removed on exit.
#
# Usually run through the harness (dev/test-cluster.sh dumptest, also the last
# step of `check`), which starts the cluster, builds the extension and exports
# the connection settings below. Standalone it needs a running cluster in which
# the extension is installed, plus these variables (defaults match the harness):
#   PGBIN   directory with psql, pg_dump, pg_restore, createdb, dropdb
#   PGHOST  socket directory or host      PGPORT  port      PGUSER  role

set -uo pipefail

PGBIN="${PGBIN:-/usr/lib/postgresql/18/bin}"
export PGHOST="${PGHOST:-/tmp/.jdate-dev-sock}"
export PGPORT="${PGPORT:-${JDATE_DEV_PORT:-55439}}"
export PGUSER="${PGUSER:-$(whoami)}"
# Never let a stray setting redirect a connection; every call names its database.
unset PGDATABASE PGSERVICE PGOPTIONS

PSQL=("$PGBIN/psql" -X -q -v ON_ERROR_STOP=1)
PREFIX="jdate_rt"
WORK="$(mktemp -d)"
FAILED=0

fail() {
	echo "dump-roundtrip: FAIL: $*" >&2
	FAILED=1
}

drop_dbs() {
	local d
	for d in $("${PSQL[@]}" -d postgres -At \
		-c "SELECT datname FROM pg_database WHERE datname LIKE '${PREFIX}\\_%' ORDER BY 1"); do
		"$PGBIN/dropdb" --if-exists --force "$d" >/dev/null 2>&1
	done
}

cleanup() {
	drop_dbs
	rm -rf "$WORK"
}
trap cleanup EXIT

# Sanity: the tools exist and the server answers.
"${PSQL[@]}" -d postgres -c "SELECT 1" >/dev/null || {
	echo "dump-roundtrip: cannot connect to the server (PGHOST=$PGHOST PGPORT=$PGPORT)" >&2
	exit 2
}

# The data and objects the round trip must preserve. $1 is the schema that
# holds the extension. The session search_path includes it so the names below
# can stay unqualified; pg_dump writes them back fully qualified.
setup_sql() {
	cat <<'SQL'
-- Boundary days, a negative year, year 0000, both infinities and 1403-01-01.
CREATE TABLE jd_rt_days (
    id int PRIMARY KEY,
    d  jdate
);
INSERT INTO jd_rt_days VALUES
    (1, '-0061-01-01'),   -- lowest supported day
    (2, '-0050-07-15'),   -- negative year
    (3, '-0001-12-29'),
    (4, '0000-01-01'),    -- year 0000
    (5, '0000-12-29'),
    (6, '1403-01-01'),
    (7, '1403-12-29'),
    (8, '1404-01-01'),
    (9, '3177-12-29'),    -- highest supported day
    (10, 'infinity'),
    (11, '-infinity'),
    (12, NULL);

-- Same values in a jdate[] column, including infinity and a NULL element.
CREATE TABLE jd_rt_arr (
    id int PRIMARY KEY,
    a  jdate[]
);
INSERT INTO jd_rt_arr VALUES
    (1, '{-0061-01-01,0000-01-01,1403-01-01,3177-12-29}'),
    (2, '{infinity,-infinity,NULL,1403-05-15}'),
    (3, '{}'),
    (4, NULL);

-- A default and a CHECK on a jdate column.
CREATE TABLE jd_rt_def (
    id int PRIMARY KEY,
    d  jdate NOT NULL DEFAULT '1403-01-01',
    CONSTRAINT jd_rt_def_after_min CHECK (d > '-0061-01-01'::jdate)
);
INSERT INTO jd_rt_def (id) VALUES (1);
INSERT INTO jd_rt_def VALUES (2, '1399-06-31'), (3, 'infinity');

-- btree and hash indexes on a jdate column.
CREATE INDEX jd_rt_days_btree ON jd_rt_days USING btree (d);
CREATE INDEX jd_rt_days_hash ON jd_rt_days USING hash (d);
CREATE INDEX jd_rt_days_desc ON jd_rt_days (d DESC NULLS LAST) WHERE d IS NOT NULL;

-- PARTITION BY HASH on a jdate column: which partition a row lands in depends
-- on jdate_hash_extended, so a restore that changed the hash would show here.
CREATE TABLE jd_rt_part (
    id int,
    d  jdate
) PARTITION BY HASH (d);
CREATE TABLE jd_rt_part_0 PARTITION OF jd_rt_part FOR VALUES WITH (MODULUS 3, REMAINDER 0);
CREATE TABLE jd_rt_part_1 PARTITION OF jd_rt_part FOR VALUES WITH (MODULUS 3, REMAINDER 1);
CREATE TABLE jd_rt_part_2 PARTITION OF jd_rt_part FOR VALUES WITH (MODULUS 3, REMAINDER 2);
CREATE INDEX jd_rt_part_idx ON jd_rt_part (d);
INSERT INTO jd_rt_part
SELECT g, jdate '1400-01-01' + g * 7 FROM generate_series(0, 59) g;
INSERT INTO jd_rt_part VALUES (100, '-0061-01-01'), (101, '3177-12-29'),
                              (102, 'infinity'), (103, '-infinity'), (104, NULL);

-- A view over EXTRACT (resolved through pg_catalog.extract(text, jdate)) and
-- jdate_trunc (an ordinary function in the extension's schema).
CREATE VIEW jd_rt_view AS
SELECT id,
       EXTRACT(year FROM d)  AS y,
       EXTRACT(month FROM d) AS m,
       EXTRACT(day FROM d)   AS dd,
       jdate_trunc('month', d) AS month_start
FROM jd_rt_days
WHERE d NOT IN ('infinity', '-infinity');

-- jtimestamp: edge values, a negative year, year 0000, a leap-year last second,
-- both infinities, epoch and a NULL. The input is Jalali text. The first and
-- last valid values are -0061-01-01 00:00:00 and 3177-12-29 23:59:59.999999.
CREATE TABLE jt_rt_ts (
    id int PRIMARY KEY,
    ts jtimestamp
);
INSERT INTO jt_rt_ts VALUES
    (1, '-0061-01-01 00:00:00'),             -- first valid value
    (2, '-0050-07-15 12:00:00'),             -- negative year
    (3, '-0001-12-29 23:59:59.999999'),
    (4, '0000-01-01 00:00:00'),              -- year 0000
    (5, '1348-10-11 00:00:00'),              -- core's epoch
    (6, '1403-01-01 00:00:00'),              -- Nowruz 1403
    (7, '1403-12-30 23:59:59.999999'),       -- last second of a leap year
    (8, '1403-05-15 12:34:56.123456'),
    (9, '3177-12-29 23:59:59.999999'),       -- last valid value
    (10, 'infinity'),
    (11, '-infinity'),
    (12, NULL);

-- jtimestamptz: the first and last valid instants (the safe range, so they
-- print in any zone), an instant in a historic-offset era, both infinities
-- and a NULL. Offsets are explicit in the input so nothing here depends on
-- the zone of the session that builds the database.
CREATE TABLE jt_rt_tz (
    id int PRIMARY KEY,
    tz jtimestamptz
);
INSERT INTO jt_rt_tz VALUES
    (1, '-0061-01-01 16:00:00+00'),          -- first valid instant
    (2, '-0050-07-15 12:00:00+03:30'),       -- negative year
    (3, '0000-01-01 00:00:00+00'),
    (4, '1348-10-11 00:00:00+00'),           -- core's epoch
    (5, '1403-01-01 00:00:00+03:30'),        -- Nowruz 1403 in Tehran
    (6, '1403-12-30 23:59:59.999999-11'),
    (7, '1403-05-15 12:34:56.123456+05:45'),
    (8, '3177-12-29 07:59:59.999999+00'),    -- last valid instant
    (9, 'infinity'),
    (10, '-infinity'),
    (11, NULL);

-- Typmod columns: the stored values were rounded to the column's precision
-- when they were inserted, and a restore must neither change nor re-round them.
CREATE TABLE jt_rt_typmod (
    id int PRIMARY KEY,
    t0 jtimestamp(0),
    t3 jtimestamp(3),
    z0 jtimestamptz(0),
    z3 jtimestamptz(3)
);
INSERT INTO jt_rt_typmod VALUES
    (1, '1403-05-15 12:34:56.789012', '1403-05-15 12:34:56.789012',
        '1403-05-15 12:34:56.789012+03:30', '1403-05-15 12:34:56.789012+03:30'),
    (2, '-0061-01-01 00:00:00.5', '-0061-01-01 00:00:00.0005',
        '-0061-01-01 16:00:00.5+00', '-0061-01-01 16:00:00.0005+00'),
    (3, '3177-12-29 23:59:59.499999', '3177-12-29 23:59:59.998999',
        '3177-12-29 07:59:59.499999+00', '3177-12-29 07:59:59.998999+00'),
    (4, 'infinity', '-infinity', 'infinity', '-infinity'),
    (5, NULL, NULL, NULL, NULL);

-- Array columns, with an infinity, a NULL element, an empty and a NULL array.
CREATE TABLE jt_rt_arr (
    id int PRIMARY KEY,
    a  jtimestamp[],
    z  jtimestamptz[]
);
INSERT INTO jt_rt_arr VALUES
    (1, '{"-0061-01-01 00:00:00","0000-01-01 00:00:00","1403-01-01 00:00:00","3177-12-29 23:59:59.999999"}',
        '{"-0061-01-01 16:00:00+00","0000-01-01 00:00:00+00","1403-01-01 00:00:00+03:30","3177-12-29 07:59:59.999999+00"}'),
    (2, '{infinity,-infinity,NULL,"1403-05-15 12:34:56.5"}',
        '{infinity,-infinity,NULL,"1403-05-15 12:34:56.5+03:30"}'),
    (3, '{}', '{}'),
    (4, NULL, NULL);

-- A DEFAULT and a CHECK on a jtimestamp and a jtimestamptz column. There are
-- no jtimestamp operators yet, so the CHECKs compare through the binary casts
-- to core's timestamp / timestamptz.
CREATE TABLE jt_rt_def (
    id int PRIMARY KEY,
    ts jtimestamp NOT NULL DEFAULT '1403-01-01 00:00:00',
    tz jtimestamptz NOT NULL DEFAULT '1403-01-01 00:00:00+03:30',
    CONSTRAINT jt_rt_def_ts_after CHECK (ts::timestamp > '1800-01-01 00:00:00'::timestamp),
    CONSTRAINT jt_rt_def_tz_after CHECK (tz::timestamptz > '1800-01-01 00:00:00+00'::timestamptz)
);
INSERT INTO jt_rt_def (id) VALUES (1);
INSERT INTO jt_rt_def VALUES
    (2, '1399-06-31 08:00:00', '1399-06-31 08:00:00-05'),
    (3, 'infinity', 'infinity');
SQL
}

# What is compared. Printed from one session with search_path = pg_catalog, so
# every name in a definition comes out schema-qualified and nothing depends on
# the connecting session. :schema is the extension's schema (psql variable).
# Each query is ordered, so the output is deterministic and diff-able.
snapshot_sql() {
	cat <<'SQL'
SET search_path = pg_catalog;
-- Pinned so the text of a jtimestamptz (a numeric offset in the session zone)
-- does not depend on the connecting session.
SET TimeZone = 'Asia/Tehran';
SET DateStyle = 'ISO, YMD';
\qecho == extension
SELECT extname, extversion, extnamespace::regnamespace, extrelocatable
FROM pg_extension WHERE extname = 'jdate';

\qecho == days
SELECT id, d::text, encode(:schema.jdate_send(d), 'hex') AS send
FROM public.jd_rt_days ORDER BY id;

\qecho == arrays
SELECT id, a::text,
       (SELECT string_agg(coalesce(encode(:schema.jdate_send(x), 'hex'), 'NULL'), ',' ORDER BY o)
        FROM unnest(a) WITH ORDINALITY u(x, o)) AS sends
FROM public.jd_rt_arr ORDER BY id;

\qecho == defaults and checks
SELECT id, d::text, encode(:schema.jdate_send(d), 'hex') AS send
FROM public.jd_rt_def ORDER BY id;
SELECT a.attname, pg_get_expr(ad.adbin, ad.adrelid) AS default_expr
FROM pg_attrdef ad JOIN pg_attribute a ON a.attrelid = ad.adrelid AND a.attnum = ad.adnum
WHERE ad.adrelid = 'public.jd_rt_def'::regclass ORDER BY a.attname;
SELECT conname, contype, pg_get_constraintdef(oid) FROM pg_constraint
WHERE conrelid = 'public.jd_rt_def'::regclass ORDER BY conname;

\qecho == partitions
SELECT tableoid::regclass::text AS part, id, d::text, encode(:schema.jdate_send(d), 'hex') AS send
FROM public.jd_rt_part ORDER BY part, id;
SELECT c.relname, pg_get_expr(c.relpartbound, c.oid) AS bound
FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
WHERE i.inhparent = 'public.jd_rt_part'::regclass ORDER BY c.relname;
SELECT pg_get_partkeydef('public.jd_rt_part'::regclass);

\qecho == indexes
SELECT indexrelid::regclass::text AS idx, pg_get_indexdef(indexrelid)
FROM pg_index
WHERE indrelid IN (SELECT oid FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relname LIKE 'jd\_rt\_%')
ORDER BY 1;

\qecho == view
SELECT pg_get_viewdef('public.jd_rt_view'::regclass);
SELECT id, y, m, dd, month_start::text, encode(:schema.jdate_send(month_start), 'hex') AS send
FROM public.jd_rt_view ORDER BY id;

\qecho == jtimestamp
SELECT id, ts::text, encode(:schema.jtimestamp_send(ts), 'hex') AS send
FROM public.jt_rt_ts ORDER BY id;

\qecho == jtimestamptz
SELECT id, tz::text, encode(:schema.jtimestamptz_send(tz), 'hex') AS send
FROM public.jt_rt_tz ORDER BY id;

\qecho == typmod columns
SELECT a.attname, format_type(a.atttypid, a.atttypmod)
FROM pg_attribute a
WHERE a.attrelid = 'public.jt_rt_typmod'::regclass AND a.attnum > 0 AND NOT a.attisdropped
ORDER BY a.attnum;
SELECT id,
       t0::text, encode(:schema.jtimestamp_send(t0), 'hex') AS t0_send,
       t3::text, encode(:schema.jtimestamp_send(t3), 'hex') AS t3_send,
       z0::text, encode(:schema.jtimestamptz_send(z0), 'hex') AS z0_send,
       z3::text, encode(:schema.jtimestamptz_send(z3), 'hex') AS z3_send
FROM public.jt_rt_typmod ORDER BY id;

\qecho == jtimestamp and jtimestamptz arrays
SELECT id, a::text,
       (SELECT string_agg(coalesce(encode(:schema.jtimestamp_send(x), 'hex'), 'NULL'), ',' ORDER BY o)
        FROM unnest(a) WITH ORDINALITY u(x, o)) AS sends,
       z::text,
       (SELECT string_agg(coalesce(encode(:schema.jtimestamptz_send(x), 'hex'), 'NULL'), ',' ORDER BY o)
        FROM unnest(z) WITH ORDINALITY u(x, o)) AS z_sends
FROM public.jt_rt_arr ORDER BY id;

\qecho == jtimestamp and jtimestamptz defaults and checks
SELECT id, ts::text, encode(:schema.jtimestamp_send(ts), 'hex') AS ts_send,
       tz::text, encode(:schema.jtimestamptz_send(tz), 'hex') AS tz_send
FROM public.jt_rt_def ORDER BY id;
SELECT a.attname, pg_get_expr(ad.adbin, ad.adrelid) AS default_expr
FROM pg_attrdef ad JOIN pg_attribute a ON a.attrelid = ad.adrelid AND a.attnum = ad.adnum
WHERE ad.adrelid = 'public.jt_rt_def'::regclass ORDER BY a.attname;
SELECT conname, contype, pg_get_constraintdef(oid) FROM pg_constraint
WHERE conrelid = 'public.jt_rt_def'::regclass ORDER BY conname;

\qecho == types
SELECT t.typname, t.typlen, t.typbyval, t.typalign, t.typstorage, t.typcategory, t.typnamespace::regnamespace,
       t.typmodin::regproc, t.typmodout::regproc
FROM pg_type t
WHERE t.typname IN ('jdate', '_jdate', 'jtimestamp', '_jtimestamp', 'jtimestamptz', '_jtimestamptz')
ORDER BY 1;
SQL
}

# run_pass LABEL SCHEMA: one full round trip with the extension in SCHEMA.
run_pass() {
	local label="$1" schema="$2"
	local src="${PREFIX}_${label}_src"
	local dir="$WORK/$label"
	mkdir -p "$dir"
	echo "dump-roundtrip [$label]: extension schema '$schema'"

	"$PGBIN/createdb" --template=template0 "$src" || { fail "$label: createdb $src"; return; }
	{
		if [ "$schema" != public ]; then
			echo "CREATE SCHEMA $schema;"
		fi
		echo "CREATE EXTENSION jdate SCHEMA $schema;"
		echo "SET search_path = public, $schema;"
		setup_sql
	} | "${PSQL[@]}" -d "$src" || { fail "$label: building the source database"; return; }

	snapshot() { # DB OUTFILE
		snapshot_sql | "${PSQL[@]}" -A -t -d "$1" -v schema="$schema" -o "$2"
	}
	snapshot "$src" "$dir/source.txt" || { fail "$label: snapshot of the source"; return; }
	# A snapshot with no rows would make every comparison pass vacuously.
	if [ "$(wc -l < "$dir/source.txt")" -lt 60 ]; then
		fail "$label: source snapshot is suspiciously short"
		return
	fi

	# The original symptom: dumping a single jdate table must work.
	local t
	for t in jd_rt_days jd_rt_arr jd_rt_part jt_rt_ts jt_rt_tz jt_rt_typmod jt_rt_arr jt_rt_def; do
		"$PGBIN/pg_dump" -d "$src" -t "$t" -f /dev/null \
			|| fail "$label: pg_dump -t $t exited non-zero"
	done

	# Three dump forms. Each is restored into its own fresh database.
	"$PGBIN/pg_dump" -d "$src" -f "$dir/plain.sql" || { fail "$label: pg_dump plain"; return; }
	"$PGBIN/pg_dump" -d "$src" --inserts -f "$dir/inserts.sql" || { fail "$label: pg_dump --inserts"; return; }
	"$PGBIN/pg_dump" -d "$src" -Fc -f "$dir/custom.dump" || { fail "$label: pg_dump -Fc"; return; }

	local form dst
	for form in plain inserts custom; do
		dst="${PREFIX}_${label}_${form}"
		"$PGBIN/createdb" --template=template0 "$dst" || { fail "$label/$form: createdb"; continue; }
		if [ "$form" = custom ]; then
			"$PGBIN/pg_restore" --exit-on-error -d "$dst" "$dir/custom.dump" \
				|| { fail "$label/$form: pg_restore"; continue; }
		else
			"${PSQL[@]}" -d "$dst" -f "$dir/$form.sql" >/dev/null \
				|| { fail "$label/$form: restoring $form.sql"; continue; }
		fi
		snapshot "$dst" "$dir/$form.txt" || { fail "$label/$form: snapshot"; continue; }
		if diff -u "$dir/source.txt" "$dir/$form.txt" >"$dir/$form.diff"; then
			echo "dump-roundtrip [$label]: $form restore matches the source"
		else
			fail "$label/$form: restored data differs from the source (diff follows)"
			head -n 40 "$dir/$form.diff" >&2
		fi
	done
}

drop_dbs
run_pass default public
run_pass schema jdate_s

if [ "$FAILED" -ne 0 ]; then
	echo "dump-roundtrip: FAILED" >&2
	exit 1
fi
echo "dump-roundtrip: OK"
