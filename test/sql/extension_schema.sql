-- The extension is not relocatable: it registers extract(text, jdate) and, for
-- jtimestamp and jtimestamptz, extract(), timezone() and overlaps() in pg_catalog
-- (EXTRACT, AT TIME ZONE and OVERLAPS always resolve to pg_catalog functions), and
-- those functions cannot follow the rest of the extension into another schema,
-- so ALTER EXTENSION ... SET SCHEMA cannot work. The schema is chosen at
-- install time with CREATE EXTENSION jdate SCHEMA s.
--
-- This file drops and recreates the extension, so it must stay LAST in REGRESS.

-- The control file says not relocatable (io.sql created it in the default schema)
SELECT extname, extrelocatable FROM pg_extension WHERE extname = 'jdate';

-- Install into a dedicated schema
CREATE SCHEMA jdate_s;
DROP EXTENSION jdate;
CREATE EXTENSION jdate SCHEMA jdate_s;

SELECT extname, extnamespace::regnamespace AS schema, extrelocatable
FROM pg_extension WHERE extname = 'jdate';

-- Every schema-qualified object of the extension lives in jdate_s, except
-- pg_catalog.extract(text, jdate), the two pg_catalog.extract() functions and the
-- six pg_catalog.timezone() and overlaps() functions of jtimestamp and jtimestamptz.
-- (Casts have no schema and are skipped.)
SELECT i.type, i.schema, i.identity
FROM pg_depend d,
     LATERAL pg_identify_object(d.classid, d.objid, d.objsubid) i
WHERE d.refclassid = 'pg_extension'::regclass
  AND d.refobjid = (SELECT oid FROM pg_extension WHERE extname = 'jdate')
  AND d.deptype = 'e'
  AND i.schema IS NOT NULL
  AND i.schema <> 'jdate_s'
ORDER BY i.type COLLATE "C", i.schema COLLATE "C", i.identity COLLATE "C";

-- ... and the kinds of object we expect really are there
SELECT DISTINCT i.type COLLATE "C" AS type
FROM pg_depend d,
     LATERAL pg_identify_object(d.classid, d.objid, d.objsubid) i
WHERE d.refclassid = 'pg_extension'::regclass
  AND d.refobjid = (SELECT oid FROM pg_extension WHERE extname = 'jdate')
  AND d.deptype = 'e'
  AND i.schema = 'jdate_s'
ORDER BY 1;

-- The type and its array type are in jdate_s and nowhere else
SELECT typname, typnamespace::regnamespace AS schema
FROM pg_type WHERE typname IN ('jdate', '_jdate') ORDER BY 1, 2;

-- The range and multirange types of jdate, jtimestamp and jtimestamptz and their
-- arrays are in jdate_s too, and so are their constructors and support functions
SELECT typname, typtype, typnamespace::regnamespace AS schema
FROM pg_type WHERE typname ~ '^_?j(date|ts|tstz)(multi)?range$'
ORDER BY typname COLLATE "C";
SELECT count(*) FILTER (WHERE pronamespace = 'jdate_s'::regnamespace) AS range_functions_in_jdate_s,
       count(*) FILTER (WHERE pronamespace <> 'jdate_s'::regnamespace) AS range_functions_elsewhere
FROM pg_proc WHERE proname ~ '^j(date|ts|tstz)(multi)?range';

-- jdate_s is not on the search_path, so the type is not visible unqualified...
\set VERBOSITY sqlstate
SELECT jdate '1403-05-15';
\set VERBOSITY default

-- ... the range types work when qualified, and so does the canonical edge check
SELECT '[1403-01-01,1403-01-31]'::jdate_s.jdaterange AS range_in_jdate_s;
SELECT '{[1403-01-01 00:00:00,1403-01-02 00:00:00)}'::jdate_s.jtsmultirange AS multirange_in_jdate_s;
\set VERBOSITY sqlstate
SELECT '[1403-01-01,3177-12-29]'::jdate_s.jdaterange;
\set VERBOSITY default

-- ... but EXTRACT still works, because extract() lives in pg_catalog
SELECT EXTRACT(year FROM jdate_s.jdate '1403-05-15') AS year;
SELECT EXTRACT(month FROM jdate_s.jdate '1403-05-15') AS month;
SELECT EXTRACT(day FROM jdate_s.jdate '1403-05-15') AS day;
SELECT jdate_s.jdate_part('year', jdate_s.jdate '1403-05-15') AS part_year;

-- ALTER EXTENSION ... SET SCHEMA is refused (0A000, feature not supported)
\set VERBOSITY sqlstate
ALTER EXTENSION jdate SET SCHEMA public;
\set VERBOSITY default
-- Same statement again, to show the message (and that there is no DETAIL)
ALTER EXTENSION jdate SET SCHEMA public;

-- The extension is intact: same schema, extract(), timezone() and overlaps() still in pg_catalog
SELECT extname, extnamespace::regnamespace AS schema, extrelocatable
FROM pg_extension WHERE extname = 'jdate';
SELECT count(*) AS extract_in_pg_catalog
FROM pg_proc
WHERE proname = 'extract' AND pronamespace = 'pg_catalog'::regnamespace
  AND pg_get_function_identity_arguments(oid) ~ 'jdate$';
SELECT count(*) AS timezone_and_overlaps_in_pg_catalog
FROM pg_proc
WHERE proname IN ('timezone', 'overlaps') AND pronamespace = 'pg_catalog'::regnamespace
  AND pg_get_function_identity_arguments(oid) ~ 'jtimestamp';
SELECT count(*) AS extract_of_timestamps_in_pg_catalog
FROM pg_proc
WHERE proname = 'extract' AND pronamespace = 'pg_catalog'::regnamespace
  AND pg_get_function_identity_arguments(oid) ~ 'jtimestamp';
SELECT count(*) AS extension_functions_outside_jdate_s
FROM pg_depend d
WHERE d.classid = 'pg_proc'::regclass
  AND d.refclassid = 'pg_extension'::regclass
  AND d.refobjid = (SELECT oid FROM pg_extension WHERE extname = 'jdate')
  AND d.deptype = 'e'
  AND (SELECT pronamespace FROM pg_proc WHERE oid = d.objid) <> 'jdate_s'::regnamespace;
SELECT EXTRACT(year FROM jdate_s.jdate '1403-05-15') AS year_after_failed_alter;

-- DROP EXTENSION removes pg_catalog.extract(), timezone() and overlaps() of our types, and the types
DROP EXTENSION jdate;
SELECT count(*) AS extract_in_pg_catalog
FROM pg_proc
WHERE proname = 'extract' AND pronamespace = 'pg_catalog'::regnamespace
  AND pg_get_function_identity_arguments(oid) ~ 'jdate$';
SELECT count(*) AS timezone_and_overlaps_in_pg_catalog
FROM pg_proc
WHERE proname IN ('timezone', 'overlaps') AND pronamespace = 'pg_catalog'::regnamespace
  AND pg_get_function_identity_arguments(oid) ~ 'jtimestamp';
SELECT count(*) AS extract_of_timestamps_in_pg_catalog
FROM pg_proc
WHERE proname = 'extract' AND pronamespace = 'pg_catalog'::regnamespace
  AND pg_get_function_identity_arguments(oid) ~ 'jtimestamp';
SELECT count(*) AS jdate_types FROM pg_type WHERE typname IN ('jdate', '_jdate');
SELECT count(*) AS range_types FROM pg_type WHERE typname ~ '^_?j(date|ts|tstz)(multi)?range$';
SELECT count(*) AS objects_left_in_jdate_s
FROM pg_depend
WHERE refclassid = 'pg_namespace'::regclass
  AND refobjid = 'jdate_s'::regnamespace;

-- Back to the default schema, as the other tests expect
DROP SCHEMA jdate_s;
CREATE EXTENSION jdate;
SELECT extname, extnamespace::regnamespace AS schema, extrelocatable
FROM pg_extension WHERE extname = 'jdate';
SELECT EXTRACT(year FROM jdate '1403-05-15') AS year;
