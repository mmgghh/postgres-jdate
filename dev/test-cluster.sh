#!/usr/bin/env bash
# Root-free local test harness for the jdate extension.
#
# Installing a Postgres C extension normally means copying its .so and
# control/SQL files into the server's pkglibdir/sharedir, which needs
# root. This script avoids that by using PostgreSQL 18's
# extension_control_path GUC (new in PG18) together with the
# long-standing dynamic_library_path GUC to point a self-owned, initdb'd
# cluster at a directory this script fully controls. No system directory
# is ever touched.
#
# Note: this harness is PostgreSQL 18 only (it needs extension_control_path),
# while the extension itself supports PostgreSQL 16 and later.
#
# Usage:
#   dev/test-cluster.sh setup   # one-time: fetch PG18 dev headers, initdb
#   dev/test-cluster.sh start   # start the local cluster (idempotent)
#   dev/test-cluster.sh stop    # stop it
#   dev/test-cluster.sh build   # compile jdate.so against the fetched headers
#   dev/test-cluster.sh tests   # print the test list parsed from the Makefile
#   dev/test-cluster.sh test [name ...]   # start + build + run pg_regress
#   dev/test-cluster.sh check [name ...]  # setup + start + test + dumptest + jalaali test (the common case)
#   dev/test-cluster.sh dumptest # start + build + pg_dump/restore round trip
#                                # (dev/dump-roundtrip.sh); also a step of check
#   dev/test-cluster.sh jalaali  # standalone exhaustive C test of src/jalaali.c
#                                # (`make test-jalaali`); also the last step of check
#
# With no names, `test` and `check` run every entry of the Makefile's
# REGRESS line. With names, only those run (in the order given). A subset
# that does not include `io` gets the extension created up front, since
# only io.sql runs CREATE EXTENSION.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Tests write relative paths under test/results, so always run from the root.
cd "$ROOT"
DEV="$ROOT/.dev"
PGDATA="$DEV/pgdata"
EXTDIR="$DEV/extdir"
HEADERS="$DEV/pg18-headers"
PORT="${JDATE_DEV_PORT:-55439}"
PGBIN="/usr/lib/postgresql/18/bin"
# Pin the client tools to the PG18 install; find/PATH can pick another major.
PSQL="$PGBIN/psql"
PG_REGRESS="${PGBIN%/bin}/lib/pgxs/src/test/regress/pg_regress"
PG_DEV_DEB_URL="https://apt.postgresql.org/pub/repos/apt/pool/main/p/postgresql-18/postgresql-server-dev-18_18.6-1.pgdg12%2b2_amd64.deb"

# A stable, short socket directory is required: PGDATA can be an
# arbitrarily deep path, but a Unix socket path has a ~100 byte limit.
SOCKDIR="/tmp/.jdate-dev-sock"

cmd_setup() {
	mkdir -p "$DEV" "$EXTDIR/extension"

	if [ ! -d "$HEADERS/usr/include/postgresql/18/server" ]; then
		echo "Fetching PostgreSQL 18 server headers (no root needed)..."
		local deb="$DEV/postgresql-server-dev-18.deb"
		curl -sS -o "$deb" "$PG_DEV_DEB_URL"
		mkdir -p "$HEADERS"
		dpkg-deb -x "$deb" "$HEADERS"
		rm -f "$deb"
	fi

	if [ ! -f "$PGDATA/PG_VERSION" ]; then
		echo "Initializing local PostgreSQL 18 cluster in $PGDATA..."
		"$PGBIN/initdb" -D "$PGDATA" -U "$(whoami)" --auth=trust >/dev/null
	fi
}

cmd_start() {
	mkdir -p "$SOCKDIR"
	if "$PGBIN/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1; then
		return 0
	fi
	# Written into postgresql.conf rather than passed via `pg_ctl -o -c`:
	# the $system/$libdir tokens must reach Postgres literally, and a
	# config file avoids any shell-quoting hazard around that.
	if ! grep -q "^extension_control_path" "$PGDATA/postgresql.conf" 2>/dev/null; then
		{
			echo "extension_control_path = '\$system:$EXTDIR'"
			echo "dynamic_library_path = '\$libdir:$EXTDIR'"
		} >> "$PGDATA/postgresql.conf"
	fi
	# 9>&-: do not leak the harness lock fd into the long-lived postmaster,
	# or the lock would stay held after this script exits.
	"$PGBIN/pg_ctl" -D "$PGDATA" -l "$DEV/server.log" -o "-p $PORT -k $SOCKDIR" start 9>&-
}

cmd_stop() {
	"$PGBIN/pg_ctl" -D "$PGDATA" stop -m fast 2>/dev/null || true
}

cmd_build() {
	local hdr="$HEADERS/usr/include/postgresql/18/server"
	local internal="$HEADERS/usr/include/postgresql/internal"
	# Same set as the Makefile's OBJS: every src/*.c except the standalone
	# test program, so a new source file needs no edit here.
	local -a srcs=()
	local f
	for f in "$ROOT"/src/*.c; do
		if [ "$(basename "$f")" != test_jalaali.c ]; then
			srcs+=("$f")
		fi
	done
	gcc -Wall -Wextra -fPIC -shared -O2 \
		-I"$hdr" -I"$internal" -I"$ROOT/src" \
		-o "$EXTDIR/jdate.so" "${srcs[@]}"
	cp "$ROOT/jdate--1.0.sql" "$EXTDIR/extension/jdate--1.0.sql"
	sed "s/^module_pathname.*/module_pathname = 'jdate'/" \
		"$ROOT/jdate.control" > "$EXTDIR/extension/jdate.control"
}

# The test list lives in the Makefile's REGRESS line (kept on ONE line);
# this is the single source of truth.
regress_list() {
	sed -n 's/^REGRESS[[:space:]]*=[[:space:]]*//p' "$ROOT/Makefile"
}

cmd_tests() {
	regress_list
}

# Serialise harness runs: they share the cluster, the jdate_dev_test
# database, extdir and test/results. The lock is held on fd 9 until this
# script exits. Idempotent, so check and test can both call it.
LOCKED=0
take_lock() {
	[ "$LOCKED" = 1 ] && return 0
	mkdir -p "$DEV"
	exec 9>"$DEV/harness.lock"
	flock 9
	LOCKED=1
}

cmd_test() {
	take_lock
	cmd_start
	cmd_build

	local -a names
	if [ "$#" -gt 0 ]; then
		names=("$@")
	else
		# Word splitting of the one-line list is intended.
		read -r -a names <<< "$(regress_list)"
	fi
	if [ "${#names[@]}" -eq 0 ]; then
		echo "no tests: could not parse REGRESS from the Makefile" >&2
		return 1
	fi

	# Only io.sql runs CREATE EXTENSION; for a subset without it, have
	# pg_regress load the extension into the database it creates.
	local pre=()
	local n have_io=0
	for n in "${names[@]}"; do
		[ "$n" = io ] && have_io=1
	done
	[ "$have_io" = 1 ] || pre=(--load-extension=jdate)

	"$PSQL" -h "$SOCKDIR" -p "$PORT" -d postgres -v ON_ERROR_STOP=1 \
		-c "DROP DATABASE IF EXISTS jdate_dev_test;" \
		-c "CREATE DATABASE jdate_dev_test;" >/dev/null
	"$PG_REGRESS" --host="$SOCKDIR" --port="$PORT" --user="$(whoami)" \
		--dbname=jdate_dev_test "${pre[@]}" \
		--inputdir="$ROOT/test" --outputdir="$ROOT/test" \
		"${names[@]}"
}

# pg_dump/restore round trip (dev/dump-roundtrip.sh). It needs the extension
# built and installed into extdir (cmd_build) and the cluster running; it
# creates and drops its own jdate_rt_* databases and never touches
# jdate_dev_test. The connection settings are handed over as libpq variables.
run_dumptest() {
	PGBIN="$PGBIN" PGHOST="$SOCKDIR" PGPORT="$PORT" PGUSER="$(whoami)" \
		"$ROOT/dev/dump-roundtrip.sh"
}

cmd_dumptest() {
	take_lock
	cmd_start
	cmd_build
	run_dumptest
}

# Standalone exhaustive test of src/jalaali.c (no server, no PG headers). It
# builds src/test_jalaali, so it runs under the harness lock like the rest.
run_jalaali_test() {
	make -C "$ROOT" --no-print-directory PG_CONFIG="$PGBIN/pg_config" test-jalaali
}

cmd_jalaali() {
	take_lock
	run_jalaali_test
}

cmd_check() {
	take_lock
	cmd_setup
	cmd_start
	cmd_test "$@"
	run_dumptest
	run_jalaali_test
}

CMD="${1:-check}"
[ "$#" -gt 0 ] && shift
case "$CMD" in
	setup) cmd_setup ;;
	start) cmd_start ;;
	stop) cmd_stop ;;
	build) take_lock; cmd_build ;;
	tests) cmd_tests ;;
	test) cmd_test "$@" ;;
	check) cmd_check "$@" ;;
	dumptest) cmd_dumptest ;;
	jalaali) cmd_jalaali ;;
	*) echo "usage: $0 {setup|start|stop|build|tests|test [name ...]|check [name ...]|dumptest|jalaali}" >&2; exit 1 ;;
esac
