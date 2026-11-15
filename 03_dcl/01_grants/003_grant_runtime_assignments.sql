-- Assignments are created and ended in place; relationship history is never deleted by the runtime role.
GRANT SELECT, INSERT, UPDATE ON appointments.clinical_assignments TO appointments_runtime;
