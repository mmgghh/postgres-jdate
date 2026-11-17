/*
 * jtimestamp_ops.c -- comparison and hashing for jtimestamp and jtimestamptz.
 *
 * Both types have exactly the representation of the core type they mirror (an
 * int64 of microseconds since 2000-01-01, the infinities at the int64
 * extremes), so every function here is a thin wrapper around the core C
 * function that works on that representation, as jdate's comparison functions
 * are around the date_* ones. Core's timestamptz functions are the timestamp
 * ones (their pg_proc.prosrc is the same symbol), so one core function serves
 * both types.
 *
 * Ordering and equality need no range check: they only look at values that
 * are already stored, and every stored value is valid.
 *
 * The SQL side (operators, the shared btree family jdatetime_ops, the hash
 * opclasses) is in jdate--1.0.sql. Its sort support, equalimage and skip
 * support entries are core's own functions, used directly, so they need no
 * wrapper here.
 */
#include "postgres.h"
#include "fmgr.h"
#include "utils/fmgrprotos.h"

/* bool f(a, b), int4 f(a, b) and int4/int8 hash wrappers */
#define JTS_WRAP2(name, core) \
	PG_FUNCTION_INFO_V1(name); \
	Datum \
	name(PG_FUNCTION_ARGS) \
	{ \
		return DirectFunctionCall2(core, PG_GETARG_DATUM(0), PG_GETARG_DATUM(1)); \
	}

#define JTS_WRAP1(name, core) \
	PG_FUNCTION_INFO_V1(name); \
	Datum \
	name(PG_FUNCTION_ARGS) \
	{ \
		return DirectFunctionCall1(core, PG_GETARG_DATUM(0)); \
	}

/* jtimestamp */
JTS_WRAP2(jtimestamp_eq, timestamp_eq)
JTS_WRAP2(jtimestamp_ne, timestamp_ne)
JTS_WRAP2(jtimestamp_lt, timestamp_lt)
JTS_WRAP2(jtimestamp_le, timestamp_le)
JTS_WRAP2(jtimestamp_gt, timestamp_gt)
JTS_WRAP2(jtimestamp_ge, timestamp_ge)
JTS_WRAP2(jtimestamp_cmp, timestamp_cmp)
JTS_WRAP1(jtimestamp_hash, timestamp_hash)
JTS_WRAP2(jtimestamp_hash_extended, timestamp_hash_extended)

/* jtimestamptz */
JTS_WRAP2(jtimestamptz_eq, timestamp_eq)
JTS_WRAP2(jtimestamptz_ne, timestamp_ne)
JTS_WRAP2(jtimestamptz_lt, timestamp_lt)
JTS_WRAP2(jtimestamptz_le, timestamp_le)
JTS_WRAP2(jtimestamptz_gt, timestamp_gt)
JTS_WRAP2(jtimestamptz_ge, timestamp_ge)
JTS_WRAP2(jtimestamptz_cmp, timestamp_cmp)
JTS_WRAP1(jtimestamptz_hash, timestamp_hash)
JTS_WRAP2(jtimestamptz_hash_extended, timestamp_hash_extended)
