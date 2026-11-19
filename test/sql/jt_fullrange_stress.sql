-- Stress-only exhaustive sweep of jtimestamptz: every one of the 1,183,020
-- days from -0061-01-01 to 3177-12-29, at its first (00:00:00) and last
-- (23:59:59.999999) microsecond, under UTC and Asia/Tehran (about 40 s).
--
-- NOT part of REGRESS and not a pg_regress file: the normal suite keeps the
-- sampled check in jt_fullrange.sql. This file is run by dev/fullrange-sweep.sh,
-- which the CI stress job calls, in a scratch database with the extension
-- installed. It has no expected file: each zone is one DO block that counts
-- the violations of the same checks jt_fullrange.sql makes (against core's
-- Gregorian, timestamptz and zone code) and raises an error if any is not 0,
-- so psql with ON_ERROR_STOP fails. The last statement is a negative control:
-- the same counting over thinned, shifted data must find violations, so a
-- sweep that cannot fail is noticed (the script treats a silent control as a
-- failure).
--
-- The first day's local midnight and the last day's last microsecond lie
-- outside the safe range of jtimestamptz (see jt_fullrange.sql), so they are
-- skipped here (g > 0 for starts, g < 1183019 for ends). The next-midnight
-- check is made under UTC only: in Tehran a clock time that does not exist on
-- a day the clocks go forward (1977-03-21 23:59:59.999999) moves to the first
-- valid one, as in jt_fullrange.sql.
SET DateStyle = 'ISO, YMD';

CREATE FUNCTION pg_temp.sweep(zone text, shift int) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    n_start bigint; n_end bigint;
    v_start_instant bigint; v_end_instant bigint; v_next_midnight bigint;
    v_local_date bigint; v_start_text bigint; v_end_text bigint;
    v_prefix bigint;
    total bigint;
BEGIN
    PERFORM set_config('timezone', zone, false);
    -- shift moves the expected Gregorian date by that many days; 0 for the
    -- real sweep, 1 for the negative control
    SELECT count(u0), count(u1),
           count(*) FILTER (WHERE u0::timestamptz <> dt::timestamptz),
           count(*) FILTER (WHERE u1::timestamptz <> (dt + time '23:59:59.999999')::timestamptz),
           count(*) FILTER (WHERE zone = 'UTC'
                             AND u1::timestamptz + interval '1 microsecond' <> (dt + 1)::timestamptz),
           count(*) FILTER (WHERE u0::jdate::date <> u0::timestamptz::date
                               OR u1::jdate::date <> u1::timestamptz::date),
           count(*) FILTER (WHERE u0::text <> u0::timestamptz::date::jdate::text || substr(u0::timestamptz::text, 11)),
           count(*) FILTER (WHERE u1::text <> u1::timestamptz::date::jdate::text || substr(u1::timestamptz::text, 11)),
           count(*) FILTER (WHERE u0::text <> t || substr(u0::timestamptz::text, 11))
      INTO n_start, n_end, v_start_instant, v_end_instant, v_next_midnight,
           v_local_date, v_start_text, v_end_text, v_prefix
      FROM (SELECT t, dt,
                   CASE WHEN g > 0 THEN (t || ' 00:00:00')::jtimestamptz END AS u0,
                   CASE WHEN g < 1183019 THEN (t || ' 23:59:59.999999')::jtimestamptz END AS u1
            FROM (SELECT g, d::text AS t, date '0560-03-20' + g + shift AS dt
                  FROM (SELECT g, '-0061-01-01'::jdate + g AS d
                        FROM generate_series(0, 1183019) AS g) AS q) AS s) AS r;
    total := v_start_instant + v_end_instant + v_next_midnight + v_local_date
           + v_start_text + v_end_text + v_prefix;
    RAISE NOTICE 'sweep % shift %: starts % ends % violations % (start_instant %, end_instant %, next_midnight %, local_date %, start_text %, end_text %, date_prefix %)',
        zone, shift, n_start, n_end, total, v_start_instant, v_end_instant,
        v_next_midnight, v_local_date, v_start_text, v_end_text, v_prefix;
    IF n_start <> 1183019 OR n_end <> 1183019 THEN
        RAISE EXCEPTION 'sweep %: expected 1183019 starts and ends, got % and %', zone, n_start, n_end;
    END IF;
    IF shift = 0 AND total <> 0 THEN
        RAISE EXCEPTION 'sweep %: % violations', zone, total;
    END IF;
    IF shift <> 0 AND total = 0 THEN
        RAISE EXCEPTION 'control %: no violations found, the sweep cannot fail', zone;
    END IF;
END $$;

SELECT pg_temp.sweep('UTC', 0);
SELECT pg_temp.sweep('Asia/Tehran', 0);
-- negative control (shift 1: every expected Gregorian date is a day off)
SELECT pg_temp.sweep('UTC', 1);
