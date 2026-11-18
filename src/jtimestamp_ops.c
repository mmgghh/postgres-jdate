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
 * The cross-type comparisons (jdate, jtimestamp and jtimestamptz against each
 * other, in both argument orders) call core's date/timestamp/timestamptz
 * cross-type functions the same way: jdate is an int32 day count like date,
 * jtimestamp and jtimestamptz are int64 microsecond counts like timestamp and
 * timestamptz, so the core function that compares the mirrored core types is
 * exact for ours. They are C wrappers, not LANGUAGE internal aliases of core's
 * symbols, so the SQL script does not depend on core's internal function names
 * (only the C symbols, which are declared in fmgrprotos.h on every supported
 * major). The pairs that involve jtimestamptz and another type read the
 * session time zone (as core's do), which is why those are STABLE.
 *
 * Ordering and equality need no range check: they only look at values that
 * are already stored, and every stored value is valid. The same holds for
 * the smaller/larger functions behind min() and max(): they return one of
 * their two arguments.
 *
 * The SQL side (operators, the shared btree family jdatetime_ops, the hash
 * opclasses) is in jdate--1.0.sql. Its sort support, equalimage and skip
 * support entries are core's own functions, used directly, so they need no
 * wrapper here.
 */
#include "postgres.h"
#include "fmgr.h"
#include "utils/fmgrprotos.h"

/* bool f(a, b), int4 f(a, b), hash and smaller/larger wrappers */
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
JTS_WRAP2(jtimestamp_smaller, timestamp_smaller)
JTS_WRAP2(jtimestamp_larger, timestamp_larger)

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
JTS_WRAP2(jtimestamptz_smaller, timestamp_smaller)
JTS_WRAP2(jtimestamptz_larger, timestamp_larger)

/*
 * Cross-type comparison. For the ordered pair (L, R), mirrored by the core
 * types (CL, CR), define L_eq_R, L_ne_R, L_lt_R, L_le_R, L_gt_R, L_ge_R and
 * L_cmp_R over core's CL_eq_CR ... CL_cmp_CR.
 */
#define JTS_CROSS(L, R, CL, CR) \
	JTS_WRAP2(L##_eq_##R, CL##_eq_##CR) \
	JTS_WRAP2(L##_ne_##R, CL##_ne_##CR) \
	JTS_WRAP2(L##_lt_##R, CL##_lt_##CR) \
	JTS_WRAP2(L##_le_##R, CL##_le_##CR) \
	JTS_WRAP2(L##_gt_##R, CL##_gt_##CR) \
	JTS_WRAP2(L##_ge_##R, CL##_ge_##CR) \
	JTS_WRAP2(L##_cmp_##R, CL##_cmp_##CR)

JTS_CROSS(jdate, jtimestamp, date, timestamp)
JTS_CROSS(jtimestamp, jdate, timestamp, date)
JTS_CROSS(jdate, jtimestamptz, date, timestamptz)
JTS_CROSS(jtimestamptz, jdate, timestamptz, date)
JTS_CROSS(jtimestamp, jtimestamptz, timestamp, timestamptz)
JTS_CROSS(jtimestamptz, jtimestamp, timestamptz, timestamp)
