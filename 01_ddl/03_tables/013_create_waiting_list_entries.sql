-- DB-13 (HU-APT-005, APT-013): waiting-list metadata; one WAITING entry per patient and preferred dentist.
CREATE TABLE appointments.waiting_list_entries (
    entry_id uuid NOT NULL CONSTRAINT pk_waiting_list_entries PRIMARY KEY,
    patient_id uuid NOT NULL,
    dentist_id uuid,
    reason text NOT NULL,
    preferred_from date,
    preferred_to date,
    status text NOT NULL,
    appointment_id uuid CONSTRAINT fk_waiting_list_entries_appointment_id
        REFERENCES appointments.appointments (appointment_id),
    created_at timestamptz NOT NULL,
    created_by uuid NOT NULL,
    resolved_at timestamptz,
    resolved_by uuid,
    version integer NOT NULL,
    CONSTRAINT ck_waiting_list_entries_reason CHECK (length(btrim(reason)) BETWEEN 1 AND 500),
    CONSTRAINT ck_waiting_list_entries_status CHECK (status IN ('WAITING','SCHEDULED','WITHDRAWN')),
    CONSTRAINT ck_waiting_list_entries_window CHECK (preferred_from IS NULL OR preferred_to IS NULL
        OR preferred_from <= preferred_to),
    CONSTRAINT ck_waiting_list_entries_appointment CHECK ((status = 'SCHEDULED') = (appointment_id IS NOT NULL)),
    CONSTRAINT ck_waiting_list_entries_resolution CHECK ((status = 'WAITING') = (resolved_at IS NULL)
        AND (resolved_at IS NULL) = (resolved_by IS NULL)),
    CONSTRAINT ck_waiting_list_entries_version CHECK (version >= 1)
);
CREATE UNIQUE INDEX uk_waiting_list_entries_waiting_patient_dentist ON appointments.waiting_list_entries
    (patient_id, coalesce(dentist_id, '00000000-0000-0000-0000-000000000000'::uuid)) WHERE status = 'WAITING';
CREATE INDEX idx_waiting_list_entries_status_created_at ON appointments.waiting_list_entries
    (status, created_at, entry_id);
