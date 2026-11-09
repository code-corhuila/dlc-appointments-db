-- DB-12 (HU-APT-006): an appointment may name one catalog type; existing rows keep none.
ALTER TABLE appointments.appointments ADD COLUMN type_code text
    CONSTRAINT fk_appointments_type_code REFERENCES appointments.appointment_types (code);
