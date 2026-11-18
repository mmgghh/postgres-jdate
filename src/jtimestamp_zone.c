/*
 * jtimestamp_zone.c -- jdate_bin, AT TIME ZONE and OVERLAPS for jtimestamp and
 * jtimestamptz.
 *
 * None of these depends on the calendar, so each one is core's own C function
 * on the same representation (an int64 of microseconds since 2000-01-01, the
 * infinities at the extremes), followed where the result is a new value by the
 * range check of the result type. Core's timestamptz functions are the same
 * symbols as the timestamp ones where the work is identical, but the zone
 * functions are not, so each type calls the one that matches the core type it
 * mirrors.
 *
 * jdate_bin(stride, source, origin). Core's date_bin is not overloaded (a bare
 * literal would pick core's calendar), so this has its own name. timestamp_bin /
 * timestamptz_bin give the start of the stride-sized bin that holds source,
 * counted from origin; strides are fixed lengths of time (a month or a year is
 * 0A000, a zero or negative stride 22008, as in core) and infinity gives
 * infinity. For jtimestamptz the bins are elapsed time from the origin instant,
 * not local days. A bin start is never later than the source, but when the
 * source is before the origin it can lie up to one stride below the source, so
 * below the range: that edge is checked (the whole range, which is the same
 * test, since the start cannot be above a valid source). A jtimestamptz is
 * checked against the safe range.
 *
 * AT TIME ZONE desugars to pg_catalog.timezone(zone, value): timestamp_zone and
 * timestamptz_zone take a zone name (text), timestamp_izone and timestamptz_izone
 * a zone as an interval (an offset; months or days in it are an error, as core
 * says). The zone lookup, DST gaps and overlaps are core's. The result is a
 * different value, a wall clock turned into an instant or the other way round,
 * and can be outside the range of its type (the first Jalali day read as a wall
 * clock in a zone east of UTC is an instant before the safe range), so it is
 * checked.
 *
 * OVERLAPS desugars to pg_catalog.overlaps. Only the forms with four
 * timestamps exist: core's forms with an interval end would add Gregorian months
 * to a Jalali value, so they are not provided and stay 42883. overlaps_timestamp
 * is not strict (it treats a NULL end as core documents), so these functions are
 * not either; they hand their own call frame to it. It only compares, so it
 * needs no range check.
 */
#include "postgres.h"
#include "fmgr.h"
#include "datatype/timestamp.h"
#include "utils/fmgrprotos.h"
#include "utils/timestamp.h"

#include "jalaali.h"
#include "jdate_common.h"

/* ---- jdate_bin ---------------------------------------------------- */

PG_FUNCTION_INFO_V1(jdate_bin_jtimestamp);
Datum
jdate_bin_jtimestamp(PG_FUNCTION_ARGS)
{
	Datum		result = DirectFunctionCall3(timestamp_bin,
											 PG_GETARG_DATUM(0),
											 PG_GETARG_DATUM(1),
											 PG_GETARG_DATUM(2));

	jtimestamp_check_range(DatumGetTimestamp(result));
	return result;
}

PG_FUNCTION_INFO_V1(jdate_bin_jtimestamptz);
Datum
jdate_bin_jtimestamptz(PG_FUNCTION_ARGS)
{
	Datum		result = DirectFunctionCall3(timestamptz_bin,
											 PG_GETARG_DATUM(0),
											 PG_GETARG_DATUM(1),
											 PG_GETARG_DATUM(2));

	jtimestamptz_check_range(DatumGetTimestampTz(result));
	return result;
}

/* ---- AT TIME ZONE ------------------------------------------------- */

/* timezone(text, jtimestamp) -> jtimestamptz: the wall clock read in the zone */
PG_FUNCTION_INFO_V1(jtimestamp_zone);
Datum
jtimestamp_zone(PG_FUNCTION_ARGS)
{
	Datum		result = DirectFunctionCall2(timestamp_zone,
											 PG_GETARG_DATUM(0),
											 PG_GETARG_DATUM(1));

	jtimestamptz_check_range(DatumGetTimestampTz(result));
	return result;
}

/* timezone(interval, jtimestamp) -> jtimestamptz */
PG_FUNCTION_INFO_V1(jtimestamp_izone);
Datum
jtimestamp_izone(PG_FUNCTION_ARGS)
{
	Datum		result = DirectFunctionCall2(timestamp_izone,
											 PG_GETARG_DATUM(0),
											 PG_GETARG_DATUM(1));

	jtimestamptz_check_range(DatumGetTimestampTz(result));
	return result;
}

/* timezone(text, jtimestamptz) -> jtimestamp: the instant's wall clock in the zone */
PG_FUNCTION_INFO_V1(jtimestamptz_zone);
Datum
jtimestamptz_zone(PG_FUNCTION_ARGS)
{
	Datum		result = DirectFunctionCall2(timestamptz_zone,
											 PG_GETARG_DATUM(0),
											 PG_GETARG_DATUM(1));

	jtimestamp_check_range(DatumGetTimestamp(result));
	return result;
}

/* timezone(interval, jtimestamptz) -> jtimestamp */
PG_FUNCTION_INFO_V1(jtimestamptz_izone);
Datum
jtimestamptz_izone(PG_FUNCTION_ARGS)
{
	Datum		result = DirectFunctionCall2(timestamptz_izone,
											 PG_GETARG_DATUM(0),
											 PG_GETARG_DATUM(1));

	jtimestamp_check_range(DatumGetTimestamp(result));
	return result;
}

/* ---- OVERLAPS ------------------------------------------------------ */

/*
 * overlaps_timestamp reads its four arguments (and their null flags) from the
 * call frame and ignores everything else in it, so this function's own frame
 * is handed straight over. Core uses the same function for timestamp and
 * timestamptz, and the representation of both of ours is the same.
 */
PG_FUNCTION_INFO_V1(jtimestamp_overlaps);
Datum
jtimestamp_overlaps(PG_FUNCTION_ARGS)
{
	return overlaps_timestamp(fcinfo);
}

PG_FUNCTION_INFO_V1(jtimestamptz_overlaps);
Datum
jtimestamptz_overlaps(PG_FUNCTION_ARGS)
{
	return overlaps_timestamp(fcinfo);
}
