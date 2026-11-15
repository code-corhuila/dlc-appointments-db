REVOKE SELECT, INSERT, UPDATE ON appointments.patient_guards FROM appointments_runtime;
REVOKE SELECT, INSERT, UPDATE ON appointments.patient_gates FROM appointments_runtime;
REVOKE SELECT, INSERT ON appointments.care_completions FROM appointments_runtime;
