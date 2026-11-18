-- jtimestamp and jtimestamptz, same-type comparison: the six operators, ordering
-- and sort support, btree builds with duplicates, the shared btree family
-- jdatetime_ops, the hash opclasses (hash join and hash aggregate), planner
-- use. Errors are shown as SQLSTATE only; plans are never printed, only
-- booleans taken from them.
--
-- The tables created here are dropped at the end: extension_schema runs
-- DROP EXTENSION, which needs no column of our types left behind.
SET DateStyle = 'ISO, YMD';
SET timezone = 'UTC';
\set VERBOSITY sqlstate

-- EXPLAIN node lines with the indentation and "->" stripped, so the test can
-- turn the plan into booleans without printing it.
CREATE FUNCTION jt_ops_plan(query text) RETURNS SETOF text
LANGUAGE plpgsql AS $$
DECLARE
    line text;
BEGIN
    FOR line IN EXECUTE 'EXPLAIN (COSTS off) ' || query LOOP
        RETURN NEXT regexp_replace(line, '^[ ]*(->)?[ ]*', '');
    END LOOP;
END
$$;

-- ---------------------------------------------------------------------
-- the operators in the catalog: the same shape for jdate and both new types
-- ---------------------------------------------------------------------
-- one row per operator name: the estimators and flags are the same for the
-- three types (that is what the "types" column counts)
SELECT o.oprname AS operator,
       o.oprrest::regproc AS restrict, o.oprjoin::regproc AS join_estimator,
       o.oprcanhash AS hashes, o.oprcanmerge AS merges,
       c.oprname AS commutator, n.oprname AS negator,
       count(*) AS types
FROM pg_operator o
LEFT JOIN pg_operator c ON c.oid = o.oprcom
LEFT JOIN pg_operator n ON n.oid = o.oprnegate
WHERE o.oprleft = o.oprright
  AND o.oprname IN ('=', '<>', '<', '<=', '>', '>=')
  AND o.oprleft IN ('jdate'::regtype, 'jtimestamp'::regtype, 'jtimestamptz'::regtype)
GROUP BY 1, 2, 3, 4, 5, 6, 7
ORDER BY o.oprname COLLATE "C";

-- every operator is its commutator's and negator's partner, within its own type
SELECT count(*) AS operators,
       count(*) FILTER (WHERE c.oprcom = o.oid AND c.oprleft = o.oprleft) AS commutator_pairs,
       count(*) FILTER (WHERE n.oprnegate = o.oid AND n.oprleft = o.oprleft) AS negator_pairs
FROM pg_operator o
JOIN pg_operator c ON c.oid = o.oprcom
JOIN pg_operator n ON n.oid = o.oprnegate
WHERE o.oprleft = o.oprright
  AND o.oprname IN ('=', '<>', '<', '<=', '>', '>=')
  AND o.oprleft IN ('jtimestamp'::regtype, 'jtimestamptz'::regtype);

-- the functions: IMMUTABLE (also for jtimestamptz), STRICT, PARALLEL SAFE, and
-- C functions of the extension
SELECT p.provolatile AS volatility, p.proparallel AS parallel, p.proisstrict AS strict,
       l.lanname AS language, count(*) AS functions
FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang
WHERE p.proname ~ '^jtimestamp(tz)?_(eq|ne|lt|le|gt|ge|cmp|hash|hash_extended)$'
GROUP BY 1, 2, 3, 4;

-- the operator functions return bool, the cmp functions int4, the hash ones
-- int4 and int8
SELECT regexp_replace(p.proname, '^jtimestamp(tz)?_', '') AS function,
       p.prorettype::regtype AS returns, count(*) AS types
FROM pg_proc p
WHERE p.proname ~ '^jtimestamp(tz)?_(eq|ne|lt|le|gt|ge|cmp|hash|hash_extended)$'
GROUP BY 1, 2
ORDER BY regexp_replace(p.proname, '^jtimestamp(tz)?_', '') COLLATE "C";

-- =====================================================================
-- jtimestamp
-- =====================================================================
-- Rows are in ascending order of value; `rank` is the position of the value
-- in the order, equal values sharing a rank, so the expectation for every
-- operator can be read off the ranks.
CREATE TEMP TABLE jt_ops_ts (id int PRIMARY KEY, rank int, v jtimestamp);
INSERT INTO jt_ops_ts VALUES
    (1, 1, '-infinity'),
    (2, 2, '-0061-01-01 00:00:00'),
    (3, 3, '-0061-01-01 00:00:00.000001'),
    (4, 4, '1402-12-29 23:59:59.999999'),
    (5, 5, '1403-01-01 00:00:00'),
    (6, 5, ('2024-03-20 00:00:00'::timestamp)::jtimestamp),
    (7, 6, '1403-01-01 00:00:00.000001'),
    (8, 7, '3177-12-29 23:59:59.999999'),
    (9, 8, 'infinity');
SELECT id, rank, v FROM jt_ops_ts ORDER BY id;

-- ---------------------------------------------------------------------
-- truth tables: row a, column b (in id order), 1 where `a op b` is true
-- ---------------------------------------------------------------------
SELECT a.id,
       string_agg(CASE WHEN a.v =  b.v THEN '1' ELSE '0' END, '' ORDER BY b.id) AS eq,
       string_agg(CASE WHEN a.v <> b.v THEN '1' ELSE '0' END, '' ORDER BY b.id) AS ne,
       string_agg(CASE WHEN a.v <  b.v THEN '1' ELSE '0' END, '' ORDER BY b.id) AS lt,
       string_agg(CASE WHEN a.v <= b.v THEN '1' ELSE '0' END, '' ORDER BY b.id) AS le,
       string_agg(CASE WHEN a.v >  b.v THEN '1' ELSE '0' END, '' ORDER BY b.id) AS gt,
       string_agg(CASE WHEN a.v >= b.v THEN '1' ELSE '0' END, '' ORDER BY b.id) AS ge
FROM jt_ops_ts a CROSS JOIN jt_ops_ts b
GROUP BY a.id ORDER BY a.id;

-- all pairs against the ranks and against core's operators on the same
-- values (timestamp is the oracle); the control compares with the opposite order
-- and must find mismatches, so the comparison can fail
SELECT count(*) AS pairs,
       count(*) FILTER (WHERE (a.v = b.v) <> (a.rank = b.rank)
                           OR (a.v <> b.v) <> (a.rank <> b.rank)
                           OR (a.v < b.v) <> (a.rank < b.rank)
                           OR (a.v <= b.v) <> (a.rank <= b.rank)
                           OR (a.v > b.v) <> (a.rank > b.rank)
                           OR (a.v >= b.v) <> (a.rank >= b.rank)) AS rank_mismatches,
       count(*) FILTER (WHERE (a.v = b.v) <> (a.v::timestamp = b.v::timestamp)
                           OR (a.v <> b.v) <> (a.v::timestamp <> b.v::timestamp)
                           OR (a.v < b.v) <> (a.v::timestamp < b.v::timestamp)
                           OR (a.v <= b.v) <> (a.v::timestamp <= b.v::timestamp)
                           OR (a.v > b.v) <> (a.v::timestamp > b.v::timestamp)
                           OR (a.v >= b.v) <> (a.v::timestamp >= b.v::timestamp)) AS core_mismatches,
       count(*) FILTER (WHERE (a.v < b.v) <> (a.rank > b.rank)) > 0 AS control_detects
FROM jt_ops_ts a CROSS JOIN jt_ops_ts b;

-- the operators agree with the cmp function: cmp is -1, 0 or 1 by the rank
SELECT count(*) FILTER (WHERE sign(jtimestamp_cmp(a.v, b.v)) <> sign(a.rank - b.rank)) AS cmp_mismatches,
       count(*) FILTER (WHERE jtimestamp_cmp(a.v, b.v) NOT IN (-1, 0, 1)) AS cmp_out_of_range
FROM jt_ops_ts a CROSS JOIN jt_ops_ts b;

-- comparison does not look at the session time zone: the whole matrix, hashed,
-- is the same under four zones
CREATE TEMP TABLE jt_ops_sig_ts (zone text, sig text);
SET timezone = 'UTC';
INSERT INTO jt_ops_sig_ts SELECT current_setting('TimeZone'), md5(string_agg(
    (a.v = b.v)::text || (a.v <> b.v)::text || (a.v < b.v)::text || (a.v <= b.v)::text
    || (a.v > b.v)::text || (a.v >= b.v)::text, ',' ORDER BY a.id, b.id))
FROM jt_ops_ts a CROSS JOIN jt_ops_ts b;
SET timezone = 'Asia/Tehran';
INSERT INTO jt_ops_sig_ts SELECT current_setting('TimeZone'), md5(string_agg(
    (a.v = b.v)::text || (a.v <> b.v)::text || (a.v < b.v)::text || (a.v <= b.v)::text
    || (a.v > b.v)::text || (a.v >= b.v)::text, ',' ORDER BY a.id, b.id))
FROM jt_ops_ts a CROSS JOIN jt_ops_ts b;
SET timezone = 'Pacific/Kiritimati';
INSERT INTO jt_ops_sig_ts SELECT current_setting('TimeZone'), md5(string_agg(
    (a.v = b.v)::text || (a.v <> b.v)::text || (a.v < b.v)::text || (a.v <= b.v)::text
    || (a.v > b.v)::text || (a.v >= b.v)::text, ',' ORDER BY a.id, b.id))
FROM jt_ops_ts a CROSS JOIN jt_ops_ts b;
SET timezone = 'America/Los_Angeles';
INSERT INTO jt_ops_sig_ts SELECT current_setting('TimeZone'), md5(string_agg(
    (a.v = b.v)::text || (a.v <> b.v)::text || (a.v < b.v)::text || (a.v <= b.v)::text
    || (a.v > b.v)::text || (a.v >= b.v)::text, ',' ORDER BY a.id, b.id))
FROM jt_ops_ts a CROSS JOIN jt_ops_ts b;
SET timezone = 'UTC';
SELECT count(*) AS zones, count(DISTINCT sig) AS distinct_matrices FROM jt_ops_sig_ts;

-- NULL in, NULL out (the functions are STRICT)
SELECT (NULL::jtimestamp = v) IS NULL AS eq, (v <> NULL::jtimestamp) IS NULL AS ne,
       (NULL::jtimestamp < v) IS NULL AS lt, (v <= NULL::jtimestamp) IS NULL AS le,
       (NULL::jtimestamp > v) IS NULL AS gt, (v >= NULL::jtimestamp) IS NULL AS ge,
       jtimestamp_cmp(v, NULL) IS NULL AS cmp
FROM jt_ops_ts WHERE id = 5;

-- a value with a typmod compares as the rounded value
SELECT '1403-01-01 00:00:00.5'::jtimestamp(0) = '1403-01-01 00:00:01'::jtimestamp AS rounded_equal,
       '1403-01-01 00:00:00.4'::jtimestamp(0) = '1403-01-01 00:00:00'::jtimestamp AS rounded_down_equal;

-- DISTINCT and GROUP BY (sort based here: no hash plan is forced)
SELECT count(DISTINCT v) AS distinct_values, count(DISTINCT rank) AS distinct_ranks FROM jt_ops_ts;

-- ---------------------------------------------------------------------
-- ORDER BY over 4,000 rows with duplicates, infinities and both range edges
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jt_ops_sort_ts (id int, v jtimestamp);
INSERT INTO jt_ops_sort_ts
SELECT g, CASE
        WHEN g % 50 = 0 THEN 'infinity'::jtimestamp
        WHEN g % 50 = 1 THEN '-infinity'::jtimestamp
        WHEN g % 50 = 2 THEN '-0061-01-01 00:00:00'::jtimestamp
        WHEN g % 50 = 3 THEN '3177-12-29 23:59:59.999999'::jtimestamp
        ELSE ('0600-01-01 00:00:00'::timestamp + ((g * 7919) % 1100000) * interval '1 day'
              + (g % 7) * interval '1 microsecond')::jtimestamp
    END
FROM generate_series(1, 4000) g;

-- non-decreasing in both directions, and the same order as core's type
SELECT count(*) AS rows_sorted,
       count(*) FILTER (WHERE v < prev_v) AS inversions
FROM (SELECT v, lag(v) OVER (ORDER BY v, id) AS prev_v FROM jt_ops_sort_ts) s;
SELECT count(*) AS rows_sorted,
       count(*) FILTER (WHERE v > prev_v) AS inversions
FROM (SELECT v, lag(v) OVER (ORDER BY v DESC, id) AS prev_v FROM jt_ops_sort_ts) s;
SELECT (SELECT array_agg(id ORDER BY v, id) FROM jt_ops_sort_ts)
     = (SELECT array_agg(id ORDER BY v::timestamp, id) FROM jt_ops_sort_ts) AS same_order_as_core,
       (SELECT array_agg(id ORDER BY v DESC, id) FROM jt_ops_sort_ts)
     = (SELECT array_agg(id ORDER BY v::timestamp DESC, id) FROM jt_ops_sort_ts) AS same_desc_order_as_core,
       (SELECT array_agg(id ORDER BY v, id) FROM jt_ops_sort_ts)
     <> (SELECT array_agg(id ORDER BY v DESC, id) FROM jt_ops_sort_ts) AS control_orders_differ;
SELECT (SELECT v FROM jt_ops_sort_ts ORDER BY v LIMIT 1) AS first_value,
       (SELECT v FROM jt_ops_sort_ts ORDER BY v DESC LIMIT 1) AS last_value,
       (SELECT v FROM jt_ops_sort_ts WHERE v > '-infinity' ORDER BY v LIMIT 1) AS first_finite,
       (SELECT v FROM jt_ops_sort_ts WHERE v < 'infinity' ORDER BY v DESC LIMIT 1) AS last_finite;
SELECT count(DISTINCT v) > 3000 AS many_distinct, count(*) - count(DISTINCT v) > 0 AS has_duplicates
FROM jt_ops_sort_ts;

-- ---------------------------------------------------------------------
-- btree build over heavy duplicates (20 distinct values, 20,000 rows): the
-- deduplicated index is smaller than the same index without deduplication
-- (the class is deduplication-safe) and returns the same rows
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jt_ops_dup_ts (id int, v jtimestamp);
INSERT INTO jt_ops_dup_ts
SELECT g, CASE g % 20
        WHEN 0 THEN 'infinity'::jtimestamp
        WHEN 1 THEN '-infinity'::jtimestamp
        WHEN 2 THEN '-0061-01-01 00:00:00'::jtimestamp
        WHEN 3 THEN '3177-12-29 23:59:59.999999'::jtimestamp
        ELSE ('2024-03-20 00:00:00'::timestamp + (g % 20) * interval '1 hour')::jtimestamp
    END
FROM generate_series(1, 20000) g;
CREATE INDEX jt_ops_dup_ts_dedup ON jt_ops_dup_ts (v) WITH (deduplicate_items = on);
CREATE INDEX jt_ops_dup_ts_nodedup ON jt_ops_dup_ts (v) WITH (deduplicate_items = off);
SELECT pg_relation_size('jt_ops_dup_ts_dedup') < pg_relation_size('jt_ops_dup_ts_nodedup') AS dedup_smaller;
DROP INDEX jt_ops_dup_ts_nodedup;
ANALYZE jt_ops_dup_ts;

SET enable_seqscan = off;
SET enable_bitmapscan = off;
SELECT bool_or(l ~ '^Index (Only )?Scan using jt_ops_dup_ts_dedup') AS equality_uses_index
FROM jt_ops_plan($q$SELECT id FROM jt_ops_dup_ts WHERE v = '-0061-01-01 00:00:00'::jtimestamp$q$) l;
SELECT bool_or(l ~ '^Index (Only )?Scan using jt_ops_dup_ts_dedup') AS range_uses_index
FROM jt_ops_plan($q$SELECT id FROM jt_ops_dup_ts WHERE v >= '-0061-01-01 00:00:00'::jtimestamp AND v < 'infinity'$q$) l;
CREATE TEMP TABLE jt_ops_dup_res_ts (method text, v jtimestamp, n bigint, total bigint);
INSERT INTO jt_ops_dup_res_ts
SELECT 'index', v, count(*), sum(id) FROM jt_ops_dup_ts
WHERE v IN ('infinity', '-infinity', '-0061-01-01 00:00:00', '3177-12-29 23:59:59.999999', ('2024-03-20 00:00:00'::timestamp + 5 * interval '1 hour')::jtimestamp, ('2024-03-20 00:00:00'::timestamp + 11 * interval '1 hour')::jtimestamp) GROUP BY v;
RESET enable_seqscan;
RESET enable_bitmapscan;
SET enable_indexscan = off;
SET enable_bitmapscan = off;
INSERT INTO jt_ops_dup_res_ts
SELECT 'seq', v, count(*), sum(id) FROM jt_ops_dup_ts
WHERE v IN ('infinity', '-infinity', '-0061-01-01 00:00:00', '3177-12-29 23:59:59.999999', ('2024-03-20 00:00:00'::timestamp + 5 * interval '1 hour')::jtimestamp, ('2024-03-20 00:00:00'::timestamp + 11 * interval '1 hour')::jtimestamp) GROUP BY v;
RESET enable_indexscan;
RESET enable_bitmapscan;
SELECT v, n, total FROM jt_ops_dup_res_ts WHERE method = 'index' ORDER BY v;
SELECT count(*) AS values_compared,
       count(*) FILTER (WHERE i.n = s.n AND i.total = s.total) AS same_rows
FROM jt_ops_dup_res_ts i JOIN jt_ops_dup_res_ts s ON s.v = i.v AND s.method = 'seq'
WHERE i.method = 'index';

-- ---------------------------------------------------------------------
-- planner: a selective predicate uses the btree with the planner's own
-- choice (nothing disabled), a predicate that takes nearly every row does not
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jt_ops_big_ts AS
SELECT g AS id, ('2024-03-20 00:00:00'::timestamp + g * interval '1 hour')::jtimestamp AS v FROM generate_series(1, 20000) g;
CREATE INDEX jt_ops_big_ts_idx ON jt_ops_big_ts (v);
ANALYZE jt_ops_big_ts;
SELECT bool_or(l ~ '^Index (Only )?Scan using jt_ops_big_ts_idx') AS equality_index_scan
FROM jt_ops_plan('SELECT id FROM jt_ops_big_ts WHERE v = (SELECT v FROM jt_ops_big_ts WHERE id = 777)') l;
SELECT bool_or(l ~ '^(Index|Bitmap Index) (Only )?Scan') AS equality_literal_uses_index
FROM jt_ops_plan(format('SELECT id FROM jt_ops_big_ts WHERE v = %L::jtimestamp', (SELECT v FROM jt_ops_big_ts WHERE id = 777))) l;
SELECT bool_or(l ~ '^(Index|Bitmap Index) (Only )?Scan') AS narrow_range_uses_index,
       bool_or(l ~ '^Seq Scan') AS narrow_range_seq_scan
FROM jt_ops_plan(format('SELECT id FROM jt_ops_big_ts WHERE v < %L::jtimestamp', (SELECT v FROM jt_ops_big_ts WHERE id = 20))) l;
SELECT bool_or(l ~ '^Seq Scan') AS wide_range_seq_scan
FROM jt_ops_plan(format('SELECT id FROM jt_ops_big_ts WHERE v < %L::jtimestamp', (SELECT v FROM jt_ops_big_ts WHERE id = 19990))) l;
-- the index answers ORDER BY ... LIMIT without a sort
SELECT bool_or(l ~ '^Index (Only )?Scan using jt_ops_big_ts_idx') AS order_by_limit_index_scan,
       bool_or(l ~ '^Sort') AS order_by_limit_sort
FROM jt_ops_plan('SELECT id FROM jt_ops_big_ts ORDER BY v LIMIT 10') l;
-- the same answer by the index and by a sequential scan
SET enable_seqscan = off;
SET enable_bitmapscan = off;
SELECT count(*) AS idx_rows, sum(id) AS idx_sum
FROM jt_ops_big_ts WHERE v BETWEEN (SELECT v FROM jt_ops_big_ts WHERE id = 100) AND (SELECT v FROM jt_ops_big_ts WHERE id = 5000);
RESET enable_seqscan;
RESET enable_bitmapscan;
SET enable_indexscan = off;
SET enable_bitmapscan = off;
SELECT count(*) AS seq_rows, sum(id) AS seq_sum
FROM jt_ops_big_ts WHERE v BETWEEN (SELECT v FROM jt_ops_big_ts WHERE id = 100) AND (SELECT v FROM jt_ops_big_ts WHERE id = 5000);
RESET enable_indexscan;
RESET enable_bitmapscan;

-- ---------------------------------------------------------------------
-- hash support: equal values hash equally and as core's type does; the
-- seeded hash agrees with the plain one in the low 32 bits at seed 0
-- ---------------------------------------------------------------------
SELECT count(*) FILTER (WHERE a.rank = b.rank AND jtimestamp_hash(a.v) <> jtimestamp_hash(b.v)) AS equal_values_unequal_hash,
       count(*) FILTER (WHERE a.rank = b.rank AND jtimestamp_hash_extended(a.v, 7) <> jtimestamp_hash_extended(b.v, 7)) AS equal_values_unequal_ext_hash,
       count(*) FILTER (WHERE a.rank <> b.rank AND jtimestamp_hash(a.v) = jtimestamp_hash(b.v)) AS distinct_values_same_hash
FROM jt_ops_ts a CROSS JOIN jt_ops_ts b;
SELECT count(*) AS values,
       count(*) FILTER (WHERE jtimestamp_hash(v) <> timestamp_hash(v::timestamp)) AS hash_mismatches,
       count(*) FILTER (WHERE jtimestamp_hash_extended(v, 7) <> timestamp_hash_extended(v::timestamp, 7)) AS ext_hash_mismatches,
       count(*) FILTER (WHERE (jtimestamp_hash_extended(v, 0) & 4294967295) <> (jtimestamp_hash(v)::bigint & 4294967295)) AS seed0_mismatches,
       count(*) FILTER (WHERE jtimestamp_hash_extended(v, 1) <> jtimestamp_hash_extended(v, 0)) > 0 AS seed_changes_hash
FROM jt_ops_ts;

-- ---------------------------------------------------------------------
-- Hash Join and HashAggregate give the same rows as the sort-based plans:
-- a has 300 distinct values, three rows each, plus both infinities;
-- b has every second value for 400 values, plus both infinities
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jt_ops_ja_ts (v jtimestamp, n int);
CREATE TEMP TABLE jt_ops_jb_ts (v jtimestamp, m int);
INSERT INTO jt_ops_ja_ts SELECT ('2024-03-20 00:00:00'::timestamp + (g % 300) * interval '1 hour')::jtimestamp, g FROM generate_series(0, 899) g;
INSERT INTO jt_ops_jb_ts SELECT ('2024-03-20 00:00:00'::timestamp + (g * 2) * interval '1 hour')::jtimestamp, g FROM generate_series(0, 199) g;
INSERT INTO jt_ops_ja_ts VALUES ('infinity', 1000), ('-infinity', 1001);
INSERT INTO jt_ops_jb_ts VALUES ('infinity', 2000), ('-infinity', 2001);
ANALYZE jt_ops_ja_ts;
ANALYZE jt_ops_jb_ts;

CREATE TEMP TABLE jt_ops_jres_ts (method text, join_rows bigint, checksum bigint);

SET enable_mergejoin = off;
SET enable_nestloop = off;
SELECT bool_or(l ~ '^Hash Join') AS hash_join_planned
FROM jt_ops_plan('SELECT * FROM jt_ops_ja_ts a JOIN jt_ops_jb_ts b ON a.v = b.v') l;
INSERT INTO jt_ops_jres_ts
SELECT 'hash', count(*), sum(a.n + b.m) FROM jt_ops_ja_ts a JOIN jt_ops_jb_ts b ON a.v = b.v;
RESET enable_mergejoin;
RESET enable_nestloop;

SET enable_hashjoin = off;
SET enable_nestloop = off;
SELECT bool_or(l ~ '^Merge Join') AS merge_join_planned
FROM jt_ops_plan('SELECT * FROM jt_ops_ja_ts a JOIN jt_ops_jb_ts b ON a.v = b.v') l;
INSERT INTO jt_ops_jres_ts
SELECT 'merge', count(*), sum(a.n + b.m) FROM jt_ops_ja_ts a JOIN jt_ops_jb_ts b ON a.v = b.v;
RESET enable_hashjoin;
RESET enable_nestloop;

SET enable_hashjoin = off;
SET enable_mergejoin = off;
SELECT bool_or(l ~ '^Nested Loop') AS nested_loop_planned
FROM jt_ops_plan('SELECT * FROM jt_ops_ja_ts a JOIN jt_ops_jb_ts b ON a.v = b.v') l;
INSERT INTO jt_ops_jres_ts
SELECT 'nestloop', count(*), sum(a.n + b.m) FROM jt_ops_ja_ts a JOIN jt_ops_jb_ts b ON a.v = b.v;
RESET enable_hashjoin;
RESET enable_mergejoin;

SELECT method, join_rows, checksum FROM jt_ops_jres_ts ORDER BY method;
SELECT count(DISTINCT (join_rows, checksum)) AS distinct_results FROM jt_ops_jres_ts;

CREATE TEMP TABLE jt_ops_ares_ts (method text, grp bigint, total bigint, biggest bigint);

SET enable_sort = off;
SELECT bool_or(l ~ '^HashAggregate') AS hash_aggregate_planned
FROM jt_ops_plan('SELECT v, count(*) FROM jt_ops_ja_ts GROUP BY v') l;
INSERT INTO jt_ops_ares_ts
SELECT 'hash', count(*), sum(c), max(c) FROM (SELECT v, count(*) AS c FROM jt_ops_ja_ts GROUP BY v) s;
RESET enable_sort;

SET enable_hashagg = off;
SELECT bool_or(l ~ '^GroupAggregate') AS group_aggregate_planned
FROM jt_ops_plan('SELECT v, count(*) FROM jt_ops_ja_ts GROUP BY v') l;
INSERT INTO jt_ops_ares_ts
SELECT 'sort', count(*), sum(c), max(c) FROM (SELECT v, count(*) AS c FROM jt_ops_ja_ts GROUP BY v) s;
RESET enable_hashagg;

SELECT method, grp, total, biggest FROM jt_ops_ares_ts ORDER BY method;
SELECT count(DISTINCT (grp, total, biggest)) AS distinct_results FROM jt_ops_ares_ts;

-- SELECT DISTINCT through a hash and through a sort
SET enable_sort = off;
SELECT bool_or(l ~ '^HashAggregate') AS hash_distinct_planned
FROM jt_ops_plan('SELECT DISTINCT v FROM jt_ops_ja_ts') l;
SELECT count(*) AS distinct_by_hash FROM (SELECT DISTINCT v FROM jt_ops_ja_ts) s;
RESET enable_sort;
SET enable_hashagg = off;
SELECT bool_or(l ~ '^(Unique|GroupAggregate)') AS sort_distinct_planned
FROM jt_ops_plan('SELECT DISTINCT v FROM jt_ops_ja_ts') l;
SELECT count(*) AS distinct_by_sort FROM (SELECT DISTINCT v FROM jt_ops_ja_ts) s;
RESET enable_hashagg;

-- =====================================================================
-- jtimestamptz
-- =====================================================================
-- Rows are in ascending order of value; `rank` is the position of the value
-- in the order, equal values sharing a rank, so the expectation for every
-- operator can be read off the ranks.
CREATE TEMP TABLE jt_ops_tz (id int PRIMARY KEY, rank int, v jtimestamptz);
INSERT INTO jt_ops_tz VALUES
    (1, 1, '-infinity'),
    (2, 2, '-0061-01-01 16:00:00+00'),
    (3, 3, '-0061-01-01 16:00:00.000001+00'),
    (4, 4, '1402-12-29 20:29:59.999999+00'),
    (5, 5, '1403-01-01 00:00:00+03:30'),
    (6, 5, '1402-12-29 20:30:00+00'),
    (7, 5, '1402-12-29 16:30:00 America/New_York'),
    (8, 5, ('2024-03-19 20:30:00+00'::timestamptz)::jtimestamptz),
    (9, 6, '1402-12-29 20:30:00.000001+00'),
    (10, 7, '3177-12-29 07:59:59.999999+00'),
    (11, 8, 'infinity');
SELECT id, rank, v FROM jt_ops_tz ORDER BY id;

-- ---------------------------------------------------------------------
-- truth tables: row a, column b (in id order), 1 where `a op b` is true
-- ---------------------------------------------------------------------
SELECT a.id,
       string_agg(CASE WHEN a.v =  b.v THEN '1' ELSE '0' END, '' ORDER BY b.id) AS eq,
       string_agg(CASE WHEN a.v <> b.v THEN '1' ELSE '0' END, '' ORDER BY b.id) AS ne,
       string_agg(CASE WHEN a.v <  b.v THEN '1' ELSE '0' END, '' ORDER BY b.id) AS lt,
       string_agg(CASE WHEN a.v <= b.v THEN '1' ELSE '0' END, '' ORDER BY b.id) AS le,
       string_agg(CASE WHEN a.v >  b.v THEN '1' ELSE '0' END, '' ORDER BY b.id) AS gt,
       string_agg(CASE WHEN a.v >= b.v THEN '1' ELSE '0' END, '' ORDER BY b.id) AS ge
FROM jt_ops_tz a CROSS JOIN jt_ops_tz b
GROUP BY a.id ORDER BY a.id;

-- all pairs against the ranks and against core's operators on the same
-- values (timestamptz is the oracle); the control compares with the opposite order
-- and must find mismatches, so the comparison can fail
SELECT count(*) AS pairs,
       count(*) FILTER (WHERE (a.v = b.v) <> (a.rank = b.rank)
                           OR (a.v <> b.v) <> (a.rank <> b.rank)
                           OR (a.v < b.v) <> (a.rank < b.rank)
                           OR (a.v <= b.v) <> (a.rank <= b.rank)
                           OR (a.v > b.v) <> (a.rank > b.rank)
                           OR (a.v >= b.v) <> (a.rank >= b.rank)) AS rank_mismatches,
       count(*) FILTER (WHERE (a.v = b.v) <> (a.v::timestamptz = b.v::timestamptz)
                           OR (a.v <> b.v) <> (a.v::timestamptz <> b.v::timestamptz)
                           OR (a.v < b.v) <> (a.v::timestamptz < b.v::timestamptz)
                           OR (a.v <= b.v) <> (a.v::timestamptz <= b.v::timestamptz)
                           OR (a.v > b.v) <> (a.v::timestamptz > b.v::timestamptz)
                           OR (a.v >= b.v) <> (a.v::timestamptz >= b.v::timestamptz)) AS core_mismatches,
       count(*) FILTER (WHERE (a.v < b.v) <> (a.rank > b.rank)) > 0 AS control_detects
FROM jt_ops_tz a CROSS JOIN jt_ops_tz b;

-- the operators agree with the cmp function: cmp is -1, 0 or 1 by the rank
SELECT count(*) FILTER (WHERE sign(jtimestamptz_cmp(a.v, b.v)) <> sign(a.rank - b.rank)) AS cmp_mismatches,
       count(*) FILTER (WHERE jtimestamptz_cmp(a.v, b.v) NOT IN (-1, 0, 1)) AS cmp_out_of_range
FROM jt_ops_tz a CROSS JOIN jt_ops_tz b;

-- comparison does not look at the session time zone: the whole matrix, hashed,
-- is the same under four zones
CREATE TEMP TABLE jt_ops_sig_tz (zone text, sig text);
SET timezone = 'UTC';
INSERT INTO jt_ops_sig_tz SELECT current_setting('TimeZone'), md5(string_agg(
    (a.v = b.v)::text || (a.v <> b.v)::text || (a.v < b.v)::text || (a.v <= b.v)::text
    || (a.v > b.v)::text || (a.v >= b.v)::text, ',' ORDER BY a.id, b.id))
FROM jt_ops_tz a CROSS JOIN jt_ops_tz b;
SET timezone = 'Asia/Tehran';
INSERT INTO jt_ops_sig_tz SELECT current_setting('TimeZone'), md5(string_agg(
    (a.v = b.v)::text || (a.v <> b.v)::text || (a.v < b.v)::text || (a.v <= b.v)::text
    || (a.v > b.v)::text || (a.v >= b.v)::text, ',' ORDER BY a.id, b.id))
FROM jt_ops_tz a CROSS JOIN jt_ops_tz b;
SET timezone = 'Pacific/Kiritimati';
INSERT INTO jt_ops_sig_tz SELECT current_setting('TimeZone'), md5(string_agg(
    (a.v = b.v)::text || (a.v <> b.v)::text || (a.v < b.v)::text || (a.v <= b.v)::text
    || (a.v > b.v)::text || (a.v >= b.v)::text, ',' ORDER BY a.id, b.id))
FROM jt_ops_tz a CROSS JOIN jt_ops_tz b;
SET timezone = 'America/Los_Angeles';
INSERT INTO jt_ops_sig_tz SELECT current_setting('TimeZone'), md5(string_agg(
    (a.v = b.v)::text || (a.v <> b.v)::text || (a.v < b.v)::text || (a.v <= b.v)::text
    || (a.v > b.v)::text || (a.v >= b.v)::text, ',' ORDER BY a.id, b.id))
FROM jt_ops_tz a CROSS JOIN jt_ops_tz b;
SET timezone = 'UTC';
SELECT count(*) AS zones, count(DISTINCT sig) AS distinct_matrices FROM jt_ops_sig_tz;

-- NULL in, NULL out (the functions are STRICT)
SELECT (NULL::jtimestamptz = v) IS NULL AS eq, (v <> NULL::jtimestamptz) IS NULL AS ne,
       (NULL::jtimestamptz < v) IS NULL AS lt, (v <= NULL::jtimestamptz) IS NULL AS le,
       (NULL::jtimestamptz > v) IS NULL AS gt, (v >= NULL::jtimestamptz) IS NULL AS ge,
       jtimestamptz_cmp(v, NULL) IS NULL AS cmp
FROM jt_ops_tz WHERE id = 5;

-- a value with a typmod compares as the rounded value
SELECT '1403-01-01 00:00:00.5'::jtimestamptz(0) = '1403-01-01 00:00:01'::jtimestamptz AS rounded_equal,
       '1403-01-01 00:00:00.4'::jtimestamptz(0) = '1403-01-01 00:00:00'::jtimestamptz AS rounded_down_equal;

-- DISTINCT and GROUP BY (sort based here: no hash plan is forced)
SELECT count(DISTINCT v) AS distinct_values, count(DISTINCT rank) AS distinct_ranks FROM jt_ops_tz;

-- ---------------------------------------------------------------------
-- ORDER BY over 4,000 rows with duplicates, infinities and both range edges
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jt_ops_sort_tz (id int, v jtimestamptz);
INSERT INTO jt_ops_sort_tz
SELECT g, CASE
        WHEN g % 50 = 0 THEN 'infinity'::jtimestamptz
        WHEN g % 50 = 1 THEN '-infinity'::jtimestamptz
        WHEN g % 50 = 2 THEN '-0061-01-01 16:00:00+00'::jtimestamptz
        WHEN g % 50 = 3 THEN '3177-12-29 07:59:59.999999+00'::jtimestamptz
        ELSE ('0600-01-01 00:00:00+00'::timestamptz + ((g * 7919) % 1100000) * interval '1 day'
              + (g % 7) * interval '1 microsecond')::jtimestamptz
    END
FROM generate_series(1, 4000) g;

-- non-decreasing in both directions, and the same order as core's type
SELECT count(*) AS rows_sorted,
       count(*) FILTER (WHERE v < prev_v) AS inversions
FROM (SELECT v, lag(v) OVER (ORDER BY v, id) AS prev_v FROM jt_ops_sort_tz) s;
SELECT count(*) AS rows_sorted,
       count(*) FILTER (WHERE v > prev_v) AS inversions
FROM (SELECT v, lag(v) OVER (ORDER BY v DESC, id) AS prev_v FROM jt_ops_sort_tz) s;
SELECT (SELECT array_agg(id ORDER BY v, id) FROM jt_ops_sort_tz)
     = (SELECT array_agg(id ORDER BY v::timestamptz, id) FROM jt_ops_sort_tz) AS same_order_as_core,
       (SELECT array_agg(id ORDER BY v DESC, id) FROM jt_ops_sort_tz)
     = (SELECT array_agg(id ORDER BY v::timestamptz DESC, id) FROM jt_ops_sort_tz) AS same_desc_order_as_core,
       (SELECT array_agg(id ORDER BY v, id) FROM jt_ops_sort_tz)
     <> (SELECT array_agg(id ORDER BY v DESC, id) FROM jt_ops_sort_tz) AS control_orders_differ;
SELECT (SELECT v FROM jt_ops_sort_tz ORDER BY v LIMIT 1) AS first_value,
       (SELECT v FROM jt_ops_sort_tz ORDER BY v DESC LIMIT 1) AS last_value,
       (SELECT v FROM jt_ops_sort_tz WHERE v > '-infinity' ORDER BY v LIMIT 1) AS first_finite,
       (SELECT v FROM jt_ops_sort_tz WHERE v < 'infinity' ORDER BY v DESC LIMIT 1) AS last_finite;
SELECT count(DISTINCT v) > 3000 AS many_distinct, count(*) - count(DISTINCT v) > 0 AS has_duplicates
FROM jt_ops_sort_tz;

-- ---------------------------------------------------------------------
-- btree build over heavy duplicates (20 distinct values, 20,000 rows): the
-- deduplicated index is smaller than the same index without deduplication
-- (the class is deduplication-safe) and returns the same rows
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jt_ops_dup_tz (id int, v jtimestamptz);
INSERT INTO jt_ops_dup_tz
SELECT g, CASE g % 20
        WHEN 0 THEN 'infinity'::jtimestamptz
        WHEN 1 THEN '-infinity'::jtimestamptz
        WHEN 2 THEN '-0061-01-01 16:00:00+00'::jtimestamptz
        WHEN 3 THEN '3177-12-29 07:59:59.999999+00'::jtimestamptz
        ELSE ('2024-03-20 00:00:00+00'::timestamptz + (g % 20) * interval '1 hour')::jtimestamptz
    END
FROM generate_series(1, 20000) g;
CREATE INDEX jt_ops_dup_tz_dedup ON jt_ops_dup_tz (v) WITH (deduplicate_items = on);
CREATE INDEX jt_ops_dup_tz_nodedup ON jt_ops_dup_tz (v) WITH (deduplicate_items = off);
SELECT pg_relation_size('jt_ops_dup_tz_dedup') < pg_relation_size('jt_ops_dup_tz_nodedup') AS dedup_smaller;
DROP INDEX jt_ops_dup_tz_nodedup;
ANALYZE jt_ops_dup_tz;

SET enable_seqscan = off;
SET enable_bitmapscan = off;
SELECT bool_or(l ~ '^Index (Only )?Scan using jt_ops_dup_tz_dedup') AS equality_uses_index
FROM jt_ops_plan($q$SELECT id FROM jt_ops_dup_tz WHERE v = '-0061-01-01 16:00:00+00'::jtimestamptz$q$) l;
SELECT bool_or(l ~ '^Index (Only )?Scan using jt_ops_dup_tz_dedup') AS range_uses_index
FROM jt_ops_plan($q$SELECT id FROM jt_ops_dup_tz WHERE v >= '-0061-01-01 16:00:00+00'::jtimestamptz AND v < 'infinity'$q$) l;
CREATE TEMP TABLE jt_ops_dup_res_tz (method text, v jtimestamptz, n bigint, total bigint);
INSERT INTO jt_ops_dup_res_tz
SELECT 'index', v, count(*), sum(id) FROM jt_ops_dup_tz
WHERE v IN ('infinity', '-infinity', '-0061-01-01 16:00:00+00', '3177-12-29 07:59:59.999999+00', ('2024-03-20 00:00:00+00'::timestamptz + 5 * interval '1 hour')::jtimestamptz, ('2024-03-20 00:00:00+00'::timestamptz + 11 * interval '1 hour')::jtimestamptz) GROUP BY v;
RESET enable_seqscan;
RESET enable_bitmapscan;
SET enable_indexscan = off;
SET enable_bitmapscan = off;
INSERT INTO jt_ops_dup_res_tz
SELECT 'seq', v, count(*), sum(id) FROM jt_ops_dup_tz
WHERE v IN ('infinity', '-infinity', '-0061-01-01 16:00:00+00', '3177-12-29 07:59:59.999999+00', ('2024-03-20 00:00:00+00'::timestamptz + 5 * interval '1 hour')::jtimestamptz, ('2024-03-20 00:00:00+00'::timestamptz + 11 * interval '1 hour')::jtimestamptz) GROUP BY v;
RESET enable_indexscan;
RESET enable_bitmapscan;
SELECT v, n, total FROM jt_ops_dup_res_tz WHERE method = 'index' ORDER BY v;
SELECT count(*) AS values_compared,
       count(*) FILTER (WHERE i.n = s.n AND i.total = s.total) AS same_rows
FROM jt_ops_dup_res_tz i JOIN jt_ops_dup_res_tz s ON s.v = i.v AND s.method = 'seq'
WHERE i.method = 'index';

-- ---------------------------------------------------------------------
-- planner: a selective predicate uses the btree with the planner's own
-- choice (nothing disabled), a predicate that takes nearly every row does not
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jt_ops_big_tz AS
SELECT g AS id, ('2024-03-20 00:00:00+00'::timestamptz + g * interval '1 hour')::jtimestamptz AS v FROM generate_series(1, 20000) g;
CREATE INDEX jt_ops_big_tz_idx ON jt_ops_big_tz (v);
ANALYZE jt_ops_big_tz;
SELECT bool_or(l ~ '^Index (Only )?Scan using jt_ops_big_tz_idx') AS equality_index_scan
FROM jt_ops_plan('SELECT id FROM jt_ops_big_tz WHERE v = (SELECT v FROM jt_ops_big_tz WHERE id = 777)') l;
SELECT bool_or(l ~ '^(Index|Bitmap Index) (Only )?Scan') AS equality_literal_uses_index
FROM jt_ops_plan(format('SELECT id FROM jt_ops_big_tz WHERE v = %L::jtimestamptz', (SELECT v FROM jt_ops_big_tz WHERE id = 777))) l;
SELECT bool_or(l ~ '^(Index|Bitmap Index) (Only )?Scan') AS narrow_range_uses_index,
       bool_or(l ~ '^Seq Scan') AS narrow_range_seq_scan
FROM jt_ops_plan(format('SELECT id FROM jt_ops_big_tz WHERE v < %L::jtimestamptz', (SELECT v FROM jt_ops_big_tz WHERE id = 20))) l;
SELECT bool_or(l ~ '^Seq Scan') AS wide_range_seq_scan
FROM jt_ops_plan(format('SELECT id FROM jt_ops_big_tz WHERE v < %L::jtimestamptz', (SELECT v FROM jt_ops_big_tz WHERE id = 19990))) l;
-- the index answers ORDER BY ... LIMIT without a sort
SELECT bool_or(l ~ '^Index (Only )?Scan using jt_ops_big_tz_idx') AS order_by_limit_index_scan,
       bool_or(l ~ '^Sort') AS order_by_limit_sort
FROM jt_ops_plan('SELECT id FROM jt_ops_big_tz ORDER BY v LIMIT 10') l;
-- the same answer by the index and by a sequential scan
SET enable_seqscan = off;
SET enable_bitmapscan = off;
SELECT count(*) AS idx_rows, sum(id) AS idx_sum
FROM jt_ops_big_tz WHERE v BETWEEN (SELECT v FROM jt_ops_big_tz WHERE id = 100) AND (SELECT v FROM jt_ops_big_tz WHERE id = 5000);
RESET enable_seqscan;
RESET enable_bitmapscan;
SET enable_indexscan = off;
SET enable_bitmapscan = off;
SELECT count(*) AS seq_rows, sum(id) AS seq_sum
FROM jt_ops_big_tz WHERE v BETWEEN (SELECT v FROM jt_ops_big_tz WHERE id = 100) AND (SELECT v FROM jt_ops_big_tz WHERE id = 5000);
RESET enable_indexscan;
RESET enable_bitmapscan;

-- ---------------------------------------------------------------------
-- hash support: equal values hash equally and as core's type does; the
-- seeded hash agrees with the plain one in the low 32 bits at seed 0
-- ---------------------------------------------------------------------
SELECT count(*) FILTER (WHERE a.rank = b.rank AND jtimestamptz_hash(a.v) <> jtimestamptz_hash(b.v)) AS equal_values_unequal_hash,
       count(*) FILTER (WHERE a.rank = b.rank AND jtimestamptz_hash_extended(a.v, 7) <> jtimestamptz_hash_extended(b.v, 7)) AS equal_values_unequal_ext_hash,
       count(*) FILTER (WHERE a.rank <> b.rank AND jtimestamptz_hash(a.v) = jtimestamptz_hash(b.v)) AS distinct_values_same_hash
FROM jt_ops_tz a CROSS JOIN jt_ops_tz b;
SELECT count(*) AS values,
       count(*) FILTER (WHERE jtimestamptz_hash(v) <> timestamptz_hash(v::timestamptz)) AS hash_mismatches,
       count(*) FILTER (WHERE jtimestamptz_hash_extended(v, 7) <> timestamptz_hash_extended(v::timestamptz, 7)) AS ext_hash_mismatches,
       count(*) FILTER (WHERE (jtimestamptz_hash_extended(v, 0) & 4294967295) <> (jtimestamptz_hash(v)::bigint & 4294967295)) AS seed0_mismatches,
       count(*) FILTER (WHERE jtimestamptz_hash_extended(v, 1) <> jtimestamptz_hash_extended(v, 0)) > 0 AS seed_changes_hash
FROM jt_ops_tz;

-- ---------------------------------------------------------------------
-- Hash Join and HashAggregate give the same rows as the sort-based plans:
-- a has 300 distinct values, three rows each, plus both infinities;
-- b has every second value for 400 values, plus both infinities
-- ---------------------------------------------------------------------
CREATE TEMP TABLE jt_ops_ja_tz (v jtimestamptz, n int);
CREATE TEMP TABLE jt_ops_jb_tz (v jtimestamptz, m int);
INSERT INTO jt_ops_ja_tz SELECT ('2024-03-20 00:00:00+00'::timestamptz + (g % 300) * interval '1 hour')::jtimestamptz, g FROM generate_series(0, 899) g;
INSERT INTO jt_ops_jb_tz SELECT ('2024-03-20 00:00:00+00'::timestamptz + (g * 2) * interval '1 hour')::jtimestamptz, g FROM generate_series(0, 199) g;
INSERT INTO jt_ops_ja_tz VALUES ('infinity', 1000), ('-infinity', 1001);
INSERT INTO jt_ops_jb_tz VALUES ('infinity', 2000), ('-infinity', 2001);
ANALYZE jt_ops_ja_tz;
ANALYZE jt_ops_jb_tz;

CREATE TEMP TABLE jt_ops_jres_tz (method text, join_rows bigint, checksum bigint);

SET enable_mergejoin = off;
SET enable_nestloop = off;
SELECT bool_or(l ~ '^Hash Join') AS hash_join_planned
FROM jt_ops_plan('SELECT * FROM jt_ops_ja_tz a JOIN jt_ops_jb_tz b ON a.v = b.v') l;
INSERT INTO jt_ops_jres_tz
SELECT 'hash', count(*), sum(a.n + b.m) FROM jt_ops_ja_tz a JOIN jt_ops_jb_tz b ON a.v = b.v;
RESET enable_mergejoin;
RESET enable_nestloop;

SET enable_hashjoin = off;
SET enable_nestloop = off;
SELECT bool_or(l ~ '^Merge Join') AS merge_join_planned
FROM jt_ops_plan('SELECT * FROM jt_ops_ja_tz a JOIN jt_ops_jb_tz b ON a.v = b.v') l;
INSERT INTO jt_ops_jres_tz
SELECT 'merge', count(*), sum(a.n + b.m) FROM jt_ops_ja_tz a JOIN jt_ops_jb_tz b ON a.v = b.v;
RESET enable_hashjoin;
RESET enable_nestloop;

SET enable_hashjoin = off;
SET enable_mergejoin = off;
SELECT bool_or(l ~ '^Nested Loop') AS nested_loop_planned
FROM jt_ops_plan('SELECT * FROM jt_ops_ja_tz a JOIN jt_ops_jb_tz b ON a.v = b.v') l;
INSERT INTO jt_ops_jres_tz
SELECT 'nestloop', count(*), sum(a.n + b.m) FROM jt_ops_ja_tz a JOIN jt_ops_jb_tz b ON a.v = b.v;
RESET enable_hashjoin;
RESET enable_mergejoin;

SELECT method, join_rows, checksum FROM jt_ops_jres_tz ORDER BY method;
SELECT count(DISTINCT (join_rows, checksum)) AS distinct_results FROM jt_ops_jres_tz;

CREATE TEMP TABLE jt_ops_ares_tz (method text, grp bigint, total bigint, biggest bigint);

SET enable_sort = off;
SELECT bool_or(l ~ '^HashAggregate') AS hash_aggregate_planned
FROM jt_ops_plan('SELECT v, count(*) FROM jt_ops_ja_tz GROUP BY v') l;
INSERT INTO jt_ops_ares_tz
SELECT 'hash', count(*), sum(c), max(c) FROM (SELECT v, count(*) AS c FROM jt_ops_ja_tz GROUP BY v) s;
RESET enable_sort;

SET enable_hashagg = off;
SELECT bool_or(l ~ '^GroupAggregate') AS group_aggregate_planned
FROM jt_ops_plan('SELECT v, count(*) FROM jt_ops_ja_tz GROUP BY v') l;
INSERT INTO jt_ops_ares_tz
SELECT 'sort', count(*), sum(c), max(c) FROM (SELECT v, count(*) AS c FROM jt_ops_ja_tz GROUP BY v) s;
RESET enable_hashagg;

SELECT method, grp, total, biggest FROM jt_ops_ares_tz ORDER BY method;
SELECT count(DISTINCT (grp, total, biggest)) AS distinct_results FROM jt_ops_ares_tz;

-- SELECT DISTINCT through a hash and through a sort
SET enable_sort = off;
SELECT bool_or(l ~ '^HashAggregate') AS hash_distinct_planned
FROM jt_ops_plan('SELECT DISTINCT v FROM jt_ops_ja_tz') l;
SELECT count(*) AS distinct_by_hash FROM (SELECT DISTINCT v FROM jt_ops_ja_tz) s;
RESET enable_sort;
SET enable_hashagg = off;
SELECT bool_or(l ~ '^(Unique|GroupAggregate)') AS sort_distinct_planned
FROM jt_ops_plan('SELECT DISTINCT v FROM jt_ops_ja_tz') l;
SELECT count(*) AS distinct_by_sort FROM (SELECT DISTINCT v FROM jt_ops_ja_tz) s;
RESET enable_hashagg;

-- =====================================================================
-- the btree family and the hash opclasses in the catalog
-- =====================================================================
-- the classes of the family: one default class per type
SELECT c.opcname AS class, c.opcintype::regtype AS type, c.opcdefault AS is_default,
       f.opfname AS family, a.amname AS method
FROM pg_opclass c
JOIN pg_opfamily f ON f.oid = c.opcfamily
JOIN pg_am a ON a.oid = c.opcmethod
WHERE f.opfname = 'jdatetime_ops'
ORDER BY c.opcintype::regtype::text COLLATE "C";

-- the same-type entries of the family: five operators each (the cross-type
-- entries are covered by jt_crossops)
SELECT amoplefttype::regtype AS left_type, amoprighttype::regtype AS right_type,
       array_agg(amopstrategy ORDER BY amopstrategy) AS strategies,
       array_agg(amopopr::regoperator::text ORDER BY amopstrategy) AS operators
FROM pg_amop
WHERE amopfamily = (SELECT oid FROM pg_opfamily WHERE opfname = 'jdatetime_ops'
                    AND opfmethod = (SELECT oid FROM pg_am WHERE amname = 'btree'))
  AND amoplefttype = amoprighttype
GROUP BY amoplefttype, amoprighttype
ORDER BY amoplefttype::regtype::text COLLATE "C";

-- support functions 1 (cmp), 2 (sort support) and 4 (equalimage) of each
-- same-type entry; jdate_ops has the same three as before the family existed.
-- Support 6 is left out here, because it exists only on PostgreSQL 18 (next
-- query). The cross-type entries have function 1 only (see jt_crossops).
SELECT amproclefttype::regtype AS left_type, amprocrighttype::regtype AS right_type,
       array_agg(amprocnum ORDER BY amprocnum) AS numbers,
       array_agg(amproc::regprocedure::text ORDER BY amprocnum) AS functions
FROM pg_amproc
WHERE amprocfamily = (SELECT oid FROM pg_opfamily WHERE opfname = 'jdatetime_ops'
                      AND opfmethod = (SELECT oid FROM pg_am WHERE amname = 'btree'))
  AND amprocnum <> 6 AND amproclefttype = amprocrighttype
GROUP BY amproclefttype, amprocrighttype
ORDER BY amproclefttype::regtype::text COLLATE "C";

-- skip support (6) is there exactly when the server is PostgreSQL 18 or later,
-- for each of the three types, and is core's date_skipsupport for jdate and
-- timestamp_skipsupport for the other two
SELECT amproclefttype::regtype AS left_type,
       (count(*) FILTER (WHERE amprocnum = 6) = 1)
         = (current_setting('server_version_num')::int >= 180000) AS skipsupport_iff_pg18,
       coalesce(bool_and(amproc::regproc::text = CASE amproclefttype
                                                    WHEN 'jdate'::regtype THEN 'date_skipsupport'
                                                    ELSE 'timestamp_skipsupport' END)
                FILTER (WHERE amprocnum = 6), true) AS skipsupport_function_right
FROM pg_amproc
WHERE amprocfamily = (SELECT oid FROM pg_opfamily WHERE opfname = 'jdatetime_ops'
                      AND opfmethod = (SELECT oid FROM pg_am WHERE amname = 'btree'))
GROUP BY amproclefttype
ORDER BY amproclefttype::regtype::text COLLATE "C";

-- the family has no support function but 1, 2, 4 and 6
SELECT count(*) AS other_support_functions
FROM pg_amproc
WHERE amprocfamily = (SELECT oid FROM pg_opfamily WHERE opfname = 'jdatetime_ops'
                      AND opfmethod = (SELECT oid FROM pg_am WHERE amname = 'btree'))
  AND amprocnum NOT IN (1, 2, 4, 6);

-- amvalidate of the three btree classes (the whole family: the cross-type
-- matrix completes it) is asserted in jt_crossops.

-- the hash opclasses: default, one per type, support functions 1 and 2, and
-- amvalidate accepts them
SELECT c.opcname AS class, c.opcintype::regtype AS type, c.opcdefault AS is_default,
       f.opfname AS family, amvalidate(c.oid) AS valid
FROM pg_opclass c
JOIN pg_opfamily f ON f.oid = c.opcfamily
WHERE c.opcname IN ('jtimestamp_hash_ops', 'jtimestamptz_hash_ops')
ORDER BY c.opcname COLLATE "C";
SELECT c.opcname AS class, p.amprocnum, p.amproc::regprocedure AS function
FROM pg_opclass c
JOIN pg_amproc p ON p.amprocfamily = c.opcfamily
WHERE c.opcname IN ('jtimestamp_hash_ops', 'jtimestamptz_hash_ops')
ORDER BY c.opcname COLLATE "C", p.amprocnum;
SELECT c.opcname AS class, o.amopstrategy, o.amopopr::regoperator AS operator
FROM pg_opclass c
JOIN pg_amop o ON o.amopfamily = c.opcfamily
WHERE c.opcname IN ('jtimestamp_hash_ops', 'jtimestamptz_hash_ops')
ORDER BY c.opcname COLLATE "C";

DROP FUNCTION jt_ops_plan(text);
