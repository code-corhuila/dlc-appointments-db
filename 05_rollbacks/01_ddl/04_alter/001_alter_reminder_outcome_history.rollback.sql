-- Restores the DB-05 check; fails while an INVALIDATED reminder keeps delivery history.
ALTER TABLE appointments.appointment_reminders DROP CONSTRAINT ck_appointment_reminders_outcome;
ALTER TABLE appointments.appointment_reminders ADD CONSTRAINT ck_appointment_reminders_outcome CHECK (
    (status IN ('SENT','DELIVERY_FAILED')) = (outcome_at IS NOT NULL)
    AND (status <> 'DELIVERY_FAILED' OR outcome_code IS NOT NULL)
    AND (outcome_code IS NULL OR outcome_code ~ '^[A-Z][A-Z0-9_]{0,63}$'));
