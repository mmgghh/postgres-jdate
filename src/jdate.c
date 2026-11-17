#include "postgres.h"
#include "fmgr.h"
#include "libpq/pqformat.h"
#include "nodes/miscnodes.h"	/* soft errors (ereturn): PostgreSQL 16+ */
#include "parser/scansup.h"
#include "utils/builtins.h"
#include "utils/date.h"
#include "utils/datetime.h"
#include "utils/float.h"
#include "utils/fmgrprotos.h"
#include "utils/numeric.h"
#include "varatt.h"	/* split out of postgres.h in PostgreSQL 16 */
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

/*
 * The text of a Jalali date, shared by jdate_out and jdate_format so the two
 * cannot disagree: an optional "-", then the year as exactly four digits, then
 * "-MM-DD". A plain %04d would pad the sign into the width ("-061" rather
 * than "-0061"), so the magnitude is padded instead.
 */
static char *
jdate_format_ymd(const JalaaliDate *jd)
{
	return psprintf("%s%04d-%02d-%02d", jd->jy < 0 ? "-" : "",
					abs(jd->jy), jd->jm, jd->jd);
}

/*
 * The text of an infinite day, shared by jdate_out and jdate_format. The
 * caller has checked DATE_NOT_FINITE(value).
 */
static const char *
jdate_infinity_text(DateADT value)
{
	return DATE_IS_NOBEGIN(value) ? "-infinity" : "infinity";
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

/*
 * Outcome of parsing one "Y-M-D" string, so that jdate_in has a single place
 * per error kind to report it from.
 */
typedef enum JdateParseStatus
{
	JDATE_PARSE_OK,
	JDATE_PARSE_SYNTAX,			/* not of the form Y-M-D */
	JDATE_PARSE_OVERFLOW		/* a field does not fit in an int32 */
} JdateParseStatus;

static const char *
jdate_skip_space(const char *s)
{
	while (scanner_isspace(*s))
		s++;
	return s;
}

/*
 * Parse an optionally signed decimal integer starting exactly at *ptr (no
 * leading whitespace), advancing *ptr past it. Unlike sscanf's %d, which
 * silently truncates an out-of-range value to the low 32 bits, a value that
 * does not fit in an int32 is reported as overflow; redundant leading zeros
 * are not an overflow. The whole token is consumed either way, so the caller
 * can still tell a syntax error from an overflow.
 */
static JdateParseStatus
jdate_scan_int(const char **ptr, int *result)
{
	const char *s = *ptr;
	bool		neg = false;
	int64		limit;
	int64		acc = 0;
	bool		overflow = false;

	if (*s == '-')
	{
		neg = true;
		s++;
	}
	else if (*s == '+')
		s++;

	if (*s < '0' || *s > '9')
		return JDATE_PARSE_SYNTAX;

	/* INT32_MAX, or INT32_MIN's magnitude for a negative value. */
	limit = neg ? -(int64) PG_INT32_MIN : (int64) PG_INT32_MAX;
	for (; *s >= '0' && *s <= '9'; s++)
	{
		if (!overflow)
		{
			acc = acc * 10 + (*s - '0');
			if (acc > limit)
				overflow = true;
		}
	}

	*ptr = s;
	if (overflow)
		return JDATE_PARSE_OVERFLOW;
	*result = (int) (neg ? -acc : acc);
	return JDATE_PARSE_OK;
}

/*
 * Parse "Y-M-D" into three ints. The grammar is what the sscanf format
 * " %d - %d - %d " accepted: whitespace may surround the string and each
 * dash, and each field may carry a sign.
 */
static JdateParseStatus
jdate_parse(const char *str, int *jy, int *jm, int *jd)
{
	const char *s = jdate_skip_space(str);
	JdateParseStatus status;
	bool		overflow = false;
	int		   *fields[3] = {jy, jm, jd};

	for (int i = 0; i < 3; i++)
	{
		if (i > 0)
		{
			s = jdate_skip_space(s);
			if (*s != '-')
				return JDATE_PARSE_SYNTAX;
			s = jdate_skip_space(s + 1);
		}

		status = jdate_scan_int(&s, fields[i]);
		if (status == JDATE_PARSE_SYNTAX)
			return JDATE_PARSE_SYNTAX;
		if (status == JDATE_PARSE_OVERFLOW)
			overflow = true;
	}

	if (*jdate_skip_space(s) != '\0')
		return JDATE_PARSE_SYNTAX;

	/* A syntax error anywhere outranks an overflow, as with the old sscanf. */
	return overflow ? JDATE_PARSE_OVERFLOW : JDATE_PARSE_OK;
}

PG_FUNCTION_INFO_V1(jdate_in);
Datum
jdate_in(PG_FUNCTION_ARGS)
{
	char	   *str = PG_GETARG_CSTRING(0);

	/*
	 * Soft-error support (PostgreSQL 16+): when the caller passes an
	 * ErrorSaveContext, ereturn() records the error there and returns, which
	 * is what pg_input_is_valid, array_in and COPY ... ON_ERROR ignore rely
	 * on. Otherwise it is an ordinary ereport(ERROR).
	 */
	Node	   *escontext = fcinfo->context;
	int			jy,
				jm,
				jd;
	int			jdn;
	DateADT		result;

	if (pg_strcasecmp(str, "infinity") == 0)
		PG_RETURN_DATEADT(DATEVAL_NOEND);
	if (pg_strcasecmp(str, "-infinity") == 0)
		PG_RETURN_DATEADT(DATEVAL_NOBEGIN);

	/*
	 * Each failure below is a single ereturn at the outermost level, with no
	 * cleanup in between, so nothing needs undoing when it returns early.
	 */
	switch (jdate_parse(str, &jy, &jm, &jd))
	{
		case JDATE_PARSE_OK:
			break;
		case JDATE_PARSE_SYNTAX:
			ereturn(escontext, (Datum) 0,
					(errcode(ERRCODE_INVALID_DATETIME_FORMAT),
					 errmsg("invalid input syntax for type jdate: \"%s\"", str)));
			break;
		case JDATE_PARSE_OVERFLOW:
			ereturn(escontext, (Datum) 0,
					(errcode(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE),
					 errmsg("date out of range for type jdate: \"%s\"", str)));
			break;
	}

	if (!jalaali_is_valid_date(jy, jm, jd))
		ereturn(escontext, (Datum) 0,
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

	if (DATE_NOT_FINITE(value))
		result = pstrdup(jdate_infinity_text(value));
	else
	{
		JalaaliDate jd = jdate_to_jalaali(value);

		result = jdate_format_ymd(&jd);
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

/*
 * The seeded, 64-bit hash (support function 2 of the hash opclass), which
 * PARTITION BY HASH needs. It must hash exactly the values jdate_hash does,
 * so that the low 32 bits agree at seed 0.
 */
PG_FUNCTION_INFO_V1(jdate_hash_extended);
Datum
jdate_hash_extended(PG_FUNCTION_ARGS)
{
	return DirectFunctionCall2(hashint4extended, PG_GETARG_DATUM(0), PG_GETARG_DATUM(1));
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

/*
 * int + jdate, the commutation of jdate + int: swap the arguments and go
 * through jdate_pli, so the range check and the infinity handling are shared.
 */
PG_FUNCTION_INFO_V1(integer_pl_jdate);
Datum
integer_pl_jdate(PG_FUNCTION_ARGS)
{
	return DirectFunctionCall2(jdate_pli, PG_GETARG_DATUM(1), PG_GETARG_DATUM(0));
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
 * to_jdate(double precision) -- the inverse of EXTRACT(epoch FROM jdate): the
 * Jalali date of the UTC day that contains the given Unix timestamp.
 *
 * This is plain arithmetic on the epoch. Unlike core's to_timestamp(), which
 * yields a timestamptz whose calendar day depends on the session TimeZone,
 * the session zone plays no part here, so the result is the same in every
 * zone and the function is IMMUTABLE (usable in index expressions).
 */
PG_FUNCTION_INFO_V1(jdate_from_epoch);
Datum
jdate_from_epoch(PG_FUNCTION_ARGS)
{
	float8		epoch = PG_GETARG_FLOAT8(0);
	int64		secs;
	int64		days;
	DateADT		result;

	if (isinf(epoch))
		PG_RETURN_DATEADT(epoch < 0 ? DATEVAL_NOBEGIN : DATEVAL_NOEND);

	/*
	 * Reject anything outside the Jalali range before narrowing the double to
	 * an integer. The bounds are the epochs of the first instant of the first
	 * supported day and of the first instant after the last one: exact
	 * doubles (multiples of 86400, far below 2^53). The test is written
	 * negated so that NaN fails it too.
	 */
	if (!(epoch >= (double) (jalaali_min_jdn() - UNIX_EPOCH_JDATE) * SECS_PER_DAY &&
		  epoch < (double) (jalaali_max_jdn() - UNIX_EPOCH_JDATE + 1) * SECS_PER_DAY))
		jdate_range_error();

	/*
	 * Floor to whole seconds, then divide with integer floor division. C's /
	 * truncates toward zero, which would put the second before the Unix epoch
	 * (and every earlier negative second) on the wrong day.
	 */
	secs = (int64) floor(epoch);
	days = secs / SECS_PER_DAY;
	if (secs % SECS_PER_DAY < 0)
		days--;

	result = (DateADT) (days - (POSTGRES_EPOCH_JDATE - UNIX_EPOCH_JDATE));

	/* Cannot fail after the test above; it keeps the invariant in one place. */
	jdate_check_range(result);
	PG_RETURN_DATEADT(result);
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

static void
jdate_unsupported_unit(void)
{
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("unit not supported for jdate_part/extract")));
}

/*
 * The field of an infinite jdate, decided before any Jalali conversion (there
 * is no calendar date to convert), with the same answers as core's date: the
 * units that only grow (year, decade, century, epoch) are +/-Infinity, and
 * every unit that cycles (month, day, quarter, doy, dow, isodow) is NULL. The
 * time-of-day units, which are 0 for every finite date, are NULL as well
 * (core's timestamp gives NULL for them too; core's date rejects them).
 */
static double
jdate_get_infinite_field(DateADT value, int val, bool *isnull)
{
	switch (val)
	{
		case DTK_YEAR:
		case DTK_DECADE:
		case DTK_CENTURY:
		case DTK_EPOCH:
			return DATE_IS_NOBEGIN(value) ? -get_float8_infinity()
				: get_float8_infinity();
		case DTK_MONTH:
		case DTK_DAY:
		case DTK_QUARTER:
		case DTK_DOY:
		case DTK_DOW:
		case DTK_ISODOW:
		case DTK_HOUR:
		case DTK_MINUTE:
		case DTK_SECOND:
		case DTK_MILLISEC:
		case DTK_MICROSEC:
			*isnull = true;
			return 0;
		default:
			jdate_unsupported_unit();
			return 0;			/* keep compiler quiet */
	}
}

/*
 * The value of field "val" of a jdate, or NULL (*isnull set) when the field
 * has no value for infinity.
 */
static double
jdate_get_field(DateADT value, int val, bool *isnull)
{
	JalaaliDate jd;

	*isnull = false;

	if (DATE_NOT_FINITE(value))
		return jdate_get_infinite_field(value, val, isnull);

	/*
	 * Day-of-week and epoch do not depend on which calendar the date is read
	 * through, so they come straight from the day number, never from the
	 * Jalali fields.
	 */
	switch (val)
	{
		case DTK_DOW:
			return j2day(value + POSTGRES_EPOCH_JDATE);
		case DTK_ISODOW:
			{
				int			dow = j2day(value + POSTGRES_EPOCH_JDATE);

				return (dow == 0) ? 7 : dow;
			}
		case DTK_EPOCH:
			/* Seconds since 1970-01-01 UTC, exact in a double for this range */
			return (double) (((int64) value + POSTGRES_EPOCH_JDATE -
							  UNIX_EPOCH_JDATE) * SECS_PER_DAY);
		default:
			break;
	}

	jd = jdate_to_jalaali(value);

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
			/*
			 * The decade number, not its first year (core: decade 202 is
			 * 2020-2029). jy is numbered like core's astronomical year (year
			 * 0 exists), for which core's result is floor(year / 10); integer
			 * division truncates, so negative years are rounded down
			 * explicitly. Decade 0 is years 0..9, decade -1 is years -10..-1.
			 */
			return (jd.jy >= 0)
				? jd.jy / 10
				: -(((-jd.jy) + 9) / 10);
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
		default:
			jdate_unsupported_unit();
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
	bool		isnull;
	double		result = jdate_get_field(value, val, &isnull);

	if (isnull)
		PG_RETURN_NULL();
	PG_RETURN_FLOAT8(result);
}

PG_FUNCTION_INFO_V1(jdate_extract);
Datum
jdate_extract(PG_FUNCTION_ARGS)
{
	text	   *units = PG_GETARG_TEXT_PP(0);
	DateADT		value = PG_GETARG_DATEADT(1);
	int			val = jdate_decode_field(units);
	bool		isnull;
	double		result = jdate_get_field(value, val, &isnull);

	if (isnull)
		PG_RETURN_NULL();
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

	/* infinity has no time of day either: same text as jdate_out */
	if (DATE_NOT_FINITE(day))
		PG_RETURN_TEXT_P(cstring_to_text(jdate_infinity_text(day)));

	jd = jdate_to_jalaali(day);

	if (with_time)
	{
		char	   *time_str = DatumGetCString(DirectFunctionCall1(time_out,
														  DirectFunctionCall1(timestamp_time, local_ts)));

		result = psprintf("%s %s", jdate_format_ymd(&jd), time_str);
	}
	else
		result = jdate_format_ymd(&jd);

	PG_RETURN_TEXT_P(cstring_to_text(result));
}
