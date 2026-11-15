-- DB-10 (D9, ADR-017): deactivation and activity guards, idempotent by patient, operationId and caller.
-- Only the SHA-256 hash of the current token is stored; guards never expire by time.
CREATE TABLE appointments.patient_guards (
    guard_id uuid NOT NULL CONSTRAINT pk_patient_guards PRIMARY KEY,
    patient_id uuid NOT NULL CONSTRAINT fk_patient_guards_patient_id
        REFERENCES appointments.patient_gates (patient_id) ON DELETE RESTRICT,
    operation_id uuid NOT NULL,
    caller_service text NOT NULL,
    kind text NOT NULL,
    state text NOT NULL,
    token_hash text NOT NULL,
    created_at timestamptz NOT NULL,
    resolved_at timestamptz,
    CONSTRAINT uk_patient_guards_patient_operation_caller UNIQUE (patient_id, operation_id, caller_service),
    CONSTRAINT ck_patient_guards_caller_service CHECK (caller_service ~ '^[a-z][a-z-]{2,63}$'),
    CONSTRAINT ck_patient_guards_kind CHECK (kind IN ('DEACTIVATION','ACTIVITY')),
    CONSTRAINT ck_patient_guards_state CHECK (state IN ('OPEN','FINALIZED','ABORTED')),
    CONSTRAINT ck_patient_guards_token_hash CHECK (token_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ck_patient_guards_resolved CHECK ((state <> 'OPEN') = (resolved_at IS NOT NULL)
        AND (resolved_at IS NULL OR resolved_at >= created_at))
);
