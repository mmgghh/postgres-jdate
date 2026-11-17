MODULE_big = jdate
OBJS = src/jalaali.o src/jdate.o
EXTENSION = jdate
DATA = jdate--1.0.sql
DOCS = README.md
# Keep REGRESS on ONE line: dev/test-cluster.sh parses it.
REGRESS = io casts operators arithmetic fields format range binary hash fullrange softerr extension_schema
REGRESS_OPTS = --inputdir=test --outputdir=test

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
