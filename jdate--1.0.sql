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

-- ============================================================
-- Comparison operators, btree + hash opclasses
-- ============================================================

CREATE FUNCTION jdate_eq(jdate, jdate) RETURNS bool
    AS 'MODULE_PATHNAME', 'jdate_eq' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_ne(jdate, jdate) RETURNS bool
    AS 'MODULE_PATHNAME', 'jdate_ne' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_lt(jdate, jdate) RETURNS bool
    AS 'MODULE_PATHNAME', 'jdate_lt' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_le(jdate, jdate) RETURNS bool
    AS 'MODULE_PATHNAME', 'jdate_le' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_gt(jdate, jdate) RETURNS bool
    AS 'MODULE_PATHNAME', 'jdate_gt' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_ge(jdate, jdate) RETURNS bool
    AS 'MODULE_PATHNAME', 'jdate_ge' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_cmp(jdate, jdate) RETURNS int4
    AS 'MODULE_PATHNAME', 'jdate_cmp' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_hash(jdate) RETURNS int4
    AS 'MODULE_PATHNAME', 'jdate_hash' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OPERATOR = (
    LEFTARG = jdate, RIGHTARG = jdate, PROCEDURE = jdate_eq,
    COMMUTATOR = =, NEGATOR = <>,
    RESTRICT = eqsel, JOIN = eqjoinsel, HASHES, MERGES
);
CREATE OPERATOR <> (
    LEFTARG = jdate, RIGHTARG = jdate, PROCEDURE = jdate_ne,
    COMMUTATOR = <>, NEGATOR = =,
    RESTRICT = neqsel, JOIN = neqjoinsel
);
CREATE OPERATOR < (
    LEFTARG = jdate, RIGHTARG = jdate, PROCEDURE = jdate_lt,
    COMMUTATOR = >, NEGATOR = >=,
    RESTRICT = scalarltsel, JOIN = scalarltjoinsel
);
CREATE OPERATOR <= (
    LEFTARG = jdate, RIGHTARG = jdate, PROCEDURE = jdate_le,
    COMMUTATOR = >=, NEGATOR = >,
    RESTRICT = scalarlesel, JOIN = scalarlejoinsel
);
CREATE OPERATOR > (
    LEFTARG = jdate, RIGHTARG = jdate, PROCEDURE = jdate_gt,
    COMMUTATOR = <, NEGATOR = <=,
    RESTRICT = scalargtsel, JOIN = scalargtjoinsel
);
CREATE OPERATOR >= (
    LEFTARG = jdate, RIGHTARG = jdate, PROCEDURE = jdate_ge,
    COMMUTATOR = <=, NEGATOR = <,
    RESTRICT = scalargesel, JOIN = scalargejoinsel
);

CREATE OPERATOR CLASS jdate_ops
    DEFAULT FOR TYPE jdate USING btree AS
        OPERATOR 1 <,
        OPERATOR 2 <=,
        OPERATOR 3 =,
        OPERATOR 4 >=,
        OPERATOR 5 >,
        FUNCTION 1 jdate_cmp(jdate, jdate);

CREATE OPERATOR CLASS jdate_hash_ops
    DEFAULT FOR TYPE jdate USING hash AS
        OPERATOR 1 =,
        FUNCTION 1 jdate_hash(jdate);

-- min()/max() are NOT automatically available for a new base type just
-- because it has a btree opclass -- each type needs its own aggregate.
-- Without these, min(jdate)/max(jdate) would resolve (silently, and to
-- the wrong type) through the jdate->timestamptz assignment cast to
-- core's own timestamptz aggregates instead of erroring or working
-- directly on jdate.
CREATE FUNCTION jdate_smaller(jdate, jdate) RETURNS jdate
    AS 'MODULE_PATHNAME', 'jdate_smaller' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_larger(jdate, jdate) RETURNS jdate
    AS 'MODULE_PATHNAME', 'jdate_larger' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE AGGREGATE min(jdate) (
    SFUNC = jdate_smaller, STYPE = jdate, SORTOP = <, PARALLEL = SAFE
);
CREATE AGGREGATE max(jdate) (
    SFUNC = jdate_larger, STYPE = jdate, SORTOP = >, PARALLEL = SAFE
);
