#!/usr/bin/env bash
# Exhaustive jtimestamptz sweep for the CI stress job: runs
# test/sql/jt_fullrange_stress.sql (every day of the supported range, first and
# last microsecond, under UTC and Asia/Tehran, about 40 s) in a scratch
# database. Not part of `make installcheck`. Exit status: 0 passed, 1 a check
# failed, 2 setup problem.
#
# Environment (same conventions as dev/stress.sh): PGBIN PGHOST PGPORT PGUSER.

set -uo pipefail

PGBIN="${PGBIN:-/usr/lib/postgresql/18/bin}"
export PGHOST="${PGHOST:-/tmp/.jdate-dev-sock}"
export PGPORT="${PGPORT:-${JDATE_DEV_PORT:-55439}}"
export PGUSER="${PGUSER:-$(whoami)}"
unset PGDATABASE PGSERVICE PGOPTIONS

DB="jdate_fullrange"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL="$SCRIPT_DIR/../test/sql/jt_fullrange_stress.sql"

cleanup() { "$PGBIN/dropdb" --if-exists --force "$DB" >/dev/null 2>&1; }
trap cleanup EXIT

"$PGBIN/psql" -X -q -d postgres -c "SELECT 1" >/dev/null 2>&1 || {
	echo "fullrange-sweep: cannot connect to the server (PGHOST=$PGHOST PGPORT=$PGPORT)" >&2
	exit 2
}
"$PGBIN/dropdb" --if-exists --force "$DB" >/dev/null 2>&1
"$PGBIN/createdb" "$DB" || { echo "fullrange-sweep: createdb failed" >&2; exit 2; }
"$PGBIN/psql" -X -q -d "$DB" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION jdate" ||
	{ echo "fullrange-sweep: CREATE EXTENSION failed" >&2; exit 2; }

# The real sweeps (shift 0) must raise nothing; the control (shift 1) is built
# to find violations and raises only if it finds none. So the first two calls
# must pass and the control must not fail on its own account: any error fails
# the run.
if "$PGBIN/psql" -X -q -d "$DB" -v ON_ERROR_STOP=1 -f "$SQL"; then
	echo "fullrange-sweep: OK"
else
	echo "fullrange-sweep: FAIL" >&2
	exit 1
fi
