/*
 * jtimestamp_arith.c -- interval arithmetic and differences for jtimestamp.
 *
 * The rules are core's, for timestamp: months first, then days, then the time
 * part. Days and time do not depend on the calendar, so core's own
 * timestamp_pl_interval does them. Only the month part is calendar-dependent,
 * so it is applied here, with Jalali month lengths, and core is then called with
 * the month zeroed. Core also applies months first, so splitting the work this
 * way gives exactly core's order. As in core, the clamp to the last day of a
 * shorter month makes a month step not invertible.
 *
 * Subtraction negates the interval through core's interval_um (which refuses
 * the one value that cannot be negated, and handles an infinite interval on
 * PostgreSQL 17 and later) and adds.
 *
 * Infinity passes through as in core. From PostgreSQL 17 an interval can be
 * infinite; INTERVAL_NOT_FINITE does not exist before that, so it is used only
 * on 17 and later. Whenever the timestamp or the interval is infinite the whole
 * call is core's, so core's results and errors for those inputs (infinity plus
 * an opposite infinite interval) are reproduced as they are.
 *
 * The month step can leave the supported years, and the days and time can leave
 * the supported range, so the result is range-checked (22008). A month step that
 * itself lands outside the years is an error even when a negative day part would
 * bring the result back inside; it is not computed on a calendar we do not have.
 *
 * jtimestamptz does the same on the wall clock of the session zone. Core applies
 * months and days there, on the local date and time of day, and only the time part
 * as elapsed time, so the month step goes through the local-time helper (instant
 * to the session zone's Jalali date and time of day, Jalali months, back to an
 * instant through core's DetermineTimeZoneOffset, so a wall time in a gap moves
 * forward and an ambiguous one takes its second occurrence, as core does), and
 * core's timestamptz_pl_interval then does days (again on the wall clock) and
 * time with the month zeroed. The result is checked against the jtimestamptz
 * safe range, and so is the instant after the month step (the helper does that),
 * so a month step that lands outside the safe range is 22008 as well.
 *
 * jdate + interval and jdate - interval are core's date + interval: the day is
 * its midnight, as a jtimestamp, and the jtimestamp arithmetic does the rest.
 * jdate + time and jdate + timetz mirror core's date + time (a jtimestamp) and
 * date + timetz (a jtimestamptz, the instant of that wall time in the timetz's
 * own offset); core's own functions compute them and the result is range-checked.
 * Core has no timestamp + time, so there is no jtimestamp + time either.
 */
#include "postgres.h"
#include "fmgr.h"
#include "datatype/timestamp.h"
#include "utils/fmgrprotos.h"
#include "utils/timestamp.h"

#include "jalaali.h"
#include "jdate_common.h"

static inline bool
jt_interval_not_finite(const Interval *span)
{
#if PG_VERSION_NUM >= 170000
	return INTERVAL_NOT_FINITE(span);
#else
	/* Intervals are always finite before PostgreSQL 17. */
	(void) span;
	return false;
#endif
}

/* The wall-clock date of a finite jtimestamp moved by whole Jalali months. */
static Timestamp
jtimestamp_add_months(Timestamp value, int32 months)
{
	JtLocal		local;

	jt_local_from_timestamp(value, &local);
	if (!jdate_add_months(&local.date, months, &local.date))
		jdate_range_error();
	return jt_local_to_timestamp(&local);
}

/*
 * value + span, for any value (finite or not) and any span: the month part with
 * Jalali rules, everything else core's, then the range check.
 */
static Timestamp
jtimestamp_add_interval(Timestamp value, const Interval *span)
{
	Interval	rest;
	Timestamp	result;

	if (!TIMESTAMP_NOT_FINITE(value) && !jt_interval_not_finite(span) &&
		span->month != 0)
	{
		value = jtimestamp_add_months(value, span->month);
		rest = *span;
		rest.month = 0;
		span = &rest;
	}

	result = DatumGetTimestamp(DirectFunctionCall2(timestamp_pl_interval,
												   TimestampGetDatum(value),
												   IntervalPGetDatum(span)));
	jtimestamp_check_range(result);
	return result;
}

/* A jtimestamptz moved by whole Jalali months on the session zone's clock. */
static TimestampTz
jtimestamptz_add_months(TimestampTz value, int32 months)
{
	JtLocal		local;

	jt_local_from_instant(value, NULL, &local);
	if (!jdate_add_months(&local.date, months, &local.date))
		jdate_range_error();
	return jt_local_to_instant(&local, NULL);
}

/* As jtimestamp_add_interval, for an instant and the session zone. */
static TimestampTz
jtimestamptz_add_interval(TimestampTz value, const Interval *span)
{
	Interval	rest;
	TimestampTz result;

	if (!TIMESTAMP_NOT_FINITE(value) && !jt_interval_not_finite(span) &&
		span->month != 0)
	{
		value = jtimestamptz_add_months(value, span->month);
		rest = *span;
		rest.month = 0;
		span = &rest;
	}

	result = DatumGetTimestampTz(DirectFunctionCall2(timestamptz_pl_interval,
													 TimestampTzGetDatum(value),
													 IntervalPGetDatum(span)));
	jtimestamptz_check_range(result);
	return result;
}

PG_FUNCTION_INFO_V1(jtimestamp_pl_interval);
Datum
jtimestamp_pl_interval(PG_FUNCTION_ARGS)
{
	PG_RETURN_TIMESTAMP(jtimestamp_add_interval(PG_GETARG_TIMESTAMP(0),
												PG_GETARG_INTERVAL_P(1)));
}

PG_FUNCTION_INFO_V1(interval_pl_jtimestamp);
Datum
interval_pl_jtimestamp(PG_FUNCTION_ARGS)
{
	PG_RETURN_TIMESTAMP(jtimestamp_add_interval(PG_GETARG_TIMESTAMP(1),
												PG_GETARG_INTERVAL_P(0)));
}

PG_FUNCTION_INFO_V1(jtimestamp_mi_interval);
Datum
jtimestamp_mi_interval(PG_FUNCTION_ARGS)
{
	Interval   *negated = DatumGetIntervalP(DirectFunctionCall1(interval_um,
																PG_GETARG_DATUM(1)));

	PG_RETURN_TIMESTAMP(jtimestamp_add_interval(PG_GETARG_TIMESTAMP(0), negated));
}

/*
 * The differences are core's timestamp_mi: days plus the time of day, no month
 * part, so no calendar is involved, and no range check, as the result is an
 * interval. jdate - jtimestamp and jtimestamp - jdate turn the day into its
 * midnight with core's date_timestamp first, as core's implicit cast does for
 * date - timestamp (an infinite day becomes the infinite timestamp, and
 * timestamp_mi then does what it does for infinities).
 */
PG_FUNCTION_INFO_V1(jtimestamp_mi);
Datum
jtimestamp_mi(PG_FUNCTION_ARGS)
{
	return DirectFunctionCall2(timestamp_mi, PG_GETARG_DATUM(0), PG_GETARG_DATUM(1));
}

PG_FUNCTION_INFO_V1(jdate_mi_jtimestamp);
Datum
jdate_mi_jtimestamp(PG_FUNCTION_ARGS)
{
	Datum		midnight = DirectFunctionCall1(date_timestamp, PG_GETARG_DATUM(0));

	return DirectFunctionCall2(timestamp_mi, midnight, PG_GETARG_DATUM(1));
}

PG_FUNCTION_INFO_V1(jtimestamp_mi_jdate);
Datum
jtimestamp_mi_jdate(PG_FUNCTION_ARGS)
{
	Datum		midnight = DirectFunctionCall1(date_timestamp, PG_GETARG_DATUM(1));

	return DirectFunctionCall2(timestamp_mi, PG_GETARG_DATUM(0), midnight);
}

PG_FUNCTION_INFO_V1(jtimestamptz_pl_interval);
Datum
jtimestamptz_pl_interval(PG_FUNCTION_ARGS)
{
	PG_RETURN_TIMESTAMPTZ(jtimestamptz_add_interval(PG_GETARG_TIMESTAMPTZ(0),
													PG_GETARG_INTERVAL_P(1)));
}

PG_FUNCTION_INFO_V1(interval_pl_jtimestamptz);
Datum
interval_pl_jtimestamptz(PG_FUNCTION_ARGS)
{
	PG_RETURN_TIMESTAMPTZ(jtimestamptz_add_interval(PG_GETARG_TIMESTAMPTZ(1),
													PG_GETARG_INTERVAL_P(0)));
}

PG_FUNCTION_INFO_V1(jtimestamptz_mi_interval);
Datum
jtimestamptz_mi_interval(PG_FUNCTION_ARGS)
{
	Interval   *negated = DatumGetIntervalP(DirectFunctionCall1(interval_um,
																PG_GETARG_DATUM(1)));

	PG_RETURN_TIMESTAMPTZ(jtimestamptz_add_interval(PG_GETARG_TIMESTAMPTZ(0), negated));
}

/*
 * jtimestamptz - jtimestamptz is core's timestamptz_mi, whose C function is
 * timestamp_mi: elapsed time as days (of 24 hours) and time of day, no months,
 * no zone. jdate - jtimestamptz and jtimestamptz - jdate take the day as its
 * midnight in the session zone (core's date_timestamptz, as its implicit cast
 * date -> timestamptz does for date - timestamptz), which is why they are
 * STABLE.
 */
PG_FUNCTION_INFO_V1(jtimestamptz_mi);
Datum
jtimestamptz_mi(PG_FUNCTION_ARGS)
{
	return DirectFunctionCall2(timestamp_mi, PG_GETARG_DATUM(0), PG_GETARG_DATUM(1));
}

PG_FUNCTION_INFO_V1(jdate_mi_jtimestamptz);
Datum
jdate_mi_jtimestamptz(PG_FUNCTION_ARGS)
{
	Datum		midnight = DirectFunctionCall1(date_timestamptz, PG_GETARG_DATUM(0));

	return DirectFunctionCall2(timestamp_mi, midnight, PG_GETARG_DATUM(1));
}

PG_FUNCTION_INFO_V1(jtimestamptz_mi_jdate);
Datum
jtimestamptz_mi_jdate(PG_FUNCTION_ARGS)
{
	Datum		midnight = DirectFunctionCall1(date_timestamptz, PG_GETARG_DATUM(1));

	return DirectFunctionCall2(timestamp_mi, PG_GETARG_DATUM(0), midnight);
}

/*
 * jdate +/- interval: the day as the jtimestamp of its midnight (an infinite day
 * is the infinite timestamp), then the jtimestamp rules.
 */
static Timestamp
jdate_midnight(Datum value)
{
	return DatumGetTimestamp(DirectFunctionCall1(date_timestamp, value));
}

PG_FUNCTION_INFO_V1(jdate_pl_interval);
Datum
jdate_pl_interval(PG_FUNCTION_ARGS)
{
	PG_RETURN_TIMESTAMP(jtimestamp_add_interval(jdate_midnight(PG_GETARG_DATUM(0)),
												PG_GETARG_INTERVAL_P(1)));
}

PG_FUNCTION_INFO_V1(interval_pl_jdate);
Datum
interval_pl_jdate(PG_FUNCTION_ARGS)
{
	PG_RETURN_TIMESTAMP(jtimestamp_add_interval(jdate_midnight(PG_GETARG_DATUM(1)),
												PG_GETARG_INTERVAL_P(0)));
}

PG_FUNCTION_INFO_V1(jdate_mi_interval);
Datum
jdate_mi_interval(PG_FUNCTION_ARGS)
{
	Interval   *negated = DatumGetIntervalP(DirectFunctionCall1(interval_um,
																PG_GETARG_DATUM(1)));

	PG_RETURN_TIMESTAMP(jtimestamp_add_interval(jdate_midnight(PG_GETARG_DATUM(0)),
												negated));
}

/*
 * jdate + time, jdate + timetz and their commutators: core's date + time
 * (datetime_timestamp) and date + timetz (datetimetz_timestamptz), then the range
 * check. The first can only leave the range with time '24:00:00' on the last day;
 * the second moves the instant by the offset of the timetz, so it can leave the
 * safe range of jtimestamptz near the ends.
 */
static Timestamp
jdate_plus_time(Datum day, Datum time)
{
	Timestamp	result = DatumGetTimestamp(DirectFunctionCall2(datetime_timestamp,
															   day, time));

	jtimestamp_check_range(result);
	return result;
}

static TimestampTz
jdate_plus_timetz(Datum day, Datum timetz)
{
	TimestampTz result = DatumGetTimestampTz(DirectFunctionCall2(datetimetz_timestamptz,
																 day, timetz));

	jtimestamptz_check_range(result);
	return result;
}

PG_FUNCTION_INFO_V1(jdate_pl_time);
Datum
jdate_pl_time(PG_FUNCTION_ARGS)
{
	PG_RETURN_TIMESTAMP(jdate_plus_time(PG_GETARG_DATUM(0), PG_GETARG_DATUM(1)));
}

PG_FUNCTION_INFO_V1(time_pl_jdate);
Datum
time_pl_jdate(PG_FUNCTION_ARGS)
{
	PG_RETURN_TIMESTAMP(jdate_plus_time(PG_GETARG_DATUM(1), PG_GETARG_DATUM(0)));
}

PG_FUNCTION_INFO_V1(jdate_pl_timetz);
Datum
jdate_pl_timetz(PG_FUNCTION_ARGS)
{
	PG_RETURN_TIMESTAMPTZ(jdate_plus_timetz(PG_GETARG_DATUM(0), PG_GETARG_DATUM(1)));
}

PG_FUNCTION_INFO_V1(timetz_pl_jdate);
Datum
timetz_pl_jdate(PG_FUNCTION_ARGS)
{
	PG_RETURN_TIMESTAMPTZ(jdate_plus_timetz(PG_GETARG_DATUM(1), PG_GETARG_DATUM(0)));
}
