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
CREATE TABLE appointments.appointments (
    appointment_id uuid NOT NULL CONSTRAINT pk_appointments PRIMARY KEY,
    patient_id uuid NOT NULL,
    dentist_id uuid NOT NULL,
    start_at timestamptz NOT NULL,
    end_at timestamptz NOT NULL,
    clinic_timezone text NOT NULL,
    reason text NOT NULL,
    status text NOT NULL,
    confirmation_status text NOT NULL,
    reminder_due_at timestamptz NOT NULL,
    reminder_status text NOT NULL,
    version integer NOT NULL,
    created_at timestamptz NOT NULL,
    created_by uuid NOT NULL,
    updated_at timestamptz NOT NULL,
    updated_by uuid NOT NULL,
    CONSTRAINT ck_appointments_interval CHECK (isfinite(start_at) AND isfinite(end_at) AND start_at < end_at),
    CONSTRAINT ck_appointments_reason CHECK (char_length(reason) BETWEEN 1 AND 500),
    CONSTRAINT ck_appointments_status CHECK (status IN ('PROGRAMADA','CONFIRMADA','EN_ATENCION','FINALIZADA','CANCELADA','NO_ASISTIO')),
    CONSTRAINT ck_appointments_confirmation CHECK (confirmation_status IN ('PENDING','CONFIRMED','NOT_CONFIRMED')),
    CONSTRAINT ck_appointments_reminder_status CHECK (reminder_status IN ('PENDING','SENT','FAILED')),
    CONSTRAINT ck_appointments_reminder_due CHECK (reminder_due_at = start_at - interval '24 hours'),
    CONSTRAINT ck_appointments_version CHECK (version >= 1),
    CONSTRAINT ex_appointments_dentist_overlap EXCLUDE USING gist (
        dentist_id %I.gist_uuid_ops WITH =,
        tstzrange(start_at,end_at,'[)') WITH &&
    ) WHERE (status IN ('PROGRAMADA','CONFIRMADA','EN_ATENCION')) NOT DEFERRABLE
);
$ddl$, extension_schema);
END $migration$;
