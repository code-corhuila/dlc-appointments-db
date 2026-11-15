-- DB-11 (D10): a reschedule may invalidate a delivered reminder; the INVALIDATED row keeps its delivery history.
-- SENT/DELIVERY_FAILED still require outcome_at; PENDING/REQUESTED still carry none.
ALTER TABLE appointments.appointment_reminders DROP CONSTRAINT ck_appointment_reminders_outcome;
ALTER TABLE appointments.appointment_reminders ADD CONSTRAINT ck_appointment_reminders_outcome CHECK (
    (CASE WHEN status IN ('SENT','DELIVERY_FAILED') THEN outcome_at IS NOT NULL
          WHEN status = 'INVALIDATED' THEN true
          ELSE outcome_at IS NULL END)
    AND (status <> 'DELIVERY_FAILED' OR outcome_code IS NOT NULL)
    AND (outcome_code IS NULL OR outcome_code ~ '^[A-Z][A-Z0-9_]{0,63}$'));
