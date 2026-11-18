/*
 * jtimestamp_fields.c -- EXTRACT and jdate_part for jtimestamp and jtimestamptz.
 *
 * The date fields (year, month, day, quarter, doy, decade, century, dow, isodow)
 * are the fields of the local Jalali date, taken by jdate_get_field, so a
 * timestamp and its date agree by construction. The time fields (hour, minute,
 * second, milliseconds, microseconds) are read from the local time of day, with
 * the numeric scales core's extract gives them (second 6 decimals, milliseconds
 * 3, microseconds 0). The local date and time come from the shared local-time
 * helper (src/jtimestamp_local.c): a jtimestamp is its own wall clock, a
 * jtimestamptz is read on the clock of the session zone.
 *
 * epoch is exact: a jtimestamp is counted as if it were UTC, as core counts a
 * timestamp, a jtimestamptz is the true instant. timezone, timezone_hour and
 * timezone_minute (the offset of the session zone at that instant, in core's
 * sign: east is positive) exist for jtimestamptz only.
 *
 * week, isoyear, millennium and julian are 0A000 for both types, as for jdate (a
 * Jalali week of the year has no standard definition, and core's week would be
 * the ISO one on a Gregorian calendar), and so are the timezone fields of a
 * jtimestamp. An unknown unit is 22023. Both errors name the real type.
 *
 * Infinity is as for jdate: the units that only grow (year, decade, century,
 * epoch) are +/-Infinity in EXTRACT and the rest are NULL; jdate_part returns
 * NULL for every unit on infinity. A unit that is not supported is refused before
 * the value is looked at, so it is 0A000 for infinity as well.
 *
 * jdate_part(text, jtimestamp[tz]) returns numeric, the same value as EXTRACT:
 * seconds and epoch need the fraction (a double would lose the microseconds of an
 * epoch near the top of the range), and the jdate version stays bigint.
 */
#include "postgres.h"
#include "fmgr.h"
#include "datatype/timestamp.h"
#include "utils/datetime.h"
#include "utils/float.h"
#include "utils/fmgrprotos.h"
#include "utils/numeric.h"
#include "utils/timestamp.h"
#include "varatt.h"

#include "jalaali.h"
#include "jdate_common.h"

typedef enum JtFieldClass
{
	JT_FIELD_DATE,				/* a field of the local Jalali date */
	JT_FIELD_TIME,				/* a field of the local time of day */
	JT_FIELD_EPOCH,
	JT_FIELD_ZONE,				/* an offset field, jtimestamptz only */
	JT_FIELD_UNSUPPORTED
} JtFieldClass;

static JtFieldClass
jt_field_class(int val, bool has_zone)
{
	switch (val)
	{
		case DTK_YEAR:
		case DTK_MONTH:
		case DTK_DAY:
		case DTK_QUARTER:
		case DTK_DOY:
		case DTK_DECADE:
		case DTK_CENTURY:
		case DTK_DOW:
		case DTK_ISODOW:
			return JT_FIELD_DATE;
		case DTK_HOUR:
		case DTK_MINUTE:
		case DTK_SECOND:
		case DTK_MILLISEC:
		case DTK_MICROSEC:
			return JT_FIELD_TIME;
		case DTK_EPOCH:
			return JT_FIELD_EPOCH;
		case DTK_TZ:
		case DTK_TZ_HOUR:
		case DTK_TZ_MINUTE:
			return has_zone ? JT_FIELD_ZONE : JT_FIELD_UNSUPPORTED;
		default:
			return JT_FIELD_UNSUPPORTED;
	}
}

/* The unit is known but not offered for this type: 0A000, naming the type. */
static void
jt_unsupported_unit(text *units, const char *typname)
{
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("unit \"%s\" not supported for type %s",
					pnstrdup(VARDATA_ANY(units), VARSIZE_ANY_EXHDR(units)),
					typname)));
}

/*
 * The fields of a finite value. has_zone is false for jtimestamp (its own wall
 * clock), true for jtimestamptz (the session zone's clock).
 */
static Numeric
jt_finite_field(int val, JtFieldClass cls, bool has_zone, int64 value)
{
	JtLocal		local;
	int64		sec_usec;

	/* epoch is the same sum for both: the microseconds since 1970-01-01 00:00 */
	if (cls == JT_FIELD_EPOCH)
		return int64_div_fast_to_numeric(value +
										 (int64) (POSTGRES_EPOCH_JDATE - UNIX_EPOCH_JDATE) * USECS_PER_DAY,
										 6);

	if (has_zone)
		jt_local_from_instant(value, NULL, &local);
	else
		jt_local_from_timestamp(value, &local);

	switch (cls)
	{
		case JT_FIELD_DATE:
			{
				DateADT		day = jalaali_to_jdn(local.date.jy, local.date.jm,
												 local.date.jd) - POSTGRES_EPOCH_JDATE;
				int64		field;

				if (jdate_get_field(day, val, &field) != JDATE_FIELD_FINITE)
					elog(ERROR, "unexpected result for a date field of a finite value");
				return int64_to_numeric(field);
			}

		case JT_FIELD_TIME:
			/* seconds and their fraction, in microseconds: 0 .. 59999999 */
			sec_usec = local.time % USECS_PER_MINUTE;
			switch (val)
			{
				case DTK_HOUR:
					return int64_to_numeric(local.time / USECS_PER_HOUR);
				case DTK_MINUTE:
					return int64_to_numeric((local.time / USECS_PER_MINUTE) % MINS_PER_HOUR);
				case DTK_SECOND:
					return int64_div_fast_to_numeric(sec_usec, 6);
				case DTK_MILLISEC:
					return int64_div_fast_to_numeric(sec_usec, 3);
				default:
					return int64_to_numeric(sec_usec);	/* DTK_MICROSEC */
			}

		default:
			/* local.tz is in seconds west of UTC, core's sign: flip it */
			switch (val)
			{
				case DTK_TZ:
					return int64_to_numeric(-local.tz);
				case DTK_TZ_HOUR:
					return int64_to_numeric(-local.tz / SECS_PER_HOUR);
				default:
					return int64_to_numeric((-local.tz / SECS_PER_MINUTE) % MINS_PER_HOUR);
			}
	}
}

/*
 * The one body behind the four functions. "growing" says what an infinite value
 * of a unit that only grows gives: +/-Infinity (EXTRACT) or NULL (jdate_part).
 */
static Datum
jt_field(FunctionCallInfo fcinfo, const char *typname, bool has_zone, bool growing)
{
	text	   *units = PG_GETARG_TEXT_PP(0);
	Timestamp	value = PG_GETARG_TIMESTAMP(1);
	int			val = jdate_decode_field(fcinfo, units, typname);
	JtFieldClass cls = jt_field_class(val, has_zone);

	if (cls == JT_FIELD_UNSUPPORTED)
		jt_unsupported_unit(units, typname);

	if (TIMESTAMP_NOT_FINITE(value))
	{
		if (growing &&
			(val == DTK_YEAR || val == DTK_DECADE || val == DTK_CENTURY ||
			 val == DTK_EPOCH))
			return DirectFunctionCall1(float8_numeric,
									   Float8GetDatum(TIMESTAMP_IS_NOBEGIN(value)
													  ? -get_float8_infinity()
													  : get_float8_infinity()));
		PG_RETURN_NULL();
	}

	PG_RETURN_NUMERIC(jt_finite_field(val, cls, has_zone, value));
}

/* pg_catalog.extract(text, jtimestamp) RETURNS numeric */
PG_FUNCTION_INFO_V1(jtimestamp_extract);
Datum
jtimestamp_extract(PG_FUNCTION_ARGS)
{
	return jt_field(fcinfo, "jtimestamp", false, true);
}

/* pg_catalog.extract(text, jtimestamptz) RETURNS numeric */
PG_FUNCTION_INFO_V1(jtimestamptz_extract);
Datum
jtimestamptz_extract(PG_FUNCTION_ARGS)
{
	return jt_field(fcinfo, "jtimestamptz", true, true);
}

/* jdate_part(text, jtimestamp) RETURNS numeric: NULL on infinity */
PG_FUNCTION_INFO_V1(jtimestamp_part);
Datum
jtimestamp_part(PG_FUNCTION_ARGS)
{
	return jt_field(fcinfo, "jtimestamp", false, false);
}

/* jdate_part(text, jtimestamptz) RETURNS numeric: NULL on infinity */
PG_FUNCTION_INFO_V1(jtimestamptz_part);
Datum
jtimestamptz_part(PG_FUNCTION_ARGS)
{
	return jt_field(fcinfo, "jtimestamptz", true, false);
}
