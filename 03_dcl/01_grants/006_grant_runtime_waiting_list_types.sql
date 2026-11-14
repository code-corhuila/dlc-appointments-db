-- DB-12/13: the runtime reads the catalog and creates/resolves waiting entries; no DELETE or catalog writes.
GRANT SELECT ON appointments.appointment_types TO appointments_runtime;
GRANT SELECT, INSERT, UPDATE ON appointments.waiting_list_entries TO appointments_runtime;
