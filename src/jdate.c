#include "postgres.h"
#include "fmgr.h"
#include "libpq/pqformat.h"
#include "parser/scansup.h"
#include "utils/builtins.h"
#include "utils/date.h"
#include "utils/datetime.h"
#include "utils/fmgrprotos.h"
#include "utils/numeric.h"
#include "varatt.h"
#include "datatype/timestamp.h"

#include "jalaali.h"

PG_MODULE_MAGIC;

/*
 * The one error for "this day is outside the supported Jalali range", shared
 * by display (jdate_to_jalaali) and by every path that produces a jdate
 * (jdate_check_range), so no out-of-range value can be stored and then fail
 * on every later read.
 */
static void
jdate_range_error(void)
{
	ereport(ERROR,
			(errcode(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE),
			 errmsg("jdate value is outside the supported Jalali range (years %d to %d)",
					JALAALI_MIN_YEAR, JALAALI_MAX_YEAR)));
}

/*
 * Raise 22008 unless a finite value lies within the Jalali range. Infinity
 * and -infinity are always valid.
 */
static void
jdate_check_range(DateADT value)
{
	if (DATE_NOT_FINITE(value))
		return;

	if (value < jalaali_min_jdn() - POSTGRES_EPOCH_JDATE ||
		value > jalaali_max_jdn() - POSTGRES_EPOCH_JDATE)
		jdate_range_error();
}

static JalaaliDate
jdate_to_jalaali(DateADT value)
{
	JalaaliDate jd;

	if (DATE_NOT_FINITE(value))
		ereport(ERROR,
				(errcode(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE),
				 errmsg("cannot convert infinite jdate to a calendar date")));

	if (!jalaali_from_jdn(value + POSTGRES_EPOCH_JDATE, &jd))
		jdate_range_error();

	return jd;
}

/* ---------------------------------------------------------------------
 * Text I/O
 * ------------------------------------------------------------------- */

PG_FUNCTION_INFO_V1(jdate_in);
Datum
jdate_in(PG_FUNCTION_ARGS)
{
	char	   *str = PG_GETARG_CSTRING(0);
	int			jy,
				jm,
				jd,
				consumed = -1;
	int			jdn;
	DateADT		result;

	if (pg_strcasecmp(str, "infinity") == 0)
		PG_RETURN_DATEADT(DATEVAL_NOEND);
	if (pg_strcasecmp(str, "-infinity") == 0)
		PG_RETURN_DATEADT(DATEVAL_NOBEGIN);

	if (sscanf(str, " %d - %d - %d %n", &jy, &jm, &jd, &consumed) != 3
		|| consumed < 0 || str[consumed] != '\0')
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_DATETIME_FORMAT),
				 errmsg("invalid input syntax for type jdate: \"%s\"", str)));

	if (!jalaali_is_valid_date(jy, jm, jd))
		ereport(ERROR,
				(errcode(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE),
				 errmsg("date out of range for type jdate: \"%s\"", str)));

	jdn = jalaali_to_jdn(jy, jm, jd);
	result = jdn - POSTGRES_EPOCH_JDATE;
	PG_RETURN_DATEADT(result);
}

PG_FUNCTION_INFO_V1(jdate_out);
Datum
jdate_out(PG_FUNCTION_ARGS)
{
	DateADT		value = PG_GETARG_DATEADT(0);
	char	   *result;

	if (DATE_IS_NOBEGIN(value))
		result = pstrdup("-infinity");
	else if (DATE_IS_NOEND(value))
		result = pstrdup("infinity");
	else
	{
		JalaaliDate jd = jdate_to_jalaali(value);

		/* %04d pads the sign into the width for a negative year (giving
		 * "-061" rather than "-0061"); pad the magnitude instead so the
		 * year is always exactly 4 digits regardless of sign. */
		result = psprintf("%s%04d-%02d-%02d", jd.jy < 0 ? "-" : "",
						   abs(jd.jy), jd.jm, jd.jd);
	}
	PG_RETURN_CSTRING(result);
}

PG_FUNCTION_INFO_V1(jdate_recv);
Datum
jdate_recv(PG_FUNCTION_ARGS)
{
	StringInfo	buf = (StringInfo) PG_GETARG_POINTER(0);
	DateADT		result = (DateADT) pq_getmsgint(buf, sizeof(int32));

	/*
	 * The wire format is date's, and a date can hold far more days than the
	 * Jalali range, so a binary COPY or a binary-protocol parameter could
	 * otherwise store a value that can never be displayed. Infinity and
	 * -infinity pass.
	 */
	jdate_check_range(result);
	PG_RETURN_DATEADT(result);
}

PG_FUNCTION_INFO_V1(jdate_send);
Datum
jdate_send(PG_FUNCTION_ARGS)
{
	DateADT		value = PG_GETARG_DATEADT(0);
	StringInfoData buf;

	pq_begintypsend(&buf);
	pq_sendint32(&buf, value);
	PG_RETURN_BYTEA_P(pq_endtypsend(&buf));
}

/* ---------------------------------------------------------------------
 * Comparison -- thin wrappers around Postgres's own date_* functions,
 * valid because jdate shares date's exact int32 (JDN-offset) representation.
 * ------------------------------------------------------------------- */

PG_FUNCTION_INFO_V1(jdate_eq);
Datum
jdate_eq(PG_FUNCTION_ARGS)
{
	return DirectFunctionCall2(date_eq, PG_GETARG_DATUM(0), PG_GETARG_DATUM(1));
}

PG_FUNCTION_INFO_V1(jdate_ne);
Datum
jdate_ne(PG_FUNCTION_ARGS)
{
	return DirectFunctionCall2(date_ne, PG_GETARG_DATUM(0), PG_GETARG_DATUM(1));
}

PG_FUNCTION_INFO_V1(jdate_lt);
Datum
jdate_lt(PG_FUNCTION_ARGS)
{
	return DirectFunctionCall2(date_lt, PG_GETARG_DATUM(0), PG_GETARG_DATUM(1));
}

PG_FUNCTION_INFO_V1(jdate_le);
Datum
jdate_le(PG_FUNCTION_ARGS)
{
	return DirectFunctionCall2(date_le, PG_GETARG_DATUM(0), PG_GETARG_DATUM(1));
}

PG_FUNCTION_INFO_V1(jdate_gt);
Datum
jdate_gt(PG_FUNCTION_ARGS)
{
	return DirectFunctionCall2(date_gt, PG_GETARG_DATUM(0), PG_GETARG_DATUM(1));
}

PG_FUNCTION_INFO_V1(jdate_ge);
Datum
jdate_ge(PG_FUNCTION_ARGS)
{
	return DirectFunctionCall2(date_ge, PG_GETARG_DATUM(0), PG_GETARG_DATUM(1));
}

PG_FUNCTION_INFO_V1(jdate_cmp);
Datum
jdate_cmp(PG_FUNCTION_ARGS)
{
	return DirectFunctionCall2(date_cmp, PG_GETARG_DATUM(0), PG_GETARG_DATUM(1));
}

PG_FUNCTION_INFO_V1(jdate_hash);
Datum
jdate_hash(PG_FUNCTION_ARGS)
{
	return DirectFunctionCall1(hashint4, PG_GETARG_DATUM(0));
}

PG_FUNCTION_INFO_V1(jdate_smaller);
Datum
jdate_smaller(PG_FUNCTION_ARGS)
{
	return DirectFunctionCall2(date_smaller, PG_GETARG_DATUM(0), PG_GETARG_DATUM(1));
}

PG_FUNCTION_INFO_V1(jdate_larger);
Datum
jdate_larger(PG_FUNCTION_ARGS)
{
	return DirectFunctionCall2(date_larger, PG_GETARG_DATUM(0), PG_GETARG_DATUM(1));
}

/* ---------------------------------------------------------------------
 * Arithmetic
 * ------------------------------------------------------------------- */

/*
 * Core's date_pli/date_mii handle infinity and int32 overflow; the result
 * must then also lie within the Jalali range.
 */
PG_FUNCTION_INFO_V1(jdate_pli);
Datum
jdate_pli(PG_FUNCTION_ARGS)
{
	DateADT		result = DatumGetDateADT(DirectFunctionCall2(date_pli, PG_GETARG_DATUM(0), PG_GETARG_DATUM(1)));

	jdate_check_range(result);
	PG_RETURN_DATEADT(result);
}

PG_FUNCTION_INFO_V1(jdate_mii);
Datum
jdate_mii(PG_FUNCTION_ARGS)
{
	DateADT		result = DatumGetDateADT(DirectFunctionCall2(date_mii, PG_GETARG_DATUM(0), PG_GETARG_DATUM(1)));

	jdate_check_range(result);
	PG_RETURN_DATEADT(result);
}

PG_FUNCTION_INFO_V1(jdate_mi);
Datum
jdate_mi(PG_FUNCTION_ARGS)
{
	return DirectFunctionCall2(date_mi, PG_GETARG_DATUM(0), PG_GETARG_DATUM(1));
}

/* ---------------------------------------------------------------------
 * Casts to/from date, timestamp and timestamptz. jdate and date share one
 * int32 representation (days since 2000-01-01), so converting jdate to
 * date/timestamp[tz] delegates to core and is always valid. The other
 * direction (date/timestamp[tz] -> jdate) accepts days that core's wider
 * calendar allows but the Jalali algorithm cannot represent, so it
 * validates the range.
 * ------------------------------------------------------------------- */

PG_FUNCTION_INFO_V1(date_jdate);
Datum
date_jdate(PG_FUNCTION_ARGS)
{
	DateADT		value = PG_GETARG_DATEADT(0);

	jdate_check_range(value);
	PG_RETURN_DATEADT(value);
}

PG_FUNCTION_INFO_V1(jdate_timestamp);
Datum
jdate_timestamp(PG_FUNCTION_ARGS)
{
	return DirectFunctionCall1(date_timestamp, PG_GETARG_DATUM(0));
}

PG_FUNCTION_INFO_V1(jdate_timestamptz);
Datum
jdate_timestamptz(PG_FUNCTION_ARGS)
{
	return DirectFunctionCall1(date_timestamptz, PG_GETARG_DATUM(0));
}

PG_FUNCTION_INFO_V1(timestamp_jdate);
Datum
timestamp_jdate(PG_FUNCTION_ARGS)
{
	DateADT		result = DatumGetDateADT(DirectFunctionCall1(timestamp_date, PG_GETARG_DATUM(0)));

	jdate_check_range(result);
	PG_RETURN_DATEADT(result);
}

PG_FUNCTION_INFO_V1(timestamptz_jdate);
Datum
timestamptz_jdate(PG_FUNCTION_ARGS)
{
	DateADT		result = DatumGetDateADT(DirectFunctionCall1(timestamptz_date, PG_GETARG_DATUM(0)));

	jdate_check_range(result);
	PG_RETURN_DATEADT(result);
}

/*
 * to_jdate(double precision) -- the inverse of EXTRACT(epoch FROM jdate),
 * mirroring core's own to_timestamp(double precision). Unlike epoch
 * extraction, going the other way genuinely needs a calendar day, which
 * depends on the session's TimeZone -- same as the timestamptz -> jdate
 * cast above, this just chains onto it via a plain float8 -> timestamptz
 * conversion first.
 */
PG_FUNCTION_INFO_V1(jdate_from_epoch);
Datum
jdate_from_epoch(PG_FUNCTION_ARGS)
{
	float8		epoch = PG_GETARG_FLOAT8(0);
	Datum		ts = DirectFunctionCall1(float8_timestamptz, Float8GetDatum(epoch));

	return DirectFunctionCall1(timestamptz_date, ts);
}

/* ---------------------------------------------------------------------
 * jdate_part / extract / jdate_trunc
 * ------------------------------------------------------------------- */

static int
jdate_decode_field(text *units)
{
	char	   *lowunits;
	int			type,
				val;

	lowunits = downcase_truncate_identifier(VARDATA_ANY(units),
											 VARSIZE_ANY_EXHDR(units),
											 false);
	type = DecodeUnits(0, lowunits, &val);
	if (type == UNKNOWN_FIELD)
		type = DecodeSpecial(0, lowunits, &val);

	/*
	 * "epoch" decodes as a RESERV special token (like "infinity"), not a
	 * UNITS token -- core's own extract_date() treats it as a field name
	 * anyway, so accept that one specific RESERV value here too.
	 */
	if (type != UNITS && !(type == RESERV && val == DTK_EPOCH))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("unit \"%s\" not recognized for type jdate", lowunits)));
	return val;
}

static double
jdate_get_field(DateADT value, int val)
{
	JalaaliDate jd = jdate_to_jalaali(value);

	switch (val)
	{
		case DTK_YEAR:
			return jd.jy;
		case DTK_MONTH:
			return jd.jm;
		case DTK_DAY:
			return jd.jd;
		case DTK_QUARTER:
			return (jd.jm - 1) / 3 + 1;
		case DTK_DOY:
			return (jd.jm <= 6)
				? (jd.jm - 1) * 31 + jd.jd
				: 186 + (jd.jm - 7) * 30 + jd.jd;
		case DTK_DECADE:
			return (jd.jy >= 0)
				? (jd.jy / 10) * 10
				: -(((-jd.jy) + 9) / 10) * 10;
		case DTK_CENTURY:
			return (jd.jy >= 1)
				? (jd.jy + 99) / 100
				: -(((-jd.jy) + 100) / 100);
		case DTK_HOUR:
		case DTK_MINUTE:
		case DTK_SECOND:
		case DTK_MILLISEC:
		case DTK_MICROSEC:
			return 0;
		case DTK_DOW:
		case DTK_ISODOW:
			/* Day-of-week doesn't depend on which calendar you read the
			 * date through, so reuse core's own (Gregorian-side) answer
			 * for the identical underlying day. */
			return DatumGetFloat8(DirectFunctionCall1(numeric_float8,
													   DirectFunctionCall2(extract_date,
																			PointerGetDatum(cstring_to_text(val == DTK_DOW ? "dow" : "isodow")),
																			DateADTGetDatum(value))));
		case DTK_EPOCH:
			/* Likewise calendar-agnostic: a Unix timestamp counts seconds
			 * since 1970-01-01 UTC regardless of which calendar the date
			 * is displayed in, so this is the same day for both. */
			return DatumGetFloat8(DirectFunctionCall1(numeric_float8,
													   DirectFunctionCall2(extract_date,
																			PointerGetDatum(cstring_to_text("epoch")),
																			DateADTGetDatum(value))));
		default:
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("unit not supported for jdate_part/extract")));
			return 0;			/* keep compiler quiet */
	}
}

PG_FUNCTION_INFO_V1(jdate_part);
Datum
jdate_part(PG_FUNCTION_ARGS)
{
	text	   *units = PG_GETARG_TEXT_PP(0);
	DateADT		value = PG_GETARG_DATEADT(1);
	int			val = jdate_decode_field(units);

	PG_RETURN_FLOAT8(jdate_get_field(value, val));
}

PG_FUNCTION_INFO_V1(jdate_extract);
Datum
jdate_extract(PG_FUNCTION_ARGS)
{
	text	   *units = PG_GETARG_TEXT_PP(0);
	DateADT		value = PG_GETARG_DATEADT(1);
	int			val = jdate_decode_field(units);
	double		result = jdate_get_field(value, val);

	return DirectFunctionCall1(float8_numeric, Float8GetDatum(result));
}

PG_FUNCTION_INFO_V1(jdate_trunc);
Datum
jdate_trunc(PG_FUNCTION_ARGS)
{
	text	   *units = PG_GETARG_TEXT_PP(0);
	DateADT		value = PG_GETARG_DATEADT(1);
	int			val = jdate_decode_field(units);
	JalaaliDate jd;
	int			jdn;

	if (DATE_NOT_FINITE(value))
		PG_RETURN_DATEADT(value);

	jd = jdate_to_jalaali(value);

	switch (val)
	{
		case DTK_YEAR:
			jd.jm = 1;
			jd.jd = 1;
			break;
		case DTK_QUARTER:
			jd.jm = ((jd.jm - 1) / 3) * 3 + 1;
			jd.jd = 1;
			break;
		case DTK_MONTH:
			jd.jd = 1;
			break;
		case DTK_DAY:
			break;
		default:
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("unit not supported for jdate_trunc")));
	}

	jdn = jalaali_to_jdn(jd.jy, jd.jm, jd.jd);
	PG_RETURN_DATEADT((DateADT) (jdn - POSTGRES_EPOCH_JDATE));
}

/* ---------------------------------------------------------------------
 * Bridge formatting: Jalali date + (calendar-agnostic) local clock time
 * for a timestamptz, respecting the session's TimeZone -- unlike the
 * hardcoded Asia/Tehran of the extension this supersedes.
 * ------------------------------------------------------------------- */

PG_FUNCTION_INFO_V1(jdate_format_timestamptz);
Datum
jdate_format_timestamptz(PG_FUNCTION_ARGS)
{
	TimestampTz ts = PG_GETARG_TIMESTAMPTZ(0);
	bool		with_time = PG_GETARG_BOOL(1);
	Datum		local_ts;
	DateADT		day;
	JalaaliDate jd;
	char	   *result;

	local_ts = DirectFunctionCall1(timestamptz_timestamp, TimestampTzGetDatum(ts));
	day = DatumGetDateADT(DirectFunctionCall1(timestamp_date, local_ts));
	jd = jdate_to_jalaali(day);

	if (with_time)
	{
		char	   *time_str = DatumGetCString(DirectFunctionCall1(time_out,
														  DirectFunctionCall1(timestamp_time, local_ts)));

		result = psprintf("%04d-%02d-%02d %s", jd.jy, jd.jm, jd.jd, time_str);
	}
	else
		result = psprintf("%04d-%02d-%02d", jd.jy, jd.jm, jd.jd);

	PG_RETURN_TEXT_P(cstring_to_text(result));
}
