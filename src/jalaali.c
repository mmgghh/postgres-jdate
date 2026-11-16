/*
 * Jalali (Persian) calendar conversion, based on the algorithm published
 * by Kazimierz M. Borkowski in "The Persian calendar for 3000 years"
 * (1996) -- exact for Jalali years -61..3177. Ported with reference to
 * the jalaali-js implementation (MIT License, (c) 2020 Behrang
 * Norouzinia, https://github.com/jalaali/jalaali-js).
 */
#include "jalaali.h"

static const int JALAALI_BREAKS[] = {
	-61, 9, 38, 199, 426, 686, 756, 818, 1111, 1181,
	1210, 1635, 2060, 2097, 2192, 2262, 2324, 2394, 2456, 3178
};
#define JALAALI_NBREAKS ((int) (sizeof(JALAALI_BREAKS) / sizeof(JALAALI_BREAKS[0])))

static inline int
jdiv(int a, int b)
{
	return a / b;
}

static inline int
jmod(int a, int b)
{
	int			r = a % b;

	return r < 0 ? r + b : r;
}

static void
jalcal_core(int jy, int *out_gy, int *out_march, int *out_jump, int *out_n)
{
	int			gy = jy + 621;
	int			leapJ = -14;
	int			jp = JALAALI_BREAKS[0];
	int			jm = 0,
				jump = 0,
				i,
				n,
				leapG;

	for (i = 1; i < JALAALI_NBREAKS; i++)
	{
		jm = JALAALI_BREAKS[i];
		jump = jm - jp;
		if (jy < jm)
			break;
		leapJ += jdiv(jump, 33) * 8 + jdiv(jmod(jump, 33), 4);
		jp = jm;
	}
	n = jy - jp;

	leapJ += jdiv(n, 33) * 8 + jdiv(jmod(n, 33) + 3, 4);
	if (jmod(jump, 33) == 4 && jump - n == 4)
		leapJ += 1;

	leapG = jdiv(gy, 4) - jdiv((jdiv(gy, 100) + 1) * 3, 4) - 150;

	*out_march = 20 + leapJ - leapG;
	*out_gy = gy;
	*out_jump = jump;
	*out_n = n;
}

static int
leap_from_cycle(int jump, int n)
{
	int			leap;

	if (jump - n < 6)
		n = n - jump + jdiv(jump + 4, 33) * 33;
	leap = jmod(jmod(n + 1, 33) - 1, 4);
	return leap == -1 ? 4 : leap;
}

bool
jalaali_cal(int jy, JalCalResult *out)
{
	int			gy,
				march,
				jump,
				n;

	if (jy < JALAALI_MIN_YEAR || jy > JALAALI_MAX_YEAR)
		return false;

	jalcal_core(jy, &gy, &march, &jump, &n);
	out->gy = gy;
	out->march = march;
	out->leap = leap_from_cycle(jump, n);
	return true;
}

bool
jalaali_is_leap_year(int jy, bool *is_leap)
{
	JalCalResult r;

	if (!jalaali_cal(jy, &r))
		return false;
	*is_leap = (r.leap == 0);
	return true;
}

int
jalaali_month_length(int jy, int jm)
{
	bool		is_leap = false;

	if (jm <= 6)
		return 31;
	if (jm <= 11)
		return 30;
	jalaali_is_leap_year(jy, &is_leap);
	return is_leap ? 30 : 29;
}

bool
jalaali_is_valid_date(int jy, int jm, int jd)
{
	if (jy < JALAALI_MIN_YEAR || jy > JALAALI_MAX_YEAR)
		return false;
	if (jm < 1 || jm > 12)
		return false;
	if (jd < 1 || jd > jalaali_month_length(jy, jm))
		return false;
	return true;
}

int
jalaali_gregorian_to_jdn(int gy, int gm, int gd)
{
	int			d = jdiv((gy + jdiv(gm - 8, 6) + 100100) * 1461, 4)
		+ jdiv(153 * jmod(gm + 9, 12) + 2, 5)
		+ gd - 34840408;

	d = d - jdiv(jdiv(gy + 100100 + jdiv(gm - 8, 6), 100) * 3, 4) + 752;
	return d;
}

void
jalaali_jdn_to_gregorian(int jdn, int *gy, int *gm, int *gd)
{
	int			j = 4 * jdn + 139361631;
	int			i;

	j = j + jdiv(jdiv(4 * jdn + 183187720, 146097) * 3, 4) * 4 - 3908;
	i = jdiv(jmod(j, 1461), 4) * 5 + 308;
	*gd = jdiv(jmod(i, 153), 5) + 1;
	*gm = jmod(jdiv(i, 153), 12) + 1;
	*gy = jdiv(j, 1461) - 100100 + jdiv(8 - *gm, 6);
}

int
jalaali_to_jdn(int jy, int jm, int jd)
{
	JalCalResult r;

	jalaali_cal(jy, &r);
	return jalaali_gregorian_to_jdn(r.gy, 3, r.march)
		+ (jm - 1) * 31 - jdiv(jm, 7) * (jm - 7) + jd - 1;
}

/* Range endpoints, computed on first use and then reused. */
static bool range_ready = false;
static int	range_min_jdn;
static int	range_max_jdn;

static void
init_range(void)
{
	range_min_jdn = jalaali_to_jdn(JALAALI_MIN_YEAR, 1, 1);
	range_max_jdn = jalaali_to_jdn(JALAALI_MAX_YEAR, 12,
								   jalaali_month_length(JALAALI_MAX_YEAR, 12));
	range_ready = true;
}

int
jalaali_min_jdn(void)
{
	if (!range_ready)
		init_range();
	return range_min_jdn;
}

int
jalaali_max_jdn(void)
{
	if (!range_ready)
		init_range();
	return range_max_jdn;
}

bool
jalaali_from_jdn(int jdn, JalaaliDate *out)
{
	int			gy,
				gm,
				gd,
				jy,
				k;
	JalCalResult r;

	if (jdn < jalaali_min_jdn() || jdn > jalaali_max_jdn())
		return false;

	jalaali_jdn_to_gregorian(jdn, &gy, &gm, &gd);
	jy = gy - 621;
	if (jy > JALAALI_MAX_YEAR)
		jy = JALAALI_MAX_YEAR;

	jalaali_cal(jy, &r);
	k = jdn - jalaali_gregorian_to_jdn(r.gy, 3, r.march);
	if (k >= 0)
	{
		if (k <= 185)
		{
			out->jy = jy;
			out->jm = 1 + jdiv(k, 31);
			out->jd = jmod(k, 31) + 1;
			return true;
		}
		k -= 186;
	}
	else
	{
		jy -= 1;
		k += 179;
		if (r.leap == 1)
			k += 1;
	}
	out->jy = jy;
	out->jm = 7 + jdiv(k, 30);
	out->jd = jmod(k, 30) + 1;
	return true;
}
