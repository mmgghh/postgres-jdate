-- Range and multirange types over the three Jalali types: jdaterange (jdate),
-- jtsrange (jtimestamp) and jtstzrange (jtimestamptz), with the multirange types
-- jdatemultirange, jtsmultirange and jtstzmultirange and the arrays of all six.
-- Core's range operators are type-agnostic, so most of this file checks that
-- they work, and that they agree with core's own range types on the same bounds
-- (daterange, tsrange and tstzrange are the oracle: the days and instants are
-- the same numbers, only the calendar of the text differs). What is specific to
-- this extension is the canonical function of jdaterange, which must refuse the
-- one range core would canonicalize to a day jdate cannot display, and the bound
-- checks of the other two types. Errors are printed as SQLSTATEs, never as
-- message text; plans are tested through booleans, never printed.
--
-- The tables and the helper function created here are dropped at the end:
-- extension_schema runs DROP EXTENSION, which needs no column of our types left
-- behind.
SET DateStyle = 'ISO, YMD';
SET timezone = 'UTC';
\set VERBOSITY sqlstate

-- true when the EXPLAIN output of the query has a line matching the regexp
CREATE FUNCTION rt_plan_has(query text, pattern text) RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE
    line text;
BEGIN
    FOR line IN EXECUTE 'EXPLAIN (COSTS off) ' || query LOOP
        IF line ~ pattern THEN
            RETURN true;
        END IF;
    END LOOP;
    RETURN false;
END
$$;

-- ---------------------------------------------------------------------
-- (a) the types in the catalog: six range and multirange types, their arrays,
-- the subtype, the canonical and subtype_diff functions and the volatility of
-- the support functions
-- ---------------------------------------------------------------------
SELECT t.typname, t.typtype, a.typname AS array_type, a.typtype AS array_typtype
FROM pg_type t JOIN pg_type a ON a.oid = t.typarray
WHERE t.typname IN ('jdaterange', 'jtsrange', 'jtstzrange',
                    'jdatemultirange', 'jtsmultirange', 'jtstzmultirange')
ORDER BY t.typname COLLATE "C";

SELECT r.rngtypid::regtype AS range_type, r.rngsubtype::regtype AS subtype,
       r.rngmultitypid::regtype AS multirange_type,
       r.rngcanonical::regproc AS canonical, r.rngsubdiff::regproc AS subdiff,
       oc.opcname AS subtype_opclass
FROM pg_range r JOIN pg_opclass oc ON oc.oid = r.rngsubopc
WHERE r.rngtypid::regtype::text IN ('jdaterange', 'jtsrange', 'jtstzrange')
ORDER BY r.rngtypid::regtype::text COLLATE "C";

SELECT p.proname, p.provolatile, p.proparallel, p.proisstrict
FROM pg_proc p
WHERE p.pronamespace = (SELECT extnamespace FROM pg_extension WHERE extname = 'jdate')
  AND p.proname IN ('jdaterange_canonical', 'jdaterange_subdiff', 'jtsrange_subdiff', 'jtstzrange_subdiff')
ORDER BY p.proname COLLATE "C";

-- every function of the extension that mentions one of the six types in its
-- signature (the range and multirange constructors, the canonical and the
-- subtype_diff functions) is PARALLEL SAFE; none is an offender
SELECT count(*) AS range_functions,
       count(*) FILTER (WHERE p.proparallel <> 's') AS not_parallel_safe
FROM pg_proc p
JOIN pg_depend d ON d.classid = 'pg_proc'::regclass AND d.objid = p.oid
                AND d.deptype = 'e' AND d.refclassid = 'pg_extension'::regclass
                AND d.refobjid = (SELECT oid FROM pg_extension WHERE extname = 'jdate')
WHERE pg_get_function_identity_arguments(p.oid) ~ 'j(date|ts|tstz)(multi)?range'
   OR pg_get_function_result(p.oid) ~ '^j(date|ts|tstz)(multi)?range'
   OR p.proname ~ '^j(date|ts|tstz)(multi)?range';

-- the three range types and the subtype support functions belong to the
-- extension (the types are counted by the range types' own names only: which
-- array and multirange types pg_depend records as members is a PostgreSQL
-- version detail, 6 on 16 and 12 on 17 and later)
SELECT count(*) FILTER (WHERE i.type = 'type'
                          AND i.identity ~ '(^|\.)j(date|ts|tstz)range$') AS member_types,
       count(*) FILTER (WHERE i.type = 'function') AS member_functions
FROM pg_depend d,
     LATERAL pg_identify_object(d.classid, d.objid, d.objsubid) i
WHERE d.refclassid = 'pg_extension'::regclass
  AND d.refobjid = (SELECT oid FROM pg_extension WHERE extname = 'jdate')
  AND d.deptype = 'e'
  AND i.identity ~ 'j(date|ts|tstz)(multi)?range';

-- ---------------------------------------------------------------------
-- (b) jdaterange: literals print with our output function and are canonical,
-- [lower, upper)
-- ---------------------------------------------------------------------
SELECT '[1403-01-01,1403-01-31]'::jdaterange AS inclusive_upper;
SELECT '[1403-01-01,1403-02-01)'::jdaterange AS already_canonical;
SELECT '(1403-01-01,1403-01-31)'::jdaterange AS exclusive_lower;
SELECT '(1403-01-01,1403-01-31]'::jdaterange AS both_changed;
SELECT '[1403-06-31,1403-07-01]'::jdaterange AS across_month_length_31;
SELECT '[1403-12-29,1403-12-30]'::jdaterange AS leap_day_1403;
SELECT '[1404-12-29,1404-12-29]'::jdaterange AS no_leap_day_1404;
SELECT '[-0061-01-01,-0061-01-03]'::jdaterange AS at_the_minimum;
SELECT '(-0061-01-01,-0061-01-03)'::jdaterange AS exclusive_at_the_minimum;
SELECT '[3177-12-28,3177-12-29)'::jdaterange AS up_to_the_last_day;
SELECT jdaterange('1403-01-01', '1403-01-31', '[]') AS constructor_inclusive;
SELECT jdaterange('1403-01-01', '1403-01-31') AS constructor_default_bounds;
SELECT jdaterange('1403-01-01', '1403-01-31', '()') AS constructor_exclusive;
SELECT '[1403-01-01,1403-01-01)'::jdaterange AS empty_by_equal_bounds;
SELECT '(1403-01-01,1403-01-02)'::jdaterange AS empty_by_canonical_form;
SELECT 'empty'::jdaterange AS the_empty_range, isempty('empty'::jdaterange) AS is_empty;
SELECT '[ 1403-01-01 , 1403-01-31 ]'::jdaterange AS whitespace_in_the_literal;
SELECT '["1403-01-01","1403-01-31"]'::jdaterange AS quoted_bounds;

-- infinite bounds: no bound at all, and the date values infinity / -infinity
SELECT '[1403-01-01,)'::jdaterange AS no_upper_bound, '(,1403-01-01]'::jdaterange AS no_lower_bound,
       '[,]'::jdaterange AS unbounded, '(,)'::jdaterange AS unbounded_open;
SELECT '[1403-01-01,infinity]'::jdaterange AS infinity_upper,
       '[-infinity,1403-01-01]'::jdaterange AS minus_infinity_lower,
       '(-infinity,infinity)'::jdaterange AS both_infinities;
SELECT lower_inf('[1403-01-01,)'::jdaterange) AS lower_inf_no, upper_inf('[1403-01-01,)'::jdaterange) AS upper_inf_yes,
       upper_inf('[1403-01-01,infinity]'::jdaterange) AS upper_inf_of_the_infinity_date;

-- accessors, and upper - lower for a jdaterange is an int (jdate - jdate)
SELECT lower(r) AS lower, upper(r) AS upper, lower_inc(r) AS lower_inc, upper_inc(r) AS upper_inc,
       upper(r) - lower(r) AS days, pg_typeof(upper(r) - lower(r)) AS days_type
FROM (VALUES ('[1403-01-01,1403-01-31]'::jdaterange)) v(r);
SELECT lower(r) AS lower, upper(r) AS upper, upper(r) - lower(r) AS days
FROM (VALUES ('[1403-12-01,1404-01-01)'::jdaterange)) v(r);
SELECT lower('empty'::jdaterange) IS NULL AS lower_of_empty_is_null,
       upper('empty'::jdaterange) IS NULL AS upper_of_empty_is_null;
SELECT range_merge('[1403-01-01,1403-01-10)'::jdaterange, '[1403-02-01,1403-02-10)') AS merged_with_gap;

-- operators
SELECT '[1403-01-01,1403-02-01)'::jdaterange @> '1403-01-15'::jdate AS contains_element,
       '[1403-01-01,1403-02-01)'::jdaterange @> '1403-02-01'::jdate AS upper_bound_is_exclusive,
       '1403-01-15'::jdate <@ '[1403-01-01,1403-02-01)'::jdaterange AS element_contained_by,
       '[1403-01-01,1403-02-01)'::jdaterange @> '[1403-01-10,1403-01-20)'::jdaterange AS contains_range,
       '[1403-01-10,1403-01-20)'::jdaterange <@ '[1403-01-01,1403-02-01)'::jdaterange AS contained_by;
SELECT '[1403-01-01,1403-02-01)'::jdaterange && '[1403-01-20,1403-02-20)'::jdaterange AS overlaps,
       '[1403-01-01,1403-02-01)'::jdaterange && '[1403-02-01,1403-02-20)'::jdaterange AS touching_does_not_overlap,
       '[1403-01-01,1403-02-01)'::jdaterange -|- '[1403-02-01,1403-02-20)'::jdaterange AS adjacent,
       '[1403-01-01,1403-02-01)'::jdaterange << '[1403-03-01,1403-04-01)'::jdaterange AS strictly_left,
       '[1403-03-01,1403-04-01)'::jdaterange >> '[1403-01-01,1403-02-01)'::jdaterange AS strictly_right,
       '[1403-01-01,1403-03-01)'::jdaterange &< '[1403-02-01,1403-04-01)'::jdaterange AS not_extending_right,
       '[1403-02-01,1403-04-01)'::jdaterange &> '[1403-01-01,1403-03-01)'::jdaterange AS not_extending_left;
SELECT '[1403-01-01,1403-02-01)'::jdaterange + '[1403-02-01,1403-03-01)'::jdaterange AS union_of_adjacent,
       '[1403-01-01,1403-02-20)'::jdaterange + '[1403-02-01,1403-03-01)'::jdaterange AS union_of_overlapping,
       '[1403-01-01,1403-03-01)'::jdaterange - '[1403-02-01,1403-04-01)'::jdaterange AS difference,
       '[1403-01-01,1403-03-01)'::jdaterange * '[1403-02-01,1403-04-01)'::jdaterange AS intersection,
       '[1403-01-01,1403-02-01)'::jdaterange * '[1403-03-01,1403-04-01)'::jdaterange AS empty_intersection;
SELECT '[1403-01-01,1403-02-01)'::jdaterange + '[1403-03-01,1403-04-01)'::jdaterange AS union_with_a_gap;
SELECT '[1403-01-01,1403-03-01)'::jdaterange - '[1403-02-01,1403-02-10)'::jdaterange AS difference_in_the_middle;
SELECT '[1403-01-01,1403-02-01)'::jdaterange = '[1403-01-01,1403-01-31]'::jdaterange AS equal_after_canonicalization,
       '[1403-01-01,1403-02-01)'::jdaterange < '[1403-01-02,1403-02-01)'::jdaterange AS less_than,
       '[1403-01-01,1403-02-01)'::jdaterange <> 'empty'::jdaterange AS not_equal_to_empty;
-- results of operators are canonical too (made through the canonical function)
SELECT jdaterange('1403-01-01', '1403-01-10', '[]') + jdaterange('1403-01-11', '1403-01-20', '[]') AS union_of_inclusive_ranges;
SELECT range_agg(r) AS agg_merges_touching_ranges
FROM (VALUES ('[1403-01-01,1403-01-31]'::jdaterange), ('[1403-02-01,1403-02-10)'), ('[1403-05-01,1403-05-05]')) v(r);

-- ordering and grouping of ranges, through the btree operator class of jdaterange
SELECT r FROM (VALUES ('[1403-03-01,1403-04-01)'::jdaterange), ('empty'), ('[1403-01-01,1403-02-01)'), ('[,1403-01-01)'),
                      ('[1403-01-01,)'), ('[1403-01-01,1403-01-15)')) v(r)
ORDER BY r;
SELECT r, count(*) FROM (VALUES ('[1403-01-01,1403-01-31]'::jdaterange), ('[1403-01-01,1403-02-01)'), ('(1403-01-01,1403-02-01)')) v(r)
GROUP BY r ORDER BY r;
SELECT DISTINCT r FROM (VALUES ('[1403-01-01,1403-01-31]'::jdaterange), ('[1403-01-01,1403-02-01)'), ('empty'), ('empty')) v(r) ORDER BY r;

-- ---------------------------------------------------------------------
-- (c) the canonical edge: core turns the inclusive upper bound 3177-12-29 into
-- 3177-12-30, a day jdate cannot display; the range is refused with 22008
-- ---------------------------------------------------------------------
SELECT '[1403-01-01,3177-12-29]'::jdaterange;
SELECT '[3177-12-29,3177-12-29]'::jdaterange;
SELECT '[3177-12-28,3177-12-29]'::jdaterange;
SELECT '(3177-12-28,3177-12-29]'::jdaterange;
SELECT '[,3177-12-29]'::jdaterange;
-- an exclusive lower bound on the last day goes the same way, from below
SELECT '(3177-12-29,)'::jdaterange;
SELECT '(3177-12-29,infinity)'::jdaterange;
-- only the bound that moves is the problem: the last day as an exclusive upper bound, an
-- inclusive lower bound, and ranges that end at the date infinity are all fine
SELECT '[3177-12-29,)'::jdaterange AS last_day_open_ended;
SELECT '[3177-12-28,3177-12-29)'::jdaterange AS last_day_excluded;
SELECT '[1403-01-01,infinity]'::jdaterange AS infinity_inclusive;
SELECT '[3177-12-29,infinity]'::jdaterange AS last_day_to_infinity;
SELECT '(3177-12-28,3177-12-29)'::jdaterange AS one_day_gap_is_empty;
SELECT '(3177-12-29,3177-12-29]'::jdaterange AS empty_range_is_not_canonicalized;
-- through the constructors, and the SELECT of the value only to force the computation
SELECT jdaterange('3177-12-28', '3177-12-29', '[]') IS NOT NULL;
SELECT jdaterange('3177-12-29', '3177-12-29', '[]') IS NOT NULL;
SELECT jdaterange('3177-12-29', '3177-12-29', '[)') AS empty_by_constructor;
SELECT jdaterange('3177-12-28', '3177-12-29', '[)') AS ok_by_constructor;
SELECT jdaterange('3177-12-29', NULL, '[]') AS last_day_up_to_nothing;
-- multirange input and arrays make their ranges the same way
SELECT '{[1403-01-01,3177-12-29]}'::jdatemultirange;
SELECT '{[1403-01-01,3177-12-29)}'::jdatemultirange AS multirange_ok;
SELECT '{"[1403-01-01,3177-12-29]"}'::jdaterange[];
SELECT jdatemultirange(jdaterange('1403-01-01', '3177-12-29', '[]')) IS NOT NULL;
-- the first day is not an edge case: nothing is incremented below it
SELECT '[-0061-01-01,-0061-01-01]'::jdaterange AS first_day_alone;
SELECT '(-0061-01-01,-0061-01-02]'::jdaterange AS first_day_excluded;
-- the soft path: pg_input_is_valid and pg_input_error_info see 22008 as a soft error
SELECT pg_input_is_valid('[1403-01-01,3177-12-29]', 'jdaterange') AS edge_range_valid,
       pg_input_is_valid('[1403-01-01,3177-12-29)', 'jdaterange') AS ok_range_valid,
       pg_input_is_valid('{[1403-01-01,3177-12-29]}', 'jdatemultirange') AS edge_multirange_valid,
       (pg_input_error_info('[1403-01-01,3177-12-29]', 'jdaterange')).sql_error_code AS edge_range_sqlstate,
       (pg_input_error_info('(3177-12-29,)', 'jdaterange')).sql_error_code AS edge_lower_sqlstate;
-- other input errors keep core's SQLSTATE; a date outside the range as a bound is 22008 too
SELECT '[1403-13-01,1403-13-05)'::jdaterange;
SELECT '[1403-01-01,1403-01-31'::jdaterange;
SELECT '[1403-02-01,1403-01-01)'::jdaterange;
SELECT '[1403-01-01,1403-01-31,1403-02-01)'::jdaterange;
SELECT '[3177-12-30,)'::jdaterange;
SELECT '[-0062-12-29,1403-01-01)'::jdaterange;

-- ---------------------------------------------------------------------
-- (d) jtsrange and jtstzrange: continuous, no canonical function, bounds keep
-- their inclusivity
-- ---------------------------------------------------------------------
SELECT '[1403-01-01 00:00:00,1403-01-31 00:00:00]'::jtsrange AS inclusive_upper;
SELECT '(1403-01-01 00:00:00,1403-01-31 12:30:15.5)'::jtsrange AS exclusive_both;
SELECT '[1403-01-01,1403-01-31]'::jtsrange AS date_only_bounds;
SELECT jtsrange('1403-01-01 00:00:00', '1403-01-01 12:00:00', '[]') AS constructor;
SELECT '[1403-01-01 00:00:00,1403-01-01 00:00:00]'::jtsrange AS single_instant;
SELECT '[1403-01-01 00:00:00,1403-01-01 00:00:00)'::jtsrange AS empty_by_equal_bounds, isempty('[1403-01-01 00:00:00,1403-01-01 00:00:00)'::jtsrange) AS is_empty;
SELECT '[1403-01-01 00:00:00,)'::jtsrange AS no_upper_bound, '(,1403-01-01 00:00:00)'::jtsrange AS no_lower_bound,
       '[1403-01-01 00:00:00,infinity)'::jtsrange AS infinity_upper, '(-infinity,1403-01-01 00:00:00]'::jtsrange AS minus_infinity_lower;
SELECT lower(r) AS lower, upper(r) AS upper, lower_inc(r) AS lower_inc, upper_inc(r) AS upper_inc,
       upper(r) - lower(r) AS length, pg_typeof(upper(r) - lower(r)) AS length_type
FROM (VALUES ('[1403-01-01 00:00:00,1403-01-31 12:00:00)'::jtsrange)) v(r);
SELECT '[1403-01-01 00:00:00,1403-02-01 00:00:00)'::jtsrange @> '1403-01-15 10:00:00'::jtimestamp AS contains_element,
       '[1403-01-01 00:00:00,1403-02-01 00:00:00)'::jtsrange @> '1403-02-01 00:00:00'::jtimestamp AS upper_bound_is_exclusive,
       '[1403-01-01 00:00:00,1403-02-01 00:00:00]'::jtsrange @> '1403-02-01 00:00:00'::jtimestamp AS upper_bound_is_inclusive,
       '[1403-01-01 00:00:00,1403-02-01 00:00:00)'::jtsrange && '[1403-01-20 00:00:00,1403-02-20 00:00:00)'::jtsrange AS overlaps,
       '[1403-01-01 00:00:00,1403-02-01 00:00:00)'::jtsrange -|- '[1403-02-01 00:00:00,1403-02-20 00:00:00)'::jtsrange AS adjacent,
       '[1403-01-01 00:00:00,1403-02-01 00:00:00)'::jtsrange << '[1403-03-01 00:00:00,1403-04-01 00:00:00)'::jtsrange AS strictly_left;
SELECT '[1403-01-01 00:00:00,1403-02-01 00:00:00)'::jtsrange + '[1403-02-01 00:00:00,1403-03-01 00:00:00)'::jtsrange AS union_of_adjacent,
       '[1403-01-01 00:00:00,1403-03-01 00:00:00)'::jtsrange - '[1403-02-01 00:00:00,1403-04-01 00:00:00)'::jtsrange AS difference,
       '[1403-01-01 00:00:00,1403-03-01 00:00:00)'::jtsrange * '[1403-02-01 00:00:00,1403-04-01 00:00:00)'::jtsrange AS intersection;
SELECT range_merge('[1403-01-01 00:00:00,1403-01-10 00:00:00)'::jtsrange, '[1403-02-01 00:00:00,1403-02-10 00:00:00)') AS merged_with_gap;
-- the extremes: the first and the last microsecond of the range, and one beyond
SELECT '[-0061-01-01 00:00:00,3177-12-29 23:59:59.999999]'::jtsrange AS full_range;
SELECT '[-0061-01-01 00:00:00,3177-12-30 00:00:00]'::jtsrange;
SELECT '[-0062-12-29 23:59:59.999999,1403-01-01 00:00:00]'::jtsrange;
SELECT jtsrange('1403-01-01 00:00:00', '3178-01-01 00:00:00') IS NOT NULL;

-- jtstzrange: the bounds are instants; they print in the session time zone
SELECT '[1403-01-01 00:00:00+03:30,1403-01-31 00:00:00+03:30)'::jtstzrange AS in_utc;
SET timezone = 'Asia/Tehran';
SELECT '[1403-01-01 00:00:00+03:30,1403-01-31 00:00:00+03:30)'::jtstzrange AS in_tehran;
SELECT '[1403-01-01 00:00:00+03:30,1403-01-31 00:00:00+03:30)'::jtstzrange
     = '[1402-12-29 20:30:00+00,1403-01-30 20:30:00+00)'::jtstzrange AS same_instants_any_spelling;
SET timezone = 'America/New_York';
SELECT '[1403-01-01 00:00:00+03:30,1403-01-31 00:00:00+03:30)'::jtstzrange AS in_new_york;
SET timezone = 'UTC';
SELECT jtstzrange('1403-01-01 00:00:00+00', '1403-01-02 00:00:00+00', '[]') AS constructor;
SELECT '[1403-01-01 00:00:00+00,)'::jtstzrange AS no_upper_bound, '(,1403-01-01 00:00:00+00)'::jtstzrange AS no_lower_bound,
       '[1403-01-01 00:00:00+00,infinity)'::jtstzrange AS infinity_upper;
SELECT lower(r) AS lower, upper(r) AS upper, upper(r) - lower(r) AS length, pg_typeof(upper(r) - lower(r)) AS length_type
FROM (VALUES ('[1403-01-01 00:00:00+00,1403-01-31 12:00:00+00)'::jtstzrange)) v(r);
SELECT '[1403-01-01 00:00:00+00,1403-02-01 00:00:00+00)'::jtstzrange @> '1403-01-15 10:00:00+00'::jtimestamptz AS contains_element,
       '[1403-01-01 00:00:00+00,1403-02-01 00:00:00+00)'::jtstzrange && '[1403-01-20 00:00:00+00,1403-02-20 00:00:00+00)'::jtstzrange AS overlaps,
       '[1403-01-01 00:00:00+00,1403-02-01 00:00:00+00)'::jtstzrange -|- '[1403-02-01 00:00:00+00,1403-02-20 00:00:00+00)'::jtstzrange AS adjacent;
SELECT '[1403-01-01 00:00:00+00,1403-03-01 00:00:00+00)'::jtstzrange + '[1403-02-01 00:00:00+00,1403-04-01 00:00:00+00)'::jtstzrange AS union_of_overlapping,
       '[1403-01-01 00:00:00+00,1403-03-01 00:00:00+00)'::jtstzrange - '[1403-02-01 00:00:00+00,1403-04-01 00:00:00+00)'::jtstzrange AS difference,
       '[1403-01-01 00:00:00+00,1403-03-01 00:00:00+00)'::jtstzrange * '[1403-02-01 00:00:00+00,1403-04-01 00:00:00+00)'::jtstzrange AS intersection;
-- the safe range: the first valid instant, the last, and one microsecond beyond each
SELECT '[-0061-01-01 16:00:00+00,3177-12-29 07:59:59.999999+00]'::jtstzrange AS full_safe_range;
SELECT '[-0061-01-01 15:59:59.999999+00,1403-01-01 00:00:00+00)'::jtstzrange;
SELECT '[1403-01-01 00:00:00+00,3177-12-29 08:00:00+00)'::jtstzrange;
SELECT jtstzrange('1403-01-01 00:00:00+00', '3177-12-29 08:00:00+00') IS NOT NULL;

-- ---------------------------------------------------------------------
-- (e) multirange types: merging, accessors, operators, range_agg
-- ---------------------------------------------------------------------
SELECT '{}'::jdatemultirange AS empty_multirange, isempty('{}'::jdatemultirange) AS is_empty;
SELECT '{[1403-01-01,1403-01-31],[1403-02-01,1403-02-10)}'::jdatemultirange AS merged_touching;
SELECT '{[1403-05-01,1403-05-05],[1403-01-01,1403-01-15),[1403-01-10,1403-01-31]}'::jdatemultirange AS sorted_and_merged;
SELECT jdatemultirange(jdaterange('1403-01-01', '1403-01-31', '[]'), jdaterange('1403-02-01', '1403-02-10')) AS constructor_variadic;
SELECT jdatemultirange() AS constructor_no_arguments, jdatemultirange('[1403-01-01,1403-01-31]'::jdaterange) AS constructor_one;
SELECT lower(m) AS lower, upper(m) AS upper, lower_inc(m) AS lower_inc, upper_inc(m) AS upper_inc
FROM (VALUES ('{[1403-01-01,1403-01-15),[1403-05-01,1403-05-05)}'::jdatemultirange)) v(m);
SELECT range_merge('{[1403-01-01,1403-01-15),[1403-05-01,1403-05-05)}'::jdatemultirange) AS bounding_range;
SELECT unnest('{[1403-01-01,1403-01-15),[1403-05-01,1403-05-05)}'::jdatemultirange) AS the_ranges;
SELECT '{[1403-01-01,1403-01-15),[1403-05-01,1403-05-05)}'::jdatemultirange @> '1403-05-02'::jdate AS contains_element,
       '{[1403-01-01,1403-01-15),[1403-05-01,1403-05-05)}'::jdatemultirange @> '1403-03-01'::jdate AS gap_is_not_contained,
       '{[1403-01-01,1403-01-15),[1403-05-01,1403-05-05)}'::jdatemultirange @> '[1403-05-02,1403-05-04)'::jdaterange AS contains_range,
       '{[1403-01-01,1403-01-15),[1403-05-01,1403-05-05)}'::jdatemultirange && '[1403-01-14,1403-02-01)'::jdaterange AS overlaps_range,
       '{[1403-01-01,1403-01-15),[1403-05-01,1403-05-05)}'::jdatemultirange && '{[1403-02-01,1403-03-01)}'::jdatemultirange AS overlaps_multirange;
SELECT '{[1403-01-01,1403-01-15),[1403-05-01,1403-05-05)}'::jdatemultirange + '{[1403-01-10,1403-02-01)}'::jdatemultirange AS union_of_multiranges,
       '{[1403-01-01,1403-01-15),[1403-05-01,1403-05-05)}'::jdatemultirange - '{[1403-01-05,1403-01-08),[1403-05-02,1403-05-03)}'::jdatemultirange AS difference,
       '{[1403-01-01,1403-01-15),[1403-05-01,1403-05-05)}'::jdatemultirange * '{[1403-01-10,1403-05-02)}'::jdatemultirange AS intersection;
-- an inclusive upper bound is canonicalized inside a multirange too
SELECT '{[1403-01-01,1403-01-14],[1403-01-15,1403-01-31]}'::jdatemultirange AS canonical_inside_multirange;
SELECT range_agg(r) AS range_agg_of_dates
FROM (VALUES ('[1403-01-01,1403-01-31]'::jdaterange), ('[1403-02-01,1403-02-10)'), ('[1403-05-01,1403-05-05]')) v(r);
SELECT range_intersect_agg(r) AS range_intersect_agg_of_dates
FROM (VALUES ('[1403-01-01,1403-03-01)'::jdaterange), ('[1403-02-01,1403-04-01)'), ('[1403-02-15,1403-05-05]')) v(r);
SELECT range_agg(r) AS range_agg_of_nothing_is_null FROM (SELECT 'empty'::jdaterange WHERE false) v(r);
SELECT range_agg(m) AS range_agg_of_multiranges
FROM (VALUES ('{[1403-01-01,1403-01-31]}'::jdatemultirange), ('{[1403-01-20,1403-02-10)}'), ('{[1403-05-01,1403-05-05)}')) v(m);

SELECT '{[1403-01-01 00:00:00,1403-01-02 00:00:00],[1403-01-02 00:00:00,1403-01-03 00:00:00)}'::jtsmultirange AS merged_touching;
SELECT '{[1403-01-01 00:00:00,1403-01-02 00:00:00),(1403-01-02 00:00:00,1403-01-03 00:00:00)}'::jtsmultirange AS not_merged_the_instant_is_missing;
SELECT range_agg(r) AS range_agg_of_timestamps
FROM (VALUES ('[1403-01-01 00:00:00,1403-01-02 00:00:00)'::jtsrange), ('[1403-01-02 00:00:00,1403-01-05 00:00:00)'), ('[1403-02-01 00:00:00,1403-02-05 00:00:00)')) v(r);
SELECT '{[1403-01-01 00:00:00,1403-01-02 00:00:00),[1403-02-01 00:00:00,1403-02-05 00:00:00)}'::jtsmultirange @> '1403-02-02 12:00:00'::jtimestamp AS contains_element;
SELECT '{[1403-01-01 00:00:00+00,1403-01-02 00:00:00+00),[1403-02-01 00:00:00+00,1403-02-05 00:00:00+00)}'::jtstzmultirange AS tz_multirange;
SELECT range_agg(r) AS range_agg_of_timestamptz
FROM (VALUES ('[1403-01-01 00:00:00+00,1403-01-02 00:00:00+00)'::jtstzrange), ('[1403-01-02 00:00:00+00,1403-01-05 00:00:00+00)'), ('[1403-02-01 00:00:00+00,1403-02-05 00:00:00+00)')) v(r);
SELECT '{[1403-01-01 00:00:00+00,1403-01-02 00:00:00+00)}'::jtstzmultirange @> '1403-01-01 12:00:00+00'::jtimestamptz AS contains_element;
SELECT '{[-0061-01-01 15:59:59.999999+00,1403-01-01 00:00:00+00)}'::jtstzmultirange;
SELECT '{[1403-01-01 00:00:00,3178-01-01 00:00:00)}'::jtsmultirange;

-- ---------------------------------------------------------------------
-- (f) arrays of ranges and multiranges, and = ANY (array)
-- ---------------------------------------------------------------------
SELECT ARRAY['[1403-01-01,1403-01-31]'::jdaterange, '[1403-03-01,1403-04-01)', 'empty'] AS range_array;
SELECT '{"[1403-01-01,1403-02-01)","[1403-03-01,1403-04-01)",empty,NULL}'::jdaterange[] AS range_array_input;
SELECT ARRAY['{[1403-01-01,1403-01-31]}'::jdatemultirange, '{}'] AS multirange_array;
SELECT ARRAY['[1403-01-01 00:00:00,1403-01-02 00:00:00)'::jtsrange, '[1403-02-01 00:00:00,)'] AS timestamp_range_array;
SELECT ARRAY['[1403-01-01 00:00:00+00,1403-01-02 00:00:00+00)'::jtstzrange, '(,1403-02-01 00:00:00+00]'] AS timestamptz_range_array;
SELECT '[1403-01-01,1403-02-01)'::jdaterange = ANY (ARRAY['[1403-03-01,1403-04-01)'::jdaterange, '[1403-01-01,1403-01-31]']) AS any_equal,
       '[1403-01-01,1403-02-01)'::jdaterange = ANY (ARRAY['[1403-03-01,1403-04-01)'::jdaterange, '[1403-01-01,1403-01-30]']) AS any_not_equal,
       '[1403-01-01,1403-02-01)'::jdaterange = ALL (ARRAY['[1403-01-01,1403-01-31]'::jdaterange, '[1403-01-01,1403-02-01)']) AS all_equal,
       '1403-01-15'::jdate <@ ANY (ARRAY['[1403-03-01,1403-04-01)'::jdaterange, '[1403-01-01,1403-02-01)']) AS element_in_any_range,
       '[1403-01-10,1403-01-20)'::jdaterange <@ ANY (ARRAY['[1403-03-01,1403-04-01)'::jdaterange, '[1403-01-01,1403-02-01)']) AS range_in_any_range,
       '[1403-01-01 00:00:00,1403-01-02 00:00:00)'::jtsrange = ANY (ARRAY['[1403-01-01 00:00:00,1403-01-02 00:00:00)'::jtsrange]) AS any_timestamp_range,
       '[1403-01-01 00:00:00+00,1403-01-02 00:00:00+00)'::jtstzrange = ANY (ARRAY['[1403-01-01 00:00:00+00,1403-01-02 00:00:00+00)'::jtstzrange]) AS any_timestamptz_range;
SELECT array_agg(r ORDER BY r) AS aggregated
FROM (VALUES ('[1403-03-01,1403-04-01)'::jdaterange), ('[1403-01-01,1403-02-01)'), ('empty')) v(r);
SELECT unnest(ARRAY['[1403-03-01,1403-04-01)'::jdaterange, '[1403-01-01,1403-02-01)']) AS unnested ORDER BY 1;
SELECT array_position(ARRAY['[1403-03-01,1403-04-01)'::jdaterange, '[1403-01-01,1403-02-01)'], '[1403-01-01,1403-01-31]') AS position_after_canonicalization;
SELECT '{"[1403-01-01,3177-12-29]"}'::jdaterange[];
SELECT pg_typeof(ARRAY['[1403-01-01,1403-02-01)'::jdaterange]) AS array_type,
       pg_typeof(ARRAY['{[1403-01-01,1403-02-01)}'::jdatemultirange]) AS multirange_array_type;

-- ---------------------------------------------------------------------
-- (g) core's range types as an oracle: the same bounds, the same answers. A
-- jdaterange and a daterange built from the same day numbers (jdate is stored
-- as date is), for every pair of ranges of a small family, must agree on every
-- range operator; the same for jtsrange against tsrange and jtstzrange against
-- tstzrange.
-- ---------------------------------------------------------------------
CREATE TABLE rt_spec (n int, lo int, hi int, bounds text);
INSERT INTO rt_spec
SELECT row_number() OVER (), lo, hi, b
FROM (VALUES (0), (3), (7), (10)) l(lo),
     (VALUES (3), (4), (7), (12)) h(hi),
     (VALUES ('[]'), ('[)'), ('(]'), ('()')) bb(b)
WHERE lo <= hi;

CREATE TABLE rt_oracle AS
SELECT n,
       jdaterange(jdate '1403-05-01' + lo, jdate '1403-05-01' + hi, bounds) AS jd,
       daterange((jdate '1403-05-01' + lo)::date, (jdate '1403-05-01' + hi)::date, bounds) AS cd,
       jtsrange(jtimestamp '1403-05-01 00:00:00' + lo * interval '7 hours',
                jtimestamp '1403-05-01 00:00:00' + hi * interval '7 hours', bounds) AS jt,
       tsrange((jtimestamp '1403-05-01 00:00:00' + lo * interval '7 hours')::timestamp,
               (jtimestamp '1403-05-01 00:00:00' + hi * interval '7 hours')::timestamp, bounds) AS ct,
       jtstzrange(jtimestamptz '1403-05-01 00:00:00+00' + lo * interval '7 hours',
                  jtimestamptz '1403-05-01 00:00:00+00' + hi * interval '7 hours', bounds) AS jz,
       tstzrange((jtimestamptz '1403-05-01 00:00:00+00' + lo * interval '7 hours')::timestamptz,
                 (jtimestamptz '1403-05-01 00:00:00+00' + hi * interval '7 hours')::timestamptz, bounds) AS cz
FROM rt_spec;

-- the oracle table is not vacuous, and the bounds themselves agree
SELECT count(*) AS ranges,
       count(*) FILTER (WHERE isempty(jd)) AS empty_ranges,
       count(*) FILTER (WHERE isempty(jd) <> isempty(cd) OR isempty(jt) <> isempty(ct) OR isempty(jz) <> isempty(cz)) AS empty_mismatches,
       count(*) FILTER (WHERE NOT isempty(jd)
                          AND (lower(jd)::date IS DISTINCT FROM lower(cd) OR upper(jd)::date IS DISTINCT FROM upper(cd)
                               OR lower_inc(jd) <> lower_inc(cd) OR upper_inc(jd) <> upper_inc(cd))) AS canonical_form_mismatches,
       count(*) FILTER (WHERE NOT isempty(jt)
                          AND (lower(jt)::timestamp IS DISTINCT FROM lower(ct) OR upper(jt)::timestamp IS DISTINCT FROM upper(ct)
                               OR lower_inc(jt) <> lower_inc(ct) OR upper_inc(jt) <> upper_inc(ct))) AS ts_bound_mismatches,
       count(*) FILTER (WHERE NOT isempty(jz)
                          AND (lower(jz)::timestamptz IS DISTINCT FROM lower(cz) OR upper(jz)::timestamptz IS DISTINCT FROM upper(cz)
                               OR lower_inc(jz) <> lower_inc(cz) OR upper_inc(jz) <> upper_inc(cz))) AS tstz_bound_mismatches
FROM rt_oracle;

-- every ordered pair: the boolean operators, as one mismatch count per type
SELECT count(*) AS pairs,
       count(*) FILTER (WHERE (a.jd && b.jd, a.jd @> b.jd, a.jd <@ b.jd, a.jd << b.jd, a.jd >> b.jd,
                               a.jd &< b.jd, a.jd &> b.jd, a.jd -|- b.jd, a.jd = b.jd, a.jd < b.jd)
                              IS DISTINCT FROM
                              (a.cd && b.cd, a.cd @> b.cd, a.cd <@ b.cd, a.cd << b.cd, a.cd >> b.cd,
                               a.cd &< b.cd, a.cd &> b.cd, a.cd -|- b.cd, a.cd = b.cd, a.cd < b.cd)) AS jdaterange_mismatches,
       count(*) FILTER (WHERE (a.jt && b.jt, a.jt @> b.jt, a.jt <@ b.jt, a.jt << b.jt, a.jt >> b.jt,
                               a.jt &< b.jt, a.jt &> b.jt, a.jt -|- b.jt, a.jt = b.jt, a.jt < b.jt)
                              IS DISTINCT FROM
                              (a.ct && b.ct, a.ct @> b.ct, a.ct <@ b.ct, a.ct << b.ct, a.ct >> b.ct,
                               a.ct &< b.ct, a.ct &> b.ct, a.ct -|- b.ct, a.ct = b.ct, a.ct < b.ct)) AS jtsrange_mismatches,
       count(*) FILTER (WHERE (a.jz && b.jz, a.jz @> b.jz, a.jz <@ b.jz, a.jz << b.jz, a.jz >> b.jz,
                               a.jz &< b.jz, a.jz &> b.jz, a.jz -|- b.jz, a.jz = b.jz, a.jz < b.jz)
                              IS DISTINCT FROM
                              (a.cz && b.cz, a.cz @> b.cz, a.cz <@ b.cz, a.cz << b.cz, a.cz >> b.cz,
                               a.cz &< b.cz, a.cz &> b.cz, a.cz -|- b.cz, a.cz = b.cz, a.cz < b.cz)) AS jtstzrange_mismatches
FROM rt_oracle a CROSS JOIN rt_oracle b;

-- the range-valued operators, compared as bounds. A union is an error for a gap in both
-- worlds, so only pairs of non-empty ranges that overlap or touch (in that type) are unioned.
SELECT count(*) AS pairs_with_a_union,
       count(*) FILTER (WHERE lower(a.jd + b.jd)::date IS DISTINCT FROM lower(a.cd + b.cd)
                           OR upper(a.jd + b.jd)::date IS DISTINCT FROM upper(a.cd + b.cd)
                           OR lower_inc(a.jd + b.jd) <> lower_inc(a.cd + b.cd)
                           OR upper_inc(a.jd + b.jd) <> upper_inc(a.cd + b.cd)) AS jdaterange_union_mismatches
FROM rt_oracle a JOIN rt_oracle b ON (a.jd && b.jd OR a.jd -|- b.jd)
WHERE NOT isempty(a.jd) AND NOT isempty(b.jd);
SELECT count(*) AS pairs_with_a_union,
       count(*) FILTER (WHERE lower(a.jt + b.jt)::timestamp IS DISTINCT FROM lower(a.ct + b.ct)
                           OR upper(a.jt + b.jt)::timestamp IS DISTINCT FROM upper(a.ct + b.ct)
                           OR lower_inc(a.jt + b.jt) <> lower_inc(a.ct + b.ct)
                           OR upper_inc(a.jt + b.jt) <> upper_inc(a.ct + b.ct)) AS jtsrange_union_mismatches
FROM rt_oracle a JOIN rt_oracle b ON (a.jt && b.jt OR a.jt -|- b.jt)
WHERE NOT isempty(a.jt) AND NOT isempty(b.jt);
SELECT count(*) AS pairs_with_a_union,
       count(*) FILTER (WHERE lower(a.jz + b.jz)::timestamptz IS DISTINCT FROM lower(a.cz + b.cz)
                           OR upper(a.jz + b.jz)::timestamptz IS DISTINCT FROM upper(a.cz + b.cz)
                           OR lower_inc(a.jz + b.jz) <> lower_inc(a.cz + b.cz)
                           OR upper_inc(a.jz + b.jz) <> upper_inc(a.cz + b.cz)) AS jtstzrange_union_mismatches
FROM rt_oracle a JOIN rt_oracle b ON (a.jz && b.jz OR a.jz -|- b.jz)
WHERE NOT isempty(a.jz) AND NOT isempty(b.jz);
-- intersection and difference: emptiness, then bounds
SELECT count(*) AS pairs,
       count(*) FILTER (WHERE isempty(a.jd * b.jd) <> isempty(a.cd * b.cd)
                          OR (NOT isempty(a.jd * b.jd)
                              AND (lower(a.jd * b.jd)::date IS DISTINCT FROM lower(a.cd * b.cd)
                                   OR upper(a.jd * b.jd)::date IS DISTINCT FROM upper(a.cd * b.cd)))) AS jdaterange_intersection_mismatches,
       count(*) FILTER (WHERE isempty(a.jt * b.jt) <> isempty(a.ct * b.ct)
                          OR (NOT isempty(a.jt * b.jt)
                              AND (lower(a.jt * b.jt)::timestamp IS DISTINCT FROM lower(a.ct * b.ct)
                                   OR upper(a.jt * b.jt)::timestamp IS DISTINCT FROM upper(a.ct * b.ct)
                                   OR lower_inc(a.jt * b.jt) <> lower_inc(a.ct * b.ct)
                                   OR upper_inc(a.jt * b.jt) <> upper_inc(a.ct * b.ct)))) AS jtsrange_intersection_mismatches,
       count(*) FILTER (WHERE isempty(a.jz * b.jz) <> isempty(a.cz * b.cz)
                          OR (NOT isempty(a.jz * b.jz)
                              AND (lower(a.jz * b.jz)::timestamptz IS DISTINCT FROM lower(a.cz * b.cz)
                                   OR upper(a.jz * b.jz)::timestamptz IS DISTINCT FROM upper(a.cz * b.cz)
                                   OR lower_inc(a.jz * b.jz) <> lower_inc(a.cz * b.cz)
                                   OR upper_inc(a.jz * b.jz) <> upper_inc(a.cz * b.cz)))) AS jtstzrange_intersection_mismatches
FROM rt_oracle a CROSS JOIN rt_oracle b;
-- a difference is an error where it would split a range in two, in core and here alike, so the
-- pairs where the left range strictly contains the right one are left out
SELECT count(*) AS pairs,
       count(*) FILTER (WHERE isempty(a.jd - b.jd) <> isempty(a.cd - b.cd)
                          OR (NOT isempty(a.jd - b.jd)
                              AND (lower(a.jd - b.jd)::date IS DISTINCT FROM lower(a.cd - b.cd)
                                   OR upper(a.jd - b.jd)::date IS DISTINCT FROM upper(a.cd - b.cd)))) AS jdaterange_difference_mismatches
FROM rt_oracle a JOIN rt_oracle b ON NOT (a.jd @> b.jd AND a.jd <> b.jd);
SELECT count(*) AS pairs,
       count(*) FILTER (WHERE isempty(a.jt - b.jt) <> isempty(a.ct - b.ct)
                          OR (NOT isempty(a.jt - b.jt)
                              AND (lower(a.jt - b.jt)::timestamp IS DISTINCT FROM lower(a.ct - b.ct)
                                   OR upper(a.jt - b.jt)::timestamp IS DISTINCT FROM upper(a.ct - b.ct)
                                   OR lower_inc(a.jt - b.jt) <> lower_inc(a.ct - b.ct)
                                   OR upper_inc(a.jt - b.jt) <> upper_inc(a.ct - b.ct)))) AS jtsrange_difference_mismatches
FROM rt_oracle a JOIN rt_oracle b ON NOT (a.jt @> b.jt AND a.jt <> b.jt);
SELECT count(*) AS pairs,
       count(*) FILTER (WHERE isempty(a.jz - b.jz) <> isempty(a.cz - b.cz)
                          OR (NOT isempty(a.jz - b.jz)
                              AND (lower(a.jz - b.jz)::timestamptz IS DISTINCT FROM lower(a.cz - b.cz)
                                   OR upper(a.jz - b.jz)::timestamptz IS DISTINCT FROM upper(a.cz - b.cz)
                                   OR lower_inc(a.jz - b.jz) <> lower_inc(a.cz - b.cz)
                                   OR upper_inc(a.jz - b.jz) <> upper_inc(a.cz - b.cz)))) AS jtstzrange_difference_mismatches
FROM rt_oracle a JOIN rt_oracle b ON NOT (a.jz @> b.jz AND a.jz <> b.jz);

-- the ordering of ranges agrees with core's: the permutation that sorts the jdaterange
-- column sorts the daterange column, and so for the other two (ties broken by n)
SELECT (SELECT array_agg(n ORDER BY jd, n) FROM rt_oracle) = (SELECT array_agg(n ORDER BY cd, n) FROM rt_oracle) AS jdaterange_same_order,
       (SELECT array_agg(n ORDER BY jt, n) FROM rt_oracle) = (SELECT array_agg(n ORDER BY ct, n) FROM rt_oracle) AS jtsrange_same_order,
       (SELECT array_agg(n ORDER BY jz, n) FROM rt_oracle) = (SELECT array_agg(n ORDER BY cz, n) FROM rt_oracle) AS jtstzrange_same_order;

-- range_agg and range_merge against core's
SELECT lower(m)::date = lower(c) AND upper(m)::date = upper(c) AS merged_bounds_agree
FROM (SELECT range_merge(range_agg(jd)) AS m, range_merge(range_agg(cd)) AS c FROM rt_oracle) s;
SELECT (SELECT count(*) FROM unnest((SELECT range_agg(jd) FROM rt_oracle))) = (SELECT count(*) FROM unnest((SELECT range_agg(cd) FROM rt_oracle))) AS jdatemultirange_same_range_count,
       (SELECT count(*) FROM unnest((SELECT range_agg(jt) FROM rt_oracle))) = (SELECT count(*) FROM unnest((SELECT range_agg(ct) FROM rt_oracle))) AS jtsmultirange_same_range_count,
       (SELECT count(*) FROM unnest((SELECT range_agg(jz) FROM rt_oracle))) = (SELECT count(*) FROM unnest((SELECT range_agg(cz) FROM rt_oracle))) AS jtstzmultirange_same_range_count;

-- ---------------------------------------------------------------------
-- (h) a table with a column of each type, GiST indexes, an exclusion
-- constraint, btree on ranges, and the plan checks
-- ---------------------------------------------------------------------
CREATE TABLE rt_tab (
    id int PRIMARY KEY,
    d  jdaterange,
    ts jtsrange,
    tz jtstzrange,
    dm jdatemultirange
);
INSERT INTO rt_tab
SELECT i,
       jdaterange(jdate '1400-01-01' + i * 10, jdate '1400-01-01' + i * 10 + 25),
       jtsrange(jtimestamp '1400-01-01 00:00:00' + i * interval '10 hours',
                jtimestamp '1400-01-01 00:00:00' + i * interval '10 hours' + interval '25 hours'),
       jtstzrange(jtimestamptz '1400-01-01 00:00:00+00' + i * interval '10 hours',
                  jtimestamptz '1400-01-01 00:00:00+00' + i * interval '10 hours' + interval '25 hours'),
       jdatemultirange(jdaterange(jdate '1400-01-01' + i * 10, jdate '1400-01-01' + i * 10 + 5),
                       jdaterange(jdate '1400-01-01' + i * 10 + 12, jdate '1400-01-01' + i * 10 + 20))
FROM generate_series(0, 2999) i;
INSERT INTO rt_tab VALUES (3000, 'empty', 'empty', 'empty', '{}'),
                          (3001, '[1403-01-01,)', '[1403-01-01 00:00:00,)', '[1403-01-01 00:00:00+00,)', '{[1403-01-01,)}'),
                          (3002, '(,1403-01-01)', '(,1403-01-01 00:00:00)', '(,1403-01-01 00:00:00+00)', '{(,1403-01-01)}'),
                          (3003, NULL, NULL, NULL, NULL);
CREATE INDEX rt_tab_d_gist ON rt_tab USING gist (d);
CREATE INDEX rt_tab_ts_gist ON rt_tab USING gist (ts);
CREATE INDEX rt_tab_tz_gist ON rt_tab USING gist (tz);
CREATE INDEX rt_tab_dm_gist ON rt_tab USING gist (dm);
ANALYZE rt_tab;

-- the planner uses the GiST indexes for the range operators, and the answers under the
-- index equal the answers of an oracle that cannot use it (an intersection is empty
-- exactly when the ranges do not overlap, and * is not indexable)
SET enable_seqscan = off;
SELECT rt_plan_has('SELECT count(*) FROM rt_tab WHERE d && ''[1410-01-01,1410-02-01)''::jdaterange',
                   'rt_tab_d_gist') AS jdaterange_overlaps_uses_gist,
       rt_plan_has('SELECT count(*) FROM rt_tab WHERE d @> ''1410-01-15''::jdate',
                   'rt_tab_d_gist') AS jdaterange_contains_element_uses_gist,
       rt_plan_has('SELECT count(*) FROM rt_tab WHERE d <@ ''[1410-01-01,1420-01-01)''::jdaterange',
                   'rt_tab_d_gist') AS jdaterange_contained_by_uses_gist,
       rt_plan_has('SELECT count(*) FROM rt_tab WHERE ts && ''[1400-02-01 00:00:00,1400-02-02 00:00:00)''::jtsrange',
                   'rt_tab_ts_gist') AS jtsrange_overlaps_uses_gist,
       rt_plan_has('SELECT count(*) FROM rt_tab WHERE tz && ''[1400-02-01 00:00:00+00,1400-02-02 00:00:00+00)''::jtstzrange',
                   'rt_tab_tz_gist') AS jtstzrange_overlaps_uses_gist,
       rt_plan_has('SELECT count(*) FROM rt_tab WHERE dm && ''{[1410-01-01,1410-02-01)}''::jdatemultirange',
                   'rt_tab_dm_gist') AS jdatemultirange_overlaps_uses_gist;
SELECT count(*) > 0 AS some_rows, count(*) = (SELECT count(*) FROM rt_tab WHERE NOT isempty(d * '[1410-01-01,1410-02-01)'::jdaterange)) AS overlaps_same_as_the_oracle
FROM rt_tab WHERE d && '[1410-01-01,1410-02-01)'::jdaterange;
SELECT count(*) > 0 AS some_rows, count(*) = (SELECT count(*) FROM rt_tab WHERE NOT isempty(d * jdaterange('1410-01-15', '1410-01-15', '[]'))) AS contains_element_same_as_the_oracle
FROM rt_tab WHERE d @> '1410-01-15'::jdate;
SELECT count(*) > 0 AS some_rows, count(*) = (SELECT count(*) FROM rt_tab WHERE d * '[1410-01-01,1420-01-01)'::jdaterange = d) AS contained_by_same_as_the_oracle
FROM rt_tab WHERE d <@ '[1410-01-01,1420-01-01)'::jdaterange;
SELECT count(*) > 0 AS some_rows, count(*) = (SELECT count(*) FROM rt_tab WHERE NOT isempty(ts * '[1400-02-01 00:00:00,1400-02-02 00:00:00)'::jtsrange)) AS jtsrange_same_as_the_oracle
FROM rt_tab WHERE ts && '[1400-02-01 00:00:00,1400-02-02 00:00:00)'::jtsrange;
SELECT count(*) > 0 AS some_rows, count(*) = (SELECT count(*) FROM rt_tab WHERE NOT isempty(tz * '[1400-02-01 00:00:00+00,1400-02-02 00:00:00+00)'::jtstzrange)) AS jtstzrange_same_as_the_oracle
FROM rt_tab WHERE tz && '[1400-02-01 00:00:00+00,1400-02-02 00:00:00+00)'::jtstzrange;
SELECT count(*) > 0 AS some_rows, count(*) = (SELECT count(*) FROM rt_tab WHERE NOT isempty(dm * '{[1410-01-01,1410-02-01)}'::jdatemultirange)) AS jdatemultirange_same_as_the_oracle
FROM rt_tab WHERE dm && '{[1410-01-01,1410-02-01)}'::jdatemultirange;
RESET enable_seqscan;

-- SP-GiST serves the range operators too (the GiST index is dropped so the planner has to choose it)
DROP INDEX rt_tab_d_gist;
CREATE INDEX rt_tab_d_spgist ON rt_tab USING spgist (d);
SET enable_seqscan = off;
SET enable_bitmapscan = off;
SELECT rt_plan_has('SELECT count(*) FROM rt_tab WHERE d && ''[1410-01-01,1410-02-01)''::jdaterange',
                   'rt_tab_d_spgist') AS jdaterange_overlaps_uses_spgist;
SELECT count(*) > 0 AS some_rows, count(*) = (SELECT count(*) FROM rt_tab WHERE NOT isempty(d * '[1410-01-01,1410-02-01)'::jdaterange)) AS overlaps_same_as_the_oracle
FROM rt_tab WHERE d && '[1410-01-01,1410-02-01)'::jdaterange;
RESET enable_bitmapscan;
RESET enable_seqscan;
DROP INDEX rt_tab_d_spgist;

-- a btree index on a range column (the range operator class compares bounds with the btree
-- operator class of the subtype); the key is a range that exists in the table
CREATE INDEX rt_tab_d_btree ON rt_tab USING btree (d);
SET enable_seqscan = off;
SELECT rt_plan_has(format('SELECT id FROM rt_tab WHERE d = %L::jdaterange', (SELECT d FROM rt_tab WHERE id = 100)),
                   'rt_tab_d_btree') AS jdaterange_equality_uses_btree;
RESET enable_seqscan;
SELECT id FROM rt_tab WHERE d = (SELECT d FROM rt_tab WHERE id = 100);
SELECT id FROM rt_tab WHERE d = (SELECT jdaterange(lower(d), upper(d) - 1, '[]') FROM rt_tab WHERE id = 100);
SELECT id, d FROM rt_tab WHERE d IS NOT NULL ORDER BY d LIMIT 3;
SELECT id, d FROM rt_tab WHERE d IS NOT NULL ORDER BY d DESC LIMIT 3;

-- an exclusion constraint with &&: non-overlapping bookings are accepted, an overlap is 23P01
CREATE TABLE rt_booking (
    room int,
    during jdaterange,
    EXCLUDE USING gist (during WITH &&)
);
INSERT INTO rt_booking VALUES (1, '[1403-05-01,1403-05-10]'), (2, '[1403-05-11,1403-05-20]');
INSERT INTO rt_booking VALUES (3, '[1403-05-10,1403-05-12)');
INSERT INTO rt_booking VALUES (4, '[1403-05-21,1403-05-30)');
SELECT room, during FROM rt_booking ORDER BY room;
DROP TABLE rt_booking;

-- unique and primary key use the btree class too
CREATE TABLE rt_uniq (r jtstzrange PRIMARY KEY);
INSERT INTO rt_uniq VALUES ('[1403-01-01 00:00:00+00,1403-01-02 00:00:00+00)');
INSERT INTO rt_uniq VALUES ('[1403-01-01 00:00:00+00,1403-01-02 00:00:00+00)');
INSERT INTO rt_uniq VALUES ('[1403-01-01 00:00:00+00,1403-01-03 00:00:00+00)');
SELECT count(*) AS rows_kept FROM rt_uniq;
DROP TABLE rt_uniq;

-- ---------------------------------------------------------------------
-- (i) casts to and from core's range types are not provided (a range value embeds the OID of
-- its own range type): no cast row, and an explicit cast is 42846; the bounds convert one by one
-- ---------------------------------------------------------------------
SELECT count(*) AS range_casts_to_core_types
FROM pg_cast c
WHERE (c.castsource::regtype::text IN ('jdaterange', 'jtsrange', 'jtstzrange')
       AND c.casttarget::regtype::text IN ('daterange', 'tsrange', 'tstzrange'))
   OR (c.castsource::regtype::text IN ('daterange', 'tsrange', 'tstzrange')
       AND c.casttarget::regtype::text IN ('jdaterange', 'jtsrange', 'jtstzrange'));
SELECT '[1403-01-01,1403-02-01)'::jdaterange::daterange;
SELECT '[2024-03-20,2024-04-20)'::daterange::jdaterange;
SELECT '[1403-01-01 00:00:00,1403-02-01 00:00:00)'::jtsrange::tsrange;
SELECT '[1403-01-01 00:00:00+00,1403-02-01 00:00:00+00)'::jtstzrange::tstzrange;
SELECT daterange(lower(r)::date, upper(r)::date) AS bounds_converted_one_by_one
FROM (VALUES ('[1403-01-01,1403-02-01)'::jdaterange)) v(r);
-- the casts between a range and its multirange are core's, and they work
SELECT '[1403-01-01,1403-01-31]'::jdaterange::jdatemultirange AS range_as_multirange;

-- ---------------------------------------------------------------------
-- (j) binary I/O: COPY (FORMAT binary) round trip of range and multirange columns, and
-- the bounds are validated on receive (a core daterange whose bound is beyond the Jalali
-- range loads as 22008). The binary files live under test/results/.
-- ---------------------------------------------------------------------
CREATE TABLE rt_bin (id int, d jdaterange, ts jtsrange, tz jtstzrange, dm jdatemultirange,
                     tsm jtsmultirange, tzm jtstzmultirange, da jdaterange[]);
INSERT INTO rt_bin VALUES
  (1, '[1403-01-01,1403-01-31]', '[1403-01-01 00:00:00,1403-01-31 12:34:56.789)', '[1403-01-01 00:00:00+03:30,1403-01-31 00:00:00+03:30]',
      '{[1403-01-01,1403-01-31],[1403-03-01,1403-03-05)}', '{[1403-01-01 00:00:00,1403-01-02 00:00:00)}',
      '{[1403-01-01 00:00:00+00,1403-01-02 00:00:00+00)}', ARRAY['[1403-01-01,1403-01-31]'::jdaterange, 'empty']),
  (2, 'empty', 'empty', 'empty', '{}', '{}', '{}', '{}'),
  (3, '[-0061-01-01,-0061-01-03)', '[-0061-01-01 00:00:00,)', '(,3177-12-29 07:59:59.999999+00]',
      '{[-0061-01-01,)}', '{(,3177-12-29 23:59:59.999999]}', '{[-0061-01-01 16:00:00+00,3177-12-29 07:59:59.999999+00]}', NULL),
  (4, '[3177-12-28,3177-12-29)', '[1403-01-01 00:00:00,infinity]', '(-infinity,1403-01-01 00:00:00+00)',
      '{[1403-01-01,infinity]}', '{[-infinity,1403-01-01 00:00:00]}', '{(,)}', ARRAY[NULL, '[1403-01-01,)']::jdaterange[]),
  (5, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
\copy rt_bin TO 'test/results/jt_rangetypes.bin' WITH (FORMAT binary)
CREATE TABLE rt_bin_back (LIKE rt_bin);
\copy rt_bin_back FROM 'test/results/jt_rangetypes.bin' WITH (FORMAT binary)
SELECT count(*) AS rows_back,
       count(*) FILTER (WHERE (a.d, a.ts, a.tz, a.dm, a.tsm, a.tzm, a.da)::text IS NOT DISTINCT FROM (b.d, b.ts, b.tz, b.dm, b.tsm, b.tzm, b.da)::text) AS rows_equal
FROM rt_bin a JOIN rt_bin_back b USING (id);
SELECT id, d, ts, tz, dm, da FROM rt_bin_back ORDER BY id;
SELECT bool_and(encode(range_send(a.d), 'hex') = encode(range_send(b.d), 'hex')) AS jdaterange_send_equal,
       bool_and(encode(range_send(a.ts), 'hex') = encode(range_send(b.ts), 'hex')) AS jtsrange_send_equal,
       bool_and(encode(range_send(a.tz), 'hex') = encode(range_send(b.tz), 'hex')) AS jtstzrange_send_equal
FROM rt_bin a JOIN rt_bin_back b USING (id) WHERE a.d IS NOT NULL;

-- core's daterange loaded as jdaterange: the same file means the same days
CREATE TABLE rt_bin_core (d daterange, ts tsrange, tz tstzrange, dm datemultirange);
INSERT INTO rt_bin_core VALUES ('[2024-03-20,2024-04-20)', '[2024-03-20 00:00:00,2024-04-20 12:00:00)',
                                '[2024-03-20 00:00:00+00,2024-04-20 12:00:00+00)', '{[2024-03-20,2024-04-20)}');
\copy rt_bin_core TO 'test/results/jt_rangetypes_core.bin' WITH (FORMAT binary)
CREATE TABLE rt_bin_as_j (d jdaterange, ts jtsrange, tz jtstzrange, dm jdatemultirange);
\copy rt_bin_as_j FROM 'test/results/jt_rangetypes_core.bin' WITH (FORMAT binary)
SELECT d, ts, tz, dm FROM rt_bin_as_j;

-- a core range with a bound beyond the Jalali range is refused, one file for each bound that
-- core accepts and the Jalali calendar cannot show; nothing is loaded
CREATE TABLE rt_bin_out (d daterange);
INSERT INTO rt_bin_out VALUES ('[3799-03-18,3799-03-19]');
\copy rt_bin_out TO 'test/results/jt_rangetypes_edge.bin' WITH (FORMAT binary)
CREATE TABLE rt_bin_in (d jdaterange);
\copy rt_bin_in FROM 'test/results/jt_rangetypes_edge.bin' WITH (FORMAT binary)
SELECT count(*) AS rows_loaded FROM rt_bin_in;
TRUNCATE rt_bin_out;
INSERT INTO rt_bin_out VALUES ('[0560-03-19,0560-03-21)');
\copy rt_bin_out TO 'test/results/jt_rangetypes_low.bin' WITH (FORMAT binary)
\copy rt_bin_in FROM 'test/results/jt_rangetypes_low.bin' WITH (FORMAT binary)
SELECT count(*) AS rows_loaded FROM rt_bin_in;
TRUNCATE rt_bin_out;
INSERT INTO rt_bin_out VALUES ('[3799-03-18,3799-03-19)');
\copy rt_bin_out TO 'test/results/jt_rangetypes_last.bin' WITH (FORMAT binary)
\copy rt_bin_in FROM 'test/results/jt_rangetypes_last.bin' WITH (FORMAT binary)
SELECT d FROM rt_bin_in;

-- ---------------------------------------------------------------------
-- (k) other places a range value is built: a range column's DEFAULT and CHECK, a generated
-- column, and ranges inside a view
-- ---------------------------------------------------------------------
CREATE TABLE rt_def (
    id int,
    r jdaterange NOT NULL DEFAULT '[1403-01-01,1403-01-31]',
    len int GENERATED ALWAYS AS (upper(r) - lower(r)) STORED,
    CONSTRAINT rt_def_inside_1403 CHECK (r <@ '[1403-01-01,1404-01-01)'::jdaterange)
);
INSERT INTO rt_def (id) VALUES (1);
INSERT INTO rt_def (id, r) VALUES (2, '[1403-12-01,1403-12-29]');
INSERT INTO rt_def (id, r) VALUES (3, '[1403-12-01,1404-01-02)');
INSERT INTO rt_def (id, r) VALUES (4, '[1403-12-01,3177-12-29]');
SELECT id, r, len FROM rt_def ORDER BY id;
UPDATE rt_def SET r = '[1403-02-01,1403-02-11]' WHERE id = 1;
SELECT id, r, len FROM rt_def ORDER BY id;
DROP TABLE rt_def;
CREATE VIEW rt_view AS
SELECT d, upper(d) - lower(d) AS days, d @> '1410-01-15'::jdate AS has_day
FROM rt_tab WHERE id < 3;
SELECT * FROM rt_view ORDER BY d;
DROP VIEW rt_view;

-- ---------------------------------------------------------------------
-- (l) clean up
-- ---------------------------------------------------------------------
DROP TABLE rt_bin, rt_bin_back, rt_bin_core, rt_bin_as_j, rt_bin_out, rt_bin_in;
DROP TABLE rt_oracle, rt_spec, rt_tab;
DROP FUNCTION rt_plan_has(text, text);
