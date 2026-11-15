-- appointments_runtime is provisioned externally; it receives DML only, never DDL or DELETE on audit-bearing rows.
GRANT USAGE ON SCHEMA appointments TO appointments_runtime;
GRANT SELECT, INSERT, UPDATE ON appointments.appointments, appointments.dentist_schedules, appointments.outbox_events TO appointments_runtime;
GRANT SELECT, INSERT, DELETE ON appointments.availability_intervals, appointments.blocked_intervals TO appointments_runtime;
