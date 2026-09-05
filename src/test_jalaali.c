#include <stdio.h>
#include <assert.h>
#include "jalaali.h"

static void
check_g2j(int gy, int gm, int gd, int jy, int jm, int jd, const char *label)
{
	int			jdn = jalaali_gregorian_to_jdn(gy, gm, gd);
	JalaaliDate d;
	bool		ok = jalaali_from_jdn(jdn, &d);

	printf("%-28s greg=%04d-%02d-%02d jdn=%d -> jalali=%d-%02d-%02d (expect %d-%02d-%02d) %s\n",
		   label, gy, gm, gd, jdn, d.jy, d.jm, d.jd, jy, jm, jd,
		   (ok && d.jy == jy && d.jm == jm && d.jd == jd) ? "OK" : "MISMATCH");
	assert(ok);
	assert(d.jy == jy && d.jm == jm && d.jd == jd);

	/* round trip the other direction too */
	{
		int			jdn2 = jalaali_to_jdn(jy, jm, jd);

		assert(jdn2 == jdn);
	}
}

int
main(void)
{
	setvbuf(stdout, NULL, _IONBF, 0);

	/* Postgres epoch sanity check: date2j(2000,1,1) == 2451545 */
	assert(jalaali_gregorian_to_jdn(2000, 1, 1) == 2451545);
	printf("epoch check OK: g2jdn(2000-01-01) = %d\n",
		   jalaali_gregorian_to_jdn(2000, 1, 1));

	/* Known Nowruz (Jalali New Year) reference dates */
	check_g2j(2024, 3, 20, 1403, 1, 1, "Nowruz 1403");
	check_g2j(2025, 3, 21, 1404, 1, 1, "Nowruz 1404");
	check_g2j(2016, 3, 20, 1395, 1, 1, "Nowruz 1395");
	check_g2j(1979, 3, 21, 1358, 1, 1, "Nowruz 1358");
	check_g2j(2021, 3, 21, 1400, 1, 1, "Nowruz 1400");
	check_g2j(2022, 3, 21, 1401, 1, 1, "Nowruz 1401");
	check_g2j(2023, 3, 21, 1402, 1, 1, "Nowruz 1402");

	/* Leap-year checks (well-known: 1395, 1399, 1403 are leap; 1394,1400 are not) */
	{
		bool		is_leap;

		jalaali_is_leap_year(1394, &is_leap);
		assert(is_leap == false);
		jalaali_is_leap_year(1395, &is_leap);
		assert(is_leap == true);
		jalaali_is_leap_year(1399, &is_leap);
		assert(is_leap == true);
		jalaali_is_leap_year(1400, &is_leap);
		assert(is_leap == false);
		jalaali_is_leap_year(1403, &is_leap);
		assert(is_leap == true);
		printf("leap year checks OK\n");
	}

	/* Month length checks */
	assert(jalaali_month_length(1394, 12) == 29);
	assert(jalaali_month_length(1395, 12) == 30);
	assert(jalaali_month_length(1402, 1) == 31);
	assert(jalaali_month_length(1402, 7) == 30);
	printf("month length checks OK\n");

	/* Validity checks */
	assert(jalaali_is_valid_date(1402, 1, 31) == true);
	assert(jalaali_is_valid_date(1402, 1, 32) == false);
	assert(jalaali_is_valid_date(1394, 12, 30) == false);	/* common year */
	assert(jalaali_is_valid_date(1395, 12, 30) == true);	/* leap year */
	assert(jalaali_is_valid_date(1402, 13, 1) == false);
	assert(jalaali_is_valid_date(1402, 0, 1) == false);
	printf("validity checks OK\n");

	/* Range boundary checks */
	assert(jalaali_is_valid_date(JALAALI_MIN_YEAR, 1, 1) == true);
	assert(jalaali_is_valid_date(JALAALI_MIN_YEAR - 1, 1, 1) == false);
	assert(jalaali_is_valid_date(JALAALI_MAX_YEAR, 12,
								  jalaali_month_length(JALAALI_MAX_YEAR, 12)) == true);
	assert(jalaali_is_valid_date(JALAALI_MAX_YEAR + 1, 1, 1) == false);
	printf("range boundary checks OK\n");

	/* A day-by-day walk across a Nowruz boundary, cross-checked against
	 * Gregorian JDN arithmetic (independent of jalaali_to_jdn). */
	{
		int			jdn0 = jalaali_gregorian_to_jdn(2024, 3, 19);	/* last day of 1402 */
		JalaaliDate d0,
					d1;

		assert(jalaali_from_jdn(jdn0, &d0));
		assert(jalaali_from_jdn(jdn0 + 1, &d1));
		printf("boundary walk: %d-%02d-%02d -> %d-%02d-%02d\n",
			   d0.jy, d0.jm, d0.jd, d1.jy, d1.jm, d1.jd);
		/* 1402 is a common year (29-day Esfand): 1399 and 1403 are the
		 * neighboring leap years, per the leap-year checks above. */
		assert(d0.jy == 1402 && d0.jm == 12 && d0.jd == 29);
		assert(d1.jy == 1403 && d1.jm == 1 && d1.jd == 1);
	}

	printf("ALL TESTS PASSED\n");
	return 0;
}
