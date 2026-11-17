-- jdate <-> timestamptz under non-UTC time zones.
--
-- jdate(timestamptz) and the timestamptz -> jdate assignment cast take the
-- calendar day in the SESSION time zone (core's timestamptz_date), and
-- timestamptz(jdate) is local midnight in the session zone. This file runs
-- the same checks in six zones, one of them UTC and two of them at the
-- extremes of the offset range (Pacific/Kiritimati is +14, Pacific/Pago_Pago
-- is -11). Instants are built from LOCAL clock times with AT TIME ZONE, so a
-- probe means the same thing whatever the session zone is.
--
-- Output must be identical on PostgreSQL 16, 17 and 18: DateStyle and
-- timezone are set explicitly (pg_regress forces PGTZ=PST8PDT and a
-- non-ISO DateStyle), only dates, booleans and counts are printed, and no
-- probe lies near a tzdata rule change (the only past rule change used is
-- Tehran's summer time in 2020, two years before it was abolished).
SET DateStyle = 'ISO, YMD';
SET timezone = 'UTC';

-- results collected per zone and printed together at the end
CREATE TABLE tz_ins (
    id    int GENERATED ALWAYS AS IDENTITY,
    zone  text,
    lt    timestamp,   -- local clock time in zone
    d     jdate,       -- stored through the assignment cast
    expect jdate
);
CREATE TABLE tz_nowruz (
    id    int GENERATED ALWAYS AS IDENTITY,
    zone  text,
    d     jdate,
    expect jdate
);

-- ---------------------------------------------------------------------
-- Per zone: instants just before and after local midnight, the INSERT
-- (assignment cast) path, timestamptz(jdate) is local midnight, round
-- trip jdate(timestamptz(d)) = d over all of 1403, hourly instants over a
-- year against core's own date conversion, the Nowruz instant, and
-- jdate_format. Local 2024-03-19 is 1402-12-29 and 2024-03-20 is 1403-01-01
-- (Nowruz 1403) in every zone.
-- ---------------------------------------------------------------------

-- ===== UTC =====
SET timezone = 'UTC';
SELECT current_setting('timezone') AS zone;

-- function form around local midnight
SELECT lt, jdate(lt AT TIME ZONE 'UTC') AS day
FROM (VALUES (timestamp '2024-03-19 23:59:59'),
             (timestamp '2024-03-19 23:59:59.999999'),
             (timestamp '2024-03-20 00:00:00'),
             (timestamp '2024-03-20 00:00:00.000001')) v(lt)
ORDER BY lt;

-- assignment cast into a jdate column, same instants
INSERT INTO tz_ins (zone, lt, d, expect)
SELECT 'UTC', lt, lt AT TIME ZONE 'UTC', expect
FROM (VALUES (timestamp '2024-03-19 23:59:59',           jdate '1402-12-29'),
             (timestamp '2024-03-19 23:59:59.999999',    jdate '1402-12-29'),
             (timestamp '2024-03-20 00:00:00',           jdate '1403-01-01'),
             (timestamp '2024-03-20 00:00:00.000001',    jdate '1403-01-01')) v(lt, expect);

-- timestamptz(jdate) is local midnight in this zone
SELECT d, timestamptz(d) AT TIME ZONE 'UTC' AS local_ts,
       timestamptz(d) = (d::timestamp AT TIME ZONE 'UTC') AS is_local_midnight
FROM (VALUES (jdate '1402-12-29'), (jdate '1403-01-01'), (jdate '1403-05-15')) v(d)
ORDER BY d;

-- round trip over every day of 1403 (it spans both DST changes of New_York
-- and Auckland): no mismatch allowed
SELECT count(*) AS days,
       count(*) FILTER (WHERE jdate(timestamptz(d)) <> d) AS roundtrip_mismatches
FROM (SELECT jdate '1403-01-01' + g AS d FROM generate_series(0, 365) g) s;

-- every hour of 2024: jdate(ts) is core's date conversion of the same ts,
-- both through the session zone and through an explicit AT TIME ZONE
SELECT count(*) AS instants,
       count(*) FILTER (WHERE jdate(ts) <> (ts::date)::jdate) AS mismatches,
       count(*) FILTER (WHERE jdate(ts) <> ((ts AT TIME ZONE 'UTC')::date)::jdate) AS mismatches_at_time_zone
FROM generate_series(timestamptz '2024-01-01 00:00:00+00',
                     timestamptz '2024-12-31 23:00:00+00',
                     interval '1 hour') AS ts;

-- the Nowruz 1403 instant: 00:30 Tehran time on 2024-03-20
INSERT INTO tz_nowruz (zone, d, expect)
VALUES ('UTC', jdate(timestamptz '2024-03-20 00:30:00+03:30'), jdate '1402-12-29');

-- jdate_format at that instant, with and without the time of day
SELECT jdate_format(timestamptz '2024-03-20 00:30:00+03:30') AS fmt_time,
       jdate_format(timestamptz '2024-03-20 00:30:00+03:30', false) AS fmt_date;
SELECT jdate_format(timestamptz '2024-03-19 23:59:59+00') AS fmt_utc_before_midnight,
       jdate_format(timestamptz '2024-03-20 00:00:00+00', false) AS fmt_utc_midnight_date;

-- ===== Asia/Tehran =====
SET timezone = 'Asia/Tehran';
SELECT current_setting('timezone') AS zone;

-- function form around local midnight
SELECT lt, jdate(lt AT TIME ZONE 'Asia/Tehran') AS day
FROM (VALUES (timestamp '2024-03-19 23:59:59'),
             (timestamp '2024-03-19 23:59:59.999999'),
             (timestamp '2024-03-20 00:00:00'),
             (timestamp '2024-03-20 00:00:00.000001')) v(lt)
ORDER BY lt;

-- assignment cast into a jdate column, same instants
INSERT INTO tz_ins (zone, lt, d, expect)
SELECT 'Asia/Tehran', lt, lt AT TIME ZONE 'Asia/Tehran', expect
FROM (VALUES (timestamp '2024-03-19 23:59:59',           jdate '1402-12-29'),
             (timestamp '2024-03-19 23:59:59.999999',    jdate '1402-12-29'),
             (timestamp '2024-03-20 00:00:00',           jdate '1403-01-01'),
             (timestamp '2024-03-20 00:00:00.000001',    jdate '1403-01-01')) v(lt, expect);

-- timestamptz(jdate) is local midnight in this zone
SELECT d, timestamptz(d) AT TIME ZONE 'Asia/Tehran' AS local_ts,
       timestamptz(d) = (d::timestamp AT TIME ZONE 'Asia/Tehran') AS is_local_midnight
FROM (VALUES (jdate '1402-12-29'), (jdate '1403-01-01'), (jdate '1403-05-15')) v(d)
ORDER BY d;

-- round trip over every day of 1403 (it spans both DST changes of New_York
-- and Auckland): no mismatch allowed
SELECT count(*) AS days,
       count(*) FILTER (WHERE jdate(timestamptz(d)) <> d) AS roundtrip_mismatches
FROM (SELECT jdate '1403-01-01' + g AS d FROM generate_series(0, 365) g) s;

-- every hour of 2024: jdate(ts) is core's date conversion of the same ts,
-- both through the session zone and through an explicit AT TIME ZONE
SELECT count(*) AS instants,
       count(*) FILTER (WHERE jdate(ts) <> (ts::date)::jdate) AS mismatches,
       count(*) FILTER (WHERE jdate(ts) <> ((ts AT TIME ZONE 'Asia/Tehran')::date)::jdate) AS mismatches_at_time_zone
FROM generate_series(timestamptz '2024-01-01 00:00:00+00',
                     timestamptz '2024-12-31 23:00:00+00',
                     interval '1 hour') AS ts;

-- the Nowruz 1403 instant: 00:30 Tehran time on 2024-03-20
INSERT INTO tz_nowruz (zone, d, expect)
VALUES ('Asia/Tehran', jdate(timestamptz '2024-03-20 00:30:00+03:30'), jdate '1403-01-01');

-- jdate_format at that instant, with and without the time of day
SELECT jdate_format(timestamptz '2024-03-20 00:30:00+03:30') AS fmt_time,
       jdate_format(timestamptz '2024-03-20 00:30:00+03:30', false) AS fmt_date;
SELECT jdate_format(timestamptz '2024-03-19 23:59:59+00') AS fmt_utc_before_midnight,
       jdate_format(timestamptz '2024-03-20 00:00:00+00', false) AS fmt_utc_midnight_date;

-- ===== America/New_York =====
SET timezone = 'America/New_York';
SELECT current_setting('timezone') AS zone;

-- function form around local midnight
SELECT lt, jdate(lt AT TIME ZONE 'America/New_York') AS day
FROM (VALUES (timestamp '2024-03-19 23:59:59'),
             (timestamp '2024-03-19 23:59:59.999999'),
             (timestamp '2024-03-20 00:00:00'),
             (timestamp '2024-03-20 00:00:00.000001')) v(lt)
ORDER BY lt;

-- assignment cast into a jdate column, same instants
INSERT INTO tz_ins (zone, lt, d, expect)
SELECT 'America/New_York', lt, lt AT TIME ZONE 'America/New_York', expect
FROM (VALUES (timestamp '2024-03-19 23:59:59',           jdate '1402-12-29'),
             (timestamp '2024-03-19 23:59:59.999999',    jdate '1402-12-29'),
             (timestamp '2024-03-20 00:00:00',           jdate '1403-01-01'),
             (timestamp '2024-03-20 00:00:00.000001',    jdate '1403-01-01')) v(lt, expect);

-- timestamptz(jdate) is local midnight in this zone
SELECT d, timestamptz(d) AT TIME ZONE 'America/New_York' AS local_ts,
       timestamptz(d) = (d::timestamp AT TIME ZONE 'America/New_York') AS is_local_midnight
FROM (VALUES (jdate '1402-12-29'), (jdate '1403-01-01'), (jdate '1403-05-15')) v(d)
ORDER BY d;

-- round trip over every day of 1403 (it spans both DST changes of New_York
-- and Auckland): no mismatch allowed
SELECT count(*) AS days,
       count(*) FILTER (WHERE jdate(timestamptz(d)) <> d) AS roundtrip_mismatches
FROM (SELECT jdate '1403-01-01' + g AS d FROM generate_series(0, 365) g) s;

-- every hour of 2024: jdate(ts) is core's date conversion of the same ts,
-- both through the session zone and through an explicit AT TIME ZONE
SELECT count(*) AS instants,
       count(*) FILTER (WHERE jdate(ts) <> (ts::date)::jdate) AS mismatches,
       count(*) FILTER (WHERE jdate(ts) <> ((ts AT TIME ZONE 'America/New_York')::date)::jdate) AS mismatches_at_time_zone
FROM generate_series(timestamptz '2024-01-01 00:00:00+00',
                     timestamptz '2024-12-31 23:00:00+00',
                     interval '1 hour') AS ts;

-- the Nowruz 1403 instant: 00:30 Tehran time on 2024-03-20
INSERT INTO tz_nowruz (zone, d, expect)
VALUES ('America/New_York', jdate(timestamptz '2024-03-20 00:30:00+03:30'), jdate '1402-12-29');

-- jdate_format at that instant, with and without the time of day
SELECT jdate_format(timestamptz '2024-03-20 00:30:00+03:30') AS fmt_time,
       jdate_format(timestamptz '2024-03-20 00:30:00+03:30', false) AS fmt_date;
SELECT jdate_format(timestamptz '2024-03-19 23:59:59+00') AS fmt_utc_before_midnight,
       jdate_format(timestamptz '2024-03-20 00:00:00+00', false) AS fmt_utc_midnight_date;

-- ===== Pacific/Kiritimati =====
SET timezone = 'Pacific/Kiritimati';
SELECT current_setting('timezone') AS zone;

-- function form around local midnight
SELECT lt, jdate(lt AT TIME ZONE 'Pacific/Kiritimati') AS day
FROM (VALUES (timestamp '2024-03-19 23:59:59'),
             (timestamp '2024-03-19 23:59:59.999999'),
             (timestamp '2024-03-20 00:00:00'),
             (timestamp '2024-03-20 00:00:00.000001')) v(lt)
ORDER BY lt;

-- assignment cast into a jdate column, same instants
INSERT INTO tz_ins (zone, lt, d, expect)
SELECT 'Pacific/Kiritimati', lt, lt AT TIME ZONE 'Pacific/Kiritimati', expect
FROM (VALUES (timestamp '2024-03-19 23:59:59',           jdate '1402-12-29'),
             (timestamp '2024-03-19 23:59:59.999999',    jdate '1402-12-29'),
             (timestamp '2024-03-20 00:00:00',           jdate '1403-01-01'),
             (timestamp '2024-03-20 00:00:00.000001',    jdate '1403-01-01')) v(lt, expect);

-- timestamptz(jdate) is local midnight in this zone
SELECT d, timestamptz(d) AT TIME ZONE 'Pacific/Kiritimati' AS local_ts,
       timestamptz(d) = (d::timestamp AT TIME ZONE 'Pacific/Kiritimati') AS is_local_midnight
FROM (VALUES (jdate '1402-12-29'), (jdate '1403-01-01'), (jdate '1403-05-15')) v(d)
ORDER BY d;

-- round trip over every day of 1403 (it spans both DST changes of New_York
-- and Auckland): no mismatch allowed
SELECT count(*) AS days,
       count(*) FILTER (WHERE jdate(timestamptz(d)) <> d) AS roundtrip_mismatches
FROM (SELECT jdate '1403-01-01' + g AS d FROM generate_series(0, 365) g) s;

-- every hour of 2024: jdate(ts) is core's date conversion of the same ts,
-- both through the session zone and through an explicit AT TIME ZONE
SELECT count(*) AS instants,
       count(*) FILTER (WHERE jdate(ts) <> (ts::date)::jdate) AS mismatches,
       count(*) FILTER (WHERE jdate(ts) <> ((ts AT TIME ZONE 'Pacific/Kiritimati')::date)::jdate) AS mismatches_at_time_zone
FROM generate_series(timestamptz '2024-01-01 00:00:00+00',
                     timestamptz '2024-12-31 23:00:00+00',
                     interval '1 hour') AS ts;

-- the Nowruz 1403 instant: 00:30 Tehran time on 2024-03-20
INSERT INTO tz_nowruz (zone, d, expect)
VALUES ('Pacific/Kiritimati', jdate(timestamptz '2024-03-20 00:30:00+03:30'), jdate '1403-01-01');

-- jdate_format at that instant, with and without the time of day
SELECT jdate_format(timestamptz '2024-03-20 00:30:00+03:30') AS fmt_time,
       jdate_format(timestamptz '2024-03-20 00:30:00+03:30', false) AS fmt_date;
SELECT jdate_format(timestamptz '2024-03-19 23:59:59+00') AS fmt_utc_before_midnight,
       jdate_format(timestamptz '2024-03-20 00:00:00+00', false) AS fmt_utc_midnight_date;

-- ===== Pacific/Pago_Pago =====
SET timezone = 'Pacific/Pago_Pago';
SELECT current_setting('timezone') AS zone;

-- function form around local midnight
SELECT lt, jdate(lt AT TIME ZONE 'Pacific/Pago_Pago') AS day
FROM (VALUES (timestamp '2024-03-19 23:59:59'),
             (timestamp '2024-03-19 23:59:59.999999'),
             (timestamp '2024-03-20 00:00:00'),
             (timestamp '2024-03-20 00:00:00.000001')) v(lt)
ORDER BY lt;

-- assignment cast into a jdate column, same instants
INSERT INTO tz_ins (zone, lt, d, expect)
SELECT 'Pacific/Pago_Pago', lt, lt AT TIME ZONE 'Pacific/Pago_Pago', expect
FROM (VALUES (timestamp '2024-03-19 23:59:59',           jdate '1402-12-29'),
             (timestamp '2024-03-19 23:59:59.999999',    jdate '1402-12-29'),
             (timestamp '2024-03-20 00:00:00',           jdate '1403-01-01'),
             (timestamp '2024-03-20 00:00:00.000001',    jdate '1403-01-01')) v(lt, expect);

-- timestamptz(jdate) is local midnight in this zone
SELECT d, timestamptz(d) AT TIME ZONE 'Pacific/Pago_Pago' AS local_ts,
       timestamptz(d) = (d::timestamp AT TIME ZONE 'Pacific/Pago_Pago') AS is_local_midnight
FROM (VALUES (jdate '1402-12-29'), (jdate '1403-01-01'), (jdate '1403-05-15')) v(d)
ORDER BY d;

-- round trip over every day of 1403 (it spans both DST changes of New_York
-- and Auckland): no mismatch allowed
SELECT count(*) AS days,
       count(*) FILTER (WHERE jdate(timestamptz(d)) <> d) AS roundtrip_mismatches
FROM (SELECT jdate '1403-01-01' + g AS d FROM generate_series(0, 365) g) s;

-- every hour of 2024: jdate(ts) is core's date conversion of the same ts,
-- both through the session zone and through an explicit AT TIME ZONE
SELECT count(*) AS instants,
       count(*) FILTER (WHERE jdate(ts) <> (ts::date)::jdate) AS mismatches,
       count(*) FILTER (WHERE jdate(ts) <> ((ts AT TIME ZONE 'Pacific/Pago_Pago')::date)::jdate) AS mismatches_at_time_zone
FROM generate_series(timestamptz '2024-01-01 00:00:00+00',
                     timestamptz '2024-12-31 23:00:00+00',
                     interval '1 hour') AS ts;

-- the Nowruz 1403 instant: 00:30 Tehran time on 2024-03-20
INSERT INTO tz_nowruz (zone, d, expect)
VALUES ('Pacific/Pago_Pago', jdate(timestamptz '2024-03-20 00:30:00+03:30'), jdate '1402-12-29');

-- jdate_format at that instant, with and without the time of day
SELECT jdate_format(timestamptz '2024-03-20 00:30:00+03:30') AS fmt_time,
       jdate_format(timestamptz '2024-03-20 00:30:00+03:30', false) AS fmt_date;
SELECT jdate_format(timestamptz '2024-03-19 23:59:59+00') AS fmt_utc_before_midnight,
       jdate_format(timestamptz '2024-03-20 00:00:00+00', false) AS fmt_utc_midnight_date;

-- ===== Pacific/Auckland =====
SET timezone = 'Pacific/Auckland';
SELECT current_setting('timezone') AS zone;

-- function form around local midnight
SELECT lt, jdate(lt AT TIME ZONE 'Pacific/Auckland') AS day
FROM (VALUES (timestamp '2024-03-19 23:59:59'),
             (timestamp '2024-03-19 23:59:59.999999'),
             (timestamp '2024-03-20 00:00:00'),
             (timestamp '2024-03-20 00:00:00.000001')) v(lt)
ORDER BY lt;

-- assignment cast into a jdate column, same instants
INSERT INTO tz_ins (zone, lt, d, expect)
SELECT 'Pacific/Auckland', lt, lt AT TIME ZONE 'Pacific/Auckland', expect
FROM (VALUES (timestamp '2024-03-19 23:59:59',           jdate '1402-12-29'),
             (timestamp '2024-03-19 23:59:59.999999',    jdate '1402-12-29'),
             (timestamp '2024-03-20 00:00:00',           jdate '1403-01-01'),
             (timestamp '2024-03-20 00:00:00.000001',    jdate '1403-01-01')) v(lt, expect);

-- timestamptz(jdate) is local midnight in this zone
SELECT d, timestamptz(d) AT TIME ZONE 'Pacific/Auckland' AS local_ts,
       timestamptz(d) = (d::timestamp AT TIME ZONE 'Pacific/Auckland') AS is_local_midnight
FROM (VALUES (jdate '1402-12-29'), (jdate '1403-01-01'), (jdate '1403-05-15')) v(d)
ORDER BY d;

-- round trip over every day of 1403 (it spans both DST changes of New_York
-- and Auckland): no mismatch allowed
SELECT count(*) AS days,
       count(*) FILTER (WHERE jdate(timestamptz(d)) <> d) AS roundtrip_mismatches
FROM (SELECT jdate '1403-01-01' + g AS d FROM generate_series(0, 365) g) s;

-- every hour of 2024: jdate(ts) is core's date conversion of the same ts,
-- both through the session zone and through an explicit AT TIME ZONE
SELECT count(*) AS instants,
       count(*) FILTER (WHERE jdate(ts) <> (ts::date)::jdate) AS mismatches,
       count(*) FILTER (WHERE jdate(ts) <> ((ts AT TIME ZONE 'Pacific/Auckland')::date)::jdate) AS mismatches_at_time_zone
FROM generate_series(timestamptz '2024-01-01 00:00:00+00',
                     timestamptz '2024-12-31 23:00:00+00',
                     interval '1 hour') AS ts;

-- the Nowruz 1403 instant: 00:30 Tehran time on 2024-03-20
INSERT INTO tz_nowruz (zone, d, expect)
VALUES ('Pacific/Auckland', jdate(timestamptz '2024-03-20 00:30:00+03:30'), jdate '1403-01-01');

-- jdate_format at that instant, with and without the time of day
SELECT jdate_format(timestamptz '2024-03-20 00:30:00+03:30') AS fmt_time,
       jdate_format(timestamptz '2024-03-20 00:30:00+03:30', false) AS fmt_date;
SELECT jdate_format(timestamptz '2024-03-19 23:59:59+00') AS fmt_utc_before_midnight,
       jdate_format(timestamptz '2024-03-20 00:00:00+00', false) AS fmt_utc_midnight_date;

-- ---------------------------------------------------------------------
-- Results gathered above
-- ---------------------------------------------------------------------
SET timezone = 'UTC';

-- the INSERT path agrees with the expected local day in every zone
SELECT zone, lt, d, d = expect AS as_expected FROM tz_ins ORDER BY id;
SELECT count(*) AS probes, count(*) FILTER (WHERE d <> expect) AS wrong FROM tz_ins;

-- one instant, different days: Tehran, Kiritimati and Auckland are already
-- on 1403-01-01, UTC, New_York and Pago_Pago are still on 1402-12-29
SELECT zone, d, d = expect AS as_expected FROM tz_nowruz ORDER BY id;
SELECT count(DISTINCT d) AS distinct_days FROM tz_nowruz;

-- ---------------------------------------------------------------------
-- Daylight saving transition days, America/New_York 2024. Instants are
-- given in UTC so there is no ambiguity at the repeated hour. The local day
-- of the spring change (2024-03-10, 1402-12-20) has 23 hours, the day of
-- the autumn change (2024-11-03, 1403-08-13) has 25.
-- ---------------------------------------------------------------------
SET timezone = 'America/New_York';
SELECT ts AT TIME ZONE 'America/New_York' AS local_ts, jdate(ts) AS day
FROM (VALUES (timestamptz '2024-03-10 04:59:59+00'),
             (timestamptz '2024-03-10 05:00:00+00'),
             (timestamptz '2024-03-10 06:59:59+00'),
             (timestamptz '2024-03-10 07:00:00+00'),
             (timestamptz '2024-03-11 03:59:59+00'),
             (timestamptz '2024-03-11 04:00:00+00')) v(ts)
ORDER BY ts;
SELECT jdate(ts) AS day, count(*) AS hours
FROM generate_series(timestamptz '2024-03-10 05:00:00+00',
                     timestamptz '2024-03-11 04:00:00+00',
                     interval '1 hour') AS ts
GROUP BY 1 ORDER BY 1;

SELECT ts AT TIME ZONE 'America/New_York' AS local_ts, jdate(ts) AS day
FROM (VALUES (timestamptz '2024-11-03 03:59:59+00'),
             (timestamptz '2024-11-03 04:00:00+00'),
             (timestamptz '2024-11-03 05:30:00+00'),
             (timestamptz '2024-11-03 06:30:00+00'),
             (timestamptz '2024-11-04 04:59:59+00'),
             (timestamptz '2024-11-04 05:00:00+00')) v(ts)
ORDER BY ts;
SELECT jdate(ts) AS day, count(*) AS hours
FROM generate_series(timestamptz '2024-11-03 04:00:00+00',
                     timestamptz '2024-11-04 05:00:00+00',
                     interval '1 hour') AS ts
GROUP BY 1 ORDER BY 1;

-- local midnight of both days, and back
SELECT d, timestamptz(d) AT TIME ZONE 'UTC' AS midnight_utc, jdate(timestamptz(d)) = d AS roundtrip_ok
FROM (VALUES (jdate '1402-12-20'), (jdate '1403-08-13')) v(d) ORDER BY d;

-- ---------------------------------------------------------------------
-- Pacific/Auckland: summer time ends 2024-04-07 (1403-01-19, a 25 hour
-- day) and starts 2024-09-29 (1403-07-08, a 23 hour day).
-- ---------------------------------------------------------------------
SET timezone = 'Pacific/Auckland';
SELECT ts AT TIME ZONE 'Pacific/Auckland' AS local_ts, jdate(ts) AS day
FROM (VALUES (timestamptz '2024-04-06 10:59:59+00'),
             (timestamptz '2024-04-06 11:00:00+00'),
             (timestamptz '2024-04-06 13:30:00+00'),
             (timestamptz '2024-04-06 14:30:00+00'),
             (timestamptz '2024-04-07 11:59:59+00'),
             (timestamptz '2024-04-07 12:00:00+00')) v(ts)
ORDER BY ts;
SELECT jdate(ts) AS day, count(*) AS hours
FROM generate_series(timestamptz '2024-04-06 11:00:00+00',
                     timestamptz '2024-04-07 12:00:00+00',
                     interval '1 hour') AS ts
GROUP BY 1 ORDER BY 1;

SELECT ts AT TIME ZONE 'Pacific/Auckland' AS local_ts, jdate(ts) AS day
FROM (VALUES (timestamptz '2024-09-28 11:59:59+00'),
             (timestamptz '2024-09-28 12:00:00+00'),
             (timestamptz '2024-09-28 13:59:59+00'),
             (timestamptz '2024-09-28 14:00:00+00'),
             (timestamptz '2024-09-29 10:59:59+00'),
             (timestamptz '2024-09-29 11:00:00+00')) v(ts)
ORDER BY ts;
SELECT jdate(ts) AS day, count(*) AS hours
FROM generate_series(timestamptz '2024-09-28 12:00:00+00',
                     timestamptz '2024-09-29 11:00:00+00',
                     interval '1 hour') AS ts
GROUP BY 1 ORDER BY 1;

SELECT d, timestamptz(d) AT TIME ZONE 'UTC' AS midnight_utc, jdate(timestamptz(d)) = d AS roundtrip_ok
FROM (VALUES (jdate '1403-01-19'), (jdate '1403-07-08')) v(d) ORDER BY d;

-- ---------------------------------------------------------------------
-- Asia/Tehran kept summer time (UTC+04:30) until 2022. 2020 is well away
-- from that change: local midnight of 1399-04-25 (2020-07-15) was
-- 19:30 UTC the evening before, while in winter (UTC+03:30) the midnight of
-- 1398-10-25 (2020-01-15) was 20:30 UTC.
-- ---------------------------------------------------------------------
SET timezone = 'Asia/Tehran';
SELECT ts AT TIME ZONE 'UTC' AS utc_ts, ts AT TIME ZONE 'Asia/Tehran' AS local_ts, jdate(ts) AS day
FROM (VALUES (timestamptz '2020-07-14 19:15:00+00'),
             (timestamptz '2020-07-14 19:45:00+00'),
             (timestamptz '2020-01-14 20:15:00+00'),
             (timestamptz '2020-01-14 20:45:00+00')) v(ts)
ORDER BY ts;
SELECT d, timestamptz(d) AT TIME ZONE 'UTC' AS midnight_utc, jdate(timestamptz(d)) = d AS roundtrip_ok
FROM (VALUES (jdate '1399-04-25'), (jdate '1398-10-25')) v(d) ORDER BY d;
SELECT count(*) AS instants,
       count(*) FILTER (WHERE jdate(ts) <> (ts::date)::jdate) AS mismatches,
       count(*) FILTER (WHERE jdate(ts) <> ((ts AT TIME ZONE 'Asia/Tehran')::date)::jdate) AS mismatches_at_time_zone
FROM generate_series(timestamptz '2020-01-01 00:00:00+00',
                     timestamptz '2020-12-31 23:00:00+00',
                     interval '1 hour') AS ts;
SELECT jdate_format(timestamptz '2020-07-14 19:45:00+00') AS fmt_summer,
       jdate_format(timestamptz '2020-01-14 20:45:00+00') AS fmt_winter;

-- ---------------------------------------------------------------------
-- Both edges of the Jalali range (-0061-01-01 and 3177-12-29) through
-- timestamptz in the extreme zones. Local midnight comes back as the same
-- day, the last second of the day still belongs to it, and one second
-- before the min edge / 24 hours after the max edge is out of range
-- (SQLSTATE 22008). The checks print booleans and local clock times only.
-- ---------------------------------------------------------------------
\set VERBOSITY sqlstate

SET timezone = 'Pacific/Kiritimati';
SELECT d, timestamptz(d) AT TIME ZONE 'Pacific/Kiritimati' AS local_ts,
       jdate(timestamptz(d)) = d AS roundtrip_ok,
       jdate(timestamptz(d) + interval '23 hours 59 minutes 59 seconds') = d AS last_second_ok,
       jdate_format(timestamptz(d)) AS fmt
FROM (VALUES (jdate '-0061-01-01'), (jdate '3177-12-29')) v(d) ORDER BY d;
SELECT jdate(timestamptz(jdate '-0061-01-01') - interval '1 second') IS NOT NULL AS below_min;
SELECT jdate(timestamptz(jdate '3177-12-29') + interval '24 hours') IS NOT NULL AS above_max;
SELECT jdate(timestamptz(jdate '-0061-01-02') - interval '1 second') AS min_edge_reached;
SELECT jdate(timestamptz(jdate '3177-12-28') + interval '24 hours') AS max_edge_reached;

SET timezone = 'Pacific/Pago_Pago';
SELECT d, timestamptz(d) AT TIME ZONE 'Pacific/Pago_Pago' AS local_ts,
       jdate(timestamptz(d)) = d AS roundtrip_ok,
       jdate(timestamptz(d) + interval '23 hours 59 minutes 59 seconds') = d AS last_second_ok,
       jdate_format(timestamptz(d)) AS fmt
FROM (VALUES (jdate '-0061-01-01'), (jdate '3177-12-29')) v(d) ORDER BY d;
SELECT jdate(timestamptz(jdate '-0061-01-01') - interval '1 second') IS NOT NULL AS below_min;
SELECT jdate(timestamptz(jdate '3177-12-29') + interval '24 hours') IS NOT NULL AS above_max;
SELECT jdate(timestamptz(jdate '-0061-01-02') - interval '1 second') AS min_edge_reached;
SELECT jdate(timestamptz(jdate '3177-12-28') + interval '24 hours') AS max_edge_reached;

\set VERBOSITY default

RESET timezone;
DROP TABLE tz_ins;
DROP TABLE tz_nowruz;
