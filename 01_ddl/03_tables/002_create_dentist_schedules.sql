-- Extension provisioning is external. Resolve and qualify its actual UUID GiST namespace.
SET LOCAL search_path = pg_catalog;
DO $migration$
DECLARE extension_schema name;
BEGIN
    SELECT n.nspname INTO STRICT extension_schema
    FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace
    JOIN pg_opclass c ON c.opcnamespace=n.oid
    JOIN pg_am a ON a.oid=c.opcmethod
    JOIN pg_depend d ON d.classid='pg_opclass'::regclass AND d.objid=c.oid
        AND d.refclassid='pg_extension'::regclass AND d.refobjid=e.oid AND d.deptype='e'
    WHERE e.extname='btree_gist' AND c.opcname='gist_uuid_ops'
        AND c.opcintype='uuid'::regtype AND a.amname='gist'
        AND has_schema_privilege(current_user,n.oid,'USAGE');
    EXECUTE format($ddl$
CREATE TABLE appointments.dentist_schedules (
    schedule_id uuid NOT NULL CONSTRAINT pk_dentist_schedules PRIMARY KEY,
    dentist_id uuid NOT NULL CONSTRAINT uk_dentist_schedules_dentist_id UNIQUE,
    version integer NOT NULL,
    created_at timestamptz NOT NULL,
    created_by uuid NOT NULL,
    updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL,
    CONSTRAINT ck_dentist_schedules_version CHECK (version >= 1)
);
CREATE TABLE appointments.availability_intervals (
    interval_id uuid NOT NULL CONSTRAINT pk_availability_intervals PRIMARY KEY,
    schedule_id uuid NOT NULL CONSTRAINT fk_availability_intervals_schedule_id
        REFERENCES appointments.dentist_schedules (schedule_id) ON DELETE RESTRICT,
    start_at timestamptz NOT NULL,
    end_at timestamptz NOT NULL,
    CONSTRAINT ck_availability_intervals_interval CHECK (isfinite(start_at) AND isfinite(end_at) AND start_at < end_at),
    CONSTRAINT ex_availability_intervals_schedule_overlap EXCLUDE USING gist (
        schedule_id %1$I.gist_uuid_ops WITH =,
        tstzrange(start_at,end_at,'[)') WITH &&
    ) NOT DEFERRABLE
);
CREATE TABLE appointments.blocked_intervals (
    interval_id uuid NOT NULL CONSTRAINT pk_blocked_intervals PRIMARY KEY,
    schedule_id uuid NOT NULL CONSTRAINT fk_blocked_intervals_schedule_id
        REFERENCES appointments.dentist_schedules (schedule_id) ON DELETE RESTRICT,
    start_at timestamptz NOT NULL,
    end_at timestamptz NOT NULL,
    CONSTRAINT ck_blocked_intervals_interval CHECK (isfinite(start_at) AND isfinite(end_at) AND start_at < end_at),
    CONSTRAINT ex_blocked_intervals_schedule_overlap EXCLUDE USING gist (
        schedule_id %1$I.gist_uuid_ops WITH =,
        tstzrange(start_at,end_at,'[)') WITH &&
    ) NOT DEFERRABLE
);
$ddl$, extension_schema);
END $migration$;
