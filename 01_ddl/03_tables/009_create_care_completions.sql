-- DB-09 (D8): the Dentist's ClinicalCareCompleted declaration, one per appointment and deduplicated by event id.
-- Identifiers only: procedure and manual-charge lists stay with Clinical/Billing; never updated or deleted.
CREATE TABLE appointments.care_completions (
    appointment_id uuid NOT NULL CONSTRAINT pk_care_completions PRIMARY KEY
        CONSTRAINT fk_care_completions_appointment_id REFERENCES appointments.appointments (appointment_id) ON DELETE RESTRICT,
    event_id uuid NOT NULL CONSTRAINT uk_care_completions_event_id UNIQUE,
    clinical_record_id uuid NOT NULL,
    consultation_id uuid NOT NULL,
    patient_id uuid NOT NULL,
    dentist_id uuid NOT NULL,
    completed_at timestamptz NOT NULL,
    clinical_version integer NOT NULL,
    recorded_at timestamptz NOT NULL,
    CONSTRAINT ck_care_completions_clinical_version CHECK (clinical_version >= 1),
    CONSTRAINT ck_care_completions_times CHECK (isfinite(completed_at) AND isfinite(recorded_at))
);
