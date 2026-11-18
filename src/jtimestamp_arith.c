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
