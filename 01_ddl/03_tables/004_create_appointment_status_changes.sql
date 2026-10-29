-- Immutable lifecycle audit: one row per accepted appointment version change. Runtime may only INSERT/SELECT.
CREATE TABLE appointments.appointment_status_changes (
    change_id uuid NOT NULL CONSTRAINT pk_appointment_status_changes PRIMARY KEY,
    appointment_id uuid NOT NULL CONSTRAINT fk_appointment_status_changes_appointment_id
        REFERENCES appointments.appointments (appointment_id) ON DELETE RESTRICT,
    appointment_version integer NOT NULL,
    operation text NOT NULL,
    from_status text,
    to_status text NOT NULL,
    previous_start_at timestamptz,
    previous_end_at timestamptz,
    new_start_at timestamptz,
    new_end_at timestamptz,
    reason text,
    override boolean NOT NULL,
    actor_id uuid NOT NULL,
    actor_role text NOT NULL,
    correlation_id uuid NOT NULL,
    occurred_at timestamptz NOT NULL,
    CONSTRAINT uk_appointment_status_changes_appointment_version UNIQUE (appointment_id, appointment_version),
    CONSTRAINT ck_appointment_status_changes_version CHECK (appointment_version >= 1),
    CONSTRAINT ck_appointment_status_changes_transition CHECK (
        (operation, coalesce(from_status, '-'), to_status) IN (
            ('SCHEDULE', '-', 'PROGRAMADA'),
            ('CONFIRM', 'PROGRAMADA', 'CONFIRMADA'),
            ('CANCEL', 'PROGRAMADA', 'CANCELADA'), ('CANCEL', 'CONFIRMADA', 'CANCELADA'),
            ('RESCHEDULE', 'PROGRAMADA', 'PROGRAMADA'), ('RESCHEDULE', 'CONFIRMADA', 'PROGRAMADA'),
            ('START_ATTENTION', 'CONFIRMADA', 'EN_ATENCION'),
            ('NO_SHOW', 'PROGRAMADA', 'NO_ASISTIO'), ('NO_SHOW', 'CONFIRMADA', 'NO_ASISTIO'),
            ('COMPLETE', 'EN_ATENCION', 'FINALIZADA'))),
    CONSTRAINT ck_appointment_status_changes_schedule_version CHECK ((operation = 'SCHEDULE') = (appointment_version = 1)),
    CONSTRAINT ck_appointment_status_changes_interval CHECK (
        CASE WHEN operation = 'RESCHEDULE' THEN
            previous_start_at IS NOT NULL AND previous_end_at IS NOT NULL AND new_start_at IS NOT NULL AND new_end_at IS NOT NULL
            AND isfinite(new_start_at) AND isfinite(new_end_at) AND new_start_at < new_end_at
            AND (previous_start_at, previous_end_at) IS DISTINCT FROM (new_start_at, new_end_at)
        ELSE num_nonnulls(previous_start_at, previous_end_at, new_start_at, new_end_at) = 0 END),
    CONSTRAINT ck_appointment_status_changes_reason CHECK (
        (reason IS NULL OR char_length(reason) BETWEEN 1 AND 1000)
        AND (operation <> 'CANCEL' OR reason IS NOT NULL)
        AND (NOT override OR reason IS NOT NULL)),
    CONSTRAINT ck_appointment_status_changes_override CHECK (NOT override OR (operation IN ('CANCEL','RESCHEDULE') AND actor_role = 'ADMINISTRATOR')),
    CONSTRAINT ck_appointment_status_changes_actor_role CHECK (actor_role IN ('ADMINISTRATOR','SECRETARY_ASSISTANT'))
);
