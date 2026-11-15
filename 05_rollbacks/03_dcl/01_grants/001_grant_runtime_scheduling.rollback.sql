REVOKE ALL ON appointments.availability_intervals, appointments.blocked_intervals FROM appointments_runtime;
REVOKE ALL ON appointments.appointments, appointments.dentist_schedules, appointments.outbox_events FROM appointments_runtime;
REVOKE USAGE ON SCHEMA appointments FROM appointments_runtime;
