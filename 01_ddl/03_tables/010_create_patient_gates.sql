-- DB-10 (D9, ADR-017): per-patient gate that serializes guards with scheduling commits; a missing row means OPEN.
CREATE TABLE appointments.patient_gates (
    patient_id uuid NOT NULL CONSTRAINT pk_patient_gates PRIMARY KEY,
    status text NOT NULL,
    version integer NOT NULL,
    updated_at timestamptz NOT NULL,
    CONSTRAINT ck_patient_gates_status CHECK (status IN ('OPEN','BLOCKED','INACTIVE')),
    CONSTRAINT ck_patient_gates_version CHECK (version >= 1)
);
