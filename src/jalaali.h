#ifndef JALAALI_H
#define JALAALI_H

#include <stdbool.h>

#define JALAALI_MIN_YEAR (-61)
#define JALAALI_MAX_YEAR 3177

typedef struct JalaaliDate
{
	int			jy;
	int			jm;
	int			jd;
} JalaaliDate;

typedef struct JalCalResult
{
	int			leap;			/* 0..3; 0 means jy is leap */
	int			gy;				/* Gregorian year of Farvardin 1 */
	int			march;			/* Gregorian day-of-March of Farvardin 1 */
} JalCalResult;

extern bool jalaali_cal(int jy, JalCalResult *out);
extern bool jalaali_is_leap_year(int jy, bool *is_leap);
extern int jalaali_month_length(int jy, int jm);
extern bool jalaali_is_valid_date(int jy, int jm, int jd);
extern int jalaali_to_jdn(int jy, int jm, int jd);
extern bool jalaali_from_jdn(int jdn, JalaaliDate *out);

/*
 * JDNs of the first and last supported days: -0061-01-01 and 3177-12-29.
 * Computed once and cached, so range checks are cheap.
 */
extern int jalaali_min_jdn(void);
extern int jalaali_max_jdn(void);

/* Exposed for cross-checking against Postgres's date2j/j2date. */
extern int jalaali_gregorian_to_jdn(int gy, int gm, int gd);
extern void jalaali_jdn_to_gregorian(int jdn, int *gy, int *gm, int *gd);

#endif
