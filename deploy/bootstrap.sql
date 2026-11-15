-- One-time owner bootstrap, run by the platform DBA before Liquibase in each environment.
-- Set passwords through the environment's secret manager; never put them in this file.
-- Re-runnable: it creates missing objects and refuses unexpected existing state.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'appointments_migrator') THEN
    CREATE ROLE appointments_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'appointments_runtime') THEN
    CREATE ROLE appointments_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_roles
    WHERE rolname IN ('appointments_migrator', 'appointments_runtime')
      AND (NOT rolcanlogin OR rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)
  ) THEN
    RAISE EXCEPTION 'Existing Appointments role has unexpected privileges';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_namespace n
    JOIN pg_roles r ON r.oid = n.nspowner
    WHERE n.nspname IN ('appointments', 'appointments_liquibase') AND r.rolname <> 'appointments_migrator'
  ) THEN
    RAISE EXCEPTION 'Existing Appointments schema has another owner';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_extension e
    JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'btree_gist' AND n.nspname <> 'appointments_extensions'
  ) THEN
    RAISE EXCEPTION 'btree_gist is installed outside appointments_extensions';
  END IF;
END $$;

-- Changeset 001 creates the owner schema as the migrator, which needs CREATE on the database only
-- until that schema exists. CREATE on the database would also allow trusted extensions, so re-run
-- this bootstrap after the first migration to seal it. Later changesets need only schema ownership.
DO $$
BEGIN
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO appointments_migrator, appointments_runtime', current_database());
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'appointments') THEN
    EXECUTE format('REVOKE CREATE ON DATABASE %I FROM appointments_migrator', current_database());
  ELSE
    EXECUTE format('GRANT CREATE ON DATABASE %I TO appointments_migrator', current_database());
  END IF;
END $$;

-- Liquibase tracking tables stay outside the business schema.
CREATE SCHEMA IF NOT EXISTS appointments_liquibase AUTHORIZATION appointments_migrator;
REVOKE ALL ON SCHEMA appointments_liquibase FROM PUBLIC;

-- External prerequisite of the GiST exclusions; the business migrations never install it.
CREATE SCHEMA IF NOT EXISTS appointments_extensions;
REVOKE ALL ON SCHEMA appointments_extensions FROM PUBLIC;
GRANT USAGE ON SCHEMA appointments_extensions TO appointments_migrator;
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA appointments_extensions;
