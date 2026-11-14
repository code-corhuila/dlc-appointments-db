ALTER TABLE appointments.idempotency_keys DROP CONSTRAINT ck_idempotency_keys_resource_type;
ALTER TABLE appointments.idempotency_keys ADD CONSTRAINT ck_idempotency_keys_resource_type
    CHECK (resource_type IN ('Appointment','ClinicalAssignment','DentistSchedule'));
