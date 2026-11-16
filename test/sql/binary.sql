-- Binary send/receive. jdate and date share one wire format (a big-endian
-- int32 of days since 2000-01-01), so core's date can be used to build
-- binary input that jdate_recv must validate: date covers far more days
-- than the Jalali range, and a stored out-of-range jdate could never be
-- read back. The binary files live under test/results/ (the harness runs
-- from the repository root).
SET DateStyle = 'ISO, YMD';
SET timezone = 'UTC';

-- ---------------------------------------------------------------------
-- send: the wire bytes are exactly date's for the same day
-- ---------------------------------------------------------------------
CREATE TABLE binary_vals (d jdate);
INSERT INTO binary_vals VALUES
    ('1403-01-01'), ('-0061-01-01'), ('3177-12-29'), ('0000-01-01'),
    ('infinity'), ('-infinity');

SELECT d, encode(jdate_send(d), 'hex') AS wire,
       jdate_send(d) = date_send(d::date) AS same_as_date
FROM binary_vals ORDER BY d;

-- ---------------------------------------------------------------------
-- COPY (FORMAT binary) round trip of jdate values
-- ---------------------------------------------------------------------
\copy binary_vals TO 'test/results/binary_jdate.bin' WITH (FORMAT binary)
CREATE TABLE binary_back (d jdate);
\copy binary_back FROM 'test/results/binary_jdate.bin' WITH (FORMAT binary)
SELECT d FROM binary_back ORDER BY d;
SELECT (SELECT array_agg(d ORDER BY d) FROM binary_vals)
     = (SELECT array_agg(d ORDER BY d) FROM binary_back) AS roundtrip_equal;

-- the same file read as date gives the same days (jdate -> date is free)
CREATE TABLE binary_as_date (d date);
\copy binary_as_date FROM 'test/results/binary_jdate.bin' WITH (FORMAT binary)
SELECT d FROM binary_as_date ORDER BY d;
SELECT (SELECT array_agg(d::date ORDER BY d) FROM binary_vals)
     = (SELECT array_agg(d ORDER BY d) FROM binary_as_date) AS same_days_as_date;

-- ---------------------------------------------------------------------
-- recv: out-of-range days must be rejected with 22008 and load nothing.
-- Each file holds one date that core accepts but the Jalali calendar
-- cannot represent (before the fix these loaded, and then every SELECT on
-- the table failed).
-- ---------------------------------------------------------------------
CREATE TABLE binary_dates (d date);
CREATE TABLE binary_target (d jdate);
\set VERBOSITY sqlstate

-- one day below the minimum (-0061-01-01 is 0560-03-20)
INSERT INTO binary_dates VALUES ('0560-03-19');
\copy binary_dates TO 'test/results/binary_bad.bin' WITH (FORMAT binary)
\copy binary_target FROM 'test/results/binary_bad.bin' WITH (FORMAT binary)
SELECT count(*) AS rows_after_below_min FROM binary_target;

-- one day above the maximum (3177-12-29 is 3799-03-19)
TRUNCATE binary_dates;
INSERT INTO binary_dates VALUES ('3799-03-20');
\copy binary_dates TO 'test/results/binary_bad.bin' WITH (FORMAT binary)
\copy binary_target FROM 'test/results/binary_bad.bin' WITH (FORMAT binary)
SELECT count(*) AS rows_after_above_max FROM binary_target;

-- far outside, in both directions, up to core's own limits
TRUNCATE binary_dates;
INSERT INTO binary_dates VALUES ('9999-12-31');
\copy binary_dates TO 'test/results/binary_bad.bin' WITH (FORMAT binary)
\copy binary_target FROM 'test/results/binary_bad.bin' WITH (FORMAT binary)
SELECT count(*) AS rows_after_9999 FROM binary_target;

TRUNCATE binary_dates;
INSERT INTO binary_dates VALUES ('0001-01-01');
\copy binary_dates TO 'test/results/binary_bad.bin' WITH (FORMAT binary)
\copy binary_target FROM 'test/results/binary_bad.bin' WITH (FORMAT binary)
SELECT count(*) AS rows_after_year_1 FROM binary_target;

TRUNCATE binary_dates;
INSERT INTO binary_dates VALUES ('4714-11-24 BC');
\copy binary_dates TO 'test/results/binary_bad.bin' WITH (FORMAT binary)
\copy binary_target FROM 'test/results/binary_bad.bin' WITH (FORMAT binary)
SELECT count(*) AS rows_after_core_min FROM binary_target;

TRUNCATE binary_dates;
INSERT INTO binary_dates VALUES ('5874897-12-31');
\copy binary_dates TO 'test/results/binary_bad.bin' WITH (FORMAT binary)
\copy binary_target FROM 'test/results/binary_bad.bin' WITH (FORMAT binary)
SELECT count(*) AS rows_after_core_max FROM binary_target;

-- one bad row among valid ones fails the whole COPY: nothing is loaded
TRUNCATE binary_dates;
INSERT INTO binary_dates VALUES
    ('2024-03-20'), ('infinity'), ('9999-12-31'), ('2025-03-21');
\copy binary_dates TO 'test/results/binary_bad.bin' WITH (FORMAT binary)
\copy binary_target FROM 'test/results/binary_bad.bin' WITH (FORMAT binary)
SELECT count(*) AS rows_after_mixed FROM binary_target;

-- the table is still readable
SELECT * FROM binary_target;

-- the edge days and both infinities are valid on the wire
\set VERBOSITY default
TRUNCATE binary_dates;
INSERT INTO binary_dates VALUES
    ('0560-03-20'), ('3799-03-19'), ('infinity'), ('-infinity');
\copy binary_dates TO 'test/results/binary_good.bin' WITH (FORMAT binary)
\copy binary_target FROM 'test/results/binary_good.bin' WITH (FORMAT binary)
SELECT * FROM binary_target ORDER BY d;

DROP TABLE binary_vals, binary_back, binary_as_date, binary_dates, binary_target;
