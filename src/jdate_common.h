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

#endif							/* JDATE_COMMON_H */
