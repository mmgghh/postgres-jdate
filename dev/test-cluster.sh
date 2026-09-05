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
# Usage:
#   dev/test-cluster.sh setup   # one-time: fetch PG18 dev headers, initdb
#   dev/test-cluster.sh start   # start the local cluster (idempotent)
#   dev/test-cluster.sh stop    # stop it
#   dev/test-cluster.sh build   # compile jdate.so against the fetched headers
#   dev/test-cluster.sh test    # build + run the pg_regress suite
#   dev/test-cluster.sh check   # setup + start + test (the common case)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV="$ROOT/.dev"
PGDATA="$DEV/pgdata"
EXTDIR="$DEV/extdir"
HEADERS="$DEV/pg18-headers"
PORT="${JDATE_DEV_PORT:-55439}"
PGBIN="/usr/lib/postgresql/18/bin"
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
	"$PGBIN/pg_ctl" -D "$PGDATA" -l "$DEV/server.log" -o "-p $PORT -k $SOCKDIR" start
}

cmd_stop() {
	"$PGBIN/pg_ctl" -D "$PGDATA" stop -m fast 2>/dev/null || true
}

cmd_build() {
	local hdr="$HEADERS/usr/include/postgresql/18/server"
	local internal="$HEADERS/usr/include/postgresql/internal"
	gcc -Wall -Wextra -fPIC -shared -O2 \
		-I"$hdr" -I"$internal" -I"$ROOT/src" \
		-o "$EXTDIR/jdate.so" "$ROOT/src/jalaali.c" "$ROOT/src/jdate.c"
	cp "$ROOT/jdate--1.0.sql" "$EXTDIR/extension/jdate--1.0.sql"
	sed "s/^module_pathname.*/module_pathname = 'jdate'/" \
		"$ROOT/jdate.control" > "$EXTDIR/extension/jdate.control"
}

cmd_test() {
	cmd_build
	local pg_regress
	pg_regress="$(find /usr/lib/postgresql -name pg_regress -print -quit)"
	psql -h "$SOCKDIR" -p "$PORT" -d postgres \
		-c "DROP DATABASE IF EXISTS jdate_dev_test;" \
		-c "CREATE DATABASE jdate_dev_test;" >/dev/null
	"$pg_regress" --host="$SOCKDIR" --port="$PORT" --user="$(whoami)" \
		--dbname=jdate_dev_test \
		--inputdir="$ROOT/test" --outputdir="$ROOT/test" \
		io casts operators arithmetic fields format
}

cmd_check() {
	cmd_setup
	cmd_start
	cmd_test
}

case "${1:-check}" in
	setup) cmd_setup ;;
	start) cmd_start ;;
	stop) cmd_stop ;;
	build) cmd_build ;;
	test) cmd_test ;;
	check) cmd_check ;;
	*) echo "usage: $0 {setup|start|stop|build|test|check}" >&2; exit 1 ;;
esac
