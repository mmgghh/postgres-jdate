/*
 * jtimestamp_series.c -- jgenerate_series for jtimestamp, jtimestamptz and jdate.
 *
 * The series functions of core are not overloaded (core's generate_series would
 * pick the Gregorian calendar for a bare literal), so these have their own name.
 * They follow core's generate_series: the first element is the start, element
 * n + 1 is element n plus the step (so the clamp of a month step to the last day
 * of a shorter month sticks: 1403-06-31 + 1 month, then + 1 month again, is
 * 1403-07-30, 1403-08-30), the series stops at the first element past the finish
 * (before it, for a negative step), a zero step is 22023.
 *
 * Every element comes from the same rules as the + operator of the type: the
 * month part of the step is applied with Jalali month lengths and the days and
 * time by core's own arithmetic, months first. They are not passed straight to
 * core's generate_series_timestamp / generate_series_timestamptz because of the
 * month part, because core 18 does not refuse an infinite endpoint (it runs until
 * its own range overflows, or for ever from -infinity), and because the zone
 * variant of core's generate_series_timestamptz is not known on PostgreSQL 16.
 * A single code path also keeps the result independent of the major version.
 *
 * jtimestamp steps on its own wall clock. jtimestamptz steps on the wall clock of
 * the session zone, or of the zone given as the fourth argument, the way core
 * does for timestamptz: months and days on the local date and time of day, the
 * time part as elapsed time. The wall clock is reached with core's own routines
 * that exist on every supported major (timestamptz_timestamp / timestamp_timestamptz
 * for the session zone, timestamptz_zone / timestamp_zone for a named one), which
 * also resolve the zone name (an unknown zone is 22023, checked on the first call)
 * and decide gaps and overlaps as core does (a wall time that does not exist
 * moves forward, an ambiguous one takes its second occurrence). The sequence of
 * conversions is core's: months, back to an instant, days, back to an instant,
 * then the time part.
 *
 * Ranges. The endpoints are valid values, so every element between them is. The
 * next element is computed before the current one is returned (as core does); if
 * it falls outside the range on the side where the series ends, it is past the
 * finish and the series simply ends after the current element, which lets a series
 * run up to the last (or down to the first) representable value. A next element
 * that falls outside on the other side (a step whose months and days point in
 * different directions) cannot be returned and is 22008. A month step that lands
 * outside the range ends or fails the series even when the days of the same step
 * would bring the result back, as for the + operator.
 *
 * An infinite endpoint is 22023 here. Core 18.6 accepts it and then loops, so
 * there is nothing to be compatible with; an infinite step is 22023 as in core
 * (it exists from PostgreSQL 17 on).
 */
#include "postgres.h"
#include "fmgr.h"
/*
 * funcapi.h pulls in headers whose inline functions have unused parameters; the
 * harness build uses -Wextra, which would report them, so they are silenced for
 * the include only.
 */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-parameter"
#include "funcapi.h"
#pragma GCC diagnostic pop
#include "datatype/timestamp.h"
#include "utils/date.h"
#include "utils/fmgrprotos.h"
#include "utils/timestamp.h"

#include "jalaali.h"
#include "jdate_common.h"

typedef enum JtSeriesKind
{
	JT_SERIES_TIMESTAMP,		/* (jtimestamp, jtimestamp, interval) */
	JT_SERIES_TIMESTAMPTZ,		/* (jtimestamptz, jtimestamptz, interval) */
	JT_SERIES_TIMESTAMPTZ_ZONE, /* (jtimestamptz, jtimestamptz, interval, text) */
	JT_SERIES_DATE				/* (jdate, jdate, interval): jtimestamp rows */
} JtSeriesKind;

typedef struct JtSeries
{
	bool		tz;				/* elements are instants (jtimestamptz) */
	int64		current;		/* the element to return next */
	int64		finish;
	Interval	step;
	int			step_sign;
	text	   *zone;			/* NULL: the session zone */
	bool		last;			/* the element being returned is the last one */
} JtSeries;

static void
jt_series_endpoint_error(const char *which)
{
	ereport(ERROR,
			(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
			 errmsg("%s value cannot be infinity", which)));
}

/* The wall clock (a timestamp) of an instant, in the session zone or a named one. */
static Timestamp
jt_series_wall(TimestampTz instant, text *zone)
{
	if (zone == NULL)
		return DatumGetTimestamp(DirectFunctionCall1(timestamptz_timestamp,
													 TimestampTzGetDatum(instant)));
	return DatumGetTimestamp(DirectFunctionCall2(timestamptz_zone,
												 PointerGetDatum(zone),
												 TimestampTzGetDatum(instant)));
}

/* The instant of a wall clock reading, as core's AT TIME ZONE / cast does it. */
static TimestampTz
jt_series_instant(Timestamp wall, text *zone)
{
	if (zone == NULL)
		return DatumGetTimestampTz(DirectFunctionCall1(timestamp_timestamptz,
													   TimestampGetDatum(wall)));
	return DatumGetTimestampTz(DirectFunctionCall2(timestamp_zone,
												   PointerGetDatum(zone),
												   TimestampGetDatum(wall)));
}

/* Which side of the range a value outside it is on: -1 below, +1 above. */
static inline int
jt_series_side(int64 value)
{
	return value < 0 ? -1 : 1;
}

/*
 * The element after "current" for a step on a jtimestamp. Returns 0 and the
 * element in *next, or -1 / +1 when the element lies below / above the range.
 */
static int
jt_series_next_timestamp(Timestamp current, const Interval *step, Timestamp *next)
{
	Timestamp	value = current;
	Interval	rest = *step;

	if (step->month != 0)
	{
		JtLocal		local;

		jt_local_from_timestamp(value, &local);
		if (!jdate_add_months(&local.date, step->month, &local.date))
			return step->month > 0 ? 1 : -1;
		value = jt_local_to_timestamp(&local);
		rest.month = 0;
	}

	if (rest.day != 0 || rest.time != 0)
		value = DatumGetTimestamp(DirectFunctionCall2(timestamp_pl_interval,
													  TimestampGetDatum(value),
													  IntervalPGetDatum(&rest)));

	if (!jtimestamp_in_range(value))
		return jt_series_side(value);
	*next = value;
	return 0;
}

/* The same for a jtimestamptz, on the wall clock of "zone" (NULL: the session zone). */
static int
jt_series_next_timestamptz(TimestampTz current, const Interval *step, text *zone,
						   TimestampTz *next)
{
	TimestampTz value = current;

	if (step->month != 0)
	{
		JtLocal		local;

		jt_local_from_timestamp(jt_series_wall(value, zone), &local);
		if (!jdate_add_months(&local.date, step->month, &local.date))
			return step->month > 0 ? 1 : -1;
		value = jt_series_instant(jt_local_to_timestamp(&local), zone);
		if (!jtimestamptz_in_range(value))
			return jt_series_side(value);
	}

	if (step->day != 0)
	{
		Interval	days = {0};
		Timestamp	wall;

		days.day = step->day;
		wall = DatumGetTimestamp(DirectFunctionCall2(timestamp_pl_interval,
													 TimestampGetDatum(jt_series_wall(value, zone)),
													 IntervalPGetDatum(&days)));
		value = jt_series_instant(wall, zone);
	}

	if (step->time != 0)
	{
		Interval	elapsed = {0};

		elapsed.time = step->time;
		value = DatumGetTimestampTz(DirectFunctionCall2(timestamptz_pl_interval,
														TimestampTzGetDatum(value),
														IntervalPGetDatum(&elapsed)));
	}

	if (!jtimestamptz_in_range(value))
		return jt_series_side(value);
	*next = value;
	return 0;
}

/* The state of a series, from the arguments of the first call. */
static JtSeries *
jt_series_init(FunctionCallInfo fcinfo, JtSeriesKind kind)
{
	JtSeries   *s = (JtSeries *) palloc0(sizeof(JtSeries));
	Interval   *step = PG_GETARG_INTERVAL_P(2);
	const Interval interval_zero = {0};
	int64		start;
	int64		finish;
	int32		cmp;

	switch (kind)
	{
		case JT_SERIES_TIMESTAMP:
			start = PG_GETARG_TIMESTAMP(0);
			finish = PG_GETARG_TIMESTAMP(1);
			break;
		case JT_SERIES_DATE:
			start = DatumGetTimestamp(DirectFunctionCall1(date_timestamp,
														  PG_GETARG_DATUM(0)));
			finish = DatumGetTimestamp(DirectFunctionCall1(date_timestamp,
														   PG_GETARG_DATUM(1)));
			break;
		case JT_SERIES_TIMESTAMPTZ:
		case JT_SERIES_TIMESTAMPTZ_ZONE:
			s->tz = true;
			start = PG_GETARG_TIMESTAMPTZ(0);
			finish = PG_GETARG_TIMESTAMPTZ(1);
			if (kind == JT_SERIES_TIMESTAMPTZ_ZONE)
				s->zone = (text *) PG_DETOAST_DATUM_COPY(PG_GETARG_DATUM(3));
			break;
		default:
			elog(ERROR, "unexpected series kind");
			start = finish = 0;
	}

	if (TIMESTAMP_NOT_FINITE(start))
		jt_series_endpoint_error("start");
	if (TIMESTAMP_NOT_FINITE(finish))
		jt_series_endpoint_error("stop");

	s->current = start;
	s->finish = finish;
	s->step = *step;
	cmp = DatumGetInt32(DirectFunctionCall2(interval_cmp,
											IntervalPGetDatum(&s->step),
											IntervalPGetDatum(&interval_zero)));
	s->step_sign = cmp < 0 ? -1 : (cmp > 0 ? 1 : 0);
	if (s->step_sign == 0)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("step size cannot equal zero")));
#if PG_VERSION_NUM >= 170000
	if (INTERVAL_NOT_FINITE(&s->step))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("step size cannot be infinite")));
#endif

	/* An unknown zone is an error whatever the step: look it up now. */
	if (s->zone != NULL)
		(void) jt_series_wall(start, s->zone);

	return s;
}

static Datum
jt_series_srf(FunctionCallInfo fcinfo, JtSeriesKind kind)
{
	FuncCallContext *funcctx;
	JtSeries   *s;
	int64		result;
	int64		next = 0;
	int			side;

	if (SRF_IS_FIRSTCALL())
	{
		MemoryContext oldcontext;

		funcctx = SRF_FIRSTCALL_INIT();
		oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);
		funcctx->user_fctx = jt_series_init(fcinfo, kind);
		MemoryContextSwitchTo(oldcontext);
	}

	funcctx = SRF_PERCALL_SETUP();
	s = (JtSeries *) funcctx->user_fctx;

	if (s->last ||
		(s->step_sign > 0 ? s->current > s->finish : s->current < s->finish))
		SRF_RETURN_DONE(funcctx);

	result = s->current;

	if (s->tz)
		side = jt_series_next_timestamptz(result, &s->step, s->zone, &next);
	else
		side = jt_series_next_timestamp(result, &s->step, &next);

	if (side == 0)
		s->current = next;
	else if (side == s->step_sign)
		s->last = true;			/* the next element is past the finish */
	else
		jdate_range_error();	/* it would be in the wrong direction */

	if (s->tz)
		jtimestamptz_check_range(result);
	else
		jtimestamp_check_range(result);

	SRF_RETURN_NEXT(funcctx, Int64GetDatum(result));  /* both are 8-byte, by value */
}

PG_FUNCTION_INFO_V1(jgenerate_series_jtimestamp);
Datum
jgenerate_series_jtimestamp(PG_FUNCTION_ARGS)
{
	return jt_series_srf(fcinfo, JT_SERIES_TIMESTAMP);
}

PG_FUNCTION_INFO_V1(jgenerate_series_jtimestamptz);
Datum
jgenerate_series_jtimestamptz(PG_FUNCTION_ARGS)
{
	return jt_series_srf(fcinfo, JT_SERIES_TIMESTAMPTZ);
}

PG_FUNCTION_INFO_V1(jgenerate_series_jtimestamptz_zone);
Datum
jgenerate_series_jtimestamptz_zone(PG_FUNCTION_ARGS)
{
	return jt_series_srf(fcinfo, JT_SERIES_TIMESTAMPTZ_ZONE);
}

PG_FUNCTION_INFO_V1(jgenerate_series_jdate_interval);
Datum
jgenerate_series_jdate_interval(PG_FUNCTION_ARGS)
{
	return jt_series_srf(fcinfo, JT_SERIES_DATE);
}

/*
 * jgenerate_series(jdate, jdate, int): one row per step of whole days, always
 * between the endpoints, so always valid. The arithmetic is in int64, so no step
 * overflows.
 */
typedef struct JtDaySeries
{
	int64		current;
	int32		finish;
	int32		step;
} JtDaySeries;

PG_FUNCTION_INFO_V1(jgenerate_series_jdate);
Datum
jgenerate_series_jdate(PG_FUNCTION_ARGS)
{
	FuncCallContext *funcctx;
	JtDaySeries *s;
	int64		result;

	if (SRF_IS_FIRSTCALL())
	{
		DateADT		start = PG_GETARG_DATEADT(0);
		DateADT		finish = PG_GETARG_DATEADT(1);
		int32		step = PG_GETARG_INT32(2);
		MemoryContext oldcontext;

		if (DATE_NOT_FINITE(start))
			jt_series_endpoint_error("start");
		if (DATE_NOT_FINITE(finish))
			jt_series_endpoint_error("stop");
		if (step == 0)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("step size cannot equal zero")));

		funcctx = SRF_FIRSTCALL_INIT();
		oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);
		s = (JtDaySeries *) palloc(sizeof(JtDaySeries));
		s->current = start;
		s->finish = finish;
		s->step = step;
		funcctx->user_fctx = s;
		MemoryContextSwitchTo(oldcontext);
	}

	funcctx = SRF_PERCALL_SETUP();
	s = (JtDaySeries *) funcctx->user_fctx;

	if (s->step > 0 ? s->current > s->finish : s->current < s->finish)
		SRF_RETURN_DONE(funcctx);

	result = s->current;
	s->current += s->step;
	jdate_check_range((DateADT) result);
	SRF_RETURN_NEXT(funcctx, DateADTGetDatum((DateADT) result));
}
