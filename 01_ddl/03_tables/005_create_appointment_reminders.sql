-- Versioned reminder work: stale worker outcomes match neither the current version nor a live row.
CREATE TABLE appointments.appointment_reminders (
    reminder_id uuid NOT NULL CONSTRAINT pk_appointment_reminders PRIMARY KEY,
    appointment_id uuid NOT NULL CONSTRAINT fk_appointment_reminders_appointment_id
        REFERENCES appointments.appointments (appointment_id) ON DELETE RESTRICT,
    appointment_version integer NOT NULL,
    due_at timestamptz NOT NULL,
    channel text NOT NULL,
    status text NOT NULL,
    attempts integer NOT NULL,
    delivery_id uuid,
    outcome_code text,
    outcome_at timestamptz,
    invalidated_at timestamptz,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    CONSTRAINT uk_appointment_reminders_appointment_version UNIQUE (appointment_id, appointment_version),
    CONSTRAINT uk_appointment_reminders_delivery_id UNIQUE (delivery_id),
    CONSTRAINT ck_appointment_reminders_version CHECK (appointment_version >= 1),
    CONSTRAINT ck_appointment_reminders_due CHECK (isfinite(due_at)),
    CONSTRAINT ck_appointment_reminders_channel CHECK (channel = 'EMAIL'),
    CONSTRAINT ck_appointment_reminders_status CHECK (status IN ('PENDING','REQUESTED','SENT','DELIVERY_FAILED','INVALIDATED')),
    CONSTRAINT ck_appointment_reminders_attempts CHECK (attempts >= 0),
    CONSTRAINT ck_appointment_reminders_outcome CHECK (
        (status IN ('SENT','DELIVERY_FAILED')) = (outcome_at IS NOT NULL)
        AND (status <> 'DELIVERY_FAILED' OR outcome_code IS NOT NULL)
        AND (outcome_code IS NULL OR outcome_code ~ '^[A-Z][A-Z0-9_]{0,63}$')),
    CONSTRAINT ck_appointment_reminders_invalidated CHECK ((status = 'INVALIDATED') = (invalidated_at IS NOT NULL)),
    CONSTRAINT ck_appointment_reminders_requested CHECK (status IN ('PENDING','INVALIDATED') OR delivery_id IS NOT NULL)
);
