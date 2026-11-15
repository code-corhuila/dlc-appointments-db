-- Runs only on the disposable fixture's empty tmpfs, never as a domain migration.
DO $$ BEGIN
  IF current_database() <> 'appointments_bootstrap_test' OR current_user <> 'bootstrap_test' THEN
    RAISE EXCEPTION 'Test provisioning requires the isolated fixture identity';
  END IF;
END $$;
CREATE SCHEMA appointments_liquibase AUTHORIZATION bootstrap_test;
CREATE SCHEMA appointments_extensions AUTHORIZATION bootstrap_test;
-- The fixture initdb superuser owns the extension and its technical objects.
CREATE EXTENSION btree_gist WITH SCHEMA appointments_extensions;
-- Externally provisioned runtime role stand-in: no login, no DDL attributes, owns nothing.
CREATE ROLE appointments_runtime NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
