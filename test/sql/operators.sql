-- comparisons
SELECT '1402-01-01'::jdate = '1402-01-01'::jdate AS eq_true;
SELECT '1402-01-01'::jdate = '1403-01-01'::jdate AS eq_false;
SELECT '1402-01-01'::jdate <> '1403-01-01'::jdate AS ne_true;
SELECT '1402-01-01'::jdate < '1403-01-01'::jdate AS lt_true;
SELECT '1403-01-01'::jdate < '1402-01-01'::jdate AS lt_false;
SELECT '1402-01-01'::jdate <= '1402-01-01'::jdate AS le_true;
SELECT '1403-01-01'::jdate > '1402-01-01'::jdate AS gt_true;
SELECT '1403-01-01'::jdate >= '1403-01-01'::jdate AS ge_true;

-- sorting
CREATE TABLE op_dates (d jdate);
INSERT INTO op_dates VALUES ('1403-05-01'), ('1401-01-01'), ('1403-01-01'), ('1402-12-29');
SELECT d FROM op_dates ORDER BY d;

-- indexing: btree opclass usable for equality and range lookups
CREATE INDEX op_dates_idx ON op_dates (d);
SET enable_seqscan = off;
EXPLAIN (COSTS off) SELECT * FROM op_dates WHERE d = '1403-01-01'::jdate;
EXPLAIN (COSTS off) SELECT * FROM op_dates WHERE d > '1402-01-01'::jdate ORDER BY d;
RESET enable_seqscan;

-- GROUP BY / DISTINCT
SELECT DISTINCT d FROM (VALUES ('1403-01-01'::jdate), ('1403-01-01'::jdate), ('1402-01-01'::jdate)) v(d) ORDER BY d;
SELECT d, count(*) FROM op_dates GROUP BY d ORDER BY d;

-- min/max aggregates
SELECT min(d), max(d), pg_typeof(min(d)) FROM op_dates;

DROP TABLE op_dates;
