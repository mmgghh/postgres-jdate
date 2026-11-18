/*
 * jtimestamp.c -- the jtimestamp and jtimestamptz types: a timestamp (without
 * and with time zone) written and read with a Jalali date.
 *
 * Both types have exactly the representation of the core type they mirror (an
 * int64 of microseconds since 2000-01-01 00:00:00, infinities at the int64
 * extremes; for jtimestamptz a UTC instant). Only the text form differs: the
 * date part is Jalali, and the time part (and the zone, for jtimestamptz) is
 * whatever core's parser and printer do with it. So input converts the Jalali
 * date prefix to Gregorian and hands the whole string to timestamp_in or
 * timestamptz_in, and output prints with core's EncodeDateTime and swaps in the
 * Jalali date.
 *
 * Every value that can be stored lies within the Jalali range (see
 * jtimestamp_in_range and jtimestamptz_in_range in jdate_common.h), so it can
 * always be displayed; for jtimestamptz, in any session time zone.
 */
#include "postgres.h"
#include "fmgr.h"
#include "libpq/pqformat.h"
#include "miscadmin.h"		/* USE_ISO_DATES */
#include "nodes/miscnodes.h"	/* soft errors (ereturn): PostgreSQL 16+ */
#include "parser/scansup.h"
#include "utils/builtins.h"
#include "utils/date.h"
#include "utils/datetime.h"
#include "utils/fmgrprotos.h"
#include "utils/timestamp.h"
#include "datatype/timestamp.h"

#include "jalaali.h"
#include "jdate_common.h"

/*
 * The words core's timestamp_in turns into a special value that we accept
 * without a Jalali date. Matched exactly (the whole string apart from
 * surrounding whitespace, case-insensitive), so that no Gregorian spelling gets
 * through to core. "allballs" is not here: it is a time-only word that core
 * rejects for timestamp.
 */
static const char *const jtimestamp_special_words[] = {
	"infinity", "-infinity", "now", "today", "tomorrow", "yesterday", "epoch"
};

/*
 * If str is one of the special words, possibly with whitespace before and after
 * it (as core accepts, and as jdate_in accepts around a date), return the word
 * alone in a palloc'd string; otherwise NULL. Whitespace inside the word (a
 * space after the minus sign) is not accepted. The caller hands the trimmed
 * word to core, so what core does with whitespace does not matter here.
 */
static char *
jtimestamp_special_word(const char *str)
{
	const char *start = str;
	const char *stop = str + strlen(str);

	while (scanner_isspace(*start))
		start++;
	while (stop > start && scanner_isspace(stop[-1]))
		stop--;

	for (size_t i = 0; i < lengthof(jtimestamp_special_words); i++)
	{
		const char *word = jtimestamp_special_words[i];

		if (strlen(word) == (size_t) (stop - start) &&
			pg_strncasecmp(start, word, stop - start) == 0)
			return pnstrdup(start, stop - start);
	}
	return NULL;
}

/*
 * Run core's input function (timestamp_in or timestamptz_in) on text, with the
 * typmod, and report a failure the way jtimestamp_in does. The caller's text is
 * in str (for the message); the text core sees is gregorian_str; typname is our
 * type's name, for the messages. Returns false after saving a soft error into
 * escontext (or raising it, when escontext is NULL).
 *
 * Core fails with a message about type timestamp and, when the text was
 * converted, about a Gregorian string the user never wrote. The SQLSTATE is
 * what matters (22007 syntax, 22008 field out of range, 22009 or 22023 for the
 * zone), so it is kept and the message is rewritten with our type name.
 *
 * PostgreSQL versions. This relies on two things that are new in 16:
 * DirectInputFunctionCallSafe (the soft-error API; the extension needs 16 or
 * later anyway) and core's timestamp_in / timestamptz_in reporting their parse
 * errors softly, into the ErrorSaveContext handed to them (the jt_softerr test
 * ran green on 16 up to its COPY ... ON_ERROR statements, which are 17 and later).
 * If core's input were not soft (a build or fork whose date/time input still
 * raises), the error would be raised from inside core and never reach the code
 * below: the SQLSTATE would still be core's (22007, 22008, 22009, 22023) but the
 * message would name type timestamp and the Gregorian text the user never wrote,
 * and pg_input_is_valid, pg_input_error_info and COPY ... ON_ERROR would raise
 * where they should answer false or skip the row. Valid input is not affected,
 * and the errors this extension finds itself (the special-word, Jalali date
 * and range checks) are soft whatever core does.
 */
static bool
jtimestamp_call_core(PGFunction core_in, const char *typname, const char *str,
					 char *gregorian_str, int32 typmod, Node *escontext,
					 int64 *result)
{
	ErrorSaveContext local = {.type = T_ErrorSaveContext, .details_wanted = true};
	Datum		datum;

	if (DirectInputFunctionCallSafe(core_in, gregorian_str, InvalidOid,
									typmod, (Node *) &local, &datum))
	{
		/* Timestamp and TimestampTz are both int64 */
		*result = DatumGetInt64(datum);
		return true;
	}

	switch (local.error_data->sqlerrcode)
	{
		case ERRCODE_INVALID_DATETIME_FORMAT:
			errsave(escontext,
					(errcode(ERRCODE_INVALID_DATETIME_FORMAT),
					 errmsg("invalid input syntax for type %s: \"%s\"", typname, str)));
			break;
		case ERRCODE_DATETIME_VALUE_OUT_OF_RANGE:
			errsave(escontext,
					(errcode(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE),
					 errmsg("date/time field value out of range for type %s: \"%s\"", typname, str)));
			break;
		default:

			/*
			 * An unknown time zone, a displacement out of range and the like.
			 * Core's message says what is wrong; keep it as the detail.
			 */
			errsave(escontext,
					(errcode(local.error_data->sqlerrcode),
					 errmsg("invalid input for type %s: \"%s\"", typname, str),
					 errdetail_internal("%s", local.error_data->message)));
			break;
	}
	return false;
}

/*
 * The input function of both types: the Jalali date prefix (or one of the
 * special words), converted to a Gregorian string and run through core's input
 * function. Returns false after saving a soft error into escontext; on true
 * *result is core's value, with the typmod applied but not yet checked against
 * the Jalali range, which is the caller's next step.
 */
static bool
jtimestamp_input(PGFunction core_in, const char *typname, char *str,
				 int32 typmod, Node *escontext, int64 *result)
{
	const char *end;
	int			jy,
				jm,
				jd;
	char	   *core_str;

	switch (jdate_scan_ymd(str, &end, &jy, &jm, &jd))
	{
		case JDATE_PARSE_OK:
			{
				int			gy,
							gm,
							gd;

				if (!jalaali_is_valid_date(jy, jm, jd))
				{
					errsave(escontext,
							(errcode(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE),
							 errmsg("date out of range for type %s: \"%s\"", typname, str)));
					return false;
				}

				/*
				 * The Jalali range is Gregorian 0560-03-20 .. 3799-03-19, so
				 * the year always has four digits and never needs an era. The
				 * rest of the string, with its separator (and for jtimestamptz
				 * its zone), goes to core as is.
				 */
				jalaali_jdn_to_gregorian(jalaali_to_jdn(jy, jm, jd), &gy, &gm, &gd);
				core_str = psprintf("%04d-%02d-%02d%s", gy, gm, gd, end);
			}
			break;

		case JDATE_PARSE_OVERFLOW:
			errsave(escontext,
					(errcode(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE),
					 errmsg("date out of range for type %s: \"%s\"", typname, str)));
			return false;

		case JDATE_PARSE_SYNTAX:
		default:
			core_str = jtimestamp_special_word(str);
			if (core_str == NULL)
			{
				errsave(escontext,
						(errcode(ERRCODE_INVALID_DATETIME_FORMAT),
						 errmsg("invalid input syntax for type %s: \"%s\"", typname, str)));
				return false;
			}
			break;
	}

	return jtimestamp_call_core(core_in, typname, str, core_str, typmod,
								escontext, result);
}

PG_FUNCTION_INFO_V1(jtimestamp_in);
Datum
jtimestamp_in(PG_FUNCTION_ARGS)
{
	char	   *str = PG_GETARG_CSTRING(0);

	/* argument 1 is the type's own OID, which we do not need */
	int32		typmod = PG_GETARG_INT32(2);

	/* Soft-error support, as in jdate_in (PostgreSQL 16+). */
	Node	   *escontext = fcinfo->context;
	int64		result;

	if (!jtimestamp_input(timestamp_in, "jtimestamp", str, typmod, escontext,
						  &result))
		PG_RETURN_NULL();

	/*
	 * After core's own range check and after its rounding to the typmod: a
	 * value that is in core's range can still be outside the Jalali one (a BC
	 * token, or rounding up past the last microsecond).
	 */
	if (!jtimestamp_in_range(result))
	{
		jdate_range_errsave(escontext);
		PG_RETURN_NULL();
	}

	PG_RETURN_TIMESTAMP(result);
}

PG_FUNCTION_INFO_V1(jtimestamp_out);
Datum
jtimestamp_out(PG_FUNCTION_ARGS)
{
	Timestamp	value = PG_GETARG_TIMESTAMP(0);
	struct pg_tm tm;
	fsec_t		fsec;
	JalaaliDate jd;
	char		buf[MAXDATELEN + 1];

	if (TIMESTAMP_NOT_FINITE(value))
		PG_RETURN_CSTRING(pstrdup(TIMESTAMP_IS_NOBEGIN(value) ? "-infinity" : "infinity"));

	if (timestamp2tm(value, NULL, &tm, &fsec, NULL, NULL) != 0)
		ereport(ERROR,
				(errcode(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE),
				 errmsg("timestamp out of range")));

	/* DateStyle is ignored: ISO text, as jdate_out. */
	EncodeDateTime(&tm, fsec, false, 0, NULL, USE_ISO_DATES, buf);

	/*
	 * A stored value is always in the Jalali range, so the Gregorian year is
	 * four digits and the date is the first ten characters of the ISO text. A
	 * value that is not (a damaged datum) is refused here, as jdate_out does.
	 */
	if (!jalaali_from_jdn(date2j(tm.tm_year, tm.tm_mon, tm.tm_mday), &jd))
		jdate_range_error();
	Assert(buf[10] == ' ' || buf[10] == '\0');

	PG_RETURN_CSTRING(psprintf("%s%s", jdate_format_ymd(&jd), buf + 10));
}

PG_FUNCTION_INFO_V1(jtimestamp_recv);
Datum
jtimestamp_recv(PG_FUNCTION_ARGS)
{
	Timestamp	result;

	/*
	 * The wire format is timestamp's. Core reads it, checks it against its own
	 * limits and applies the typmod; ours is the narrower Jalali range, which
	 * a binary COPY or a binary-protocol parameter could otherwise exceed with
	 * a value that could then never be displayed.
	 */
	result = DatumGetTimestamp(DirectFunctionCall3(timestamp_recv,
												   PG_GETARG_DATUM(0),
												   PG_GETARG_DATUM(1),
												   PG_GETARG_DATUM(2)));
	jtimestamp_check_range(result);
	PG_RETURN_TIMESTAMP(result);
}

PG_FUNCTION_INFO_V1(jtimestamp_send);
Datum
jtimestamp_send(PG_FUNCTION_ARGS)
{
	return DirectFunctionCall1(timestamp_send, PG_GETARG_DATUM(0));
}

/*
 * The type modifier as text, "(p)". Core's timestamptypmodout would print
 * "(p) without time zone" and so make format_type say
 * "jtimestamp(3) without time zone".
 */
PG_FUNCTION_INFO_V1(jtimestamp_typmodout);
Datum
jtimestamp_typmodout(PG_FUNCTION_ARGS)
{
	int32		typmod = PG_GETARG_INT32(0);

	if (typmod >= 0)
		PG_RETURN_CSTRING(psprintf("(%d)", (int) typmod));
	PG_RETURN_CSTRING(pstrdup(""));
}

/* ---------------------------------------------------------------------
 * jtimestamptz
 *
 * The valid range is the "safe range" of jtimestamptz_in_range, so a stored
 * instant shows a Jalali day in every session time zone.
 * ------------------------------------------------------------------- */

PG_FUNCTION_INFO_V1(jtimestamptz_in);
Datum
jtimestamptz_in(PG_FUNCTION_ARGS)
{
	char	   *str = PG_GETARG_CSTRING(0);

	/* argument 1 is the type's own OID, which we do not need */
	int32		typmod = PG_GETARG_INT32(2);
	Node	   *escontext = fcinfo->context;
	int64		result;

	/*
	 * A zone in the text is core's business (Z, +03:30, +03:30:15, names,
	 * abbreviations); with none, core uses the session TimeZone.
	 */
	if (!jtimestamp_input(timestamptz_in, "jtimestamptz", str, typmod, escontext,
						  &result))
		PG_RETURN_NULL();

	/* After core's range check and its rounding to the typmod, as jtimestamp_in. */
	if (!jtimestamptz_in_range(result))
	{
		jdate_range_errsave(escontext);
		PG_RETURN_NULL();
	}

	PG_RETURN_TIMESTAMPTZ(result);
}

PG_FUNCTION_INFO_V1(jtimestamptz_out);
Datum
jtimestamptz_out(PG_FUNCTION_ARGS)
{
	TimestampTz value = PG_GETARG_TIMESTAMPTZ(0);
	int			tz;
	struct pg_tm tm;
	fsec_t		fsec;
	const char *tzn;
	JalaaliDate jd;
	char		buf[MAXDATELEN + 1];

	if (TIMESTAMP_NOT_FINITE(value))
		PG_RETURN_CSTRING(pstrdup(TIMESTAMP_IS_NOBEGIN(value) ? "-infinity" : "infinity"));

	/* The local time in the session time zone */
	if (timestamp2tm(value, &tz, &tm, &fsec, &tzn, NULL) != 0)
		ereport(ERROR,
				(errcode(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE),
				 errmsg("timestamp out of range")));

	/*
	 * DateStyle is ignored: ISO text, always with a numeric offset (+HH,
	 * +HH:MM or +HH:MM:SS, as core's ISO style prints it).
	 */
	EncodeDateTime(&tm, fsec, true, tz, tzn, USE_ISO_DATES, buf);

	/*
	 * A stored instant is inside the safe range, so its local date is inside
	 * the Jalali range for every zone (offsets reach +/-15:59:59, the margin
	 * is 16 hours); a value that is not (a damaged datum) is refused here.
	 */
	if (!jalaali_from_jdn(date2j(tm.tm_year, tm.tm_mon, tm.tm_mday), &jd))
		jdate_range_error();
	Assert(buf[10] == ' ' || buf[10] == '\0');

	PG_RETURN_CSTRING(psprintf("%s%s", jdate_format_ymd(&jd), buf + 10));
}

PG_FUNCTION_INFO_V1(jtimestamptz_recv);
Datum
jtimestamptz_recv(PG_FUNCTION_ARGS)
{
	TimestampTz result;

	/* As jtimestamp_recv: core's wire format and checks, then the safe range. */
	result = DatumGetTimestampTz(DirectFunctionCall3(timestamptz_recv,
													 PG_GETARG_DATUM(0),
													 PG_GETARG_DATUM(1),
													 PG_GETARG_DATUM(2)));
	jtimestamptz_check_range(result);
	PG_RETURN_TIMESTAMPTZ(result);
}

PG_FUNCTION_INFO_V1(jtimestamptz_send);
Datum
jtimestamptz_send(PG_FUNCTION_ARGS)
{
	return DirectFunctionCall1(timestamptz_send, PG_GETARG_DATUM(0));
}

/*
 * to_jtimestamptz(double precision) -- the instant of a Unix timestamp, as
 * core's to_timestamp(double precision) gives it (microseconds, rounded), but
 * of our type: the same bounds as to_jdate (NaN and anything outside the days
 * of the Jalali range are 22008, +/-Infinity are the infinities) and then the
 * safe-range check on the result. The session zone plays no part, so the
 * function is IMMUTABLE.
 */
PG_FUNCTION_INFO_V1(jtimestamptz_from_epoch);
Datum
jtimestamptz_from_epoch(PG_FUNCTION_ARGS)
{
	float8		epoch = PG_GETARG_FLOAT8(0);
	TimestampTz result;

	if (isinf(epoch))
		PG_RETURN_TIMESTAMPTZ(epoch < 0 ? DT_NOBEGIN : DT_NOEND);

	/* Also rejects NaN, and keeps the conversion below far from overflow. */
	if (!jdate_epoch_in_range(epoch))
		jdate_range_error();

	result = DatumGetTimestampTz(DirectFunctionCall1(float8_timestamptz,
													 Float8GetDatum(epoch)));
	jtimestamptz_check_range(result);
	PG_RETURN_TIMESTAMPTZ(result);
}

/* ---------------------------------------------------------------------
 * Casts
 *
 * jtimestamp -> timestamp and jtimestamptz -> timestamptz are binary
 * coercions (WITHOUT FUNCTION, no code here): every stored value is a valid
 * core value. Every cast INTO a Jalali type that can produce a value outside
 * the Jalali range runs its result through the range check; the casts out of a
 * Jalali type into jdate need none, because a valid value always lies within
 * the Jalali days (for jtimestamptz, in every session zone: that is what the
 * safe range is for).
 * ------------------------------------------------------------------- */

PG_FUNCTION_INFO_V1(timestamp_jtimestamp);
Datum
timestamp_jtimestamp(PG_FUNCTION_ARGS)
{
	Timestamp	value = PG_GETARG_TIMESTAMP(0);

	jtimestamp_check_range(value);
	PG_RETURN_TIMESTAMP(value);
}

PG_FUNCTION_INFO_V1(timestamptz_jtimestamptz);
Datum
timestamptz_jtimestamptz(PG_FUNCTION_ARGS)
{
	TimestampTz value = PG_GETARG_TIMESTAMPTZ(0);

	jtimestamptz_check_range(value);
	PG_RETURN_TIMESTAMPTZ(value);
}

/* date -> jtimestamp: core's date_timestamp, then the range check. */
PG_FUNCTION_INFO_V1(date_jtimestamp);
Datum
date_jtimestamp(PG_FUNCTION_ARGS)
{
	Timestamp	result = DatumGetTimestamp(DirectFunctionCall1(date_timestamp,
															   PG_GETARG_DATUM(0)));

	jtimestamp_check_range(result);
	PG_RETURN_TIMESTAMP(result);
}

/*
 * date -> jtimestamptz: local midnight of the day in the session zone (core's
 * date_timestamptz), then the safe-range check. A date inside the Jalali range
 * can still fail: the local midnight of the first or last Jalali day, or of a
 * neighbour, can lie within 16 hours of the range's ends.
 */
PG_FUNCTION_INFO_V1(date_jtimestamptz);
Datum
date_jtimestamptz(PG_FUNCTION_ARGS)
{
	TimestampTz result = DatumGetTimestampTz(DirectFunctionCall1(date_timestamptz,
																 PG_GETARG_DATUM(0)));

	jtimestamptz_check_range(result);
	PG_RETURN_TIMESTAMPTZ(result);
}

/*
 * jtimestamp <-> jtimestamptz: core's conversions through the session zone,
 * then the check on the result. Both directions are checked: a valid
 * jtimestamp can fall outside the safe range as an instant, and the check
 * after jtimestamptz -> jtimestamp is the same predicate as a safety net (the
 * safe range already guarantees it passes).
 */
PG_FUNCTION_INFO_V1(jtimestamp_jtimestamptz);
Datum
jtimestamp_jtimestamptz(PG_FUNCTION_ARGS)
{
	TimestampTz result = DatumGetTimestampTz(DirectFunctionCall1(timestamp_timestamptz,
																 PG_GETARG_DATUM(0)));

	jtimestamptz_check_range(result);
	PG_RETURN_TIMESTAMPTZ(result);
}

PG_FUNCTION_INFO_V1(jtimestamptz_jtimestamp);
Datum
jtimestamptz_jtimestamp(PG_FUNCTION_ARGS)
{
	Timestamp	result = DatumGetTimestamp(DirectFunctionCall1(timestamptz_timestamp,
															   PG_GETARG_DATUM(0)));

	jtimestamp_check_range(result);
	PG_RETURN_TIMESTAMP(result);
}

/*
 * jdate -> jtimestamp: midnight of the day. A jdate is always inside the
 * Jalali range, and so is the start of its day, so there is nothing to check.
 */
PG_FUNCTION_INFO_V1(jdate_jtimestamp);
Datum
jdate_jtimestamp(PG_FUNCTION_ARGS)
{
	return DirectFunctionCall1(date_timestamp, PG_GETARG_DATUM(0));
}

/* jdate -> jtimestamptz: as date_jtimestamptz, local midnight needs the check. */
PG_FUNCTION_INFO_V1(jdate_jtimestamptz);
Datum
jdate_jtimestamptz(PG_FUNCTION_ARGS)
{
	TimestampTz result = DatumGetTimestampTz(DirectFunctionCall1(date_timestamptz,
																 PG_GETARG_DATUM(0)));

	jtimestamptz_check_range(result);
	PG_RETURN_TIMESTAMPTZ(result);
}

/*
 * jtimestamp -> jdate and jtimestamptz -> jdate: core's conversions (the latter
 * in the session zone). A valid value lies on a Jalali day, so no check.
 */
PG_FUNCTION_INFO_V1(jtimestamp_jdate);
Datum
jtimestamp_jdate(PG_FUNCTION_ARGS)
{
	return DirectFunctionCall1(timestamp_date, PG_GETARG_DATUM(0));
}

PG_FUNCTION_INFO_V1(jtimestamptz_jdate);
Datum
jtimestamptz_jdate(PG_FUNCTION_ARGS)
{
	return DirectFunctionCall1(timestamptz_date, PG_GETARG_DATUM(0));
}

/*
 * The typmod ("scale") casts jtimestamp(p) and jtimestamptz(p): core's
 * timestamp_scale / timestamptz_scale round to p fractional digits (they use
 * the first two arguments; the third, "explicit", does not matter), then the
 * range is checked again: rounding up the last microseconds of the range goes
 * to the first instant outside it.
 */
PG_FUNCTION_INFO_V1(jtimestamp_scale);
Datum
jtimestamp_scale(PG_FUNCTION_ARGS)
{
	Timestamp	result = DatumGetTimestamp(DirectFunctionCall2(timestamp_scale,
															   PG_GETARG_DATUM(0),
															   PG_GETARG_DATUM(1)));

	jtimestamp_check_range(result);
	PG_RETURN_TIMESTAMP(result);
}

PG_FUNCTION_INFO_V1(jtimestamptz_scale);
Datum
jtimestamptz_scale(PG_FUNCTION_ARGS)
{
	TimestampTz result = DatumGetTimestampTz(DirectFunctionCall2(timestamptz_scale,
																 PG_GETARG_DATUM(0),
																 PG_GETARG_DATUM(1)));

	jtimestamptz_check_range(result);
	PG_RETURN_TIMESTAMPTZ(result);
}
