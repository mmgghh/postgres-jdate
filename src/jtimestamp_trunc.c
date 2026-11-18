/*
 * jtimestamp_trunc.c -- jdate_trunc for jtimestamp and jtimestamptz.
 *
 * Three functions: jdate_trunc(text, jtimestamp), jdate_trunc(text, jtimestamptz)
 * (the session zone's clock) and jdate_trunc(text, jtimestamptz, text zone).
 *
 * The units split three ways:
 *
 *   year, quarter, month, week  the Jalali period start, at local midnight.
 *                               The local date is taken from the shared local
 *                               time helper (src/jtimestamp_local.c), turned
 *                               into the start of its period (the week is
 *                               Saturday-first, as jdate_trunc('week', jdate)),
 *                               and brought back through the helper, which uses
 *                               core's own DetermineTimeZoneOffset: a midnight
 *                               that does not exist (Tehran, 2020-03-21 00:00)
 *                               becomes the first valid instant of the day, as
 *                               core's date_trunc('day') gives.
 *   day, hour, minute, second,  nothing here depends on the calendar, so core's
 *   milliseconds, microseconds  timestamp_trunc / timestamptz_trunc /
 *                               timestamptz_trunc_zone does the work.
 *   anything else               0A000 (decade, century and millennium are not
 *                               offered for jdate_trunc either); a name that is
 *                               not a unit at all is 22023.
 *
 * With a zone argument, the Jalali units go through core's timestamptz_zone and
 * timestamp_zone (the functions behind AT TIME ZONE) instead of a pg_tz handle,
 * so the zone name, abbreviation or POSIX offset (core's sign: '+03:30' is
 * UTC-3:30) is decoded by core exactly as it is for AT TIME ZONE and for
 * date_trunc, on every server version.
 *
 * Infinity returns infinity for every unit that is decodable at all, as core's
 * date_trunc and jdate_trunc(text, jdate) do. With a zone argument the zone is
 * still looked up first, as core does (an unknown zone is 22023 for infinity too).
 *
 * Range checks. A jtimestamp result is never below its input and period starts
 * of in-range dates are in range, except the Saturday-first week at the very
 * start of the range (-0061-01-01 is a Thursday, so its week starts five days
 * below the minimum: 22008). A jtimestamptz result is checked for EVERY unit
 * against the safe range: the truncated local clock can fall below the safe
 * lower bound (the day start of the first safe instant, in a zone 15:59 east of
 * UTC, is 8 hours and 1 minute after the first day's start, which is before
 * the first safe instant), and an instant there could not be shown in a zone
 * 15:59:59 west of UTC.
 */
#include "postgres.h"
#include "fmgr.h"
#include "datatype/timestamp.h"
#include "utils/datetime.h"
#include "utils/fmgrprotos.h"
#include "utils/timestamp.h"
#include "varatt.h"

#include "jalaali.h"
#include "jdate_common.h"

typedef enum JtTruncClass
{
	JT_TRUNC_JALALI,			/* done here, on the local Jalali date */
	JT_TRUNC_CORE,				/* core's trunc function does it */
	JT_TRUNC_UNSUPPORTED
} JtTruncClass;

static JtTruncClass
jt_trunc_class(int val)
{
	switch (val)
	{
		case DTK_YEAR:
		case DTK_QUARTER:
		case DTK_MONTH:
		case DTK_WEEK:
			return JT_TRUNC_JALALI;
		case DTK_DAY:
		case DTK_HOUR:
		case DTK_MINUTE:
		case DTK_SECOND:
		case DTK_MILLISEC:
		case DTK_MICROSEC:
			return JT_TRUNC_CORE;
		default:
			return JT_TRUNC_UNSUPPORTED;
	}
}

/* The unit is known but not offered: 0A000, naming the unit and the type. */
static void
jt_trunc_unsupported(text *units, const char *typname)
{
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("unit \"%s\" not supported for jdate_trunc on type %s",
					pnstrdup(VARDATA_ANY(units), VARSIZE_ANY_EXHDR(units)),
					typname)));
}

/*
 * The start of the Jalali period (year, quarter, month or week) that holds the
 * date, in place. The week start can lie below the supported years, for the
 * first days of the range: that is the range error.
 */
static void
jt_trunc_date(int val, JalaaliDate *date)
{
	switch (val)
	{
		case DTK_YEAR:
			date->jm = 1;
			date->jd = 1;
			break;
		case DTK_QUARTER:
			date->jm = ((date->jm - 1) / 3) * 3 + 1;
			date->jd = 1;
			break;
		case DTK_MONTH:
			date->jd = 1;
			break;
		case DTK_WEEK:
			{
				/*
				 * Saturday-first, as the dow field and jdate_trunc('week',
				 * jdate): the start is the day minus its dow.
				 */
				int			jdn = jalaali_to_jdn(date->jy, date->jm, date->jd);

				if (!jalaali_from_jdn(jdn - (j2day(jdn) + 1) % 7, date))
					jdate_range_error();
				break;
			}
		default:
			elog(ERROR, "unexpected unit for a Jalali truncation");
	}
}

/* jtimestamp: its own wall clock, the result checked by the helper */
static Timestamp
jt_trunc_wall_clock(int val, Timestamp value)
{
	JtLocal		local;

	jt_local_from_timestamp(value, &local);
	jt_trunc_date(val, &local.date);
	local.time = 0;
	return jt_local_to_timestamp(&local);
}

/* jdate_trunc(text, jtimestamp) RETURNS jtimestamp */
PG_FUNCTION_INFO_V1(jdate_trunc_jtimestamp);
Datum
jdate_trunc_jtimestamp(PG_FUNCTION_ARGS)
{
	text	   *units = PG_GETARG_TEXT_PP(0);
	Timestamp	value = PG_GETARG_TIMESTAMP(1);
	int			val = jdate_decode_field(fcinfo, units, "jtimestamp");
	JtTruncClass cls = jt_trunc_class(val);
	Datum		result;

	if (TIMESTAMP_NOT_FINITE(value))
		PG_RETURN_TIMESTAMP(value);

	switch (cls)
	{
		case JT_TRUNC_JALALI:
			PG_RETURN_TIMESTAMP(jt_trunc_wall_clock(val, value));
		case JT_TRUNC_CORE:
			result = DirectFunctionCall2(timestamp_trunc,
										 PG_GETARG_DATUM(0),
										 PG_GETARG_DATUM(1));
			jtimestamp_check_range(DatumGetTimestamp(result));
			return result;
		default:
			jt_trunc_unsupported(units, "jtimestamp");
	}
	PG_RETURN_NULL();			/* not reached */
}

/* jdate_trunc(text, jtimestamptz) RETURNS jtimestamptz: the session zone */
PG_FUNCTION_INFO_V1(jdate_trunc_jtimestamptz);
Datum
jdate_trunc_jtimestamptz(PG_FUNCTION_ARGS)
{
	text	   *units = PG_GETARG_TEXT_PP(0);
	TimestampTz value = PG_GETARG_TIMESTAMPTZ(1);
	int			val = jdate_decode_field(fcinfo, units, "jtimestamptz");
	JtTruncClass cls = jt_trunc_class(val);
	Datum		result;

	if (TIMESTAMP_NOT_FINITE(value))
		PG_RETURN_TIMESTAMPTZ(value);

	switch (cls)
	{
		case JT_TRUNC_JALALI:
			{
				JtLocal		local;

				jt_local_from_instant(value, NULL, &local);
				jt_trunc_date(val, &local.date);
				local.time = 0;
				PG_RETURN_TIMESTAMPTZ(jt_local_to_instant(&local, NULL));
			}
		case JT_TRUNC_CORE:
			result = DirectFunctionCall2(timestamptz_trunc,
										 PG_GETARG_DATUM(0),
										 PG_GETARG_DATUM(1));
			jtimestamptz_check_range(DatumGetTimestampTz(result));
			return result;
		default:
			jt_trunc_unsupported(units, "jtimestamptz");
	}
	PG_RETURN_NULL();			/* not reached */
}

/* jdate_trunc(text, jtimestamptz, text) RETURNS jtimestamptz: the given zone */
PG_FUNCTION_INFO_V1(jdate_trunc_jtimestamptz_zone);
Datum
jdate_trunc_jtimestamptz_zone(PG_FUNCTION_ARGS)
{
	text	   *units = PG_GETARG_TEXT_PP(0);
	TimestampTz value = PG_GETARG_TIMESTAMPTZ(1);
	text	   *zone = PG_GETARG_TEXT_PP(2);
	int			val = jdate_decode_field(fcinfo, units, "jtimestamptz");
	JtTruncClass cls = jt_trunc_class(val);
	Datum		result;

	if (TIMESTAMP_NOT_FINITE(value))
	{
		/*
		 * Core looks the zone up before it looks at the value, so an unknown
		 * zone is an error for infinity too; its timestamptz_zone returns an
		 * infinite value untouched, so it is asked about a finite one.
		 */
		(void) DirectFunctionCall2(timestamptz_zone,
								   PointerGetDatum(zone),
								   TimestampTzGetDatum(0));
		PG_RETURN_TIMESTAMPTZ(value);
	}

	switch (cls)
	{
		case JT_TRUNC_JALALI:
			{
				/* the wall clock in the zone, truncated, and read back in it */
				Timestamp	wall = DatumGetTimestamp(DirectFunctionCall2(timestamptz_zone,
																		 PointerGetDatum(zone),
																		 TimestampTzGetDatum(value)));
				Timestamp	start = jt_trunc_wall_clock(val, wall);

				result = DirectFunctionCall2(timestamp_zone,
											 PointerGetDatum(zone),
											 TimestampGetDatum(start));
				jtimestamptz_check_range(DatumGetTimestampTz(result));
				return result;
			}
		case JT_TRUNC_CORE:
			result = DirectFunctionCall3(timestamptz_trunc_zone,
										 PG_GETARG_DATUM(0),
										 PG_GETARG_DATUM(1),
										 PG_GETARG_DATUM(2));
			jtimestamptz_check_range(DatumGetTimestampTz(result));
			return result;
		default:
			jt_trunc_unsupported(units, "jtimestamptz");
	}
	PG_RETURN_NULL();			/* not reached */
}
