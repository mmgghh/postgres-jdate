\echo Use "CREATE EXTENSION jdate" to load this file. \quit

-- ============================================================
-- Type shell + I/O
-- ============================================================

CREATE TYPE jdate;

CREATE FUNCTION jdate_in(cstring) RETURNS jdate
    AS 'MODULE_PATHNAME', 'jdate_in'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION jdate_out(jdate) RETURNS cstring
    AS 'MODULE_PATHNAME', 'jdate_out'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION jdate_recv(internal) RETURNS jdate
    AS 'MODULE_PATHNAME', 'jdate_recv'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION jdate_send(jdate) RETURNS bytea
    AS 'MODULE_PATHNAME', 'jdate_send'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE TYPE jdate (
    INPUT = jdate_in,
    OUTPUT = jdate_out,
    RECEIVE = jdate_recv,
    SEND = jdate_send,
    INTERNALLENGTH = 4,
    PASSEDBYVALUE,
    ALIGNMENT = int4,
    STORAGE = plain,
    CATEGORY = 'D',
    PREFERRED = false
);

COMMENT ON TYPE jdate IS 'Jalali (Persian) calendar date, 4 bytes, binary-compatible with date';

-- ============================================================
-- Casts
-- ============================================================

-- jdate and date share the exact same internal representation (days
-- since 2000-01-01, i.e. the same Julian Day Number minus a fixed
-- offset) -- only their text I/O differs. The cast is therefore a pure
-- reinterpretation: WITHOUT FUNCTION, zero bytes touched.
--
-- ASSIGNMENT (not IMPLICIT): a jdate and a date can represent the same
-- physical day while displaying completely different digits, so silently
-- converting one to the other inside an ordinary comparison would be
-- surprising. An explicit cast, or an assignment context, is required.
CREATE CAST (jdate AS date) WITHOUT FUNCTION AS ASSIGNMENT;
CREATE CAST (date AS jdate) WITHOUT FUNCTION AS ASSIGNMENT;
