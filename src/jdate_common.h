/*
 * jdate_common.h -- what the jdate, jtimestamp and jtimestamptz source files
 * share: the range checks, the text pieces of a Jalali date, the parser
 * scanner, the unit decoder and the field extractor.
 *
 * Include it after "postgres.h", like any server header. PG_MODULE_MAGIC lives
 * only in src/jdate.c.
 *
 * The small hot helpers are static inline here; the larger ones are declared
 * here and defined in src/jdate.c.
 */
#ifndef JDATE_COMMON_H
#define JDATE_COMMON_H

#include "fmgr.h"
#include "nodes/nodes.h"
#include "pgtime.h"
#include "datatype/timestamp.h"
#include "utils/date.h"

#include "jalaali.h"

/* ---------------------------------------------------------------------
 * Range checks
 *
 * Every check that a value lies within the supported Jalali range goes through
 * a static inline helper in this one section; no source file open-codes the
 * comparison. The helpers for the timestamp types are added here as well. That
 * keeps all of them in one place, so a throwaway measurement build can turn the
 * checks off by editing only this section.
 * ------------------------------------------------------------------- */

/*
 * The one error for "this value is outside the supported Jalali range", raised
 * by every range check below and by display (jdate_to_jalaali), so no
 * out-of-range value can be stored and then fail on every later read.
 */
extern void jdate_range_error(void);

/*
 * The same error, reported softly: with an ErrorSaveContext in escontext it is
 * saved and the call returns (the caller must then return at once); with NULL
 * it is raised, like jdate_range_error.
 */
extern void jdate_range_errsave(Node *escontext);

/*
 * Raise 22008 unless a finite value lies within the Jalali range. Infinity
 * and -infinity are always valid.
 */
static inline void
jdate_check_range(DateADT value)
{
	if (DATE_NOT_FINITE(value))
		return;

	if (value < jalaali_min_jdn() - POSTGRES_EPOCH_JDATE ||
		value > jalaali_max_jdn() - POSTGRES_EPOCH_JDATE)
		jdate_range_error();
}

/*
 * Whether a jtimestamp lies within the Jalali range: from the start of the first
 * day (-0061-01-01 00:00:00) up to, not including, the start of the day after
 * the last (3178-01-01 00:00:00). Infinity and -infinity are always valid.
 *
 * This is the single test behind every jtimestamp range check. The soft input
 * path calls it directly (it must report through the ErrorSaveContext), every
 * other path goes through jtimestamp_check_range.
 */
static inline bool
jtimestamp_in_range(Timestamp value)
{
	if (TIMESTAMP_NOT_FINITE(value))
		return true;

	return value >= ((int64) jalaali_min_jdn() - POSTGRES_EPOCH_JDATE) * USECS_PER_DAY &&
		value < ((int64) jalaali_max_jdn() + 1 - POSTGRES_EPOCH_JDATE) * USECS_PER_DAY;
}

/* Raise 22008 unless the jtimestamp is within the Jalali range. */
static inline void
jtimestamp_check_range(Timestamp value)
{
	if (!jtimestamp_in_range(value))
		jdate_range_error();
}

/*
 * jtimestamptz: the same Jalali range, shrunk at both ends by the largest zone
 * displacement (TZDISP_LIMIT, 16 hours: offsets reach +/-15:59:59). An instant
 * is displayed in the session zone, so only instants at least that far inside
 * the range are guaranteed to show a Jalali day in every zone. The safe range
 * is [first day start + 16h, day after the last day start - 16h), plus both
 * infinities. It needs no zone, so the check is the same for every session.
 */
static inline bool
jtimestamptz_in_range(TimestampTz value)
{
	if (TIMESTAMP_NOT_FINITE(value))
		return true;

	return value >= ((int64) jalaali_min_jdn() - POSTGRES_EPOCH_JDATE) * USECS_PER_DAY
		+ (int64) TZDISP_LIMIT * USECS_PER_SEC &&
		value < ((int64) jalaali_max_jdn() + 1 - POSTGRES_EPOCH_JDATE) * USECS_PER_DAY
		- (int64) TZDISP_LIMIT * USECS_PER_SEC;
}

/* Raise 22008 unless the jtimestamptz is within the safe range. */
static inline void
jtimestamptz_check_range(TimestampTz value)
{
	if (!jtimestamptz_in_range(value))
		jdate_range_error();
}

/*
 * Whether a Unix epoch (seconds, double) lies within the days of the Jalali
 * range: from the first instant of the first day to just before the first
 * instant after the last. The bounds are exact doubles (multiples of 86400,
 * far below 2^53). The test is written so that NaN fails it; callers deal with
 * +/-Infinity before they ask. Shared by every to_j* function that takes an
 * epoch, so they reject the same inputs.
 */
static inline bool
jdate_epoch_in_range(float8 epoch)
{
	return epoch >= (double) (jalaali_min_jdn() - UNIX_EPOCH_JDATE) * SECS_PER_DAY &&
		epoch < (double) (jalaali_max_jdn() - UNIX_EPOCH_JDATE + 1) * SECS_PER_DAY;
}

/* ---------------------------------------------------------------------
 * Text and calendar pieces
 * ------------------------------------------------------------------- */

/*
 * The text of a Jalali date, shared by jdate_out and jdate_format so the two
 * cannot disagree: an optional "-", then the year as exactly four digits, then
 * "-MM-DD". A plain %04d would pad the sign into the width ("-061" rather
 * than "-0061"), so the magnitude is padded instead.
 */
static inline char *
jdate_format_ymd(const JalaaliDate *jd)
{
	return psprintf("%s%04d-%02d-%02d", jd->jy < 0 ? "-" : "",
					abs(jd->jy), jd->jm, jd->jd);
}

/*
 * The text of an infinite day, shared by jdate_out and jdate_format. The
 * caller has checked DATE_NOT_FINITE(value).
 */
static inline const char *
jdate_infinity_text(DateADT value)
{
	return DATE_IS_NOBEGIN(value) ? "-infinity" : "infinity";
}

static inline JalaaliDate
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
 * Parsing a "Y-M-D" prefix
 * ------------------------------------------------------------------- */

/*
 * Outcome of scanning one "Y-M-D" string, so that each caller has a single
 * place per error kind to report it from.
 */
typedef enum JdateParseStatus
{
	JDATE_PARSE_OK,
	JDATE_PARSE_SYNTAX,			/* not of the form Y-M-D */
	JDATE_PARSE_OVERFLOW		/* a field does not fit in an int32 */
} JdateParseStatus;

/*
 * Scan a Jalali "Y-M-D" at the start of str (after optional whitespace), and
 * set *end to the first character after the day field, so the caller can look
 * at, or hand on, the rest of the string. Whitespace may surround each dash
 * and each field may carry a sign. The fields are not range-validated (use
 * jalaali_is_valid_date). On JDATE_PARSE_SYNTAX the fields and *end are not
 * set; on JDATE_PARSE_OVERFLOW *end is set, and the fields that overflowed are
 * not.
 */
extern JdateParseStatus jdate_scan_ymd(const char *str, const char **end,
									   int *jy, int *jm, int *jd);

/* ---------------------------------------------------------------------
 * Unit decoding for jdate_part / extract / jdate_trunc
 * ------------------------------------------------------------------- */

/*
 * Per call site cache of the last decoded unit, kept in fn_extra (allocated
 * in fn_mcxt). The raw bytes are compared with memcmp, so a different
 * spelling, case or value is always a miss and goes through the full decoder.
 * Only successful decodes are stored; an invalid unit raises an error before
 * the cache is touched. Units longer than the buffer are never cached.
 */
#define JDATE_UNIT_CACHE_MAX 32

typedef struct JdateUnitCache
{
	int			len;
	int			val;
	char		bytes[JDATE_UNIT_CACHE_MAX];
} JdateUnitCache;

/* The DTK_* token of a unit name, or an error; the cached form uses fn_extra. */
extern int	jdate_decode_field_uncached(text *units);
extern int	jdate_decode_field(FunctionCallInfo fcinfo, text *units);

extern void jdate_unsupported_unit(void);

/* ---------------------------------------------------------------------
 * Fields of a jdate
 * ------------------------------------------------------------------- */

/*
 * What a field of a jdate is: a finite integer, an infinite value (only for an
 * infinite jdate and a unit that only grows), or NULL.
 */
typedef enum JdateFieldKind
{
	JDATE_FIELD_FINITE,
	JDATE_FIELD_INFINITE,		/* *result is -1 (-Infinity) or +1 (Infinity) */
	JDATE_FIELD_NULL
} JdateFieldKind;

/*
 * Field "val" (a DTK_* token from jdate_decode_field) of a jdate as an exact
 * int64 in *result, with the kind telling whether it is a finite value, an
 * infinity or NULL.
 */
extern JdateFieldKind jdate_get_field(DateADT value, int val, int64 *result);

/* ---------------------------------------------------------------------
 * Jalali months, and the local wall clock of an instant
 *
 * Defined in src/jtimestamp_local.c. Shared by the interval arithmetic (J3),
 * the date_bin and trunc code and the EXTRACT code (J4).
 * ------------------------------------------------------------------- */

/*
 * Add "months" Jalali months to a valid Jalali date, as core adds months to a
 * Gregorian one: the month count moves the (year, month) pair, and the day is
 * kept unless the target month is shorter, when it becomes the last day of that
 * month (1403-06-31 + 1 month is 1403-07-30). Negative counts floor, so
 * 0000-01-31 - 1 month is -0001-12-29. The same rule makes it not invertible,
 * exactly as in core. "months" is the type of Interval.month, so the year
 * arithmetic cannot overflow. Returns false, leaving *out alone, when the
 * target year lies outside the supported years (the caller raises the range
 * error, jdate_range_error); true otherwise. *out may be the same as *in.
 */
extern bool jdate_add_months(const JalaaliDate *in, int32 months, JalaaliDate *out);

/*
 * The wall clock of an instant: the Jalali date and the time of day on the
 * clock of one time zone (or on no zone, for a jtimestamp, which is already a
 * wall clock). This is the only place that turns an instant into a local Jalali
 * date and back, so every caller gets core's treatment of gaps and overlaps,
 * which are never reimplemented here:
 *
 *   - instant to local goes through core's timestamp2tm, in the given zone;
 *   - local to instant goes through core's DetermineTimeZoneOffset (which
 *     decides the offset of a wall time that does not exist, or occurs twice,
 *     as core does for timestamptz + interval and date_trunc) and tm2timestamp;
 *   - the result is then range-checked (jtimestamp range, or for an instant the
 *     jtimestamptz safe range): 22008 outside it.
 *
 * "date" is the Jalali day on that clock and "time" the microseconds since its
 * midnight, 0 .. USECS_PER_DAY - 1. A caller changes "date" and/or "time" and
 * converts back; a date outside the supported Jalali years (what
 * jdate_add_months refuses) is not accepted on the way back and raises 22008.
 * "tz" is only filled in by jt_local_from_instant: the offset core's
 * timestamp2tm reports, in seconds WEST of UTC (core's sign), for callers that
 * need the offset (the timezone fields); it is ignored on the way back.
 *
 * "zone" is a pg_tz (session_timezone, or one looked up by name); NULL means
 * the session zone. Only finite values can be converted: an infinite one is
 * the caller's to deal with first, and raises 22008 here.
 */
typedef struct JtLocal
{
	JalaaliDate date;
	int64		time;
	int			tz;
} JtLocal;

extern void jt_local_from_timestamp(Timestamp value, JtLocal *local);
extern void jt_local_from_instant(TimestampTz instant, pg_tz *zone, JtLocal *local);
extern Timestamp jt_local_to_timestamp(const JtLocal *local);
extern TimestampTz jt_local_to_instant(const JtLocal *local, pg_tz *zone);

#endif							/* JDATE_COMMON_H */
