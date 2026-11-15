-- Relationship metadata only: no clinical narrative. Ending preserves the row with its audit pair.
CREATE TABLE appointments.clinical_assignments (
    assignment_id uuid NOT NULL CONSTRAINT pk_clinical_assignments PRIMARY KEY,
    patient_id uuid NOT NULL,
    dentist_id uuid NOT NULL,
    status text NOT NULL,
    reason text NOT NULL,
    started_at timestamptz NOT NULL,
    started_by uuid NOT NULL,
    ended_at timestamptz,
    ended_by uuid,
    end_reason text,
    version integer NOT NULL,
    CONSTRAINT ck_clinical_assignments_status CHECK (status IN ('ACTIVE','ENDED')),
    CONSTRAINT ck_clinical_assignments_reason CHECK (char_length(reason) BETWEEN 1 AND 1000),
    CONSTRAINT ck_clinical_assignments_version CHECK (version >= 1),
    CONSTRAINT ck_clinical_assignments_ended CHECK (
        CASE WHEN status = 'ENDED' THEN
            ended_at IS NOT NULL AND ended_by IS NOT NULL AND end_reason IS NOT NULL
            AND char_length(end_reason) BETWEEN 1 AND 1000 AND ended_at >= started_at AND version >= 2
        ELSE num_nonnulls(ended_at, ended_by, end_reason) = 0 END),
    CONSTRAINT ck_clinical_assignments_self_assignment CHECK (started_by <> dentist_id)
);
