-- DB-08: Norma 5.3.8 idempotency records, written in the transaction of the business change they protect.
-- Append-only: a replay with the same request_hash returns resource_id; a different hash is a conflict.
CREATE TABLE appointments.idempotency_keys (
    actor_user_id uuid NOT NULL,
    operation text NOT NULL,
    idempotency_key text NOT NULL,
    request_hash text NOT NULL,
    resource_type text NOT NULL,
    resource_id uuid NOT NULL,
    response_status integer NOT NULL,
    created_at timestamptz NOT NULL,
    CONSTRAINT pk_idempotency_keys PRIMARY KEY (actor_user_id, operation, idempotency_key),
    CONSTRAINT ck_idempotency_keys_operation CHECK (operation ~ '^[A-Z][A-Z_]{2,63}$'),
    CONSTRAINT ck_idempotency_keys_idempotency_key CHECK (char_length(idempotency_key) BETWEEN 8 AND 128),
    CONSTRAINT ck_idempotency_keys_request_hash CHECK (request_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ck_idempotency_keys_resource_type CHECK (resource_type IN ('Appointment','ClinicalAssignment','DentistSchedule')),
    CONSTRAINT ck_idempotency_keys_response_status CHECK (response_status IN (200, 201))
);
