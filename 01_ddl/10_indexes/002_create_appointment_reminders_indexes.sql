-- At most one live reminder per appointment; stale versions are INVALIDATED and cannot be revived beside it.
CREATE UNIQUE INDEX uk_appointment_reminders_live_appointment_id ON appointments.appointment_reminders (appointment_id)
    WHERE status <> 'INVALIDATED';
-- Due-reminder polling path.
CREATE INDEX idx_appointment_reminders_due_at ON appointments.appointment_reminders (due_at)
    WHERE status = 'PENDING';
