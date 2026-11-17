-- Hashing and min()/max() for jtimestamp and jtimestamptz, modelled on
-- hash.sql: the hash opclass (support function 1 serves hash indexes, Hash Join
-- and HashAggregate; support function 2, seeded and 64-bit, is what
-- PARTITION BY HASH needs), then the aggregates min() and max() with NULLs and
-- infinities. Hash values, and which partition a row lands in, depend on the
-- hash function, so this file prints only counts and booleans that hold
-- whatever the hash values are. Plans are tested through booleans, never
-- printed.

SET DateStyle = 'ISO, YMD';
SET timezone = 'UTC';

-- true when the EXPLAIN output of the query has a line matching the regexp
CREATE FUNCTION jh_plan_has(query text, pattern text) RETURNS boolean
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

-- number of EXPLAIN lines of the query that match the regexp
CREATE FUNCTION jh_plan_count(query text, pattern text) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
    line text;
    n int := 0;
BEGIN
    FOR line IN EXECUTE 'EXPLAIN (COSTS off) ' || query LOOP
        IF line ~ pattern THEN
            n := n + 1;
        END IF;
    END LOOP;
    RETURN n;
END
$$;

-- core's int64 representation of a value (microseconds since 2000-01-01, the
-- infinities at the int64 extremes), computed from the epoch so that it does
-- not depend on how the type stores it
CREATE FUNCTION jh_int64(jtimestamp) RETURNS bigint LANGUAGE sql IMMUTABLE AS $f$
    SELECT CASE $1 WHEN 'infinity' THEN 9223372036854775807::bigint
                   WHEN '-infinity' THEN -9223372036854775807::bigint - 1
                   ELSE ((extract(epoch FROM $1::timestamp) - 946684800) * 1000000)::bigint END
$f$;
CREATE FUNCTION jh_int64(jtimestamptz) RETURNS bigint LANGUAGE sql IMMUTABLE AS $f$
    SELECT CASE $1 WHEN 'infinity' THEN 9223372036854775807::bigint
                   WHEN '-infinity' THEN -9223372036854775807::bigint - 1
                   ELSE ((extract(epoch FROM $1::timestamptz) - 946684800) * 1000000)::bigint END
$f$;

-- =====================================================================
-- jtimestamp
-- =====================================================================

-- ---------------------------------------------------------------------
-- catalog: both support functions are registered and the opclass validates
-- ---------------------------------------------------------------------
SELECT amprocnum, amproc::regproc
FROM pg_amproc
WHERE amprocfamily = (SELECT opcfamily FROM pg_opclass WHERE opcname = 'jtimestamp_hash_ops')
ORDER BY amprocnum;

SELECT amvalidate(oid) AS jtimestamp_hash_ops_valid
FROM pg_opclass WHERE opcname = 'jtimestamp_hash_ops';

-- ---------------------------------------------------------------------
-- the extended hash agrees with the standard one at seed 0 (in the low 32
-- bits, the rule core's extended hash functions follow) and depends on the
-- seed; infinity and the range edges hash like any other value
-- ---------------------------------------------------------------------
CREATE TABLE jh_ts_vals AS
    SELECT (timestamp '2024-03-20 00:00:00' + (g) * interval '1 hour')::jtimestamp AS v FROM generate_series(0, 999) g;
INSERT INTO jh_ts_vals VALUES
    ('infinity'), ('-infinity'), ('-0061-01-01 00:00:00'), ('3177-12-29 23:59:59.999999');

SELECT count(*) AS vals,
       count(*) FILTER (WHERE (jtimestamp_hash_extended(v, 0) & 4294967295)
                            <> (jtimestamp_hash(v)::bigint & 4294967295)) AS seed0_mismatches,
       count(*) FILTER (WHERE jtimestamp_hash_extended(v, 1) <> jtimestamp_hash_extended(v, 0)) * 10
           >= count(*) * 9 AS seed_changes_most_hashes
FROM jh_ts_vals;

-- the hash is core's hash of the int64 (microseconds since 2000-01-01, the
-- infinities at the int64 extremes), for the standard and the extended
-- function: hashint8 over that integer, computed here from the epoch
SELECT count(*) FILTER (WHERE jtimestamp_hash(v) <> hashint8(jh_int64(v))) AS hash_vs_int64,
       count(*) FILTER (WHERE jtimestamp_hash_extended(v, 42) <> hashint8extended(jh_int64(v), 42)) AS ext_hash_vs_int64
FROM jh_ts_vals;

-- equal values hash equally, whichever way they were written
SELECT jtimestamp_hash('1403-01-01 00:00:00'::jtimestamp) = jtimestamp_hash('1403-01-01'::jtimestamp) AS same_value_same_hash,
       jtimestamp_hash_extended('1403-01-01 00:00:00'::jtimestamp, 7) = jtimestamp_hash_extended('1403-01-01'::jtimestamp, 7) AS same_value_same_ext_hash,
       jtimestamp_hash('1403-01-01 00:00:00'::jtimestamp) = jtimestamp_hash(('2024-03-20 00:00:00'::timestamp)::jtimestamp) AS same_hash_as_cast,
       '1403-01-01 00:00:00'::jtimestamp = '1403-01-01'::jtimestamp AS written_differently_equal;
-- a control that must differ: one microsecond apart is a different value
SELECT jtimestamp_hash_extended('1403-01-01 00:00:00'::jtimestamp, 7) <> jtimestamp_hash_extended('1403-01-01 00:00:00.000001'::jtimestamp, 7) AS one_microsecond_apart_differs;

-- ---------------------------------------------------------------------
-- PARTITION BY HASH
-- ---------------------------------------------------------------------
CREATE TABLE jh_ts_part (v jtimestamp NOT NULL, n int) PARTITION BY HASH (v);
CREATE TABLE jh_ts_part_0 PARTITION OF jh_ts_part FOR VALUES WITH (modulus 3, remainder 0);
CREATE TABLE jh_ts_part_1 PARTITION OF jh_ts_part FOR VALUES WITH (modulus 3, remainder 1);
CREATE TABLE jh_ts_part_2 PARTITION OF jh_ts_part FOR VALUES WITH (modulus 3, remainder 2);

-- every row finds a partition (otherwise the INSERT fails), and the rows are
-- spread over at least two of them
INSERT INTO jh_ts_part SELECT v, 1 FROM jh_ts_vals;
SELECT count(*) AS rows_total FROM jh_ts_part;
SELECT (SELECT count(*) FROM jh_ts_part_0)
     + (SELECT count(*) FROM jh_ts_part_1)
     + (SELECT count(*) FROM jh_ts_part_2) AS rows_in_partitions;
SELECT count(DISTINCT tableoid) >= 2 AS spread_over_partitions FROM jh_ts_part;

-- partition pruning picks the one partition that holds the key: one scan
-- instead of three, and it still finds the row
SELECT jh_plan_count('SELECT * FROM jh_ts_part', 'Scan on') AS partitions_scanned_unpruned;
SELECT jh_plan_count('SELECT * FROM jh_ts_part WHERE v = ''1403-01-05 04:00:00''', 'Scan on') AS partitions_scanned_by_key;
SELECT jh_plan_count('SELECT * FROM jh_ts_part WHERE v = ''infinity''', 'Scan on') AS partitions_scanned_by_infinity;
SELECT count(*) AS found_key FROM jh_ts_part WHERE v = '1403-01-05 04:00:00';
SELECT count(*) AS found_infinity FROM jh_ts_part WHERE v = 'infinity';
SELECT count(*) AS found_both_edges FROM jh_ts_part WHERE v IN ('-0061-01-01 00:00:00', '3177-12-29 23:59:59.999999');

-- runtime pruning (the key is a parameter) agrees with where insert put each
-- row: a wrong partition would give 0 rows for that key
SELECT count(*) AS values_found_by_key
FROM jh_ts_vals h WHERE (SELECT count(*) FROM jh_ts_part p WHERE p.v = h.v) = 1;

DROP TABLE jh_ts_part;

-- ---------------------------------------------------------------------
-- hash index
-- ---------------------------------------------------------------------
CREATE TABLE jh_ts_idx (v jtimestamp, n int);
INSERT INTO jh_ts_idx SELECT (timestamp '2024-03-20 00:00:00' + (g) * interval '1 hour')::jtimestamp, g FROM generate_series(0, 4999) g;
INSERT INTO jh_ts_idx VALUES ('infinity', -1), ('-infinity', -2);
CREATE INDEX jh_ts_idx_v ON jh_ts_idx USING hash (v);
ANALYZE jh_ts_idx;

SET enable_seqscan = off;
SET enable_bitmapscan = off;
SELECT jh_plan_has('SELECT n FROM jh_ts_idx WHERE v = ''1403-01-05 04:00:00''', 'Index Scan using jh_ts_idx_v') AS uses_hash_index;
SELECT n FROM jh_ts_idx WHERE v = '1403-01-05 04:00:00';
SELECT n FROM jh_ts_idx WHERE v = (timestamp '2024-03-20 00:00:00' + (4999) * interval '1 hour')::jtimestamp;
SELECT n FROM jh_ts_idx WHERE v = 'infinity';
SELECT n FROM jh_ts_idx WHERE v = '-infinity';
SELECT count(*) AS absent FROM jh_ts_idx WHERE v = '1420-01-01 00:00:00';
RESET enable_seqscan;
RESET enable_bitmapscan;

DROP TABLE jh_ts_idx;

-- ---------------------------------------------------------------------
-- Hash Join and HashAggregate give the same rows as the sort-based plans
-- ---------------------------------------------------------------------
-- a: 300 distinct values, three rows each, plus both infinities;
-- b: every second value for 400 values, plus both infinities
CREATE TABLE jh_ts_join_a (v jtimestamp, n int);
CREATE TABLE jh_ts_join_b (v jtimestamp, m int);
INSERT INTO jh_ts_join_a SELECT (timestamp '2024-03-20 00:00:00' + (g % 300) * interval '1 hour')::jtimestamp, g FROM generate_series(0, 899) g;
INSERT INTO jh_ts_join_b SELECT (timestamp '2024-03-20 00:00:00' + (g * 2) * interval '1 hour')::jtimestamp, g FROM generate_series(0, 199) g;
INSERT INTO jh_ts_join_a VALUES ('infinity', 1000), ('-infinity', 1001);
INSERT INTO jh_ts_join_b VALUES ('infinity', 2000), ('-infinity', 2001);
ANALYZE jh_ts_join_a;
ANALYZE jh_ts_join_b;

CREATE TEMP TABLE jh_ts_join_results (method text, join_rows bigint, checksum bigint);

SET enable_mergejoin = off;
SET enable_nestloop = off;
SELECT jh_plan_has('SELECT * FROM jh_ts_join_a a JOIN jh_ts_join_b b ON a.v = b.v', '^ *(->)? *Hash Join') AS is_hash_join;
INSERT INTO jh_ts_join_results
SELECT 'hash', count(*), sum(a.n + b.m) FROM jh_ts_join_a a JOIN jh_ts_join_b b ON a.v = b.v;
RESET enable_mergejoin;
RESET enable_nestloop;

SET enable_hashjoin = off;
SET enable_nestloop = off;
SELECT jh_plan_has('SELECT * FROM jh_ts_join_a a JOIN jh_ts_join_b b ON a.v = b.v', '^ *(->)? *Merge Join') AS is_merge_join;
INSERT INTO jh_ts_join_results
SELECT 'merge', count(*), sum(a.n + b.m) FROM jh_ts_join_a a JOIN jh_ts_join_b b ON a.v = b.v;
RESET enable_hashjoin;
RESET enable_nestloop;

SET enable_hashjoin = off;
SET enable_mergejoin = off;
SELECT jh_plan_has('SELECT * FROM jh_ts_join_a a JOIN jh_ts_join_b b ON a.v = b.v', '^ *(->)? *Nested Loop') AS is_nested_loop;
INSERT INTO jh_ts_join_results
SELECT 'nestloop', count(*), sum(a.n + b.m) FROM jh_ts_join_a a JOIN jh_ts_join_b b ON a.v = b.v;
RESET enable_hashjoin;
RESET enable_mergejoin;

SELECT method, join_rows, checksum FROM jh_ts_join_results ORDER BY method;
SELECT count(DISTINCT (join_rows, checksum)) AS distinct_results FROM jh_ts_join_results;

CREATE TEMP TABLE jh_ts_agg_results (method text, grp bigint, total bigint, biggest bigint);

SET enable_sort = off;
SELECT jh_plan_has('SELECT v, count(*) FROM jh_ts_join_a GROUP BY v', 'HashAggregate') AS is_hash_aggregate;
INSERT INTO jh_ts_agg_results
SELECT 'hash', count(*), sum(c), max(c) FROM (SELECT v, count(*) AS c FROM jh_ts_join_a GROUP BY v) s;
RESET enable_sort;

SET enable_hashagg = off;
SELECT jh_plan_has('SELECT v, count(*) FROM jh_ts_join_a GROUP BY v', 'GroupAggregate') AS is_group_aggregate;
INSERT INTO jh_ts_agg_results
SELECT 'sort', count(*), sum(c), max(c) FROM (SELECT v, count(*) AS c FROM jh_ts_join_a GROUP BY v) s;
RESET enable_hashagg;

SELECT method, grp, total, biggest FROM jh_ts_agg_results ORDER BY method;
SELECT count(DISTINCT (grp, total, biggest)) AS distinct_results FROM jh_ts_agg_results;

DROP TABLE jh_ts_join_results, jh_ts_agg_results, jh_ts_join_a, jh_ts_join_b;

-- ---------------------------------------------------------------------
-- min() and max()
-- ---------------------------------------------------------------------
-- catalog: transition function, combine function (the same function, so the
-- aggregate can run as Partial/Finalize under a Gather), sort operator,
-- parallel safety
SELECT a.aggfnoid::regprocedure AS aggregate,
       a.aggtransfn::regproc AS transfn,
       a.aggcombinefn::regproc AS combinefn,
       a.aggsortop::regoperator AS sortop,
       p.proparallel AS parallel,
       a.aggtransfn = a.aggcombinefn AS combine_is_transfn
FROM pg_aggregate a JOIN pg_proc p ON p.oid = a.aggfnoid
WHERE a.aggfnoid IN ('min(jtimestamp)'::regprocedure, 'max(jtimestamp)'::regprocedure)
ORDER BY a.aggfnoid::regprocedure::text;

-- the result has the type of the column, not a core type reached through a cast
SELECT pg_typeof(min(v)) AS min_type, pg_typeof(max(v)) AS max_type FROM jh_ts_vals;

-- values and NULLs: NULLs are skipped, an empty or all-NULL input gives NULL
CREATE TABLE jh_ts_mm (g int, v jtimestamp);
INSERT INTO jh_ts_mm VALUES
    (1, '1400-01-01 00:00:00'), (1, NULL), (1, '1380-03-01 08:15:00'), (1, '1399-09-09 09:09:09'),
    (2, NULL), (2, NULL),
    (3, '1390-06-15 12:00:00.5'),
    (4, '1403-12-30 23:59:59.999999'), (4, '1403-12-30 23:59:59.999999');

SELECT min(v) AS min_v, max(v) AS max_v, count(v) AS counted, count(*) AS total FROM jh_ts_mm;
SELECT g, min(v) AS min_v, max(v) AS max_v, min(v) IS NULL AS min_is_null FROM jh_ts_mm GROUP BY g ORDER BY g;
SELECT min(v) AS min_empty, max(v) AS max_empty FROM jh_ts_mm WHERE false;
SELECT min(v) FILTER (WHERE g > 1) AS min_filtered, max(v) FILTER (WHERE g < 3) AS max_filtered FROM jh_ts_mm;
-- as a window aggregate
SELECT g, min(v) OVER (PARTITION BY g) AS wmin, max(v) OVER (PARTITION BY g) AS wmax
FROM jh_ts_mm WHERE g IN (1, 3) ORDER BY g, v NULLS LAST;

-- infinities: -infinity is the smallest value and infinity the largest
INSERT INTO jh_ts_mm VALUES (5, 'infinity'), (5, '-infinity'), (5, '1400-01-01 00:00:00'), (6, 'infinity'), (7, '-infinity');
SELECT min(v) AS min_all, max(v) AS max_all FROM jh_ts_mm;
SELECT g, min(v) AS min_v, max(v) AS max_v FROM jh_ts_mm WHERE g >= 5 GROUP BY g ORDER BY g;
SELECT min(v) AS min_finite, max(v) AS max_finite
FROM jh_ts_mm WHERE v NOT IN ('infinity', '-infinity');

-- the range edges
INSERT INTO jh_ts_mm VALUES (8, '-0061-01-01 00:00:00'), (8, '3177-12-29 23:59:59.999999');
SELECT min(v) AS min_edges, max(v) AS max_edges FROM jh_ts_mm WHERE g = 8;

-- agrees with ORDER BY ... LIMIT 1 and with core's aggregate on the cast
SELECT min(v) IS NOT DISTINCT FROM (SELECT v FROM jh_ts_mm ORDER BY v LIMIT 1) AS min_is_first,
       max(v) IS NOT DISTINCT FROM (SELECT v FROM jh_ts_mm ORDER BY v DESC NULLS LAST LIMIT 1) AS max_is_last,
       min(v)::timestamp = min(v::timestamp) AS min_as_core,
       max(v)::timestamp = max(v::timestamp) AS max_as_core
FROM jh_ts_mm;

-- one aggregate over thousands of values, against the sorted order
SELECT min(v) = (SELECT v FROM jh_ts_vals ORDER BY v LIMIT 1) AS min_of_many,
       max(v) = (SELECT v FROM jh_ts_vals ORDER BY v DESC LIMIT 1) AS max_of_many
FROM jh_ts_vals;

DROP TABLE jh_ts_mm;

-- SORTOP: with a btree index the planner answers min()/max() with a one-row
-- index scan (no Aggregate node), and the answer is the same
CREATE TABLE jh_ts_mmi (v jtimestamp);
INSERT INTO jh_ts_mmi SELECT (timestamp '2024-03-20 00:00:00' + (g) * interval '1 hour')::jtimestamp FROM generate_series(0, 4999) g;
INSERT INTO jh_ts_mmi VALUES (NULL), (NULL);
CREATE INDEX jh_ts_mmi_v ON jh_ts_mmi (v);
ANALYZE jh_ts_mmi;
SELECT jh_plan_has('SELECT min(v) FROM jh_ts_mmi', 'Index (Only )?Scan (Backward )?using jh_ts_mmi_v') AS min_uses_index,
       jh_plan_has('SELECT max(v) FROM jh_ts_mmi', 'Index (Only )?Scan (Backward )?using jh_ts_mmi_v') AS max_uses_index,
       NOT jh_plan_has('SELECT min(v) FROM jh_ts_mmi', 'Aggregate') AS min_without_aggregate_node,
       NOT jh_plan_has('SELECT max(v) FROM jh_ts_mmi', 'Aggregate') AS max_without_aggregate_node;
SELECT min(v) = (timestamp '2024-03-20 00:00:00' + (0) * interval '1 hour')::jtimestamp AS min_by_index, max(v) = (timestamp '2024-03-20 00:00:00' + (4999) * interval '1 hour')::jtimestamp AS max_by_index FROM jh_ts_mmi;
SET enable_indexscan = off;
SET enable_indexonlyscan = off;
SET enable_bitmapscan = off;
SELECT min(v) = (timestamp '2024-03-20 00:00:00' + (0) * interval '1 hour')::jtimestamp AS min_by_seqscan, max(v) = (timestamp '2024-03-20 00:00:00' + (4999) * interval '1 hour')::jtimestamp AS max_by_seqscan FROM jh_ts_mmi;
RESET enable_indexscan;
RESET enable_indexonlyscan;
RESET enable_bitmapscan;
DROP TABLE jh_ts_mmi;

DROP TABLE jh_ts_vals;

-- =====================================================================
-- jtimestamptz
-- =====================================================================

-- ---------------------------------------------------------------------
-- catalog: both support functions are registered and the opclass validates
-- ---------------------------------------------------------------------
SELECT amprocnum, amproc::regproc
FROM pg_amproc
WHERE amprocfamily = (SELECT opcfamily FROM pg_opclass WHERE opcname = 'jtimestamptz_hash_ops')
ORDER BY amprocnum;

SELECT amvalidate(oid) AS jtimestamptz_hash_ops_valid
FROM pg_opclass WHERE opcname = 'jtimestamptz_hash_ops';

-- ---------------------------------------------------------------------
-- the extended hash agrees with the standard one at seed 0 (in the low 32
-- bits, the rule core's extended hash functions follow) and depends on the
-- seed; infinity and the range edges hash like any other value
-- ---------------------------------------------------------------------
CREATE TABLE jh_tz_vals AS
    SELECT (timestamptz '2024-03-20 00:00:00+00' + (g) * interval '1 hour')::jtimestamptz AS v FROM generate_series(0, 999) g;
INSERT INTO jh_tz_vals VALUES
    ('infinity'), ('-infinity'), ('-0061-01-01 16:00:00+00'), ('3177-12-29 07:59:59.999999+00');

SELECT count(*) AS vals,
       count(*) FILTER (WHERE (jtimestamptz_hash_extended(v, 0) & 4294967295)
                            <> (jtimestamptz_hash(v)::bigint & 4294967295)) AS seed0_mismatches,
       count(*) FILTER (WHERE jtimestamptz_hash_extended(v, 1) <> jtimestamptz_hash_extended(v, 0)) * 10
           >= count(*) * 9 AS seed_changes_most_hashes
FROM jh_tz_vals;

-- the hash is core's hash of the int64 (microseconds since 2000-01-01, the
-- infinities at the int64 extremes), for the standard and the extended
-- function: hashint8 over that integer, computed here from the epoch
SELECT count(*) FILTER (WHERE jtimestamptz_hash(v) <> hashint8(jh_int64(v))) AS hash_vs_int64,
       count(*) FILTER (WHERE jtimestamptz_hash_extended(v, 42) <> hashint8extended(jh_int64(v), 42)) AS ext_hash_vs_int64
FROM jh_tz_vals;

-- equal values hash equally, whichever way they were written
SELECT jtimestamptz_hash('1403-01-01 00:00:00+00'::jtimestamptz) = jtimestamptz_hash('1403-01-01 03:30:00+03:30'::jtimestamptz) AS same_value_same_hash,
       jtimestamptz_hash_extended('1403-01-01 00:00:00+00'::jtimestamptz, 7) = jtimestamptz_hash_extended('1403-01-01 03:30:00+03:30'::jtimestamptz, 7) AS same_value_same_ext_hash,
       jtimestamptz_hash('1403-01-01 00:00:00+00'::jtimestamptz) = jtimestamptz_hash(('2024-03-20 00:00:00+00'::timestamptz)::jtimestamptz) AS same_hash_as_cast,
       '1403-01-01 00:00:00+00'::jtimestamptz = '1403-01-01 03:30:00+03:30'::jtimestamptz AS written_differently_equal;
-- a control that must differ: one microsecond apart is a different value
SELECT jtimestamptz_hash_extended('1403-01-01 00:00:00+00'::jtimestamptz, 7) <> jtimestamptz_hash_extended('1403-01-01 00:00:00.000001+00'::jtimestamptz, 7) AS one_microsecond_apart_differs;

-- ---------------------------------------------------------------------
-- PARTITION BY HASH
-- ---------------------------------------------------------------------
CREATE TABLE jh_tz_part (v jtimestamptz NOT NULL, n int) PARTITION BY HASH (v);
CREATE TABLE jh_tz_part_0 PARTITION OF jh_tz_part FOR VALUES WITH (modulus 3, remainder 0);
CREATE TABLE jh_tz_part_1 PARTITION OF jh_tz_part FOR VALUES WITH (modulus 3, remainder 1);
CREATE TABLE jh_tz_part_2 PARTITION OF jh_tz_part FOR VALUES WITH (modulus 3, remainder 2);

-- every row finds a partition (otherwise the INSERT fails), and the rows are
-- spread over at least two of them
INSERT INTO jh_tz_part SELECT v, 1 FROM jh_tz_vals;
SELECT count(*) AS rows_total FROM jh_tz_part;
SELECT (SELECT count(*) FROM jh_tz_part_0)
     + (SELECT count(*) FROM jh_tz_part_1)
     + (SELECT count(*) FROM jh_tz_part_2) AS rows_in_partitions;
SELECT count(DISTINCT tableoid) >= 2 AS spread_over_partitions FROM jh_tz_part;

-- partition pruning picks the one partition that holds the key: one scan
-- instead of three, and it still finds the row
SELECT jh_plan_count('SELECT * FROM jh_tz_part', 'Scan on') AS partitions_scanned_unpruned;
SELECT jh_plan_count('SELECT * FROM jh_tz_part WHERE v = ''1403-01-05 04:00:00+00''', 'Scan on') AS partitions_scanned_by_key;
SELECT jh_plan_count('SELECT * FROM jh_tz_part WHERE v = ''infinity''', 'Scan on') AS partitions_scanned_by_infinity;
SELECT count(*) AS found_key FROM jh_tz_part WHERE v = '1403-01-05 04:00:00+00';
SELECT count(*) AS found_infinity FROM jh_tz_part WHERE v = 'infinity';
SELECT count(*) AS found_both_edges FROM jh_tz_part WHERE v IN ('-0061-01-01 16:00:00+00', '3177-12-29 07:59:59.999999+00');

-- runtime pruning (the key is a parameter) agrees with where insert put each
-- row: a wrong partition would give 0 rows for that key
SELECT count(*) AS values_found_by_key
FROM jh_tz_vals h WHERE (SELECT count(*) FROM jh_tz_part p WHERE p.v = h.v) = 1;

DROP TABLE jh_tz_part;

-- ---------------------------------------------------------------------
-- hash index
-- ---------------------------------------------------------------------
CREATE TABLE jh_tz_idx (v jtimestamptz, n int);
INSERT INTO jh_tz_idx SELECT (timestamptz '2024-03-20 00:00:00+00' + (g) * interval '1 hour')::jtimestamptz, g FROM generate_series(0, 4999) g;
INSERT INTO jh_tz_idx VALUES ('infinity', -1), ('-infinity', -2);
CREATE INDEX jh_tz_idx_v ON jh_tz_idx USING hash (v);
ANALYZE jh_tz_idx;

SET enable_seqscan = off;
SET enable_bitmapscan = off;
SELECT jh_plan_has('SELECT n FROM jh_tz_idx WHERE v = ''1403-01-05 04:00:00+00''', 'Index Scan using jh_tz_idx_v') AS uses_hash_index;
SELECT n FROM jh_tz_idx WHERE v = '1403-01-05 04:00:00+00';
SELECT n FROM jh_tz_idx WHERE v = (timestamptz '2024-03-20 00:00:00+00' + (4999) * interval '1 hour')::jtimestamptz;
SELECT n FROM jh_tz_idx WHERE v = 'infinity';
SELECT n FROM jh_tz_idx WHERE v = '-infinity';
SELECT count(*) AS absent FROM jh_tz_idx WHERE v = '1420-01-01 00:00:00+00';
RESET enable_seqscan;
RESET enable_bitmapscan;

DROP TABLE jh_tz_idx;

-- ---------------------------------------------------------------------
-- Hash Join and HashAggregate give the same rows as the sort-based plans
-- ---------------------------------------------------------------------
-- a: 300 distinct values, three rows each, plus both infinities;
-- b: every second value for 400 values, plus both infinities
CREATE TABLE jh_tz_join_a (v jtimestamptz, n int);
CREATE TABLE jh_tz_join_b (v jtimestamptz, m int);
INSERT INTO jh_tz_join_a SELECT (timestamptz '2024-03-20 00:00:00+00' + (g % 300) * interval '1 hour')::jtimestamptz, g FROM generate_series(0, 899) g;
INSERT INTO jh_tz_join_b SELECT (timestamptz '2024-03-20 00:00:00+00' + (g * 2) * interval '1 hour')::jtimestamptz, g FROM generate_series(0, 199) g;
INSERT INTO jh_tz_join_a VALUES ('infinity', 1000), ('-infinity', 1001);
INSERT INTO jh_tz_join_b VALUES ('infinity', 2000), ('-infinity', 2001);
ANALYZE jh_tz_join_a;
ANALYZE jh_tz_join_b;

CREATE TEMP TABLE jh_tz_join_results (method text, join_rows bigint, checksum bigint);

SET enable_mergejoin = off;
SET enable_nestloop = off;
SELECT jh_plan_has('SELECT * FROM jh_tz_join_a a JOIN jh_tz_join_b b ON a.v = b.v', '^ *(->)? *Hash Join') AS is_hash_join;
INSERT INTO jh_tz_join_results
SELECT 'hash', count(*), sum(a.n + b.m) FROM jh_tz_join_a a JOIN jh_tz_join_b b ON a.v = b.v;
RESET enable_mergejoin;
RESET enable_nestloop;

SET enable_hashjoin = off;
SET enable_nestloop = off;
SELECT jh_plan_has('SELECT * FROM jh_tz_join_a a JOIN jh_tz_join_b b ON a.v = b.v', '^ *(->)? *Merge Join') AS is_merge_join;
INSERT INTO jh_tz_join_results
SELECT 'merge', count(*), sum(a.n + b.m) FROM jh_tz_join_a a JOIN jh_tz_join_b b ON a.v = b.v;
RESET enable_hashjoin;
RESET enable_nestloop;

SET enable_hashjoin = off;
SET enable_mergejoin = off;
SELECT jh_plan_has('SELECT * FROM jh_tz_join_a a JOIN jh_tz_join_b b ON a.v = b.v', '^ *(->)? *Nested Loop') AS is_nested_loop;
INSERT INTO jh_tz_join_results
SELECT 'nestloop', count(*), sum(a.n + b.m) FROM jh_tz_join_a a JOIN jh_tz_join_b b ON a.v = b.v;
RESET enable_hashjoin;
RESET enable_mergejoin;

SELECT method, join_rows, checksum FROM jh_tz_join_results ORDER BY method;
SELECT count(DISTINCT (join_rows, checksum)) AS distinct_results FROM jh_tz_join_results;

CREATE TEMP TABLE jh_tz_agg_results (method text, grp bigint, total bigint, biggest bigint);

SET enable_sort = off;
SELECT jh_plan_has('SELECT v, count(*) FROM jh_tz_join_a GROUP BY v', 'HashAggregate') AS is_hash_aggregate;
INSERT INTO jh_tz_agg_results
SELECT 'hash', count(*), sum(c), max(c) FROM (SELECT v, count(*) AS c FROM jh_tz_join_a GROUP BY v) s;
RESET enable_sort;

SET enable_hashagg = off;
SELECT jh_plan_has('SELECT v, count(*) FROM jh_tz_join_a GROUP BY v', 'GroupAggregate') AS is_group_aggregate;
INSERT INTO jh_tz_agg_results
SELECT 'sort', count(*), sum(c), max(c) FROM (SELECT v, count(*) AS c FROM jh_tz_join_a GROUP BY v) s;
RESET enable_hashagg;

SELECT method, grp, total, biggest FROM jh_tz_agg_results ORDER BY method;
SELECT count(DISTINCT (grp, total, biggest)) AS distinct_results FROM jh_tz_agg_results;

DROP TABLE jh_tz_join_results, jh_tz_agg_results, jh_tz_join_a, jh_tz_join_b;

-- ---------------------------------------------------------------------
-- min() and max()
-- ---------------------------------------------------------------------
-- catalog: transition function, combine function (the same function, so the
-- aggregate can run as Partial/Finalize under a Gather), sort operator,
-- parallel safety
SELECT a.aggfnoid::regprocedure AS aggregate,
       a.aggtransfn::regproc AS transfn,
       a.aggcombinefn::regproc AS combinefn,
       a.aggsortop::regoperator AS sortop,
       p.proparallel AS parallel,
       a.aggtransfn = a.aggcombinefn AS combine_is_transfn
FROM pg_aggregate a JOIN pg_proc p ON p.oid = a.aggfnoid
WHERE a.aggfnoid IN ('min(jtimestamptz)'::regprocedure, 'max(jtimestamptz)'::regprocedure)
ORDER BY a.aggfnoid::regprocedure::text;

-- the result has the type of the column, not a core type reached through a cast
SELECT pg_typeof(min(v)) AS min_type, pg_typeof(max(v)) AS max_type FROM jh_tz_vals;

-- values and NULLs: NULLs are skipped, an empty or all-NULL input gives NULL
CREATE TABLE jh_tz_mm (g int, v jtimestamptz);
INSERT INTO jh_tz_mm VALUES
    (1, '1400-01-01 00:00:00+00'), (1, NULL), (1, '1380-03-01 08:15:00+00'), (1, '1399-09-09 09:09:09+00'),
    (2, NULL), (2, NULL),
    (3, '1390-06-15 12:00:00.5+03:30'),
    (4, '1403-12-30 23:59:59.999999-11'), (4, '1403-12-30 23:59:59.999999-11');

SELECT min(v) AS min_v, max(v) AS max_v, count(v) AS counted, count(*) AS total FROM jh_tz_mm;
SELECT g, min(v) AS min_v, max(v) AS max_v, min(v) IS NULL AS min_is_null FROM jh_tz_mm GROUP BY g ORDER BY g;
SELECT min(v) AS min_empty, max(v) AS max_empty FROM jh_tz_mm WHERE false;
SELECT min(v) FILTER (WHERE g > 1) AS min_filtered, max(v) FILTER (WHERE g < 3) AS max_filtered FROM jh_tz_mm;
-- as a window aggregate
SELECT g, min(v) OVER (PARTITION BY g) AS wmin, max(v) OVER (PARTITION BY g) AS wmax
FROM jh_tz_mm WHERE g IN (1, 3) ORDER BY g, v NULLS LAST;

-- infinities: -infinity is the smallest value and infinity the largest
INSERT INTO jh_tz_mm VALUES (5, 'infinity'), (5, '-infinity'), (5, '1400-01-01 00:00:00+00'), (6, 'infinity'), (7, '-infinity');
SELECT min(v) AS min_all, max(v) AS max_all FROM jh_tz_mm;
SELECT g, min(v) AS min_v, max(v) AS max_v FROM jh_tz_mm WHERE g >= 5 GROUP BY g ORDER BY g;
SELECT min(v) AS min_finite, max(v) AS max_finite
FROM jh_tz_mm WHERE v NOT IN ('infinity', '-infinity');

-- the range edges
INSERT INTO jh_tz_mm VALUES (8, '-0061-01-01 16:00:00+00'), (8, '3177-12-29 07:59:59.999999+00');
SELECT min(v) AS min_edges, max(v) AS max_edges FROM jh_tz_mm WHERE g = 8;

-- agrees with ORDER BY ... LIMIT 1 and with core's aggregate on the cast
SELECT min(v) IS NOT DISTINCT FROM (SELECT v FROM jh_tz_mm ORDER BY v LIMIT 1) AS min_is_first,
       max(v) IS NOT DISTINCT FROM (SELECT v FROM jh_tz_mm ORDER BY v DESC NULLS LAST LIMIT 1) AS max_is_last,
       min(v)::timestamptz = min(v::timestamptz) AS min_as_core,
       max(v)::timestamptz = max(v::timestamptz) AS max_as_core
FROM jh_tz_mm;

-- one aggregate over thousands of values, against the sorted order
SELECT min(v) = (SELECT v FROM jh_tz_vals ORDER BY v LIMIT 1) AS min_of_many,
       max(v) = (SELECT v FROM jh_tz_vals ORDER BY v DESC LIMIT 1) AS max_of_many
FROM jh_tz_vals;

DROP TABLE jh_tz_mm;

-- SORTOP: with a btree index the planner answers min()/max() with a one-row
-- index scan (no Aggregate node), and the answer is the same
CREATE TABLE jh_tz_mmi (v jtimestamptz);
INSERT INTO jh_tz_mmi SELECT (timestamptz '2024-03-20 00:00:00+00' + (g) * interval '1 hour')::jtimestamptz FROM generate_series(0, 4999) g;
INSERT INTO jh_tz_mmi VALUES (NULL), (NULL);
CREATE INDEX jh_tz_mmi_v ON jh_tz_mmi (v);
ANALYZE jh_tz_mmi;
SELECT jh_plan_has('SELECT min(v) FROM jh_tz_mmi', 'Index (Only )?Scan (Backward )?using jh_tz_mmi_v') AS min_uses_index,
       jh_plan_has('SELECT max(v) FROM jh_tz_mmi', 'Index (Only )?Scan (Backward )?using jh_tz_mmi_v') AS max_uses_index,
       NOT jh_plan_has('SELECT min(v) FROM jh_tz_mmi', 'Aggregate') AS min_without_aggregate_node,
       NOT jh_plan_has('SELECT max(v) FROM jh_tz_mmi', 'Aggregate') AS max_without_aggregate_node;
SELECT min(v) = (timestamptz '2024-03-20 00:00:00+00' + (0) * interval '1 hour')::jtimestamptz AS min_by_index, max(v) = (timestamptz '2024-03-20 00:00:00+00' + (4999) * interval '1 hour')::jtimestamptz AS max_by_index FROM jh_tz_mmi;
SET enable_indexscan = off;
SET enable_indexonlyscan = off;
SET enable_bitmapscan = off;
SELECT min(v) = (timestamptz '2024-03-20 00:00:00+00' + (0) * interval '1 hour')::jtimestamptz AS min_by_seqscan, max(v) = (timestamptz '2024-03-20 00:00:00+00' + (4999) * interval '1 hour')::jtimestamptz AS max_by_seqscan FROM jh_tz_mmi;
RESET enable_indexscan;
RESET enable_indexonlyscan;
RESET enable_bitmapscan;
DROP TABLE jh_tz_mmi;

DROP TABLE jh_tz_vals;

-- an instant is the same in every zone: min()/max() do not depend on the
-- session zone, only their text does
CREATE TABLE jh_tz_zones (v jtimestamptz);
INSERT INTO jh_tz_zones VALUES
    ('1403-05-15 12:00:00+03:30'), ('1403-05-15 09:00:00+00'), ('1403-05-15 03:00:00-05'), (NULL);
SET timezone = 'UTC';
CREATE TEMP TABLE jh_tz_zone_results AS SELECT 'UTC' AS zone, min(v) AS mn, max(v) AS mx FROM jh_tz_zones;
SET timezone = 'Asia/Tehran';
INSERT INTO jh_tz_zone_results SELECT 'Asia/Tehran', min(v), max(v) FROM jh_tz_zones;
SET timezone = 'Pacific/Kiritimati';
INSERT INTO jh_tz_zone_results SELECT 'Pacific/Kiritimati', min(v), max(v) FROM jh_tz_zones;
SET timezone = 'UTC';
SELECT count(DISTINCT (mn, mx)) AS distinct_results_over_zones, count(*) AS zones FROM jh_tz_zone_results;
SELECT min(v) AS min_v, max(v) AS max_v FROM jh_tz_zones;
-- 08:30, 09:00 and 08:00 UTC: three different instants
SELECT count(DISTINCT v) AS distinct_instants FROM jh_tz_zones;
SET timezone = 'Asia/Tehran';
SELECT min(v) AS min_v_tehran, max(v) AS max_v_tehran FROM jh_tz_zones;
SET timezone = 'UTC';
DROP TABLE jh_tz_zone_results, jh_tz_zones;

DROP FUNCTION jh_plan_has(text, text);
DROP FUNCTION jh_plan_count(text, text);
DROP FUNCTION jh_int64(jtimestamp);
DROP FUNCTION jh_int64(jtimestamptz);
RESET DateStyle;
RESET timezone;
