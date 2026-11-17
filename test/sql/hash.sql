-- The hash opclass: support function 1 (jdate_hash) serves hash indexes,
-- Hash Join and HashAggregate; support function 2 (jdate_hash_extended,
-- seeded, 64-bit) is what PARTITION BY HASH needs. Hash values, and which
-- partition a row lands in, depend on the hash function, so this file prints
-- only counts and booleans that hold whatever the hash values are.

-- EXPLAIN node lines, indented text and "->" stripped, so a test can count or
-- print nodes without depending on the rest of the plan.
CREATE FUNCTION hash_test_plan(query text) RETURNS SETOF text
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
-- catalog: both support functions are registered and the opclass validates
-- ---------------------------------------------------------------------
SELECT amprocnum, amproc::regproc
FROM pg_amproc
WHERE amprocfamily = (SELECT opcfamily FROM pg_opclass WHERE opcname = 'jdate_hash_ops')
ORDER BY amprocnum;

SELECT amvalidate(oid) AS jdate_hash_ops_valid
FROM pg_opclass WHERE opcname = 'jdate_hash_ops';

-- ---------------------------------------------------------------------
-- the extended hash agrees with the standard one at seed 0 (in the low 32
-- bits, the rule core's extended hash functions follow) and depends on the
-- seed; infinity and the range edges hash like any other day
-- ---------------------------------------------------------------------
CREATE TABLE hash_days AS
    SELECT '1403-01-01'::jdate + g AS d FROM generate_series(0, 999) g;
INSERT INTO hash_days VALUES
    ('infinity'), ('-infinity'), ('-0061-01-01'), ('3177-12-29');

SELECT count(*) AS days,
       count(*) FILTER (WHERE (jdate_hash_extended(d, 0) & 4294967295)
                            <> (jdate_hash(d)::bigint & 4294967295)) AS seed0_mismatches,
       count(*) FILTER (WHERE jdate_hash_extended(d, 1) <> jdate_hash_extended(d, 0)) * 10
           >= count(*) * 9 AS seed_changes_most_hashes
FROM hash_days;

-- equal days hash equally, whichever way they were written
SELECT jdate_hash_extended('1403-01-01'::jdate, 7)
     = jdate_hash_extended(('2024-03-20'::date)::jdate, 7) AS same_day_same_hash;

-- ---------------------------------------------------------------------
-- PARTITION BY HASH
-- ---------------------------------------------------------------------
CREATE TABLE hash_part (d jdate NOT NULL, n int) PARTITION BY HASH (d);
CREATE TABLE hash_part_0 PARTITION OF hash_part FOR VALUES WITH (modulus 3, remainder 0);
CREATE TABLE hash_part_1 PARTITION OF hash_part FOR VALUES WITH (modulus 3, remainder 1);
CREATE TABLE hash_part_2 PARTITION OF hash_part FOR VALUES WITH (modulus 3, remainder 2);

-- every row finds a partition (otherwise the INSERT fails), and the rows are
-- spread over at least two of them
INSERT INTO hash_part SELECT d, 1 FROM hash_days;
SELECT count(*) AS rows_total FROM hash_part;
SELECT (SELECT count(*) FROM hash_part_0)
     + (SELECT count(*) FROM hash_part_1)
     + (SELECT count(*) FROM hash_part_2) AS rows_in_partitions;
SELECT count(DISTINCT tableoid) >= 2 AS spread_over_partitions FROM hash_part;

-- partition pruning picks the one partition that holds the key: one scan
-- instead of three, and it still finds the row
SELECT count(*) AS partitions_scanned_unpruned
FROM hash_test_plan('SELECT * FROM hash_part') AS l WHERE l LIKE '%Scan on%';
SELECT count(*) AS partitions_scanned_by_key
FROM hash_test_plan('SELECT * FROM hash_part WHERE d = ''1403-01-05''') AS l
WHERE l LIKE '%Scan on%';
SELECT count(*) AS partitions_scanned_by_infinity
FROM hash_test_plan('SELECT * FROM hash_part WHERE d = ''infinity''') AS l
WHERE l LIKE '%Scan on%';
SELECT count(*) AS found_1403_01_05 FROM hash_part WHERE d = '1403-01-05';
SELECT count(*) AS found_infinity FROM hash_part WHERE d = 'infinity';

-- runtime pruning (the key is a parameter) agrees with where insert put each
-- row: a wrong partition would give 0 rows for that key
SELECT count(*) AS days_found_by_key
FROM hash_days h WHERE (SELECT count(*) FROM hash_part p WHERE p.d = h.d) = 1;

DROP TABLE hash_part;

-- ---------------------------------------------------------------------
-- hash index
-- ---------------------------------------------------------------------
CREATE TABLE hash_idx_t (d jdate, n int);
INSERT INTO hash_idx_t SELECT '1403-01-01'::jdate + g, g FROM generate_series(0, 4999) g;
INSERT INTO hash_idx_t VALUES ('infinity', -1), ('-infinity', -2);
CREATE INDEX hash_idx_t_d ON hash_idx_t USING hash (d);
ANALYZE hash_idx_t;

SET enable_seqscan = off;
SET enable_bitmapscan = off;
SELECT trim(l) AS plan_node FROM hash_test_plan('SELECT n FROM hash_idx_t WHERE d = ''1403-01-05''') AS l
WHERE l LIKE '%Scan%';
SELECT n FROM hash_idx_t WHERE d = '1403-01-05';
SELECT n FROM hash_idx_t WHERE d = '1403-01-01'::jdate + 4999;
SELECT n FROM hash_idx_t WHERE d = 'infinity';
SELECT n FROM hash_idx_t WHERE d = '-infinity';
SELECT count(*) AS absent FROM hash_idx_t WHERE d = '1420-01-01';
RESET enable_seqscan;
RESET enable_bitmapscan;

DROP TABLE hash_idx_t;

-- ---------------------------------------------------------------------
-- Hash Join and HashAggregate give the same rows as the sort-based plans
-- ---------------------------------------------------------------------
-- a: 300 distinct days, three rows each, plus both infinities;
-- b: every second day for 400 days, plus both infinities
CREATE TABLE hash_join_a (d jdate, n int);
CREATE TABLE hash_join_b (d jdate, m int);
INSERT INTO hash_join_a SELECT '1403-01-01'::jdate + (g % 300), g FROM generate_series(0, 899) g;
INSERT INTO hash_join_b SELECT '1403-01-01'::jdate + (g * 2), g FROM generate_series(0, 199) g;
INSERT INTO hash_join_a VALUES ('infinity', 1000), ('-infinity', 1001);
INSERT INTO hash_join_b VALUES ('infinity', 2000), ('-infinity', 2001);
ANALYZE hash_join_a;
ANALYZE hash_join_b;

CREATE TEMP TABLE hash_join_results (method text, join_rows bigint, checksum bigint);

SET enable_mergejoin = off;
SET enable_nestloop = off;
SELECT trim(l) AS plan_node
FROM hash_test_plan('SELECT * FROM hash_join_a a JOIN hash_join_b b ON a.d = b.d') AS l
WHERE l ~ '^(Hash Join|Merge Join|Nested Loop)';
INSERT INTO hash_join_results
SELECT 'hash', count(*), sum(a.n + b.m) FROM hash_join_a a JOIN hash_join_b b ON a.d = b.d;
RESET enable_mergejoin;
RESET enable_nestloop;

SET enable_hashjoin = off;
SET enable_nestloop = off;
SELECT trim(l) AS plan_node
FROM hash_test_plan('SELECT * FROM hash_join_a a JOIN hash_join_b b ON a.d = b.d') AS l
WHERE l ~ '^(Hash Join|Merge Join|Nested Loop)';
INSERT INTO hash_join_results
SELECT 'merge', count(*), sum(a.n + b.m) FROM hash_join_a a JOIN hash_join_b b ON a.d = b.d;
RESET enable_hashjoin;
RESET enable_nestloop;

SET enable_hashjoin = off;
SET enable_mergejoin = off;
SELECT trim(l) AS plan_node
FROM hash_test_plan('SELECT * FROM hash_join_a a JOIN hash_join_b b ON a.d = b.d') AS l
WHERE l ~ '^(Hash Join|Merge Join|Nested Loop)';
INSERT INTO hash_join_results
SELECT 'nestloop', count(*), sum(a.n + b.m) FROM hash_join_a a JOIN hash_join_b b ON a.d = b.d;
RESET enable_hashjoin;
RESET enable_mergejoin;

SELECT method, join_rows, checksum FROM hash_join_results ORDER BY method;
SELECT count(DISTINCT (join_rows, checksum)) AS distinct_results FROM hash_join_results;

CREATE TEMP TABLE hash_agg_results (method text, grp bigint, total bigint, biggest bigint);

SET enable_sort = off;
SELECT trim(l) AS plan_node
FROM hash_test_plan('SELECT d, count(*) FROM hash_join_a GROUP BY d') AS l
WHERE l ~ 'Aggregate$';
INSERT INTO hash_agg_results
SELECT 'hash', count(*), sum(c), max(c) FROM (SELECT d, count(*) AS c FROM hash_join_a GROUP BY d) s;
RESET enable_sort;

SET enable_hashagg = off;
SELECT trim(l) AS plan_node
FROM hash_test_plan('SELECT d, count(*) FROM hash_join_a GROUP BY d') AS l
WHERE l ~ 'Aggregate$';
INSERT INTO hash_agg_results
SELECT 'sort', count(*), sum(c), max(c) FROM (SELECT d, count(*) AS c FROM hash_join_a GROUP BY d) s;
RESET enable_hashagg;

SELECT method, grp, total, biggest FROM hash_agg_results ORDER BY method;
SELECT count(DISTINCT (grp, total, biggest)) AS distinct_results FROM hash_agg_results;

DROP TABLE hash_join_results, hash_agg_results, hash_join_a, hash_join_b, hash_days;
DROP FUNCTION hash_test_plan(text);
