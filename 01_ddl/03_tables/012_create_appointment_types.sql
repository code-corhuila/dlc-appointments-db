-- DB-12 (HU-APT-006, APT-014): appointment-type catalog for scheduling and the calendar legend; migration-owned.
CREATE TABLE appointments.appointment_types (
    code text NOT NULL CONSTRAINT pk_appointment_types PRIMARY KEY,
    label text NOT NULL,
    color text NOT NULL,
    active boolean NOT NULL,
    sort_order integer NOT NULL,
    CONSTRAINT ck_appointment_types_code CHECK (code ~ '^[A-Z][A-Z_]{1,31}$'),
    CONSTRAINT ck_appointment_types_label CHECK (length(btrim(label)) BETWEEN 1 AND 60),
    CONSTRAINT ck_appointment_types_color CHECK (color ~ '^#[0-9A-F]{6}$'),
    CONSTRAINT ck_appointment_types_sort_order CHECK (sort_order >= 0)
);
