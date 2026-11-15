-- DB-13 (HU-APT-005): waiting-list writes record their Idempotency-Key like the other owner resources.
ALTER TABLE appointments.idempotency_keys DROP CONSTRAINT ck_idempotency_keys_resource_type;
ALTER TABLE appointments.idempotency_keys ADD CONSTRAINT ck_idempotency_keys_resource_type
    CHECK (resource_type IN ('Appointment','ClinicalAssignment','DentistSchedule','WaitingListEntry'));
