-- DB-08: consumer inbox; the row commits with the event's effect, so a redelivered event_id has no second effect.
-- Only identifiers and a safe error code are kept; event content is never copied here.
CREATE TABLE appointments.inbox_events (
    event_id uuid NOT NULL CONSTRAINT pk_inbox_events PRIMARY KEY,
    event_type text NOT NULL,
    event_version integer NOT NULL,
    producer text NOT NULL,
    aggregate_id uuid NOT NULL,
    correlation_id uuid NOT NULL,
    received_at timestamptz NOT NULL,
    processed_at timestamptz,
    status text NOT NULL,
    last_error_code text,
    CONSTRAINT ck_inbox_events_event_type CHECK (event_type ~ '^[A-Z][A-Za-z]{2,99}$'),
    CONSTRAINT ck_inbox_events_event_version CHECK (event_version >= 1),
    CONSTRAINT ck_inbox_events_producer CHECK (producer ~ '^[a-z][a-z-]{2,63}$'),
    CONSTRAINT ck_inbox_events_status CHECK (status IN ('PROCESSED','FAILED')),
    CONSTRAINT ck_inbox_events_processed CHECK ((status = 'PROCESSED') = (processed_at IS NOT NULL)),
    CONSTRAINT ck_inbox_events_error_code CHECK (last_error_code IS NULL OR last_error_code ~ '^[A-Z][A-Z0-9_]{0,63}$')
);
