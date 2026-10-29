-- GET /api/v1/appointments query paths (API-APT-01). The partial GiST exclusion covers only active
-- statuses, so it cannot serve calendars that include FINALIZADA or patient/default-order pages.
CREATE INDEX idx_appointments_dentist_id_start_at ON appointments.appointments (dentist_id, start_at);
CREATE INDEX idx_appointments_patient_id_start_at ON appointments.appointments (patient_id, start_at);
CREATE INDEX idx_appointments_created_at_appointment_id ON appointments.appointments (created_at, appointment_id);
