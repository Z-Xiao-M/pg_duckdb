-- For this test we duckdb set execution to false
SET duckdb.force_execution = false;
CREATE TABLE t(a int);
INSERT INTO t VALUES (1);

CREATE TEMP TABLE t_ddb(a int) USING duckdb;
INSERT INTO t_ddb VALUES (1);

BEGIN;
SELECT * FROM t_ddb;
INSERT INTO t_ddb VALUES (2);
SELECT * FROM t_ddb ORDER BY a;
ROLLBACK;

-- Executing many write commands is fine
BEGIN;
INSERT INTO t_ddb VALUES (2);
INSERT INTO t_ddb VALUES (3);
INSERT INTO t_ddb VALUES (4);
INSERT INTO t_ddb VALUES (5);
INSERT INTO t_ddb VALUES (6);
COMMIT;

SELECT * FROM t_ddb;

-- Writing to PG and DDB tables in the same transaction is not supported. We
-- fail early for simple DML (no matter the order).
BEGIN;
INSERT INTO t_ddb VALUES (2);
INSERT INTO t VALUES (2);
ROLLBACK;

BEGIN;
INSERT INTO t VALUES (2);
INSERT INTO t_ddb VALUES (2);
ROLLBACK;

-- Unless users explicitely opt-in
BEGIN;
SET LOCAL duckdb.unsafe_allow_mixed_transactions = true;
INSERT INTO t_ddb VALUES (4);
INSERT INTO t VALUES (4);
COMMIT;

BEGIN;
SET LOCAL duckdb.unsafe_allow_mixed_transactions = true;
INSERT INTO t VALUES (5);
INSERT INTO t_ddb VALUES (5);
COMMIT;

-- And for other writes that are not easy to detect, such as CREATE TABLE, we
-- fail on COMMIT.
BEGIN;
INSERT INTO t_ddb VALUES (2);
CREATE TABLE t2(a int);
COMMIT;

-- Savepoints in PG-only transactions should still work
BEGIN;
INSERT INTO t VALUES (2);
SAVEPOINT my_savepoint;
INSERT INTO t VALUES (3);
ROLLBACK TO SAVEPOINT my_savepoint;
COMMIT;

-- But savepoints are not allowed in DuckDB transactions
BEGIN;
INSERT INTO t_ddb VALUES (2);
SAVEPOINT my_savepoint;
ROLLBACK;;

-- Also not already started ones
BEGIN;
SAVEPOINT my_savepoint;
INSERT INTO t_ddb VALUES (2);
ROLLBACK;;

-- Unless the subtransaction is already completed
BEGIN;
SAVEPOINT my_savepoint;
SELECT count(*) FROM t;
RELEASE SAVEPOINT my_savepoint;
INSERT INTO t_ddb VALUES (2);
COMMIT;

-- Statements in functions should be run inside a single transaction. So a
-- failure later in the function should roll back.
CREATE OR REPLACE FUNCTION f(fail boolean) RETURNS void
    LANGUAGE plpgsql
    RETURNS NULL ON NULL INPUT
    AS
$$
BEGIN
INSERT INTO t_ddb VALUES (8);
IF fail THEN
    RAISE EXCEPTION 'fail';
END IF;
END;
$$;

-- After executing the function the table should not contain the value 8,
-- because that change was rolled back
SELECT * FROM f(true);
SELECT * FROM t_ddb ORDER BY a;

-- But if the function succeeds we should see the new value
SELECT * FROM f(false);
SELECT * FROM t_ddb ORDER BY a;

-- DuckDB DDL in transactions is allowed
BEGIN;
    CREATE TEMP TABLE t_ddb2(a int) USING duckdb;
    CREATE TEMP TABLE t_ddb3(a) USING duckdb AS SELECT 1;
    DROP TABLE t_ddb3;
    INSERT INTO t_ddb2 VALUES (1);
    ALTER TABLE t_ddb2 ADD COLUMN b int;
    ALTER TABLE t_ddb2 ADD COLUMN c int;
    ALTER TABLE t_ddb2 ADD COLUMN d int DEFAULT 100, ADD COLUMN e int DEFAULT 10;
    ALTER TABLE t_ddb2 RENAME COLUMN b TO f;
    ALTER TABLE t_ddb2 RENAME TO t_ddb4;
    SELECT * FROM t_ddb4;
END;

DROP TABLE t_ddb4;

-- Similarly is DDL in functions

CREATE OR REPLACE FUNCTION f2() RETURNS void
    LANGUAGE plpgsql
    RETURNS NULL ON NULL INPUT
    AS
$$
BEGIN
    CREATE TEMP TABLE t_ddb2(a int) USING duckdb;
    CREATE TEMP TABLE t_ddb3(a) USING duckdb AS SELECT 1;
    DROP TABLE t_ddb3;
    INSERT INTO t_ddb2 VALUES (1);
    ALTER TABLE t_ddb2 ADD COLUMN b int;
    ALTER TABLE t_ddb2 ADD COLUMN c int;
    ALTER TABLE t_ddb2 ADD COLUMN d int DEFAULT 100, ADD COLUMN e int DEFAULT 10;
    ALTER TABLE t_ddb2 RENAME COLUMN b TO f;
    ALTER TABLE t_ddb2 RENAME TO t_ddb4;
END;
$$;

SELECT * FROM f2();

DROP TABLE t_ddb4;

-- ...unless there's also PG only changes happing in the same transaction (no matter the order of statements).
BEGIN;
    CREATE TABLE t_x(a int);
    CREATE TEMP TABLE t_ddb2(a int) USING duckdb;
END;

BEGIN;
    CREATE TEMP TABLE t_ddb2(a int) USING duckdb;
    CREATE TABLE t_x(a int);
END;

BEGIN;
    CREATE TABLE t_x(a int);
    CREATE TEMP TABLE t_ddb2(a) USING duckdb AS SELECT 1;
END;

BEGIN;
    CREATE TEMP TABLE t_ddb2(a) USING duckdb AS SELECT 1;
    CREATE TABLE t_x(a int);
END;

-- And again the same for functions

CREATE OR REPLACE FUNCTION f2() RETURNS void
    LANGUAGE plpgsql
    RETURNS NULL ON NULL INPUT
    AS
$$
BEGIN
    CREATE TABLE t_x(a int);
    CREATE TEMP TABLE t_ddb2(a int) USING duckdb;
END;
$$;

SELECT * FROM f2();

CREATE OR REPLACE FUNCTION f2() RETURNS void
    LANGUAGE plpgsql
    RETURNS NULL ON NULL INPUT
    AS
$$
BEGIN
    CREATE TABLE t_x(a int);
    CREATE TEMP TABLE t_ddb2(a int) USING duckdb;
END;
$$;

SELECT * FROM f2();

BEGIN;
    CREATE TEMP TABLE t_ddb2(a) USING duckdb AS SELECT 1;
    CREATE TABLE t_x(a int);
    DROP TABLE t_ddb;
END;

BEGIN;
    DROP TABLE t_ddb;
    CREATE TABLE t_x(a int);
END;

BEGIN;
    CREATE TABLE t_x(a int);
    DROP TABLE t_ddb;
END;

BEGIN;
    CREATE TABLE t_x(a int);
    ALTER TABLE t_ddb ADD COLUMN b int;
END;

BEGIN;
    ALTER TABLE t_ddb ADD COLUMN b int;
    CREATE TABLE t_x(a int);
END;

-- Dropping both duckdb tables and postgres tables in the same command is
-- disallowed in a transaction.
BEGIN;
    DROP TABLE t, t_ddb;
END;

-- Dropping both duckdb tables and postgres tables in the same command is
-- disallowed in a transaction.
BEGIN;
    DROP TABLE t, t_ddb;
END;

-- In separate commands it's also not allowed
BEGIN;
    DROP TABLE t;
    DROP TABLE t_ddb;
END;

-- ...in any order
BEGIN;
    DROP TABLE t_ddb;
    DROP TABLE t;
END;

-- Non-existing tables should be allowed to be dropped in a transaction
-- together with DuckDB.
BEGIN;
    DROP TABLE IF EXISTS t_ddb, t_doesnotexist;
END;
CREATE TEMP TABLE t_ddb(a int) USING duckdb;


-- It should also not be allowed to drop duckdb and postgres tables in the same
-- transaction if it's implicitely done using a DROP SCHEMA ... CASCADE.
CREATE SCHEMA mixed;
CREATE TEMP TABLE t_ddb2(a int) USING duckdb;
-- Insert a row into pg_depend to make t_ddb depend on the mixed schema. We do
-- this because wo cannot insert TEMP tables in a schema. This is meant to
-- emulate a MotherDuck table in the mixed schema. To be clear, this is a
-- pretty big hack. Normally you're not supposed to manually mess with
-- pg_depend, but it's the easiest way to test this.
-- NOTE: 1259 is the oid for pg_class, and 2615 is the oid for pg_namespace. These
-- are not expected to change.
INSERT INTO pg_depend(classid, objid, objsubid, refclassid, refobjid, refobjsubid, deptype) SELECT 1259, 't_ddb2'::regclass, 0, 2615, 'mixed'::regnamespace, 0, 'n';
BEGIN;
    DROP SCHEMA mixed CASCADE;
END;

-- We have a special message for tables
CREATE TABLE mixed.t(a int);
BEGIN;
    DROP SCHEMA mixed CASCADE;
END;

-- It should work outside of a transaction though.
DROP SCHEMA mixed CASCADE;

TRUNCATE t_ddb;
INSERT INTO t_ddb VALUES (1);

BEGIN;
DECLARE c SCROLL CURSOR FOR SELECT a FROM t_ddb;
FETCH NEXT FROM c;
FETCH NEXT FROM c;
FETCH PRIOR FROM c;
COMMIT;

DROP FUNCTION f, f2;
DROP TABLE t;
