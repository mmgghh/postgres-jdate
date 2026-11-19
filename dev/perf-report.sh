#!/usr/bin/env bash
# Performance report: jdate, jtimestamp and jtimestamptz against the core types
# on a 1,000,000-row table.
#
# Builds a scratch database with matching core and Jalali columns, times a set
# of operations with dev/perf.sql (5 repeats, median, clock_timestamp() inside
# a function) and prints a Markdown table: operation, core ms, j ms, ratio. The
# table goes to stdout, to perf-report.md in the current directory and, when
# set, to $GITHUB_STEP_SUMMARY.
#
# Report only, apart from one gate: the script exits non-zero if some ratio
# exceeds JDATE_PERF_MAX_RATIO (default 50). Operations with no core
# equivalent (among them every "check: ..." row, the range-check paths) show
# their absolute j time and are never gated. Not part of `make installcheck`.
#
# To measure what the range checks cost, run the "check: " rows against two
# builds of the same sources, the normal one and one whose check helpers in
# src/jdate_common.h do nothing (a throwaway patch, never committed), and
# compare:
#   JDATE_PERF_ONLY='^check: ' JDATE_PERF_REPS=15 dev/perf-report.sh
#
# The "recv" rows run a binary COPY from a file the server writes itself, in a
# temporary directory this script makes world-writable: the server must run on
# the same machine as the script (it does under CI and dev/test-cluster.sh).
#
# Environment (same conventions as dev/dump-roundtrip.sh):
#   PGBIN PGHOST PGPORT PGUSER   server tools and connection settings
#   JDATE_PERF_MAX_RATIO         failure threshold, default 50
#   JDATE_PERF_ROWS              table size, default 1000000
#   JDATE_PERF_REPS              repeats per statement, default 5
#   JDATE_PERF_ONLY              regular expression on the row name: only the
#                                matching rows run (default: all)

set -uo pipefail

PGBIN="${PGBIN:-/usr/lib/postgresql/18/bin}"
export PGHOST="${PGHOST:-/tmp/.jdate-dev-sock}"
export PGPORT="${PGPORT:-${JDATE_DEV_PORT:-55439}}"
export PGUSER="${PGUSER:-$(whoami)}"
unset PGDATABASE PGSERVICE PGOPTIONS

MAX_RATIO="${JDATE_PERF_MAX_RATIO:-50}"
ROWS="${JDATE_PERF_ROWS:-1000000}"
REPS="${JDATE_PERF_REPS:-5}"
ONLY="${JDATE_PERF_ONLY:-}"
DB="jdate_perf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
chmod 777 "$WORK"	# the server may run as another user and writes the COPY files here
REPORT="perf-report.md"

cleanup() {
	"$PGBIN/dropdb" --if-exists --force "$DB" >/dev/null 2>&1
	rm -rf "$WORK"
}
trap cleanup EXIT

"$PGBIN/psql" -X -q -d postgres -c "SELECT 1" >/dev/null 2>&1 || {
	echo "perf-report: cannot connect to the server (PGHOST=$PGHOST PGPORT=$PGPORT)" >&2
	exit 2
}
"$PGBIN/dropdb" --if-exists --force "$DB" >/dev/null 2>&1
"$PGBIN/createdb" "$DB" || { echo "perf-report: createdb failed" >&2; exit 2; }
"$PGBIN/psql" -X -q -d "$DB" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION jdate" || exit 2

VERSION="$("$PGBIN/psql" -X -At -d "$DB" -c "SHOW server_version")"
"$PGBIN/psql" -X -q -d "$DB" -v ON_ERROR_STOP=1 -v rows="$ROWS" -v reps="$REPS" \
	-v only="$ONLY" -v bindir="$WORK" -f "$SCRIPT_DIR/perf.sql" >"$WORK/rows.txt" || {
	echo "perf-report: perf.sql failed" >&2
	exit 1
}

{
	echo "### jdate, jtimestamp and jtimestamptz vs core performance (PostgreSQL $VERSION, $ROWS rows, median of $REPS)"
	echo
	echo "| operation | core ms | j ms | ratio |"
	echo "| --- | ---: | ---: | ---: |"
	awk -F'|' '{
		d = ($2 == "") ? "n/a" : $2
		r = ($4 == "") ? "n/a" : $4 "x"
		printf "| %s | %s | %s | %s |\n", $1, d, $3, r
	}' "$WORK/rows.txt"
	echo
	echo "Gate: fail if a ratio exceeds ${MAX_RATIO}x. Operations without a core equivalent are not gated."
} >"$REPORT"

cat "$REPORT"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$REPORT" >>"$GITHUB_STEP_SUMMARY"

nrows="$(wc -l <"$WORK/rows.txt")"
[ "$nrows" -ge 10 ] || { [ -n "$ONLY" ] && [ "$nrows" -ge 1 ]; } || { echo "perf-report: FAIL: only $nrows result rows" >&2; exit 1; }

over="$(awk -F'|' -v max="$MAX_RATIO" '$4 != "" && $4 + 0 > max + 0 { printf "%s (%sx) ", $1, $4 }' "$WORK/rows.txt")"
if [ -n "$over" ]; then
	echo "perf-report: FAIL: ratio above ${MAX_RATIO}x: $over" >&2
	exit 1
fi
