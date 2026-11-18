/*
 * jtimestamp_local.c -- Jalali months, and the local wall clock of an instant.
 *
 * What the interval arithmetic, date_bin, trunc and the EXTRACT code of the
 * jtimestamp and jtimestamptz types share. The contract is described with the
 * declarations in jdate_common.h; the short version is: an instant becomes a
 * Jalali date plus a time of day on one zone's clock, the caller edits that,
 * and the result becomes an instant again through core's own routines, so gaps
 * and overlaps behave exactly as they do for core's timestamptz.
 */
#include "postgres.h"
#include "fmgr.h"
#include "pgtime.h"
#include "utils/datetime.h"
#include "utils/timestamp.h"
#include "datatype/timestamp.h"

#include "jalaali.h"
#include "jdate_common.h"

/*
 * Jalali month arithmetic. The month count of a date is jy * 12 + (jm - 1);
 * adding n moves it to t, and floor division by 12 gives the year and the
 * remainder the month. C's / and % truncate toward zero, so a negative t is
 * fixed up to the floor.
 */
bool
jdate_add_months(const JalaaliDate *in, int32 months, JalaaliDate *out)
{
	int64		t = (int64) in->jy * 12 + (in->jm - 1) + months;
	int64		year = t / 12;
	int			month = (int) (t % 12);
	int			last;

	if (month < 0)
	{
		month += 12;
		year--;
	}

	if (year < JALAALI_MIN_YEAR || year > JALAALI_MAX_YEAR)
		return false;

	last = jalaali_month_length((int) year, month + 1);
	out->jd = in->jd < last ? in->jd : last;
	out->jy = (int) year;
	out->jm = month + 1;
	return true;
}

/*
 * The JDN of the Jalali date of a JtLocal, as the day count of the Postgres
 * epoch plus POSTGRES_EPOCH_JDATE. A date outside the supported years (or not a
 * date at all) is the same error as a result outside the range.
 */
static int
jt_local_jdn(const JtLocal *local)
{
	if (!jalaali_is_valid_date(local->date.jy, local->date.jm, local->date.jd))
		jdate_range_error();
	return jalaali_to_jdn(local->date.jy, local->date.jm, local->date.jd);
}

/* The time of day in microseconds, from the clock fields of a pg_tm. */
static int64
jt_time_of_day(const struct pg_tm *tm, fsec_t fsec)
{
	return (((int64) tm->tm_hour * MINS_PER_HOUR + tm->tm_min) * SECS_PER_MINUTE
			+ tm->tm_sec) * USECS_PER_SEC + fsec;
}

static void
jt_not_finite_error(void)
{
	ereport(ERROR,
			(errcode(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE),
			 errmsg("cannot convert an infinite timestamp to a calendar date")));
}

/* A jtimestamp has no zone: it is its own wall clock. */
void
jt_local_from_timestamp(Timestamp value, JtLocal *local)
{
	int64		days;
	int64		time;

	if (TIMESTAMP_NOT_FINITE(value))
		jt_not_finite_error();

	days = value / USECS_PER_DAY;
	time = value % USECS_PER_DAY;
	if (time < 0)
	{
		time += USECS_PER_DAY;
		days--;
	}

	/*
	 * |days| is below 1.1e8 for any int64, so the narrowing is safe; a stored
	 * value is in range, so a failure here is a damaged datum, which is
	 * refused as jtimestamp_out refuses it.
	 */
	if (!jalaali_from_jdn((int) days + POSTGRES_EPOCH_JDATE, &local->date))
		jdate_range_error();
	local->time = time;
	local->tz = 0;
}

/* An instant on the clock of a zone (NULL: the session zone). */
void
jt_local_from_instant(TimestampTz instant, pg_tz *zone, JtLocal *local)
{
	struct pg_tm tm;
	fsec_t		fsec;
	int			tz;

	if (TIMESTAMP_NOT_FINITE(instant))
		jt_not_finite_error();

	/* A NULL zone makes timestamp2tm use session_timezone. */
	if (timestamp2tm(instant, &tz, &tm, &fsec, NULL, zone) != 0)
		ereport(ERROR,
				(errcode(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE),
				 errmsg("timestamp out of range")));

	if (!jalaali_from_jdn(date2j(tm.tm_year, tm.tm_mon, tm.tm_mday), &local->date))
		jdate_range_error();
	local->time = jt_time_of_day(&tm, fsec);
	local->tz = tz;
}

Timestamp
jt_local_to_timestamp(const JtLocal *local)
{
	Timestamp	result;

	Assert(local->time >= 0 && local->time < USECS_PER_DAY);

	result = (int64) (jt_local_jdn(local) - POSTGRES_EPOCH_JDATE) * USECS_PER_DAY
		+ local->time;
	jtimestamp_check_range(result);
	return result;
}

/*
 * A wall time to an instant in a zone (NULL: the session zone). The offset is
 * DetermineTimeZoneOffset's: for a time that does not exist (a gap) it is the
 * offset before the change, which moves the result forward by the length of the
 * gap, and for a time that occurs twice it is the later one's (the second
 * occurrence, the offset after the change); the same
 * choice core makes for timestamptz + interval, date_trunc and timezone().
 */
TimestampTz
jt_local_to_instant(const JtLocal *local, pg_tz *zone)
{
	struct pg_tm tm;
	fsec_t		fsec;
	int			tz;
	int64		time = local->time;
	TimestampTz result;

	Assert(time >= 0 && time < USECS_PER_DAY);

	/* DetermineTimeZoneOffset needs a zone, unlike timestamp2tm */
	if (zone == NULL)
		zone = session_timezone;

	memset(&tm, 0, sizeof(tm));
	j2date(jt_local_jdn(local), &tm.tm_year, &tm.tm_mon, &tm.tm_mday);
	tm.tm_hour = (int) (time / USECS_PER_HOUR);
	time -= (int64) tm.tm_hour * USECS_PER_HOUR;
	tm.tm_min = (int) (time / USECS_PER_MINUTE);
	time -= (int64) tm.tm_min * USECS_PER_MINUTE;
	tm.tm_sec = (int) (time / USECS_PER_SEC);
	fsec = (fsec_t) (time - (int64) tm.tm_sec * USECS_PER_SEC);
	tm.tm_isdst = -1;

	tz = DetermineTimeZoneOffset(&tm, zone);
	if (tm2timestamp(&tm, fsec, &tz, &result) != 0)
		ereport(ERROR,
				(errcode(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE),
				 errmsg("timestamp out of range")));

	jtimestamptz_check_range(result);
	return result;
}
