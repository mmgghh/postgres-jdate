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
-- Same-type comparison only (the cross-type matrix comes later). Every
-- function delegates to core's timestamp_eq, timestamp_lt, ... and
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
