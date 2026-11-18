MODULE_big = jdate
# Every src/*.c except the standalone test program, so a new source file needs
# no edit here. dev/test-cluster.sh (cmd_build) compiles the same set.
OBJS = $(patsubst %.c,%.o,$(filter-out src/test_jalaali.c,$(wildcard src/*.c)))
EXTENSION = jdate
DATA = jdate--1.0.sql
DOCS = README.md
# Keep REGRESS on ONE line: dev/test-cluster.sh parses it.
REGRESS = io casts operators arithmetic fields format range binary hash fullrange softerr tz_casts sqlstate parallel jt_io jt_casts jt_bounds jt_softerr jt_binary jt_fullrange jt_ops jt_hash jt_crossops jt_arith jt_dst extension_schema
REGRESS_OPTS = --inputdir=test --outputdir=test
# Binary built by `make test-jalaali` (rule below). Set before the PGXS include:
# pgxs.mk tests `ifdef EXTRA_CLEAN` while it is being read.
JALAALI_TEST = src/test_jalaali
EXTRA_CLEAN = $(JALAALI_TEST)

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Supported servers: PostgreSQL 16 or later. varatt.h was split out of
# postgres.h in PG16, and the soft-error API used by jdate_in (nodes/miscnodes.h,
# ereturn) is new in PG16. Placed after the PGXS include because MAJORVERSION
# comes from it. Check the guard with: make -n MAJORVERSION=15
ifneq ($(filter 12 13 14 15,$(MAJORVERSION)),)
$(error jdate requires PostgreSQL 16 or later)
endif

# Standalone exhaustive test of src/jalaali.c. It needs no server and no
# PostgreSQL headers, so it uses the plain C compiler, and it relies on
# assert(), so it must not be built with NDEBUG. Placed after the PGXS include
# so it does not become the default goal.
.PHONY: test-jalaali
test-jalaali: src/jalaali.c src/jalaali.h src/test_jalaali.c
	$(CC) -std=c99 -Wall -Wextra -O2 -Isrc -o $(JALAALI_TEST) src/jalaali.c src/test_jalaali.c
	./$(JALAALI_TEST)
