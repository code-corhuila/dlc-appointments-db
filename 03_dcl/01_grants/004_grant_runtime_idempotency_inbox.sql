-- Idempotency records are append-only for the runtime; inbox rows may move from FAILED to PROCESSED on retry.
GRANT SELECT, INSERT ON appointments.idempotency_keys TO appointments_runtime;
GRANT SELECT, INSERT, UPDATE ON appointments.inbox_events TO appointments_runtime;
