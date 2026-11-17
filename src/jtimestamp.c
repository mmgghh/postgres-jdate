/*
 * jtimestamp.c -- the jtimestamp type: a timestamp (no time zone) written and
 * read with a Jalali date.
 *
 * jtimestamp has exactly the representation of core's timestamp (an int64 of
 * microseconds since 2000-01-01 00:00:00, infinities at the int64 extremes).
 * Only the text form differs: the date part is Jalali, and the time part is
 * whatever core's timestamp parser and printer do with it. So input converts
 * the Jalali date prefix to Gregorian and hands the whole string to timestamp_in,
 * and output prints with core's EncodeDateTime and swaps in the Jalali date.
 *
 * Every value that can be stored lies within the Jalali range (see
 * jtimestamp_in_range in jdate_common.h), so it can always be displayed.
 */
#include "postgres.h"
#include "fmgr.h"
#include "libpq/pqformat.h"
#include "miscadmin.h"		/* USE_ISO_DATES */
#include "nodes/miscnodes.h"	/* soft errors (ereturn): PostgreSQL 16+ */
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
 * without a Jalali date. Matched exactly (whole string, case-insensitive), so
 * that no Gregorian spelling gets through to core. "allballs" is not here: it
 * is a time-only word that core rejects for timestamp.
 */
static const char *const jtimestamp_special_words[] = {
	"infinity", "-infinity", "now", "today", "tomorrow", "yesterday", "epoch"
};

static bool
jtimestamp_is_special_word(const char *str)
{
	for (size_t i = 0; i < lengthof(jtimestamp_special_words); i++)
	{
		if (pg_strcasecmp(str, jtimestamp_special_words[i]) == 0)
			return true;
	}
	return false;
}

/*
 * Run core's timestamp_in on text, with the typmod, and report a failure the
 * way jtimestamp_in does. The caller's text is in str (for the message); the
 * text core sees is gregorian_str. Returns false after saving a soft error
 * into escontext (or raising it, when escontext is NULL).
 *
 * Core fails with a message about type timestamp and, when the text was
 * converted, about a Gregorian string the user never wrote. The SQLSTATE is
 * what matters (22007 syntax, 22008 field out of range, 22009 or 22023 for the
 * zone), so it is kept and the message is rewritten with our type name.
 */
static bool
jtimestamp_call_core(const char *str, char *gregorian_str, int32 typmod,
					 Node *escontext, Timestamp *result)
{
	ErrorSaveContext local = {.type = T_ErrorSaveContext, .details_wanted = true};
	Datum		datum;

	if (DirectInputFunctionCallSafe(timestamp_in, gregorian_str, InvalidOid,
									typmod, (Node *) &local, &datum))
	{
		*result = DatumGetTimestamp(datum);
		return true;
	}

	switch (local.error_data->sqlerrcode)
	{
		case ERRCODE_INVALID_DATETIME_FORMAT:
			errsave(escontext,
					(errcode(ERRCODE_INVALID_DATETIME_FORMAT),
					 errmsg("invalid input syntax for type jtimestamp: \"%s\"", str)));
			break;
		case ERRCODE_DATETIME_VALUE_OUT_OF_RANGE:
			errsave(escontext,
					(errcode(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE),
					 errmsg("date/time field value out of range for type jtimestamp: \"%s\"", str)));
			break;
		default:

			/*
			 * An unknown time zone, a displacement out of range and the like.
			 * Core's message says what is wrong; keep it as the detail.
			 */
			errsave(escontext,
					(errcode(local.error_data->sqlerrcode),
					 errmsg("invalid input for type jtimestamp: \"%s\"", str),
					 errdetail_internal("%s", local.error_data->message)));
			break;
	}
	return false;
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
	const char *end;
	int			jy,
				jm,
				jd;
	char	   *core_str;
	Timestamp	result;

	switch (jdate_scan_ymd(str, &end, &jy, &jm, &jd))
	{
		case JDATE_PARSE_OK:
			{
				int			gy,
							gm,
							gd;

				if (!jalaali_is_valid_date(jy, jm, jd))
					ereturn(escontext, (Datum) 0,
							(errcode(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE),
							 errmsg("date out of range for type jtimestamp: \"%s\"", str)));

				/*
				 * The Jalali range is Gregorian 0560-03-20 .. 3799-03-19, so
				 * the year always has four digits and never needs an era. The
				 * rest of the string, with its separator, goes to core as is.
				 */
				jalaali_jdn_to_gregorian(jalaali_to_jdn(jy, jm, jd), &gy, &gm, &gd);
				core_str = psprintf("%04d-%02d-%02d%s", gy, gm, gd, end);
			}
			break;

		case JDATE_PARSE_OVERFLOW:
			ereturn(escontext, (Datum) 0,
					(errcode(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE),
					 errmsg("date out of range for type jtimestamp: \"%s\"", str)));
			break;

		case JDATE_PARSE_SYNTAX:
		default:
			if (!jtimestamp_is_special_word(str))
				ereturn(escontext, (Datum) 0,
						(errcode(ERRCODE_INVALID_DATETIME_FORMAT),
						 errmsg("invalid input syntax for type jtimestamp: \"%s\"", str)));
			core_str = str;
			break;
	}

	if (!jtimestamp_call_core(str, core_str, typmod, escontext, &result))
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
