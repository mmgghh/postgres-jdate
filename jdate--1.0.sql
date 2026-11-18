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
-- offset) -- only their text I/O differs. jdate -> date therefore needs no
-- conversion and is always valid: WITHOUT FUNCTION, zero bytes touched.
--
-- date -> jdate is NOT free: date covers far more days (4714 BC to
-- 5874897 AD) than the Jalali algorithm (-0061-01-01 .. 3177-12-29), and a
-- stored out-of-range value could never be displayed again. It goes
-- through jdate(date), which raises SQLSTATE 22008 outside the range.
--
-- ASSIGNMENT (not IMPLICIT): a jdate and a date can represent the same
-- physical day while displaying completely different digits, so silently
-- converting one to the other inside an ordinary comparison would be
-- surprising. An explicit cast, or an assignment context, is required.
CREATE CAST (jdate AS date) WITHOUT FUNCTION AS ASSIGNMENT;

CREATE FUNCTION jdate(date) RETURNS jdate
    AS 'MODULE_PATHNAME', 'date_jdate'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE CAST (date AS jdate) WITH FUNCTION jdate(date) AS ASSIGNMENT;

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
CREATE FUNCTION jdate_hash_extended(jdate, int8) RETURNS int8
    AS 'MODULE_PATHNAME', 'jdate_hash_extended' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

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

-- One btree operator family for jdate, jtimestamp and jtimestamptz, as core's
-- datetime_ops covers date, timestamp and timestamptz. The classes of the two
-- timestamp types join it further down, in the operators section for those
-- types, and so does skip support (function 6, PostgreSQL 18 only).
CREATE OPERATOR FAMILY jdatetime_ops USING btree;

CREATE OPERATOR CLASS jdate_ops
    DEFAULT FOR TYPE jdate USING btree FAMILY jdatetime_ops AS
        OPERATOR 1 <,
        OPERATOR 2 <=,
        OPERATOR 3 =,
        OPERATOR 4 >=,
        OPERATOR 5 >,
        FUNCTION 1 jdate_cmp(jdate, jdate),
        -- jdate is an int32 day count, binary compatible with core's date,
        -- so core's date sort support and btequalimage apply unchanged.
        -- Skip support (function 6) exists only on PG 18; it is added to the
        -- family by the DO block at the end of the jtimestamp operators.
        FUNCTION 2 date_sortsupport(internal),
        FUNCTION 4 btequalimage(oid);

CREATE OPERATOR CLASS jdate_hash_ops
    DEFAULT FOR TYPE jdate USING hash AS
        OPERATOR 1 =,
        FUNCTION 1 jdate_hash(jdate),
        FUNCTION 2 jdate_hash_extended(jdate, int8);

-- min()/max() are NOT automatically available for a new base type just
-- because it has a btree opclass -- each type needs its own aggregate.
-- Without these, min(jdate)/max(jdate) would resolve (silently, and to
-- the wrong type) through the jdate->timestamptz assignment cast to
-- core's own timestamptz aggregates instead of erroring or working
-- directly on jdate.
-- COMBINEFUNC is the same function as the transition function (as in core's
-- date min/max): both merge two partial states by taking the smaller/larger,
-- and both are STRICT, so a NULL partial state is skipped. This is what lets
-- the planner use Partial Aggregate / Finalize Aggregate under a Gather.
CREATE FUNCTION jdate_smaller(jdate, jdate) RETURNS jdate
    AS 'MODULE_PATHNAME', 'jdate_smaller' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_larger(jdate, jdate) RETURNS jdate
    AS 'MODULE_PATHNAME', 'jdate_larger' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE AGGREGATE min(jdate) (
    SFUNC = jdate_smaller, STYPE = jdate, COMBINEFUNC = jdate_smaller,
    SORTOP = <, PARALLEL = SAFE
);
CREATE AGGREGATE max(jdate) (
    SFUNC = jdate_larger, STYPE = jdate, COMBINEFUNC = jdate_larger,
    SORTOP = >, PARALLEL = SAFE
);

-- ============================================================
-- Arithmetic
-- ============================================================

CREATE FUNCTION jdate_pli(jdate, int4) RETURNS jdate
    AS 'MODULE_PATHNAME', 'jdate_pli' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION integer_pl_jdate(int4, jdate) RETURNS jdate
    AS 'MODULE_PATHNAME', 'integer_pl_jdate' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_mii(jdate, int4) RETURNS jdate
    AS 'MODULE_PATHNAME', 'jdate_mii' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_mi(jdate, jdate) RETURNS int4
    AS 'MODULE_PATHNAME', 'jdate_mi' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OPERATOR + (
    LEFTARG = jdate, RIGHTARG = int4, PROCEDURE = jdate_pli,
    COMMUTATOR = +
);
-- Completes the shell operator that COMMUTATOR = + above creates: without
-- this, 5 + some_jdate fails with "operator is only a shell".
CREATE OPERATOR + (
    LEFTARG = int4, RIGHTARG = jdate, PROCEDURE = integer_pl_jdate,
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
-- Unix epoch conversion
-- ============================================================

-- Epoch extraction needs no new function: it's calendar-agnostic (a Unix
-- timestamp counts seconds since 1970-01-01 UTC regardless of which
-- calendar the date is displayed in), so it's just another case in the
-- jdate_part/EXTRACT machinery below -- see jdate_get_field's DTK_EPOCH
-- case in jdate.c.
--   SELECT EXTRACT(epoch FROM some_jdate);
--   SELECT jdate_part('epoch', some_jdate);

-- to_jdate(double precision): the inverse, mirroring core's own
-- to_timestamp(double precision). Plain function, not a cast: like
-- to_timestamp(), this is never applied implicitly or on assignment.
-- It returns the Jalali date of the UTC day containing the Unix timestamp
-- (infinity for +/-Infinity; SQLSTATE 22008 for NaN or an epoch outside the
-- supported range). It is pure arithmetic on the epoch: the session
-- TimeZone is irrelevant, so it is IMMUTABLE and can be indexed.
CREATE FUNCTION to_jdate(double precision) RETURNS jdate
    AS 'MODULE_PATHNAME', 'jdate_from_epoch'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- to_jdate(double precision, text): the same, but the day is the calendar day
-- in the named time zone (core's timezone(text, timestamptz) conversion, so
-- zone names, abbreviations and the unknown-zone error are core's own). The
-- epoch is validated like the one-argument version; the local day is
-- range-checked too (SQLSTATE 22008). Volatility is copied from core's
-- timezone(text, timestamptz), which is IMMUTABLE PARALLEL SAFE: the session
-- TimeZone is not consulted, so it can be indexed.
CREATE FUNCTION to_jdate(double precision, text) RETURNS jdate
    AS 'MODULE_PATHNAME', 'jdate_from_epoch_zone'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- ============================================================
-- Field access: jdate_part / extract() / jdate_trunc
-- ============================================================

-- jdate_part returns bigint: every field of a finite date is an exact integer
-- (epoch included), and every unit is NULL for infinity. EXTRACT below stays
-- numeric and keeps +/-Infinity for the units that only grow.
CREATE FUNCTION jdate_part(text, jdate) RETURNS bigint
    AS 'MODULE_PATHNAME', 'jdate_part' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- EXTRACT(field FROM source) desugars to a *schema-qualified* call to
-- pg_catalog.extract(text, sourcetype) -- confirmed by testing: an
-- unqualified extract(text, jdate) in this extension's own schema is
-- never considered, regardless of search_path. It must be registered
-- directly in pg_catalog to participate in EXTRACT(... FROM jdate_val)
-- syntax. This requires the extension to be installed by a superuser
-- (or a role with equivalent privileges) -- already true for any
-- C-language extension, since placing its files requires that access.
--
-- Because this one function lives outside the extension's schema, the
-- extension cannot be relocatable: ALTER EXTENSION jdate SET SCHEMA would
-- be refused by the server (the function is not in the extension's
-- schema), so jdate.control sets relocatable = false. The schema is
-- chosen at install time instead: CREATE EXTENSION jdate SCHEMA s.
-- Every other object follows that schema; only extract() stays in
-- pg_catalog, and EXTRACT(... FROM x) works whether or not s is on the
-- search_path.
CREATE FUNCTION pg_catalog.extract(text, jdate) RETURNS numeric
    AS 'MODULE_PATHNAME', 'jdate_extract' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION jdate_trunc(text, jdate) RETURNS jdate
    AS 'MODULE_PATHNAME', 'jdate_trunc' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- ============================================================
-- Timestamptz formatting bridge (until a native jtimestamptz type ships)
-- ============================================================

CREATE FUNCTION jdate_format(timestamptz, with_time boolean DEFAULT true) RETURNS text
    AS 'MODULE_PATHNAME', 'jdate_format_timestamptz' LANGUAGE C STABLE STRICT PARALLEL SAFE;

-- ============================================================
-- jtimestamp: timestamp without time zone, Jalali text I/O
-- ============================================================
--
-- jtimestamp has exactly the representation of core's timestamp (int64
-- microseconds since 2000-01-01 00:00:00, infinities at the int64 extremes);
-- only the text differs. Input is a Jalali date followed by whatever core's
-- timestamp parser takes ('1403-01-01 12:30:45.5', '1403-01-01T12:30', ...), or
-- one of the special words infinity, -infinity, now, today, tomorrow, yesterday,
-- epoch. Output is always ISO with a Jalali date; DateStyle is ignored.
-- The valid range is -0061-01-01 00:00:00 up to 3177-12-29 23:59:59.999999, and
-- both infinities.

CREATE TYPE jtimestamp;

-- STABLE, not IMMUTABLE as jdate_in is: 'now', 'today', 'tomorrow' and
-- 'yesterday' depend on the clock and the session time zone. Declared IMMUTABLE,
-- a text-to-jtimestamp cast could be used in an index expression.
CREATE FUNCTION jtimestamp_in(cstring, oid, integer) RETURNS jtimestamp
    AS 'MODULE_PATHNAME', 'jtimestamp_in'
    LANGUAGE C STABLE STRICT PARALLEL SAFE;

CREATE FUNCTION jtimestamp_out(jtimestamp) RETURNS cstring
    AS 'MODULE_PATHNAME', 'jtimestamp_out'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION jtimestamp_recv(internal, oid, integer) RETURNS jtimestamp
    AS 'MODULE_PATHNAME', 'jtimestamp_recv'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION jtimestamp_send(jtimestamp) RETURNS bytea
    AS 'MODULE_PATHNAME', 'jtimestamp_send'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- Core's timestamptypmodin is the type modifier input (jtimestamp(p), p 0..6).
-- Core's timestamptypmodout would print "(p) without time zone", so it has its
-- own output function that prints "(p)".
CREATE FUNCTION jtimestamp_typmodout(integer) RETURNS cstring
    AS 'MODULE_PATHNAME', 'jtimestamp_typmodout'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE TYPE jtimestamp (
    INPUT = jtimestamp_in,
    OUTPUT = jtimestamp_out,
    RECEIVE = jtimestamp_recv,
    SEND = jtimestamp_send,
    TYPMOD_IN = timestamptypmodin,
    TYPMOD_OUT = jtimestamp_typmodout,
    INTERNALLENGTH = 8,
    PASSEDBYVALUE,
    ALIGNMENT = double,
    STORAGE = plain,
    CATEGORY = 'D',
    PREFERRED = false
);

COMMENT ON TYPE jtimestamp IS 'Jalali (Persian) timestamp without time zone, 8 bytes, binary-compatible with timestamp';

-- ============================================================
-- jtimestamptz: timestamp with time zone, Jalali text I/O
-- ============================================================
--
-- jtimestamptz has exactly the representation of core's timestamptz (int64
-- microseconds since 2000-01-01 00:00:00 UTC, infinities at the int64
-- extremes); only the text differs. Input is a Jalali date followed by
-- whatever core's timestamptz parser takes ('1403-01-01 12:30+03:30',
-- '1403-01-01T12:30Z', '1403-01-01 12:30 Asia/Tehran', ...; no zone means the
-- session TimeZone), or one of the special words infinity, -infinity, now,
-- today, tomorrow, yesterday, epoch. Output is the instant in the session
-- time zone as ISO text with a Jalali date and a numeric offset (+HH, +HH:MM
-- or +HH:MM:SS); DateStyle is ignored.
--
-- The valid range is the Jalali range shrunk by 16 hours at both ends:
-- instants from -0061-01-01 00:00:00 UTC + 16h up to, not including, the start
-- of 3178-01-01 UTC - 16h, and both infinities. Zone offsets reach
-- +/-15:59:59, so every stored instant shows a Jalali day in every time
-- zone, and the check needs no zone.

CREATE TYPE jtimestamptz;

-- STABLE, like core's timestamptz_in and for the same reasons as jtimestamp_in:
-- the special words, and the session TimeZone when the text has no zone.
CREATE FUNCTION jtimestamptz_in(cstring, oid, integer) RETURNS jtimestamptz
    AS 'MODULE_PATHNAME', 'jtimestamptz_in'
    LANGUAGE C STABLE STRICT PARALLEL SAFE;

-- STABLE: the text depends on the session TimeZone (as core's timestamptz_out),
-- which also makes jtimestamptz::text STABLE.
CREATE FUNCTION jtimestamptz_out(jtimestamptz) RETURNS cstring
    AS 'MODULE_PATHNAME', 'jtimestamptz_out'
    LANGUAGE C STABLE STRICT PARALLEL SAFE;

CREATE FUNCTION jtimestamptz_recv(internal, oid, integer) RETURNS jtimestamptz
    AS 'MODULE_PATHNAME', 'jtimestamptz_recv'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION jtimestamptz_send(jtimestamptz) RETURNS bytea
    AS 'MODULE_PATHNAME', 'jtimestamptz_send'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- Core's timestamptztypmodin is the type modifier input (jtimestamptz(p), p
-- 0..6). The type modifier prints as "(p)": the same C function as
-- jtimestamp_typmodout, under its own SQL name.
CREATE FUNCTION jtimestamptz_typmodout(integer) RETURNS cstring
    AS 'MODULE_PATHNAME', 'jtimestamp_typmodout'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE TYPE jtimestamptz (
    INPUT = jtimestamptz_in,
    OUTPUT = jtimestamptz_out,
    RECEIVE = jtimestamptz_recv,
    SEND = jtimestamptz_send,
    TYPMOD_IN = timestamptztypmodin,
    TYPMOD_OUT = jtimestamptz_typmodout,
    INTERNALLENGTH = 8,
    PASSEDBYVALUE,
    ALIGNMENT = double,
    STORAGE = plain,
    CATEGORY = 'D',
    PREFERRED = false
);

COMMENT ON TYPE jtimestamptz IS 'Jalali (Persian) timestamp with time zone, 8 bytes, binary-compatible with timestamptz';

-- to_jtimestamptz(double precision): the instant of a Unix timestamp, like core's
-- to_timestamp(double precision) but of this type, and like to_jdate it is pure
-- arithmetic on the epoch: the session TimeZone is irrelevant, so it is
-- IMMUTABLE. +/-Infinity give the infinities; NaN, an epoch outside the days of
-- the Jalali range and an instant outside the safe range are SQLSTATE 22008.
CREATE FUNCTION to_jtimestamptz(double precision) RETURNS jtimestamptz
    AS 'MODULE_PATHNAME', 'jtimestamptz_from_epoch'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- ============================================================
-- Casts for jtimestamp and jtimestamptz
-- ============================================================
--
-- As for jdate, no cast is IMPLICIT, apart from the typmod (scale) casts at
-- the end, which only round: `jtimestamp = timestamp` stays an error instead
-- of silently comparing two calendars' digits. Everything is ASSIGNMENT, so
-- INSERT and UPDATE convert, and an explicit cast always works.
--
-- Out of a Jalali type into the core type of the same kind: binary (WITHOUT
-- FUNCTION), a valid value is always a valid core value.
CREATE CAST (jtimestamp AS timestamp) WITHOUT FUNCTION AS ASSIGNMENT;
CREATE CAST (jtimestamptz AS timestamptz) WITHOUT FUNCTION AS ASSIGNMENT;

-- Into a Jalali type from the core type: the same bits, but only inside the
-- Jalali range (jtimestamptz: the safe range), SQLSTATE 22008 outside it.
-- IMMUTABLE for both: the checks need no time zone.
CREATE FUNCTION jtimestamp(timestamp) RETURNS jtimestamp
    AS 'MODULE_PATHNAME', 'timestamp_jtimestamp'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE CAST (timestamp AS jtimestamp) WITH FUNCTION jtimestamp(timestamp) AS ASSIGNMENT;

CREATE FUNCTION jtimestamptz(timestamptz) RETURNS jtimestamptz
    AS 'MODULE_PATHNAME', 'timestamptz_jtimestamptz'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE CAST (timestamptz AS jtimestamptz) WITH FUNCTION jtimestamptz(timestamptz) AS ASSIGNMENT;

-- Between the two Jalali types: core's conversions through the session time
-- zone (so STABLE), then the range check of the result. A jtimestamp that is
-- valid can still be an instant outside the safe range, and the other
-- direction cannot fail but is checked all the same.
CREATE FUNCTION jtimestamptz(jtimestamp) RETURNS jtimestamptz
    AS 'MODULE_PATHNAME', 'jtimestamp_jtimestamptz'
    LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE CAST (jtimestamp AS jtimestamptz) WITH FUNCTION jtimestamptz(jtimestamp) AS ASSIGNMENT;

CREATE FUNCTION jtimestamp(jtimestamptz) RETURNS jtimestamp
    AS 'MODULE_PATHNAME', 'jtimestamptz_jtimestamp'
    LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE CAST (jtimestamptz AS jtimestamp) WITH FUNCTION jtimestamp(jtimestamptz) AS ASSIGNMENT;

-- From date: midnight of the day, range-checked. For jtimestamptz it is local
-- midnight in the session zone (STABLE, as core's date -> timestamptz), which
-- the check can refuse even for a day inside the Jalali range.
CREATE FUNCTION jtimestamp(date) RETURNS jtimestamp
    AS 'MODULE_PATHNAME', 'date_jtimestamp'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE CAST (date AS jtimestamp) WITH FUNCTION jtimestamp(date) AS ASSIGNMENT;

CREATE FUNCTION jtimestamptz(date) RETURNS jtimestamptz
    AS 'MODULE_PATHNAME', 'date_jtimestamptz'
    LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE CAST (date AS jtimestamptz) WITH FUNCTION jtimestamptz(date) AS ASSIGNMENT;

-- From jdate: the same, but a jdate is always inside the range, so only the
-- zone-dependent jtimestamptz one has a check.
CREATE FUNCTION jtimestamp(jdate) RETURNS jtimestamp
    AS 'MODULE_PATHNAME', 'jdate_jtimestamp'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE CAST (jdate AS jtimestamp) WITH FUNCTION jtimestamp(jdate) AS ASSIGNMENT;

CREATE FUNCTION jtimestamptz(jdate) RETURNS jtimestamptz
    AS 'MODULE_PATHNAME', 'jdate_jtimestamptz'
    LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE CAST (jdate AS jtimestamptz) WITH FUNCTION jtimestamptz(jdate) AS ASSIGNMENT;

-- To jdate: the calendar day (for jtimestamptz in the session zone, STABLE).
-- A valid value always lies on a Jalali day, so there is no check.
CREATE FUNCTION jdate(jtimestamp) RETURNS jdate
    AS 'MODULE_PATHNAME', 'jtimestamp_jdate'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE CAST (jtimestamp AS jdate) WITH FUNCTION jdate(jtimestamp) AS ASSIGNMENT;

CREATE FUNCTION jdate(jtimestamptz) RETURNS jdate
    AS 'MODULE_PATHNAME', 'jtimestamptz_jdate'
    LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE CAST (jtimestamptz AS jdate) WITH FUNCTION jdate(jtimestamptz) AS ASSIGNMENT;

-- Typmod coercion, jtimestamp(p) and jtimestamptz(p): core's scale functions
-- round to p fractional digits, then the range is checked again, because
-- rounding up the last microseconds of the range leaves it. IMPLICIT like core's
-- own (it only changes the precision of the same type), which is also what
-- makes a literal or an INSERT apply the column's typmod.
CREATE FUNCTION jtimestamp(jtimestamp, integer, boolean) RETURNS jtimestamp
    AS 'MODULE_PATHNAME', 'jtimestamp_scale'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE CAST (jtimestamp AS jtimestamp) WITH FUNCTION jtimestamp(jtimestamp, integer, boolean) AS IMPLICIT;

CREATE FUNCTION jtimestamptz(jtimestamptz, integer, boolean) RETURNS jtimestamptz
    AS 'MODULE_PATHNAME', 'jtimestamptz_scale'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE CAST (jtimestamptz AS jtimestamptz) WITH FUNCTION jtimestamptz(jtimestamptz, integer, boolean) AS IMPLICIT;

-- ============================================================
-- Comparison operators, btree and hash opclasses for jtimestamp and jtimestamptz
-- ============================================================
--
-- Same-type comparison only (the cross-type matrix is at the end of this file).
-- Every function delegates to core's timestamp_eq, timestamp_lt, ... and
-- timestamp_cmp, which work on the shared int64 representation (core's
-- timestamptz comparison functions are those same functions). All are
-- IMMUTABLE, also for jtimestamptz: an instant compares the same in every time
-- zone. The estimators are those of jdate and of core's timestamp operators.
--
-- Both btree classes join the family jdatetime_ops that jdate_ops is in, as
-- core's date, timestamp and timestamptz classes share datetime_ops, so the
-- cross-type operators added later can sit in the same family. Core's sort
-- support (function 2) and btequalimage (function 4, btree deduplication)
-- apply unchanged, as they do for jdate_ops.
--
-- The hash opclasses are here and not with the aggregates because `=` is
-- marked HASHES: without a hash opclass for the type, the planner fails with
-- "could not find hash function" as soon as it considers a hash join.

-- jtimestamp

CREATE FUNCTION jtimestamp_eq(jtimestamp, jtimestamp) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamp_eq' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamp_ne(jtimestamp, jtimestamp) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamp_ne' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamp_lt(jtimestamp, jtimestamp) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamp_lt' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamp_le(jtimestamp, jtimestamp) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamp_le' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamp_gt(jtimestamp, jtimestamp) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamp_gt' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamp_ge(jtimestamp, jtimestamp) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamp_ge' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamp_cmp(jtimestamp, jtimestamp) RETURNS int4
    AS 'MODULE_PATHNAME', 'jtimestamp_cmp' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamp_hash(jtimestamp) RETURNS int4
    AS 'MODULE_PATHNAME', 'jtimestamp_hash' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamp_hash_extended(jtimestamp, int8) RETURNS int8
    AS 'MODULE_PATHNAME', 'jtimestamp_hash_extended' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OPERATOR = (
    LEFTARG = jtimestamp, RIGHTARG = jtimestamp, PROCEDURE = jtimestamp_eq,
    COMMUTATOR = =, NEGATOR = <>,
    RESTRICT = eqsel, JOIN = eqjoinsel, HASHES, MERGES
);
CREATE OPERATOR <> (
    LEFTARG = jtimestamp, RIGHTARG = jtimestamp, PROCEDURE = jtimestamp_ne,
    COMMUTATOR = <>, NEGATOR = =,
    RESTRICT = neqsel, JOIN = neqjoinsel
);
CREATE OPERATOR < (
    LEFTARG = jtimestamp, RIGHTARG = jtimestamp, PROCEDURE = jtimestamp_lt,
    COMMUTATOR = >, NEGATOR = >=,
    RESTRICT = scalarltsel, JOIN = scalarltjoinsel
);
CREATE OPERATOR <= (
    LEFTARG = jtimestamp, RIGHTARG = jtimestamp, PROCEDURE = jtimestamp_le,
    COMMUTATOR = >=, NEGATOR = >,
    RESTRICT = scalarlesel, JOIN = scalarlejoinsel
);
CREATE OPERATOR > (
    LEFTARG = jtimestamp, RIGHTARG = jtimestamp, PROCEDURE = jtimestamp_gt,
    COMMUTATOR = <, NEGATOR = <=,
    RESTRICT = scalargtsel, JOIN = scalargtjoinsel
);
CREATE OPERATOR >= (
    LEFTARG = jtimestamp, RIGHTARG = jtimestamp, PROCEDURE = jtimestamp_ge,
    COMMUTATOR = <=, NEGATOR = <,
    RESTRICT = scalargesel, JOIN = scalargejoinsel
);

CREATE OPERATOR CLASS jtimestamp_ops
    DEFAULT FOR TYPE jtimestamp USING btree FAMILY jdatetime_ops AS
        OPERATOR 1 <,
        OPERATOR 2 <=,
        OPERATOR 3 =,
        OPERATOR 4 >=,
        OPERATOR 5 >,
        FUNCTION 1 jtimestamp_cmp(jtimestamp, jtimestamp),
        FUNCTION 2 timestamp_sortsupport(internal),
        FUNCTION 4 btequalimage(oid);

CREATE OPERATOR CLASS jtimestamp_hash_ops
    DEFAULT FOR TYPE jtimestamp USING hash AS
        OPERATOR 1 =,
        FUNCTION 1 jtimestamp_hash(jtimestamp),
        FUNCTION 2 jtimestamp_hash_extended(jtimestamp, int8);

-- jtimestamptz

CREATE FUNCTION jtimestamptz_eq(jtimestamptz, jtimestamptz) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamptz_eq' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamptz_ne(jtimestamptz, jtimestamptz) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamptz_ne' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamptz_lt(jtimestamptz, jtimestamptz) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamptz_lt' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamptz_le(jtimestamptz, jtimestamptz) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamptz_le' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamptz_gt(jtimestamptz, jtimestamptz) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamptz_gt' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamptz_ge(jtimestamptz, jtimestamptz) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamptz_ge' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamptz_cmp(jtimestamptz, jtimestamptz) RETURNS int4
    AS 'MODULE_PATHNAME', 'jtimestamptz_cmp' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamptz_hash(jtimestamptz) RETURNS int4
    AS 'MODULE_PATHNAME', 'jtimestamptz_hash' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamptz_hash_extended(jtimestamptz, int8) RETURNS int8
    AS 'MODULE_PATHNAME', 'jtimestamptz_hash_extended' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OPERATOR = (
    LEFTARG = jtimestamptz, RIGHTARG = jtimestamptz, PROCEDURE = jtimestamptz_eq,
    COMMUTATOR = =, NEGATOR = <>,
    RESTRICT = eqsel, JOIN = eqjoinsel, HASHES, MERGES
);
CREATE OPERATOR <> (
    LEFTARG = jtimestamptz, RIGHTARG = jtimestamptz, PROCEDURE = jtimestamptz_ne,
    COMMUTATOR = <>, NEGATOR = =,
    RESTRICT = neqsel, JOIN = neqjoinsel
);
CREATE OPERATOR < (
    LEFTARG = jtimestamptz, RIGHTARG = jtimestamptz, PROCEDURE = jtimestamptz_lt,
    COMMUTATOR = >, NEGATOR = >=,
    RESTRICT = scalarltsel, JOIN = scalarltjoinsel
);
CREATE OPERATOR <= (
    LEFTARG = jtimestamptz, RIGHTARG = jtimestamptz, PROCEDURE = jtimestamptz_le,
    COMMUTATOR = >=, NEGATOR = >,
    RESTRICT = scalarlesel, JOIN = scalarlejoinsel
);
CREATE OPERATOR > (
    LEFTARG = jtimestamptz, RIGHTARG = jtimestamptz, PROCEDURE = jtimestamptz_gt,
    COMMUTATOR = <, NEGATOR = <=,
    RESTRICT = scalargtsel, JOIN = scalargtjoinsel
);
CREATE OPERATOR >= (
    LEFTARG = jtimestamptz, RIGHTARG = jtimestamptz, PROCEDURE = jtimestamptz_ge,
    COMMUTATOR = <=, NEGATOR = <,
    RESTRICT = scalargesel, JOIN = scalargejoinsel
);

CREATE OPERATOR CLASS jtimestamptz_ops
    DEFAULT FOR TYPE jtimestamptz USING btree FAMILY jdatetime_ops AS
        OPERATOR 1 <,
        OPERATOR 2 <=,
        OPERATOR 3 =,
        OPERATOR 4 >=,
        OPERATOR 5 >,
        FUNCTION 1 jtimestamptz_cmp(jtimestamptz, jtimestamptz),
        FUNCTION 2 timestamp_sortsupport(internal),
        FUNCTION 4 btequalimage(oid);

CREATE OPERATOR CLASS jtimestamptz_hash_ops
    DEFAULT FOR TYPE jtimestamptz USING hash AS
        OPERATOR 1 =,
        FUNCTION 1 jtimestamptz_hash(jtimestamptz),
        FUNCTION 2 jtimestamptz_hash_extended(jtimestamptz, int8);

-- Skip support (function 6, the btree skip scan of PostgreSQL 18) goes with the
-- same-type entries of all three types. Support number 6 does not exist before
-- PostgreSQL 18 and the server would refuse the statement, so it runs through
-- EXECUTE only when the server is 18 or later; no C code refers to it.
DO $do$
BEGIN
    IF current_setting('server_version_num')::int >= 180000 THEN
        EXECUTE 'ALTER OPERATOR FAMILY jdatetime_ops USING btree ADD
            FUNCTION 6 (jdate, jdate) date_skipsupport(internal),
            FUNCTION 6 (jtimestamp, jtimestamp) timestamp_skipsupport(internal),
            FUNCTION 6 (jtimestamptz, jtimestamptz) timestamp_skipsupport(internal)';
    END IF;
END
$do$;

-- ============================================================
-- min() and max() for jtimestamp and jtimestamptz
-- ============================================================
--
-- As for jdate above: a btree opclass does not give a new type its own
-- min()/max(), so each type needs its aggregates. Both aggregates take the
-- transition function as COMBINEFUNC (core does the same for timestamp), so
-- the planner may run them as Partial/Finalize Aggregate under a Gather; the
-- functions are STRICT, so a NULL partial state is skipped. The functions
-- delegate to core's timestamp_smaller / timestamp_larger (core's timestamptz
-- ones are the same functions). They return one of their arguments, so no
-- range check is needed. SORTOP lets the planner answer min()/max() with an
-- index scan on a btree index of the column.
CREATE FUNCTION jtimestamp_smaller(jtimestamp, jtimestamp) RETURNS jtimestamp
    AS 'MODULE_PATHNAME', 'jtimestamp_smaller' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamp_larger(jtimestamp, jtimestamp) RETURNS jtimestamp
    AS 'MODULE_PATHNAME', 'jtimestamp_larger' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamptz_smaller(jtimestamptz, jtimestamptz) RETURNS jtimestamptz
    AS 'MODULE_PATHNAME', 'jtimestamptz_smaller' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamptz_larger(jtimestamptz, jtimestamptz) RETURNS jtimestamptz
    AS 'MODULE_PATHNAME', 'jtimestamptz_larger' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE AGGREGATE min(jtimestamp) (
    SFUNC = jtimestamp_smaller, STYPE = jtimestamp, COMBINEFUNC = jtimestamp_smaller,
    SORTOP = <, PARALLEL = SAFE
);
CREATE AGGREGATE max(jtimestamp) (
    SFUNC = jtimestamp_larger, STYPE = jtimestamp, COMBINEFUNC = jtimestamp_larger,
    SORTOP = >, PARALLEL = SAFE
);
CREATE AGGREGATE min(jtimestamptz) (
    SFUNC = jtimestamptz_smaller, STYPE = jtimestamptz, COMBINEFUNC = jtimestamptz_smaller,
    SORTOP = <, PARALLEL = SAFE
);
CREATE AGGREGATE max(jtimestamptz) (
    SFUNC = jtimestamptz_larger, STYPE = jtimestamptz, COMBINEFUNC = jtimestamptz_larger,
    SORTOP = >, PARALLEL = SAFE
);

-- ============================================================
-- Cross-type comparison: jdate, jtimestamp and jtimestamptz against each other
-- ============================================================
--
-- The three types compare with each other in both argument orders: 6 ordered
-- pairs, each with the six operators and one cmp function: 36 operators, backed
-- by 36 operator functions and 6 cmp functions. The functions are C wrappers (src/jtimestamp_ops.c) over
-- core's date_eq_timestamp, timestamp_eq_timestamptz, date_eq_timestamptz ...
-- family, which compare the mirrored core types; jdate is binary compatible
-- with date and the timestamp types with timestamp and timestamptz.
--
-- Volatility follows core's: a pair that involves jtimestamptz and a type
-- without a zone (jdate, jtimestamp) is STABLE, because the other value is
-- placed on the time line in the session zone; the jdate / jtimestamp pairs
-- are IMMUTABLE. `=` is MERGES but not HASHES: core has no cross-type hash
-- either, so a join of two of these types is a merge join or a nested loop.
-- `<>` stays outside the btree family, as for the same-type operators.
--
-- Every operator is added to the family jdatetime_ops (strategies 1 to 5), with
-- only support function 1 (the cmp function) on the cross-type entries, as core
-- does in datetime_ops. That gives the family 45 operators (3 same-type and 6
-- cross-type entries of 5 each) and 9 `<>` operators outside it, and lets the
-- planner use an index on one of the types for a predicate on another and
-- merge-join across them. No operator against a core type and no implicit
-- cast is added: `jdate = date` stays an error, and a bare literal still
-- resolves to the same-type operator.

-- jdate against jtimestamp (IMMUTABLE: no time zone is read)

CREATE FUNCTION jdate_eq_jtimestamp(jdate, jtimestamp) RETURNS bool
    AS 'MODULE_PATHNAME', 'jdate_eq_jtimestamp' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_ne_jtimestamp(jdate, jtimestamp) RETURNS bool
    AS 'MODULE_PATHNAME', 'jdate_ne_jtimestamp' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_lt_jtimestamp(jdate, jtimestamp) RETURNS bool
    AS 'MODULE_PATHNAME', 'jdate_lt_jtimestamp' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_le_jtimestamp(jdate, jtimestamp) RETURNS bool
    AS 'MODULE_PATHNAME', 'jdate_le_jtimestamp' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_gt_jtimestamp(jdate, jtimestamp) RETURNS bool
    AS 'MODULE_PATHNAME', 'jdate_gt_jtimestamp' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_ge_jtimestamp(jdate, jtimestamp) RETURNS bool
    AS 'MODULE_PATHNAME', 'jdate_ge_jtimestamp' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_cmp_jtimestamp(jdate, jtimestamp) RETURNS int4
    AS 'MODULE_PATHNAME', 'jdate_cmp_jtimestamp' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OPERATOR = (
    LEFTARG = jdate, RIGHTARG = jtimestamp, PROCEDURE = jdate_eq_jtimestamp,
    COMMUTATOR = =, NEGATOR = <>,
    RESTRICT = eqsel, JOIN = eqjoinsel, MERGES
);
CREATE OPERATOR <> (
    LEFTARG = jdate, RIGHTARG = jtimestamp, PROCEDURE = jdate_ne_jtimestamp,
    COMMUTATOR = <>, NEGATOR = =,
    RESTRICT = neqsel, JOIN = neqjoinsel
);
CREATE OPERATOR < (
    LEFTARG = jdate, RIGHTARG = jtimestamp, PROCEDURE = jdate_lt_jtimestamp,
    COMMUTATOR = >, NEGATOR = >=,
    RESTRICT = scalarltsel, JOIN = scalarltjoinsel
);
CREATE OPERATOR <= (
    LEFTARG = jdate, RIGHTARG = jtimestamp, PROCEDURE = jdate_le_jtimestamp,
    COMMUTATOR = >=, NEGATOR = >,
    RESTRICT = scalarlesel, JOIN = scalarlejoinsel
);
CREATE OPERATOR > (
    LEFTARG = jdate, RIGHTARG = jtimestamp, PROCEDURE = jdate_gt_jtimestamp,
    COMMUTATOR = <, NEGATOR = <=,
    RESTRICT = scalargtsel, JOIN = scalargtjoinsel
);
CREATE OPERATOR >= (
    LEFTARG = jdate, RIGHTARG = jtimestamp, PROCEDURE = jdate_ge_jtimestamp,
    COMMUTATOR = <=, NEGATOR = <,
    RESTRICT = scalargesel, JOIN = scalargejoinsel
);

ALTER OPERATOR FAMILY jdatetime_ops USING btree ADD
    OPERATOR 1 < (jdate, jtimestamp),
    OPERATOR 2 <= (jdate, jtimestamp),
    OPERATOR 3 = (jdate, jtimestamp),
    OPERATOR 4 >= (jdate, jtimestamp),
    OPERATOR 5 > (jdate, jtimestamp),
    FUNCTION 1 (jdate, jtimestamp) jdate_cmp_jtimestamp(jdate, jtimestamp);

-- jtimestamp against jdate (IMMUTABLE: no time zone is read)

CREATE FUNCTION jtimestamp_eq_jdate(jtimestamp, jdate) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamp_eq_jdate' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamp_ne_jdate(jtimestamp, jdate) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamp_ne_jdate' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamp_lt_jdate(jtimestamp, jdate) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamp_lt_jdate' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamp_le_jdate(jtimestamp, jdate) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamp_le_jdate' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamp_gt_jdate(jtimestamp, jdate) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamp_gt_jdate' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamp_ge_jdate(jtimestamp, jdate) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamp_ge_jdate' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamp_cmp_jdate(jtimestamp, jdate) RETURNS int4
    AS 'MODULE_PATHNAME', 'jtimestamp_cmp_jdate' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OPERATOR = (
    LEFTARG = jtimestamp, RIGHTARG = jdate, PROCEDURE = jtimestamp_eq_jdate,
    COMMUTATOR = =, NEGATOR = <>,
    RESTRICT = eqsel, JOIN = eqjoinsel, MERGES
);
CREATE OPERATOR <> (
    LEFTARG = jtimestamp, RIGHTARG = jdate, PROCEDURE = jtimestamp_ne_jdate,
    COMMUTATOR = <>, NEGATOR = =,
    RESTRICT = neqsel, JOIN = neqjoinsel
);
CREATE OPERATOR < (
    LEFTARG = jtimestamp, RIGHTARG = jdate, PROCEDURE = jtimestamp_lt_jdate,
    COMMUTATOR = >, NEGATOR = >=,
    RESTRICT = scalarltsel, JOIN = scalarltjoinsel
);
CREATE OPERATOR <= (
    LEFTARG = jtimestamp, RIGHTARG = jdate, PROCEDURE = jtimestamp_le_jdate,
    COMMUTATOR = >=, NEGATOR = >,
    RESTRICT = scalarlesel, JOIN = scalarlejoinsel
);
CREATE OPERATOR > (
    LEFTARG = jtimestamp, RIGHTARG = jdate, PROCEDURE = jtimestamp_gt_jdate,
    COMMUTATOR = <, NEGATOR = <=,
    RESTRICT = scalargtsel, JOIN = scalargtjoinsel
);
CREATE OPERATOR >= (
    LEFTARG = jtimestamp, RIGHTARG = jdate, PROCEDURE = jtimestamp_ge_jdate,
    COMMUTATOR = <=, NEGATOR = <,
    RESTRICT = scalargesel, JOIN = scalargejoinsel
);

ALTER OPERATOR FAMILY jdatetime_ops USING btree ADD
    OPERATOR 1 < (jtimestamp, jdate),
    OPERATOR 2 <= (jtimestamp, jdate),
    OPERATOR 3 = (jtimestamp, jdate),
    OPERATOR 4 >= (jtimestamp, jdate),
    OPERATOR 5 > (jtimestamp, jdate),
    FUNCTION 1 (jtimestamp, jdate) jtimestamp_cmp_jdate(jtimestamp, jdate);

-- jdate against jtimestamptz (STABLE: reads the session time zone)

CREATE FUNCTION jdate_eq_jtimestamptz(jdate, jtimestamptz) RETURNS bool
    AS 'MODULE_PATHNAME', 'jdate_eq_jtimestamptz' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_ne_jtimestamptz(jdate, jtimestamptz) RETURNS bool
    AS 'MODULE_PATHNAME', 'jdate_ne_jtimestamptz' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_lt_jtimestamptz(jdate, jtimestamptz) RETURNS bool
    AS 'MODULE_PATHNAME', 'jdate_lt_jtimestamptz' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_le_jtimestamptz(jdate, jtimestamptz) RETURNS bool
    AS 'MODULE_PATHNAME', 'jdate_le_jtimestamptz' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_gt_jtimestamptz(jdate, jtimestamptz) RETURNS bool
    AS 'MODULE_PATHNAME', 'jdate_gt_jtimestamptz' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_ge_jtimestamptz(jdate, jtimestamptz) RETURNS bool
    AS 'MODULE_PATHNAME', 'jdate_ge_jtimestamptz' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_cmp_jtimestamptz(jdate, jtimestamptz) RETURNS int4
    AS 'MODULE_PATHNAME', 'jdate_cmp_jtimestamptz' LANGUAGE C STABLE STRICT PARALLEL SAFE;

CREATE OPERATOR = (
    LEFTARG = jdate, RIGHTARG = jtimestamptz, PROCEDURE = jdate_eq_jtimestamptz,
    COMMUTATOR = =, NEGATOR = <>,
    RESTRICT = eqsel, JOIN = eqjoinsel, MERGES
);
CREATE OPERATOR <> (
    LEFTARG = jdate, RIGHTARG = jtimestamptz, PROCEDURE = jdate_ne_jtimestamptz,
    COMMUTATOR = <>, NEGATOR = =,
    RESTRICT = neqsel, JOIN = neqjoinsel
);
CREATE OPERATOR < (
    LEFTARG = jdate, RIGHTARG = jtimestamptz, PROCEDURE = jdate_lt_jtimestamptz,
    COMMUTATOR = >, NEGATOR = >=,
    RESTRICT = scalarltsel, JOIN = scalarltjoinsel
);
CREATE OPERATOR <= (
    LEFTARG = jdate, RIGHTARG = jtimestamptz, PROCEDURE = jdate_le_jtimestamptz,
    COMMUTATOR = >=, NEGATOR = >,
    RESTRICT = scalarlesel, JOIN = scalarlejoinsel
);
CREATE OPERATOR > (
    LEFTARG = jdate, RIGHTARG = jtimestamptz, PROCEDURE = jdate_gt_jtimestamptz,
    COMMUTATOR = <, NEGATOR = <=,
    RESTRICT = scalargtsel, JOIN = scalargtjoinsel
);
CREATE OPERATOR >= (
    LEFTARG = jdate, RIGHTARG = jtimestamptz, PROCEDURE = jdate_ge_jtimestamptz,
    COMMUTATOR = <=, NEGATOR = <,
    RESTRICT = scalargesel, JOIN = scalargejoinsel
);

ALTER OPERATOR FAMILY jdatetime_ops USING btree ADD
    OPERATOR 1 < (jdate, jtimestamptz),
    OPERATOR 2 <= (jdate, jtimestamptz),
    OPERATOR 3 = (jdate, jtimestamptz),
    OPERATOR 4 >= (jdate, jtimestamptz),
    OPERATOR 5 > (jdate, jtimestamptz),
    FUNCTION 1 (jdate, jtimestamptz) jdate_cmp_jtimestamptz(jdate, jtimestamptz);

-- jtimestamptz against jdate (STABLE: reads the session time zone)

CREATE FUNCTION jtimestamptz_eq_jdate(jtimestamptz, jdate) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamptz_eq_jdate' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamptz_ne_jdate(jtimestamptz, jdate) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamptz_ne_jdate' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamptz_lt_jdate(jtimestamptz, jdate) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamptz_lt_jdate' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamptz_le_jdate(jtimestamptz, jdate) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamptz_le_jdate' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamptz_gt_jdate(jtimestamptz, jdate) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamptz_gt_jdate' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamptz_ge_jdate(jtimestamptz, jdate) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamptz_ge_jdate' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamptz_cmp_jdate(jtimestamptz, jdate) RETURNS int4
    AS 'MODULE_PATHNAME', 'jtimestamptz_cmp_jdate' LANGUAGE C STABLE STRICT PARALLEL SAFE;

CREATE OPERATOR = (
    LEFTARG = jtimestamptz, RIGHTARG = jdate, PROCEDURE = jtimestamptz_eq_jdate,
    COMMUTATOR = =, NEGATOR = <>,
    RESTRICT = eqsel, JOIN = eqjoinsel, MERGES
);
CREATE OPERATOR <> (
    LEFTARG = jtimestamptz, RIGHTARG = jdate, PROCEDURE = jtimestamptz_ne_jdate,
    COMMUTATOR = <>, NEGATOR = =,
    RESTRICT = neqsel, JOIN = neqjoinsel
);
CREATE OPERATOR < (
    LEFTARG = jtimestamptz, RIGHTARG = jdate, PROCEDURE = jtimestamptz_lt_jdate,
    COMMUTATOR = >, NEGATOR = >=,
    RESTRICT = scalarltsel, JOIN = scalarltjoinsel
);
CREATE OPERATOR <= (
    LEFTARG = jtimestamptz, RIGHTARG = jdate, PROCEDURE = jtimestamptz_le_jdate,
    COMMUTATOR = >=, NEGATOR = >,
    RESTRICT = scalarlesel, JOIN = scalarlejoinsel
);
CREATE OPERATOR > (
    LEFTARG = jtimestamptz, RIGHTARG = jdate, PROCEDURE = jtimestamptz_gt_jdate,
    COMMUTATOR = <, NEGATOR = <=,
    RESTRICT = scalargtsel, JOIN = scalargtjoinsel
);
CREATE OPERATOR >= (
    LEFTARG = jtimestamptz, RIGHTARG = jdate, PROCEDURE = jtimestamptz_ge_jdate,
    COMMUTATOR = <=, NEGATOR = <,
    RESTRICT = scalargesel, JOIN = scalargejoinsel
);

ALTER OPERATOR FAMILY jdatetime_ops USING btree ADD
    OPERATOR 1 < (jtimestamptz, jdate),
    OPERATOR 2 <= (jtimestamptz, jdate),
    OPERATOR 3 = (jtimestamptz, jdate),
    OPERATOR 4 >= (jtimestamptz, jdate),
    OPERATOR 5 > (jtimestamptz, jdate),
    FUNCTION 1 (jtimestamptz, jdate) jtimestamptz_cmp_jdate(jtimestamptz, jdate);

-- jtimestamp against jtimestamptz (STABLE: reads the session time zone)

CREATE FUNCTION jtimestamp_eq_jtimestamptz(jtimestamp, jtimestamptz) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamp_eq_jtimestamptz' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamp_ne_jtimestamptz(jtimestamp, jtimestamptz) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamp_ne_jtimestamptz' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamp_lt_jtimestamptz(jtimestamp, jtimestamptz) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamp_lt_jtimestamptz' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamp_le_jtimestamptz(jtimestamp, jtimestamptz) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamp_le_jtimestamptz' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamp_gt_jtimestamptz(jtimestamp, jtimestamptz) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamp_gt_jtimestamptz' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamp_ge_jtimestamptz(jtimestamp, jtimestamptz) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamp_ge_jtimestamptz' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamp_cmp_jtimestamptz(jtimestamp, jtimestamptz) RETURNS int4
    AS 'MODULE_PATHNAME', 'jtimestamp_cmp_jtimestamptz' LANGUAGE C STABLE STRICT PARALLEL SAFE;

CREATE OPERATOR = (
    LEFTARG = jtimestamp, RIGHTARG = jtimestamptz, PROCEDURE = jtimestamp_eq_jtimestamptz,
    COMMUTATOR = =, NEGATOR = <>,
    RESTRICT = eqsel, JOIN = eqjoinsel, MERGES
);
CREATE OPERATOR <> (
    LEFTARG = jtimestamp, RIGHTARG = jtimestamptz, PROCEDURE = jtimestamp_ne_jtimestamptz,
    COMMUTATOR = <>, NEGATOR = =,
    RESTRICT = neqsel, JOIN = neqjoinsel
);
CREATE OPERATOR < (
    LEFTARG = jtimestamp, RIGHTARG = jtimestamptz, PROCEDURE = jtimestamp_lt_jtimestamptz,
    COMMUTATOR = >, NEGATOR = >=,
    RESTRICT = scalarltsel, JOIN = scalarltjoinsel
);
CREATE OPERATOR <= (
    LEFTARG = jtimestamp, RIGHTARG = jtimestamptz, PROCEDURE = jtimestamp_le_jtimestamptz,
    COMMUTATOR = >=, NEGATOR = >,
    RESTRICT = scalarlesel, JOIN = scalarlejoinsel
);
CREATE OPERATOR > (
    LEFTARG = jtimestamp, RIGHTARG = jtimestamptz, PROCEDURE = jtimestamp_gt_jtimestamptz,
    COMMUTATOR = <, NEGATOR = <=,
    RESTRICT = scalargtsel, JOIN = scalargtjoinsel
);
CREATE OPERATOR >= (
    LEFTARG = jtimestamp, RIGHTARG = jtimestamptz, PROCEDURE = jtimestamp_ge_jtimestamptz,
    COMMUTATOR = <=, NEGATOR = <,
    RESTRICT = scalargesel, JOIN = scalargejoinsel
);

ALTER OPERATOR FAMILY jdatetime_ops USING btree ADD
    OPERATOR 1 < (jtimestamp, jtimestamptz),
    OPERATOR 2 <= (jtimestamp, jtimestamptz),
    OPERATOR 3 = (jtimestamp, jtimestamptz),
    OPERATOR 4 >= (jtimestamp, jtimestamptz),
    OPERATOR 5 > (jtimestamp, jtimestamptz),
    FUNCTION 1 (jtimestamp, jtimestamptz) jtimestamp_cmp_jtimestamptz(jtimestamp, jtimestamptz);

-- jtimestamptz against jtimestamp (STABLE: reads the session time zone)

CREATE FUNCTION jtimestamptz_eq_jtimestamp(jtimestamptz, jtimestamp) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamptz_eq_jtimestamp' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamptz_ne_jtimestamp(jtimestamptz, jtimestamp) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamptz_ne_jtimestamp' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamptz_lt_jtimestamp(jtimestamptz, jtimestamp) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamptz_lt_jtimestamp' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamptz_le_jtimestamp(jtimestamptz, jtimestamp) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamptz_le_jtimestamp' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamptz_gt_jtimestamp(jtimestamptz, jtimestamp) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamptz_gt_jtimestamp' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamptz_ge_jtimestamp(jtimestamptz, jtimestamp) RETURNS bool
    AS 'MODULE_PATHNAME', 'jtimestamptz_ge_jtimestamp' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamptz_cmp_jtimestamp(jtimestamptz, jtimestamp) RETURNS int4
    AS 'MODULE_PATHNAME', 'jtimestamptz_cmp_jtimestamp' LANGUAGE C STABLE STRICT PARALLEL SAFE;

CREATE OPERATOR = (
    LEFTARG = jtimestamptz, RIGHTARG = jtimestamp, PROCEDURE = jtimestamptz_eq_jtimestamp,
    COMMUTATOR = =, NEGATOR = <>,
    RESTRICT = eqsel, JOIN = eqjoinsel, MERGES
);
CREATE OPERATOR <> (
    LEFTARG = jtimestamptz, RIGHTARG = jtimestamp, PROCEDURE = jtimestamptz_ne_jtimestamp,
    COMMUTATOR = <>, NEGATOR = =,
    RESTRICT = neqsel, JOIN = neqjoinsel
);
CREATE OPERATOR < (
    LEFTARG = jtimestamptz, RIGHTARG = jtimestamp, PROCEDURE = jtimestamptz_lt_jtimestamp,
    COMMUTATOR = >, NEGATOR = >=,
    RESTRICT = scalarltsel, JOIN = scalarltjoinsel
);
CREATE OPERATOR <= (
    LEFTARG = jtimestamptz, RIGHTARG = jtimestamp, PROCEDURE = jtimestamptz_le_jtimestamp,
    COMMUTATOR = >=, NEGATOR = >,
    RESTRICT = scalarlesel, JOIN = scalarlejoinsel
);
CREATE OPERATOR > (
    LEFTARG = jtimestamptz, RIGHTARG = jtimestamp, PROCEDURE = jtimestamptz_gt_jtimestamp,
    COMMUTATOR = <, NEGATOR = <=,
    RESTRICT = scalargtsel, JOIN = scalargtjoinsel
);
CREATE OPERATOR >= (
    LEFTARG = jtimestamptz, RIGHTARG = jtimestamp, PROCEDURE = jtimestamptz_ge_jtimestamp,
    COMMUTATOR = <=, NEGATOR = <,
    RESTRICT = scalargesel, JOIN = scalargejoinsel
);

ALTER OPERATOR FAMILY jdatetime_ops USING btree ADD
    OPERATOR 1 < (jtimestamptz, jtimestamp),
    OPERATOR 2 <= (jtimestamptz, jtimestamp),
    OPERATOR 3 = (jtimestamptz, jtimestamp),
    OPERATOR 4 >= (jtimestamptz, jtimestamp),
    OPERATOR 5 > (jtimestamptz, jtimestamp),
    FUNCTION 1 (jtimestamptz, jtimestamp) jtimestamptz_cmp_jtimestamp(jtimestamptz, jtimestamp);

-- ============================================================
-- Interval arithmetic and differences for jtimestamp
-- ============================================================
--
-- jtimestamp + interval, interval + jtimestamp, jtimestamp - interval: the
-- month part of the interval is applied with Jalali month lengths, then the
-- days and the time part by core's timestamp_pl_interval (months first, then
-- days, then time, as core). A month step clamps to the last day of a shorter
-- month (1403-06-31 + 1 month is 1403-07-30) and so is not invertible, as in
-- core; 1 year is 12 months. The result is range-checked (22008). Infinity
-- passes through; on PostgreSQL 17 and later an infinite interval is handled as
-- core handles it. IMMUTABLE: the result depends on nothing but the arguments.
--
-- jtimestamp - jtimestamp is core's timestamp_mi: an interval of days and time
-- of day, no months. jdate - jtimestamp and jtimestamp - jdate are the same with
-- the day taken as its midnight (core gets them through its implicit cast
-- date -> timestamp; these types have no implicit casts).
--
-- The C code is in src/jtimestamp_arith.c; the Jalali month arithmetic and the
-- local-time helper it uses are in src/jtimestamp_local.c.

CREATE FUNCTION jtimestamp_pl_interval(jtimestamp, interval) RETURNS jtimestamp
    AS 'MODULE_PATHNAME', 'jtimestamp_pl_interval' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION interval_pl_jtimestamp(interval, jtimestamp) RETURNS jtimestamp
    AS 'MODULE_PATHNAME', 'interval_pl_jtimestamp' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamp_mi_interval(jtimestamp, interval) RETURNS jtimestamp
    AS 'MODULE_PATHNAME', 'jtimestamp_mi_interval' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamp_mi(jtimestamp, jtimestamp) RETURNS interval
    AS 'MODULE_PATHNAME', 'jtimestamp_mi' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_mi_jtimestamp(jdate, jtimestamp) RETURNS interval
    AS 'MODULE_PATHNAME', 'jdate_mi_jtimestamp' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamp_mi_jdate(jtimestamp, jdate) RETURNS interval
    AS 'MODULE_PATHNAME', 'jtimestamp_mi_jdate' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OPERATOR + (
    LEFTARG = jtimestamp, RIGHTARG = interval, PROCEDURE = jtimestamp_pl_interval,
    COMMUTATOR = +
);
-- Completes the shell operator that COMMUTATOR = + above creates.
CREATE OPERATOR + (
    LEFTARG = interval, RIGHTARG = jtimestamp, PROCEDURE = interval_pl_jtimestamp,
    COMMUTATOR = +
);
CREATE OPERATOR - (
    LEFTARG = jtimestamp, RIGHTARG = interval, PROCEDURE = jtimestamp_mi_interval
);
CREATE OPERATOR - (
    LEFTARG = jtimestamp, RIGHTARG = jtimestamp, PROCEDURE = jtimestamp_mi
);
CREATE OPERATOR - (
    LEFTARG = jdate, RIGHTARG = jtimestamp, PROCEDURE = jdate_mi_jtimestamp
);
CREATE OPERATOR - (
    LEFTARG = jtimestamp, RIGHTARG = jdate, PROCEDURE = jtimestamp_mi_jdate
);

-- ============================================================
-- Interval arithmetic for jtimestamptz and jdate, jdate with time
-- ============================================================
--
-- jtimestamptz + interval, interval + jtimestamptz, jtimestamptz - interval
-- (STABLE: they read the session time zone). As core does for timestamptz,
-- months and days are applied on the local wall clock of the session zone and
-- the time part as elapsed time. The month part is applied here with Jalali
-- month lengths (as for jtimestamp), the instant going to the zone's local
-- date and time of day and back through core's own zone routines, and core's
-- timestamptz_pl_interval then does days and time with the month zeroed. So
-- 2024-03-30 12:00 in Paris + 1 day keeps the wall time and + 24 hours does
-- not, a wall time that does not exist (a gap) moves forward, and a wall time
-- that occurs twice takes its second occurrence (the offset after the change),
-- exactly as in core. The result
-- is range-checked against the jtimestamptz safe range (22008), and so is the
-- instant after the month step: a month step that itself lands outside the
-- safe range is an error even when a negative day part would bring the result
-- back inside.
--
-- jtimestamptz - jtimestamptz is core's timestamptz_mi (IMMUTABLE): elapsed
-- days (of 24 hours) and time of day, no months. jdate - jtimestamptz and
-- jtimestamptz - jdate take the day as its midnight in the session zone (core
-- does this through its implicit cast date -> timestamptz, which these types
-- do not have), so they are STABLE.
--
-- jdate + interval, interval + jdate, jdate - interval return jtimestamp
-- (IMMUTABLE), as core's date + interval returns timestamp: the day is its
-- midnight and the jtimestamp rules apply.
--
-- jdate + time and time + jdate return jtimestamp, jdate + timetz and
-- timetz + jdate return jtimestamptz (all IMMUTABLE, the zone is in the
-- timetz): exactly the date / time and date / timetz operators core has. Core
-- has no timestamp + time, so there is no jtimestamp + time.
--
-- With these operators a bare literal next to a jdate is ambiguous: jdate + '5'
-- is 42725, as date + '5' is in core. Write jdate + 5 or jdate + interval '5 days'.

CREATE FUNCTION jtimestamptz_pl_interval(jtimestamptz, interval) RETURNS jtimestamptz
    AS 'MODULE_PATHNAME', 'jtimestamptz_pl_interval' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION interval_pl_jtimestamptz(interval, jtimestamptz) RETURNS jtimestamptz
    AS 'MODULE_PATHNAME', 'interval_pl_jtimestamptz' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamptz_mi_interval(jtimestamptz, interval) RETURNS jtimestamptz
    AS 'MODULE_PATHNAME', 'jtimestamptz_mi_interval' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamptz_mi(jtimestamptz, jtimestamptz) RETURNS interval
    AS 'MODULE_PATHNAME', 'jtimestamptz_mi' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_mi_jtimestamptz(jdate, jtimestamptz) RETURNS interval
    AS 'MODULE_PATHNAME', 'jdate_mi_jtimestamptz' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jtimestamptz_mi_jdate(jtimestamptz, jdate) RETURNS interval
    AS 'MODULE_PATHNAME', 'jtimestamptz_mi_jdate' LANGUAGE C STABLE STRICT PARALLEL SAFE;

CREATE FUNCTION jdate_pl_interval(jdate, interval) RETURNS jtimestamp
    AS 'MODULE_PATHNAME', 'jdate_pl_interval' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION interval_pl_jdate(interval, jdate) RETURNS jtimestamp
    AS 'MODULE_PATHNAME', 'interval_pl_jdate' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_mi_interval(jdate, interval) RETURNS jtimestamp
    AS 'MODULE_PATHNAME', 'jdate_mi_interval' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION jdate_pl_time(jdate, time) RETURNS jtimestamp
    AS 'MODULE_PATHNAME', 'jdate_pl_time' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION time_pl_jdate(time, jdate) RETURNS jtimestamp
    AS 'MODULE_PATHNAME', 'time_pl_jdate' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_pl_timetz(jdate, timetz) RETURNS jtimestamptz
    AS 'MODULE_PATHNAME', 'jdate_pl_timetz' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION timetz_pl_jdate(timetz, jdate) RETURNS jtimestamptz
    AS 'MODULE_PATHNAME', 'timetz_pl_jdate' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OPERATOR + (
    LEFTARG = jtimestamptz, RIGHTARG = interval, PROCEDURE = jtimestamptz_pl_interval,
    COMMUTATOR = +
);
-- Completes the shell operator that COMMUTATOR = + above creates.
CREATE OPERATOR + (
    LEFTARG = interval, RIGHTARG = jtimestamptz, PROCEDURE = interval_pl_jtimestamptz,
    COMMUTATOR = +
);
CREATE OPERATOR - (
    LEFTARG = jtimestamptz, RIGHTARG = interval, PROCEDURE = jtimestamptz_mi_interval
);
CREATE OPERATOR - (
    LEFTARG = jtimestamptz, RIGHTARG = jtimestamptz, PROCEDURE = jtimestamptz_mi
);
CREATE OPERATOR - (
    LEFTARG = jdate, RIGHTARG = jtimestamptz, PROCEDURE = jdate_mi_jtimestamptz
);
CREATE OPERATOR - (
    LEFTARG = jtimestamptz, RIGHTARG = jdate, PROCEDURE = jtimestamptz_mi_jdate
);

CREATE OPERATOR + (
    LEFTARG = jdate, RIGHTARG = interval, PROCEDURE = jdate_pl_interval,
    COMMUTATOR = +
);
CREATE OPERATOR + (
    LEFTARG = interval, RIGHTARG = jdate, PROCEDURE = interval_pl_jdate,
    COMMUTATOR = +
);
CREATE OPERATOR - (
    LEFTARG = jdate, RIGHTARG = interval, PROCEDURE = jdate_mi_interval
);

CREATE OPERATOR + (
    LEFTARG = jdate, RIGHTARG = time, PROCEDURE = jdate_pl_time,
    COMMUTATOR = +
);
CREATE OPERATOR + (
    LEFTARG = time, RIGHTARG = jdate, PROCEDURE = time_pl_jdate,
    COMMUTATOR = +
);
CREATE OPERATOR + (
    LEFTARG = jdate, RIGHTARG = timetz, PROCEDURE = jdate_pl_timetz,
    COMMUTATOR = +
);
CREATE OPERATOR + (
    LEFTARG = timetz, RIGHTARG = jdate, PROCEDURE = timetz_pl_jdate,
    COMMUTATOR = +
);

-- ============================================================
-- jgenerate_series
-- ============================================================
--
-- Core's generate_series is not overloaded for these types: a bare literal would
-- silently pick the Gregorian calendar, so the functions have their own name, and
-- a call whose arguments are all bare literals is ambiguous (42725) instead.
--
-- jgenerate_series(jtimestamp, jtimestamp, interval) is IMMUTABLE;
-- jgenerate_series(jtimestamptz, jtimestamptz, interval) is STABLE (it steps on the
-- wall clock of the session zone) and the form with a zone name as fourth argument
-- is IMMUTABLE, as in core. jgenerate_series(jdate, jdate, interval) returns
-- jtimestamp (the midnights of the days, as core's date version returns
-- timestamptz) and jgenerate_series(jdate, jdate, int) returns the days
-- themselves, one per step of that many days (default 1).
--
-- As in core, element n + 1 is element n plus the step, so the clamp of a month
-- step to the last day of a shorter month sticks, and a step with a month part is
-- counted in Jalali months. Days keep the wall time across a daylight saving
-- change. A zero step is 22023, as in core, and so is an infinite step (PostgreSQL
-- 17 and later) and, unlike in core 18, an infinite endpoint. Every element is
-- range-checked; a series may run up to the last or down to the first
-- representable value, and ends there instead of failing on the element after it.
--
-- The C code is in src/jtimestamp_series.c.

CREATE FUNCTION jgenerate_series(jtimestamp, jtimestamp, interval) RETURNS SETOF jtimestamp
    AS 'MODULE_PATHNAME', 'jgenerate_series_jtimestamp' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jgenerate_series(jtimestamptz, jtimestamptz, interval) RETURNS SETOF jtimestamptz
    AS 'MODULE_PATHNAME', 'jgenerate_series_jtimestamptz' LANGUAGE C STABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jgenerate_series(jtimestamptz, jtimestamptz, interval, text) RETURNS SETOF jtimestamptz
    AS 'MODULE_PATHNAME', 'jgenerate_series_jtimestamptz_zone' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jgenerate_series(jdate, jdate, interval) RETURNS SETOF jtimestamp
    AS 'MODULE_PATHNAME', 'jgenerate_series_jdate_interval' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jgenerate_series(jdate, jdate, int DEFAULT 1) RETURNS SETOF jdate
    AS 'MODULE_PATHNAME', 'jgenerate_series_jdate' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- ============================================================
-- jdate_bin, AT TIME ZONE and OVERLAPS
-- ============================================================
--
-- None of these depends on the calendar, so each one is core's own C function on
-- the same representation, plus the range check of the result where it is a new
-- value. The C code is in src/jtimestamp_zone.c.
--
-- jdate_bin(stride, source, origin) has its own name because a bare literal given
-- to core's date_bin would pick core's timestamptz. IMMUTABLE for both types, as
-- core's. The bins are fixed lengths of elapsed time counted from the origin: for
-- jtimestamptz a one-day bin is a local day only in a zone with a fixed offset and
-- an origin at local midnight (use jdate_trunc for local days). A month or a year
-- in the stride is 0A000, a zero stride 22008, infinity gives infinity, as in
-- core. When the source is before the origin the start of its bin lies up to one
-- stride below the source, which can be below the supported range: that is 22008
-- (for jtimestamptz the bound is the safe range).
--
-- x AT TIME ZONE zone desugars to pg_catalog.timezone(zone, x), so the functions
-- must live in pg_catalog (as extract() does; the extension is not relocatable for
-- that reason). jtimestamp AT TIME ZONE reads the wall clock in the zone and gives
-- the jtimestamptz instant; jtimestamptz AT TIME ZONE gives the jtimestamp wall
-- clock of the instant in the zone. The zone is a name or, as in core, an interval
-- (a plain offset: months or days in it are an error). Gaps and overlaps are core's.
-- IMMUTABLE as core's, and the result is range-checked (22008): the safe range for
-- the jtimestamptz result, the Jalali range for the jtimestamp result. Core's AT
-- LOCAL forms (timezone with one argument) are not provided.
--
-- (a, b) OVERLAPS (c, d) desugars to pg_catalog.overlaps. Only the four-timestamp
-- forms exist. Core's forms that take an interval for an end are not provided: core
-- would add Gregorian months to a Jalali value, so they stay 42883. The functions
-- are not STRICT, as core's overlaps_timestamp is not (it handles a NULL end).
-- IMMUTABLE for both types, as core's.

CREATE FUNCTION jdate_bin(interval, jtimestamp, jtimestamp) RETURNS jtimestamp
    AS 'MODULE_PATHNAME', 'jdate_bin_jtimestamp' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION jdate_bin(interval, jtimestamptz, jtimestamptz) RETURNS jtimestamptz
    AS 'MODULE_PATHNAME', 'jdate_bin_jtimestamptz' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION pg_catalog.timezone(text, jtimestamp) RETURNS jtimestamptz
    AS 'MODULE_PATHNAME', 'jtimestamp_zone' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION pg_catalog.timezone(interval, jtimestamp) RETURNS jtimestamptz
    AS 'MODULE_PATHNAME', 'jtimestamp_izone' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION pg_catalog.timezone(text, jtimestamptz) RETURNS jtimestamp
    AS 'MODULE_PATHNAME', 'jtimestamptz_zone' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION pg_catalog.timezone(interval, jtimestamptz) RETURNS jtimestamp
    AS 'MODULE_PATHNAME', 'jtimestamptz_izone' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION pg_catalog.overlaps(jtimestamp, jtimestamp, jtimestamp, jtimestamp) RETURNS boolean
    AS 'MODULE_PATHNAME', 'jtimestamp_overlaps' LANGUAGE C IMMUTABLE PARALLEL SAFE;
CREATE FUNCTION pg_catalog.overlaps(jtimestamptz, jtimestamptz, jtimestamptz, jtimestamptz) RETURNS boolean
    AS 'MODULE_PATHNAME', 'jtimestamptz_overlaps' LANGUAGE C IMMUTABLE PARALLEL SAFE;
