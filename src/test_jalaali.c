/*
 * Standalone exhaustive test for src/jalaali.c. No server and no PostgreSQL
 * headers are needed: build and run it with `make test-jalaali`.
 *
 * It is the only test that checks jalaali.c's own Gregorian helpers
 * (jalaali_gregorian_to_jdn, jalaali_jdn_to_gregorian) against an independent
 * Gregorian implementation (Fliegel and Van Flandern, written below), and it
 * walks every supported day, so a regression in the calendar core fails here
 * in milliseconds. The SQL test test/sql/fullrange.sql covers the integration
 * side (the same days through the extension and core's Gregorian machinery).
 *
 * Checks are plain assert()s, so this must be compiled without NDEBUG. It
 * prints one summary line and exits 0 on success; a failed check aborts with
 * the file, line and expression.
 */
#include <stdio.h>
#include <assert.h>
#include "jalaali.h"

#ifdef NDEBUG
#error "test_jalaali.c relies on assert(); do not compile it with NDEBUG"
#endif

/* Every day from -0061-01-01 through 3177-12-29 inclusive. */
#define TOTAL_DAYS 1183020

static long checks = 0;

#define CHECK(cond) \
	do { \
		checks++; \
		assert(cond); \
	} while (0)

/*
 * Independent Gregorian calendar <-> Julian Day Number, after Fliegel and
 * Van Flandern (1968), with truncating integer division. Deliberately a
 * different formulation from jalaali.c's and Postgres's date2j/j2date.
 */
static int
ref_date2j(int y, int m, int d)
{
	int			a = (m - 14) / 12;	/* -1 for January and February, else 0 */

	return (1461 * (y + 4800 + a)) / 4
		+ (367 * (m - 2 - 12 * a)) / 12
		- (3 * ((y + 4900 + a) / 100)) / 4
		+ d - 32075;
}

static void
ref_j2date(int jdn, int *y, int *m, int *d)
{
	int			l = jdn + 68569;
	int			n = (4 * l) / 146097;
	int			i,
				j;

	l = l - (146097 * n + 3) / 4;
	i = (4000 * (l + 1)) / 1461001;
	l = l - (1461 * i) / 4 + 31;
	j = (80 * l) / 2447;
	*d = l - (2447 * j) / 80;
	l = j / 11;
	*m = j + 2 - 12 * l;
	*y = 100 * (n - 49) + i + l;
}

static bool
ref_is_leap(int y)
{
	return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
}

static int
ref_days_in_month(int y, int m)
{
	static const int len[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};

	return (m == 2 && ref_is_leap(y)) ? 29 : len[m - 1];
}

/* A known Nowruz: Gregorian date <-> Jalali date, both directions. */
static void
check_nowruz(int gy, int gm, int gd, int jy, int jm, int jd)
{
	int			jdn = jalaali_gregorian_to_jdn(gy, gm, gd);
	JalaaliDate d;

	CHECK(jalaali_from_jdn(jdn, &d));
	CHECK(d.jy == jy && d.jm == jm && d.jd == jd);
	CHECK(jalaali_to_jdn(jy, jm, jd) == jdn);
	CHECK(ref_date2j(gy, gm, gd) == jdn);
}

static void
test_spot_checks(void)
{
	bool		is_leap = false;

	/* Postgres epoch: date2j(2000,1,1) == 2451545 */
	CHECK(jalaali_gregorian_to_jdn(2000, 1, 1) == 2451545);
	CHECK(ref_date2j(2000, 1, 1) == 2451545);

	/* Known Nowruz (Jalali New Year) reference dates */
	check_nowruz(2024, 3, 20, 1403, 1, 1);
	check_nowruz(2025, 3, 21, 1404, 1, 1);
	check_nowruz(2016, 3, 20, 1395, 1, 1);
	check_nowruz(1979, 3, 21, 1358, 1, 1);
	check_nowruz(2021, 3, 21, 1400, 1, 1);
	check_nowruz(2022, 3, 21, 1401, 1, 1);
	check_nowruz(2023, 3, 21, 1402, 1, 1);

	/* Well-known leap years: 1395, 1399, 1403; common: 1394, 1400 */
	CHECK(jalaali_is_leap_year(1394, &is_leap) && !is_leap);
	CHECK(jalaali_is_leap_year(1395, &is_leap) && is_leap);
	CHECK(jalaali_is_leap_year(1399, &is_leap) && is_leap);
	CHECK(jalaali_is_leap_year(1400, &is_leap) && !is_leap);
	CHECK(jalaali_is_leap_year(1403, &is_leap) && is_leap);
	CHECK(!jalaali_is_leap_year(JALAALI_MIN_YEAR - 1, &is_leap));
	CHECK(!jalaali_is_leap_year(JALAALI_MAX_YEAR + 1, &is_leap));

	/* Month lengths */
	CHECK(jalaali_month_length(1394, 12) == 29);
	CHECK(jalaali_month_length(1395, 12) == 30);
	CHECK(jalaali_month_length(1402, 1) == 31);
	CHECK(jalaali_month_length(1402, 7) == 30);

	/* Validity */
	CHECK(jalaali_is_valid_date(1402, 1, 31));
	CHECK(!jalaali_is_valid_date(1402, 1, 32));
	CHECK(!jalaali_is_valid_date(1394, 12, 30));	/* common year */
	CHECK(jalaali_is_valid_date(1395, 12, 30));		/* leap year */
	CHECK(!jalaali_is_valid_date(1402, 13, 1));
	CHECK(!jalaali_is_valid_date(1402, 0, 1));
	CHECK(!jalaali_is_valid_date(1402, 1, 0));

	/* The day across a Nowruz boundary: 1402 is common (29-day Esfand). */
	{
		int			jdn0 = jalaali_gregorian_to_jdn(2024, 3, 19);
		JalaaliDate d0,
					d1;

		CHECK(jalaali_from_jdn(jdn0, &d0));
		CHECK(jalaali_from_jdn(jdn0 + 1, &d1));
		CHECK(d0.jy == 1402 && d0.jm == 12 && d0.jd == 29);
		CHECK(d1.jy == 1403 && d1.jm == 1 && d1.jd == 1);
	}
}

static void
test_boundaries(void)
{
	int			min_jdn = jalaali_min_jdn();
	int			max_jdn = jalaali_max_jdn();
	int			max_len = jalaali_month_length(JALAALI_MAX_YEAR, 12);
	JalaaliDate d;
	bool		is_leap = false;

	/* The supported years' edges, and one past each */
	CHECK(jalaali_is_valid_date(JALAALI_MIN_YEAR, 1, 1));
	CHECK(!jalaali_is_valid_date(JALAALI_MIN_YEAR - 1, 12, 29));
	CHECK(!jalaali_is_valid_date(JALAALI_MIN_YEAR - 1, 1, 1));
	CHECK(jalaali_is_valid_date(JALAALI_MAX_YEAR, 12, max_len));
	CHECK(!jalaali_is_valid_date(JALAALI_MAX_YEAR, 12, max_len + 1));
	CHECK(!jalaali_is_valid_date(JALAALI_MAX_YEAR + 1, 1, 1));

	/* 3177 is a common year, so the last supported day is 3177-12-29 */
	CHECK(max_len == 29);
	CHECK(jalaali_is_leap_year(JALAALI_MAX_YEAR, &is_leap) && !is_leap);

	/* min_jdn/max_jdn are the first and last day, and one past each fails */
	CHECK(max_jdn - min_jdn + 1 == TOTAL_DAYS);
	CHECK(jalaali_to_jdn(JALAALI_MIN_YEAR, 1, 1) == min_jdn);
	CHECK(jalaali_to_jdn(JALAALI_MAX_YEAR, 12, max_len) == max_jdn);
	CHECK(jalaali_from_jdn(min_jdn, &d));
	CHECK(d.jy == JALAALI_MIN_YEAR && d.jm == 1 && d.jd == 1);
	CHECK(jalaali_from_jdn(max_jdn, &d));
	CHECK(d.jy == JALAALI_MAX_YEAR && d.jm == 12 && d.jd == max_len);
	CHECK(!jalaali_from_jdn(min_jdn - 1, &d));
	CHECK(!jalaali_from_jdn(max_jdn + 1, &d));
	CHECK(!jalaali_from_jdn(0, &d));

	/* Esfand is 30 days in a leap year and 29 in a common year */
	CHECK(jalaali_month_length(1403, 12) == 30);	/* leap */
	CHECK(jalaali_month_length(1402, 12) == 29);	/* common */
}

/*
 * Each Farvardin 1: jalaali_cal agrees with the independent Gregorian code
 * on which day it is, it falls on March 19..22 of year y+621, and the gap to
 * the next Farvardin 1 is 365 or 366 days (leap iff 366).
 */
static void
test_nowruz_every_year(void)
{
	int			jy;

	for (jy = JALAALI_MIN_YEAR; jy <= JALAALI_MAX_YEAR; jy++)
	{
		JalCalResult r;
		JalaaliDate d;
		int			jdn1;
		bool		is_leap = false;

		CHECK(jalaali_cal(jy, &r));
		CHECK(r.gy == jy + 621);
		CHECK(r.march >= 19 && r.march <= 22);

		jdn1 = jalaali_to_jdn(jy, 1, 1);
		CHECK(jdn1 == ref_date2j(r.gy, 3, r.march));
		CHECK(jalaali_from_jdn(jdn1, &d));
		CHECK(d.jy == jy && d.jm == 1 && d.jd == 1);

		/* the next Farvardin 1 only exists inside the supported range */
		if (jy < JALAALI_MAX_YEAR)
		{
			int			len = jalaali_to_jdn(jy + 1, 1, 1) - jdn1;

			CHECK(len == 365 || len == 366);
			CHECK(jalaali_is_leap_year(jy, &is_leap));
			CHECK(is_leap == (len == 366));
		}
	}
}

/*
 * Every supported day: from_jdn/to_jdn identity, contiguity and calendar
 * structure, and the Gregorian cross-check against the independent code.
 */
static void
test_every_day(void)
{
	int			min_jdn = jalaali_min_jdn();
	int			max_jdn = jalaali_max_jdn();
	long		days = 0;
	long		year_days_sum = 0;
	int			year_start = min_jdn;
	JalaaliDate prev = {0, 0, 0};
	int			jdn;

	for (jdn = min_jdn; jdn <= max_jdn; jdn++)
	{
		JalaaliDate d;
		int			gy,
					gm,
					gd,
					ry,
					rm,
					rd;

		days++;

		/* from_jdn then to_jdn is the identity; the date is valid */
		CHECK(jalaali_from_jdn(jdn, &d));
		CHECK(jalaali_is_valid_date(d.jy, d.jm, d.jd));
		CHECK(jalaali_to_jdn(d.jy, d.jm, d.jd) == jdn);

		/* the day after the last day of a month is invalid, else valid */
		CHECK(jalaali_is_valid_date(d.jy, d.jm, d.jd + 1) ==
			  (d.jd < jalaali_month_length(d.jy, d.jm)));

		/* Gregorian, both directions, against the independent code */
		jalaali_jdn_to_gregorian(jdn, &gy, &gm, &gd);
		ref_j2date(jdn, &ry, &rm, &rd);
		CHECK(gy == ry && gm == rm && gd == rd);
		CHECK(jalaali_gregorian_to_jdn(ry, rm, rd) == jdn);
		CHECK(ref_date2j(gy, gm, gd) == jdn);
		CHECK(gy == d.jy + 621 || gy == d.jy + 622);

		/* contiguity and structure against the previous day */
		if (jdn > min_jdn)
		{
			if (d.jd != 1)
			{
				/* same month: day-of-month advanced by exactly 1 */
				CHECK(d.jy == prev.jy && d.jm == prev.jm);
				CHECK(d.jd == prev.jd + 1);
			}
			else
			{
				/* rolled over: the previous day was the month's last */
				int			plen = prev.jm <= 6 ? 31 : (prev.jm <= 11 ? 30 : 0);
				bool		is_leap = false;

				CHECK(jalaali_is_leap_year(prev.jy, &is_leap));
				if (prev.jm == 12)
					plen = is_leap ? 30 : 29;
				CHECK(prev.jd == plen);
				CHECK(prev.jd == jalaali_month_length(prev.jy, prev.jm));

				if (prev.jm < 12)
				{
					CHECK(d.jy == prev.jy && d.jm == prev.jm + 1);
				}
				else
				{
					int			ylen = jdn - year_start;

					/* new year: the old one had 365 or 366 days */
					CHECK(d.jy == prev.jy + 1 && d.jm == 1);
					CHECK(ylen == 365 || ylen == 366);
					CHECK(is_leap == (ylen == 366));
					year_days_sum += ylen;
					year_start = jdn;
				}
			}
		}
		prev = d;
	}

	/* the last year (3177, common) ends exactly at max_jdn */
	CHECK(prev.jy == JALAALI_MAX_YEAR && prev.jm == 12 && prev.jd == 29);
	year_days_sum += max_jdn - year_start + 1;

	CHECK(days == TOTAL_DAYS);
	CHECK(year_days_sum == TOTAL_DAYS);
}

/*
 * Walk the Gregorian calendar itself, using only this file's day counts and
 * leap rule (no JDN formula), from the first to the last supported day, and
 * check jalaali.c's helpers against it in both directions.
 */
static void
test_gregorian_walk(void)
{
	int			min_jdn = jalaali_min_jdn();
	int			max_jdn = jalaali_max_jdn();
	int			y,
				m,
				d;
	int			jdn;

	ref_j2date(min_jdn, &y, &m, &d);	/* only the starting point */
	for (jdn = min_jdn; jdn <= max_jdn; jdn++)
	{
		int			gy,
					gm,
					gd;

		CHECK(jalaali_gregorian_to_jdn(y, m, d) == jdn);
		jalaali_jdn_to_gregorian(jdn, &gy, &gm, &gd);
		CHECK(gy == y && gm == m && gd == d);

		if (++d > ref_days_in_month(y, m))
		{
			d = 1;
			if (++m > 12)
			{
				m = 1;
				y++;
			}
		}
	}
	/* the walk ended on the day after the last supported one */
	CHECK(ref_date2j(y, m, d) == max_jdn + 1);
}

int
main(void)
{
	test_spot_checks();
	test_boundaries();
	test_nowruz_every_year();
	test_every_day();
	test_gregorian_walk();

	printf("test_jalaali: ALL TESTS PASSED (%d days, %ld checks)\n",
		   TOTAL_DAYS, checks);
	return 0;
}
