-- Relay polling path: unpublished events in retry order.
CREATE INDEX idx_outbox_events_next_attempt_at ON appointments.outbox_events (next_attempt_at, recorded_at)
    WHERE status <> 'PUBLISHED';
