MODULE_big = jdate
OBJS = src/jalaali.o src/jdate.o
EXTENSION = jdate
DATA = jdate--1.0.sql
DOCS = README.md
# Keep REGRESS on ONE line: dev/test-cluster.sh parses it.
REGRESS = io casts operators arithmetic fields format range binary
REGRESS_OPTS = --inputdir=test --outputdir=test

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
