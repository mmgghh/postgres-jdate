/*
 * jtimestamp_format.c -- jday_format and jmonth_format.
 *
 * jday_format(x, sep) is the text key YYYY<sep>MM<sep>DD of the Jalali day of x,
 * jmonth_format(x, sep) the key YYYY<sep>MM, for x a jdate, a jtimestamp or a
 * jtimestamptz. Both are STRICT (a NULL separator gives NULL) and the separator
 * is any text, '' included ('14030503').
 *
 * The year is printed as jdate_out prints it: four digits, and a sign for a
 * negative year that sits outside the padding ('-0061-05-03', never '-061'),
 * the month and the day on two digits. An infinite value gives the text jdate_out
 * gives, 'infinity' or '-infinity', whatever the separator and for both
 * functions.
 *
 * The day of a jtimestamptz is the day on the clock of the SESSION time zone,
 * so that version is STABLE. It is deliberately not IMMUTABLE and has no
 * explicit-zone variant: the index recipe is jday_format(ts AT TIME ZONE
 * 'Asia/Tehran') on a jtimestamp, whose function is IMMUTABLE. The functions are
 * written in C and not as SQL wrappers because an SQL function that calls
 * another function by name fails inside CREATE INDEX (the build runs with a
 * restricted search_path).
 *
 * The local date of a jtimestamptz comes from the shared local time helper
 * (src/jtimestamp_local.c), so the instant is turned into a date exactly as
 * EXTRACT, jdate_part and jdate_trunc do it.
 */
#include "postgres.h"
#include "fmgr.h"
#include "datatype/timestamp.h"
#include "utils/builtins.h"
#include "utils/date.h"
#include "utils/timestamp.h"
#include "varatt.h"

#include "jalaali.h"
#include "jdate_common.h"

/*
 * The text of the key for a date, as a text datum. with_day selects YYYY-MM-DD
 * over YYYY-MM.
 */
static text *
jt_key_text(const JalaaliDate *jd, text *sep, bool with_day)
{
	char	   *s = text_to_cstring(sep);
	char	   *result;

	if (with_day)
		result = psprintf("%s%04d%s%02d%s%02d", jd->jy < 0 ? "-" : "",
						  abs(jd->jy), s, jd->jm, s, jd->jd);
	else
		result = psprintf("%s%04d%s%02d", jd->jy < 0 ? "-" : "",
						  abs(jd->jy), s, jd->jm);

	return cstring_to_text(result);
}

/* the text of an infinite value, whatever the separator */
static text *
jt_key_infinity(bool is_nobegin)
{
	return cstring_to_text(is_nobegin ? "-infinity" : "infinity");
}

static Datum
jdate_key(FunctionCallInfo fcinfo, bool with_day)
{
	DateADT		value = PG_GETARG_DATEADT(0);
	text	   *sep = PG_GETARG_TEXT_PP(1);

	if (DATE_NOT_FINITE(value))
		PG_RETURN_TEXT_P(jt_key_infinity(DATE_IS_NOBEGIN(value)));

	{
		JalaaliDate jd = jdate_to_jalaali(value);

		PG_RETURN_TEXT_P(jt_key_text(&jd, sep, with_day));
	}
}

static Datum
jtimestamp_key(FunctionCallInfo fcinfo, bool with_day)
{
	Timestamp	value = PG_GETARG_TIMESTAMP(0);
	text	   *sep = PG_GETARG_TEXT_PP(1);
	JtLocal		local;

	if (TIMESTAMP_NOT_FINITE(value))
		PG_RETURN_TEXT_P(jt_key_infinity(TIMESTAMP_IS_NOBEGIN(value)));

	jt_local_from_timestamp(value, &local);
	PG_RETURN_TEXT_P(jt_key_text(&local.date, sep, with_day));
}

static Datum
jtimestamptz_key(FunctionCallInfo fcinfo, bool with_day)
{
	TimestampTz value = PG_GETARG_TIMESTAMPTZ(0);
	text	   *sep = PG_GETARG_TEXT_PP(1);
	JtLocal		local;

	if (TIMESTAMP_NOT_FINITE(value))
		PG_RETURN_TEXT_P(jt_key_infinity(TIMESTAMP_IS_NOBEGIN(value)));

	/* the session zone's clock */
	jt_local_from_instant(value, NULL, &local);
	PG_RETURN_TEXT_P(jt_key_text(&local.date, sep, with_day));
}

PG_FUNCTION_INFO_V1(jday_format_jdate);
Datum
jday_format_jdate(PG_FUNCTION_ARGS)
{
	return jdate_key(fcinfo, true);
}

PG_FUNCTION_INFO_V1(jday_format_jtimestamp);
Datum
jday_format_jtimestamp(PG_FUNCTION_ARGS)
{
	return jtimestamp_key(fcinfo, true);
}

PG_FUNCTION_INFO_V1(jday_format_jtimestamptz);
Datum
jday_format_jtimestamptz(PG_FUNCTION_ARGS)
{
	return jtimestamptz_key(fcinfo, true);
}

PG_FUNCTION_INFO_V1(jmonth_format_jdate);
Datum
jmonth_format_jdate(PG_FUNCTION_ARGS)
{
	return jdate_key(fcinfo, false);
}

PG_FUNCTION_INFO_V1(jmonth_format_jtimestamp);
Datum
jmonth_format_jtimestamp(PG_FUNCTION_ARGS)
{
	return jtimestamp_key(fcinfo, false);
}

PG_FUNCTION_INFO_V1(jmonth_format_jtimestamptz);
Datum
jmonth_format_jtimestamptz(PG_FUNCTION_ARGS)
{
	return jtimestamptz_key(fcinfo, false);
}
