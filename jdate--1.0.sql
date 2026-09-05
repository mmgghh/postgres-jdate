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

-- ============================================================
-- Arithmetic
-- ============================================================

CREATE FUNCTION jdate_pli(jdate, int4) RETURNS jdate
    AS 'MODULE_PATHNAME', 'jdate_pli' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_mii(jdate, int4) RETURNS jdate
    AS 'MODULE_PATHNAME', 'jdate_mii' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_mi(jdate, jdate) RETURNS int4
    AS 'MODULE_PATHNAME', 'jdate_mi' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OPERATOR + (
    LEFTARG = jdate, RIGHTARG = int4, PROCEDURE = jdate_pli,
    COMMUTATOR = +
);
CREATE OPERATOR - (
    LEFTARG = jdate, RIGHTARG = int4, PROCEDURE = jdate_mii
);
CREATE OPERATOR - (
    LEFTARG = jdate, RIGHTARG = jdate, PROCEDURE = jdate_mi
);

-- ============================================================
-- Casts to/from timestamp and timestamptz
-- ============================================================

-- ASSIGNMENT, not IMPLICIT: an implicit jdate->timestamptz cast let the
-- planner silently satisfy min(jdate)/max(jdate) via core's timestamptz
-- aggregate (through the cast) instead of using jdate's own min/max
-- above -- surfaced by testing, not by inspection. Keeping these
-- assignment-only (like jdate<->date) avoids that whole class of silent
-- cross-type resolution.
CREATE FUNCTION "timestamp"(jdate) RETURNS timestamp
    AS 'MODULE_PATHNAME', 'jdate_timestamp'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE CAST (jdate AS timestamp) WITH FUNCTION "timestamp"(jdate) AS ASSIGNMENT;

CREATE FUNCTION "timestamptz"(jdate) RETURNS timestamptz
    AS 'MODULE_PATHNAME', 'jdate_timestamptz'
    LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE CAST (jdate AS timestamptz) WITH FUNCTION "timestamptz"(jdate) AS ASSIGNMENT;

CREATE FUNCTION jdate(timestamp) RETURNS jdate
    AS 'MODULE_PATHNAME', 'timestamp_jdate'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE CAST (timestamp AS jdate) WITH FUNCTION jdate(timestamp) AS ASSIGNMENT;

CREATE FUNCTION jdate(timestamptz) RETURNS jdate
    AS 'MODULE_PATHNAME', 'timestamptz_jdate'
    LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE CAST (timestamptz AS jdate) WITH FUNCTION jdate(timestamptz) AS ASSIGNMENT;

-- ============================================================
-- Field access: jdate_part / extract() / jdate_trunc
-- ============================================================

CREATE FUNCTION jdate_part(text, jdate) RETURNS float8
    AS 'MODULE_PATHNAME', 'jdate_part' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- EXTRACT(field FROM source) desugars to a *schema-qualified* call to
-- pg_catalog.extract(text, sourcetype) -- confirmed by testing: an
-- unqualified extract(text, jdate) in this extension's own schema is
-- never considered, regardless of search_path. It must be registered
-- directly in pg_catalog to participate in EXTRACT(... FROM jdate_val)
-- syntax. This requires the extension to be installed by a superuser
-- (or a role with equivalent privileges) -- already true for any
-- C-language extension, since placing its files requires that access.
CREATE FUNCTION pg_catalog.extract(text, jdate) RETURNS numeric
    AS 'MODULE_PATHNAME', 'jdate_extract' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION jdate_trunc(text, jdate) RETURNS jdate
    AS 'MODULE_PATHNAME', 'jdate_trunc' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- ============================================================
-- Timestamptz formatting bridge (until a native jtimestamptz type ships)
-- ============================================================

CREATE FUNCTION jdate_format(timestamptz, with_time boolean DEFAULT true) RETURNS text
    AS 'MODULE_PATHNAME', 'jdate_format_timestamptz' LANGUAGE C STABLE STRICT PARALLEL SAFE;
