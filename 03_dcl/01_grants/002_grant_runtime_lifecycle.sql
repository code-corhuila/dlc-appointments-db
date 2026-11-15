-- Lifecycle audit is insert-only for the runtime role; reminder work is updated in place, never deleted.
GRANT SELECT, INSERT ON appointments.appointment_status_changes TO appointments_runtime;
GRANT SELECT, INSERT, UPDATE ON appointments.appointment_reminders TO appointments_runtime;
