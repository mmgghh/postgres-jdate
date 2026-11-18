#!/usr/bin/env bash
# Concurrency stress test for the jdate extension, driven by pgbench.
#
# Creates a scratch database, `CREATE EXTENSION jdate`, a table
# jd_stress(id bigserial, d jdate, owner int) with a btree and a hash index on
# d, and a per-client ledger table jd_ledger(owner, n). 16 clients then run the
# scripts in dev/pgbench/ at once: stress-write.sql (insert / update / delete
# of the client's own rows, ledger updated in the same transaction),
# stress-read.sql (range scans, GROUP BY, min/max, jdate_part / jdate_trunc /
# jdate_format under a per-client TimeZone) and stress-mixed.sql (a write and
# reads, one run in twenty with a forced parallel plan). The run is repeated
# under pgbench -M simple, -M extended and -M prepared.
#
# After each run the script verifies, and exits non-zero with a message on the
# first failure:
#   - pgbench exited 0 and printed no ERROR / FATAL / aborted-client line
#     and processed at least one transaction;
#   - count(*) of jd_stress equals the sum of the ledger, and per owner;
#   - every d lies inside the supported range -0061-01-01 .. 3177-12-29;
#   - amcheck bt_index_check(index, true) passes on the btree;
#   - index scans and a sequential scan return the same rows for sampled
#     ranges (btree) and sampled values (hash index), with the EXPLAIN plan
#     checked to really use the index under test.
#
#   dev/stress.sh             run and verify
#   dev/stress.sh --selftest  run briefly, corrupt the ledger on purpose and
#                             check the verifier notices. Exits 3 when it did
#                             (the expected outcome, the verifier can fail),
#                             0 if the corruption went unnoticed, anything
#                             else for a setup problem.
#
# Environment (same conventions as dev/dump-roundtrip.sh):
#   PGBIN                  directory with psql, pgbench, createdb, dropdb
#   PGHOST PGPORT PGUSER   connection settings
#   JDATE_STRESS_SECONDS   seconds per pgbench run (default 20)

set -uo pipefail

PGBIN="${PGBIN:-/usr/lib/postgresql/18/bin}"
export PGHOST="${PGHOST:-/tmp/.jdate-dev-sock}"
export PGPORT="${PGPORT:-${JDATE_DEV_PORT:-55439}}"
export PGUSER="${PGUSER:-$(whoami)}"
unset PGDATABASE PGSERVICE PGOPTIONS

SECONDS_PER_RUN="${JDATE_STRESS_SECONDS:-20}"
CLIENTS=16
THREADS=4
DB="jdate_stress"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$SCRIPT_DIR/pgbench"
PGBENCH="$PGBIN/pgbench"
[ -x "$PGBENCH" ] || PGBENCH="$(command -v pgbench || true)"
WORK="$(mktemp -d)"
SELFTEST=0
[ "${1:-}" = "--selftest" ] && SELFTEST=1

PSQL=("$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -d "$DB")

cleanup() {
	"$PGBIN/dropdb" --if-exists --force "$DB" >/dev/null 2>&1
	rm -rf "$WORK"
}
trap cleanup EXIT

die() {
	echo "stress: FAIL: $*" >&2
	exit 1
}

[ -n "$PGBENCH" ] && [ -x "$PGBENCH" ] || { echo "stress: pgbench not found" >&2; exit 2; }
"$PGBIN/psql" -X -q -d postgres -c "SELECT 1" >/dev/null 2>&1 || {
	echo "stress: cannot connect to the server (PGHOST=$PGHOST PGPORT=$PGPORT)" >&2
	exit 2
}

"$PGBIN/dropdb" --if-exists --force "$DB" >/dev/null 2>&1
"$PGBIN/createdb" "$DB" || { echo "stress: createdb failed" >&2; exit 2; }
"${PSQL[@]}" <<'SQL' || { echo "stress: setup failed" >&2; exit 2; }
CREATE EXTENSION jdate;
CREATE EXTENSION amcheck;
CREATE TABLE jd_stress (id bigserial PRIMARY KEY, d jdate NOT NULL, owner int NOT NULL);
CREATE INDEX jd_stress_btree ON jd_stress USING btree (d);
CREATE INDEX jd_stress_hash ON jd_stress USING hash (d);
CREATE TABLE jd_ledger (owner int PRIMARY KEY, n bigint NOT NULL);
INSERT INTO jd_ledger SELECT g, 0 FROM generate_series(0, 63) g;
SQL

# pgbench 17 and later can stop the whole run at the first aborted client
# (--exit-on-abort). Without it a client that dies on an error is only counted
# and the others keep going for the full -T seconds, so a script error would be
# noticed late. pgbench 16 has no such option; the output check below still
# catches the aborted clients there, after the run.
PGBENCH_ABORT=()
if "$PGBENCH" --help 2>&1 | grep -q -- '--exit-on-abort'; then
	PGBENCH_ABORT=(--exit-on-abort)
fi

# Run pgbench in one protocol mode: $1 = simple|extended|prepared, $2 = seconds.
# Under -M extended and -M prepared every :variable reaches the server as an
# untyped parameter ($1), so the scripts in dev/pgbench cast the ones that sit
# next to a jdate operator: jdate + $1 alone is ambiguous (42725).
run_pgbench() {
	local mode="$1" secs="$2" out="$WORK/pgbench-$1.log" rc
	"$PGBENCH" -n -c "$CLIENTS" -j "$THREADS" -T "$secs" -M "$mode" "${PGBENCH_ABORT[@]}" \
		-f "$SCRIPTS/stress-write.sql@4" \
		-f "$SCRIPTS/stress-read.sql@4" \
		-f "$SCRIPTS/stress-mixed.sql@2" \
		"$DB" >"$out" 2>&1
	rc=$?
	grep -E 'number of transactions actually processed|number of failed transactions|latency average|tps' "$out" |
		sed "s/^/stress: [$mode] /"
	[ "$rc" -eq 0 ] || { cat "$out" >&2; die "pgbench -M $mode exited $rc"; }
	if grep -Eq 'ERROR|FATAL|aborted' "$out"; then
		grep -E 'ERROR|FATAL|aborted' "$out" | head -20 >&2
		die "pgbench -M $mode reported errors"
	fi
	local n
	n="$(sed -n 's/^number of transactions actually processed: *//p' "$out")"
	[ "${n:-0}" -gt 0 ] || die "pgbench -M $mode processed no transactions"
}

# Verify the table after a run. Prints findings and returns non-zero on failure.
verify() {
	local label="$1" rows ledger bad
	rows="$("${PSQL[@]}" -At -c "SELECT count(*) FROM jd_stress")" || return 1
	ledger="$("${PSQL[@]}" -At -c "SELECT coalesce(sum(n), 0) FROM jd_ledger")" || return 1
	echo "stress: [$label] rows=$rows ledger=$ledger"
	if [ "$rows" != "$ledger" ]; then
		echo "stress: FAIL: [$label] row count $rows differs from ledger $ledger" >&2
		return 1
	fi
	bad="$("${PSQL[@]}" -At -c "
		SELECT l.owner || ':' || l.n || '<>' || coalesce(s.c, 0)
		  FROM jd_ledger l
		  LEFT JOIN (SELECT owner, count(*) AS c FROM jd_stress GROUP BY owner) s USING (owner)
		 WHERE l.n <> coalesce(s.c, 0)
		UNION ALL
		SELECT 'orphan owner ' || s.owner FROM jd_stress s
		 WHERE NOT EXISTS (SELECT 1 FROM jd_ledger l WHERE l.owner = s.owner) LIMIT 5")" || return 1
	if [ -n "$bad" ]; then
		echo "stress: FAIL: [$label] per-owner ledger mismatch (owner:ledger<>rows): $bad" >&2
		return 1
	fi
	echo "stress: [$label] ledger check ok"
	bad="$("${PSQL[@]}" -At -c "
		SELECT count(*) FROM jd_stress
		 WHERE d IS NULL OR d NOT BETWEEN '-0061-01-01'::jdate AND '3177-12-29'::jdate")" || return 1
	if [ "$bad" != "0" ]; then
		echo "stress: FAIL: [$label] $bad rows outside the Jalali range" >&2
		return 1
	fi
	echo "stress: [$label] range check ok"
	"${PSQL[@]}" -c "SELECT bt_index_check('jd_stress_btree'::regclass, true)" >/dev/null || {
		echo "stress: FAIL: [$label] amcheck bt_index_check failed" >&2
		return 1
	}
	echo "stress: [$label] amcheck bt_index_check(heapallindexed) ok"
	"${PSQL[@]}" -c "ANALYZE jd_stress" || return 1
	verify_index "$label" btree jd_stress_hash || return 1
	verify_index "$label" hash jd_stress_btree || return 1
}

# Compare an index scan with a sequential scan. $2 = index kind under test, $3
# = the other index, dropped inside a rolled-back transaction so the planner
# can only use the one under test. Nothing else is running at this point.
verify_index() {
	local label="$1" kind="$2" other="$3" idx
	idx="jd_stress_$kind"
	"${PSQL[@]}" <<SQL || { echo "stress: FAIL: [$label] $kind index disagrees with a sequential scan" >&2; return 1; }
BEGIN;
DROP INDEX $other;
DO \$\$
DECLARE
    r record;
    plan text;
    seq_res text;
    idx_res text;
    q text;
    n int := 0;
BEGIN
    FOR r IN SELECT d AS a,
                    '-0061-01-01'::jdate + least((d - '-0061-01-01'::jdate) + (id % 3000)::int, 1183019) AS b
               FROM (SELECT d, id FROM jd_stress ORDER BY id
                      LIMIT 200 OFFSET (SELECT count(*) / 400 FROM jd_stress)) s
    LOOP
        IF '$kind' = 'hash' THEN
            q := format('SELECT count(*) || '':'' || coalesce(sum(id), 0) FROM jd_stress WHERE d = %L::jdate', r.a);
        ELSE
            q := format('SELECT count(*) || '':'' || coalesce(sum(id), 0) FROM jd_stress WHERE d BETWEEN %L::jdate AND %L::jdate', r.a, r.b);
        END IF;
        PERFORM set_config('enable_indexscan', 'off', true);
        PERFORM set_config('enable_bitmapscan', 'off', true);
        PERFORM set_config('enable_indexonlyscan', 'off', true);
        PERFORM set_config('enable_seqscan', 'on', true);
        EXECUTE q INTO seq_res;
        PERFORM set_config('enable_indexscan', 'on', true);
        PERFORM set_config('enable_bitmapscan', 'on', true);
        PERFORM set_config('enable_indexonlyscan', 'on', true);
        PERFORM set_config('enable_seqscan', 'off', true);
        IF n = 0 THEN
            FOR plan IN EXECUTE 'EXPLAIN (COSTS OFF) ' || q LOOP
                IF plan LIKE '%$idx%' THEN idx_res := 'used'; END IF;
            END LOOP;
            IF idx_res IS DISTINCT FROM 'used' THEN
                RAISE EXCEPTION 'plan does not use $idx';
            END IF;
        END IF;
        EXECUTE q INTO idx_res;
        IF seq_res <> idx_res THEN
            RAISE EXCEPTION '$kind index vs seq scan differ for %: seq=% index=%', q, seq_res, idx_res;
        END IF;
        n := n + 1;
    END LOOP;
    IF n < 20 THEN RAISE EXCEPTION 'only % sampled probes', n; END IF;
    RAISE NOTICE 'stress: $kind index agrees with seq scan on % probes', n;
END \$\$;
ROLLBACK;
SQL
	echo "stress: [$label] $kind index vs seq scan ok"
}

if [ "$SELFTEST" -eq 1 ]; then
	run_pgbench simple 3
	verify selftest-baseline || { echo "stress: selftest: baseline verification failed before corruption" >&2; exit 2; }
	"${PSQL[@]}" -c "UPDATE jd_ledger SET n = n + 1 WHERE owner = 0" || exit 2
	if verify selftest-corrupted 2>"$WORK/selftest.err"; then
		echo "stress: selftest: FAIL: corrupted ledger was NOT detected" >&2
		exit 0
	fi
	cat "$WORK/selftest.err" >&2
	echo "stress: selftest: ledger corruption detected, the verifier can fail (exit 3 is the expected outcome)" >&2
	exit 3
fi

for mode in simple extended prepared; do
	run_pgbench "$mode" "$SECONDS_PER_RUN"
	verify "$mode" || exit 1
done
echo "stress: OK"
