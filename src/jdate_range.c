/*
 * jdate_range.c -- the support functions of the range types jdaterange,
 * jtsrange and jtstzrange (and their multirange types, which CREATE TYPE ...
 * AS RANGE makes along with them).
 *
 * Core's operators on ranges are type-agnostic: they work through the subtype's
 * btree comparison function (the default operator class of jdate, jtimestamp
 * and jtimestamptz) and need nothing here. A range type takes two optional
 * helpers, and this file holds them.
 *
 * subtype_diff. The GiST operator class and the planner's range statistics use
 * it to measure the distance between two bounds, as a double. jdate, jtimestamp
 * and jtimestamptz have the representation of date, timestamp and timestamptz,
 * so core's daterange_subdiff, tsrange_subdiff and tstzrange_subdiff are exact
 * for them. CREATE TYPE ... AS RANGE looks the function up by the exact subtype
 * signature, so core's (date, date) function cannot be named directly; these
 * are C wrappers over the core C functions instead (not LANGUAGE internal
 * aliases of core's function names, so the SQL script does not depend on those
 * names).
 *
 * canonical, for jdaterange only (a discrete range). Core's
 * daterange_canonical turns every range into the form [lower, upper): an
 * exclusive lower bound becomes the next day and an inclusive upper bound
 * becomes the next day, exclusive. For the last day of the supported range that
 * is a day jdate cannot display: '[1403-01-01,3177-12-29]' would become
 * '[1403-01-01,3177-12-30)', a value whose bound could never be printed again
 * (jdate_out refuses it). So jdaterange_canonical lets core canonicalize and
 * then range-checks both finite bounds with the shared jdate check, giving the
 * usual 22008 (softly, when the range is being read by an input function that
 * asked for soft errors, such as pg_input_is_valid). Continuous ranges
 * (jtsrange, jtstzrange) have no canonical function, as core's tsrange has none.
 *
 * The result of every range operator (union, intersection, difference,
 * multirange merge) is made of bounds that already exist in its operands, which
 * are valid, so only the places where a bound is incremented need the check.
 */
#include "postgres.h"
#include "fmgr.h"
#include "nodes/miscnodes.h"	/* soft errors (SOFT_ERROR_OCCURRED): PostgreSQL 16+ */
#include "utils/fmgrprotos.h"
#include "utils/rangetypes.h"

#include "jdate_common.h"

#define JDATE_RANGE_SUBDIFF(name, core) \
	PG_FUNCTION_INFO_V1(name); \
	Datum \
	name(PG_FUNCTION_ARGS) \
	{ \
		return DirectFunctionCall2(core, PG_GETARG_DATUM(0), PG_GETARG_DATUM(1)); \
	}

JDATE_RANGE_SUBDIFF(jdaterange_subdiff, daterange_subdiff)
JDATE_RANGE_SUBDIFF(jtsrange_subdiff, tsrange_subdiff)
JDATE_RANGE_SUBDIFF(jtstzrange_subdiff, tstzrange_subdiff)

/*
 * jdaterange_canonical(jdaterange) RETURNS jdaterange.
 *
 * Core's function is called with our own fcinfo: it needs the flinfo (it keeps
 * the range type's cache entry in fn_extra, which range_get_typcache below reads
 * again) and the context (an ErrorSaveContext, when there is one). It returns
 * its argument unchanged for an empty range.
 */
PG_FUNCTION_INFO_V1(jdaterange_canonical);
Datum
jdaterange_canonical(PG_FUNCTION_ARGS)
{
	Datum		result = daterange_canonical(fcinfo);
	Node	   *escontext = fcinfo->context;
	RangeType  *range;
	TypeCacheEntry *typcache;
	RangeBound	lower;
	RangeBound	upper;
	bool		empty;

	/* core reported a soft error (it does not raise one for dates, but be exact) */
	if (SOFT_ERROR_OCCURRED(escontext))
		PG_RETURN_NULL();

	range = DatumGetRangeTypeP(result);
	typcache = range_get_typcache(fcinfo, RangeTypeGetOid(range));
	range_deserialize(typcache, range, &lower, &upper, &empty);

	if (empty)
		return result;

	/*
	 * An infinite bound (no value at all) and the dates 'infinity' and
	 * '-infinity' are always valid; a finite date must be a Jalali-range day.
	 * Core has already incremented the bounds it was going to, so a bound that
	 * went past the last day is caught here.
	 */
	if (!lower.infinite && !jdate_in_range(DatumGetDateADT(lower.val)))
	{
		jdate_range_errsave(escontext);
		PG_RETURN_NULL();
	}
	if (!upper.infinite && !jdate_in_range(DatumGetDateADT(upper.val)))
	{
		jdate_range_errsave(escontext);
		PG_RETURN_NULL();
	}

	return result;
}
