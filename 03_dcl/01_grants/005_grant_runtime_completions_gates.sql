-- Declarations are insert-only for the runtime; gates and guards change state but are never deleted.
GRANT SELECT, INSERT ON appointments.care_completions TO appointments_runtime;
GRANT SELECT, INSERT, UPDATE ON appointments.patient_gates TO appointments_runtime;
GRANT SELECT, INSERT, UPDATE ON appointments.patient_guards TO appointments_runtime;
