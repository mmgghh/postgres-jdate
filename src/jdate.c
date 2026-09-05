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

static JalaaliDate
jdate_to_jalaali(DateADT value)
{
	JalaaliDate jd;

	if (DATE_NOT_FINITE(value))
		ereport(ERROR,
				(errcode(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE),
				 errmsg("cannot convert infinite jdate to a calendar date")));

	if (!jalaali_from_jdn(value + POSTGRES_EPOCH_JDATE, &jd))
		ereport(ERROR,
				(errcode(ERRCODE_DATETIME_VALUE_OUT_OF_RANGE),
				 errmsg("jdate value is outside the supported Jalali range (years %d to %d)",
						JALAALI_MIN_YEAR, JALAALI_MAX_YEAR)));

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

	PG_RETURN_DATEADT((DateADT) pq_getmsgint(buf, sizeof(int32)));
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
