\set ON_ERROR_STOP on
-- HU-APT-005 / HU-APT-006 (APT-013, APT-014): waiting list, appointment-type catalog and appointments.type_code.
-- Run on a disposable database after the migration; everything is rolled back.
BEGIN;
DO $$
BEGIN
  IF (SELECT count(*) FROM appointments.appointment_types WHERE active) < 6 THEN
    RAISE EXCEPTION 'Seeded appointment types are missing';
  END IF;
  IF EXISTS (SELECT 1 FROM appointments.appointment_types WHERE color !~ '^#[0-9A-F]{6}$') THEN
    RAISE EXCEPTION 'A seeded type colour is not #RRGGBB';
  END IF;
END $$;

SET LOCAL ROLE appointments_runtime;
INSERT INTO appointments.waiting_list_entries
  (entry_id, patient_id, dentist_id, reason, preferred_from, preferred_to, status, created_at, created_by, version)
VALUES ('91000000-0000-4000-8000-000000000001', '92000000-0000-4000-8000-000000000001',
        '93000000-0000-4000-8000-000000000001', 'Limpieza', DATE '2026-11-10', DATE '2026-11-20', 'WAITING',
        now(), '94000000-0000-4000-8000-000000000001', 1);
DO $$
BEGIN
  BEGIN
    INSERT INTO appointments.waiting_list_entries
      (entry_id, patient_id, dentist_id, reason, status, created_at, created_by, version)
    VALUES ('91000000-0000-4000-8000-000000000002', '92000000-0000-4000-8000-000000000001',
            '93000000-0000-4000-8000-000000000001', 'Otra', 'WAITING', now(),
            '94000000-0000-4000-8000-000000000001', 1);
    RAISE EXCEPTION 'Two WAITING entries for one patient and dentist were accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    UPDATE appointments.waiting_list_entries SET status = 'SCHEDULED', resolved_at = now(),
      resolved_by = '94000000-0000-4000-8000-000000000001', version = 2
     WHERE entry_id = '91000000-0000-4000-8000-000000000001';
    RAISE EXCEPTION 'SCHEDULED without an appointment was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO appointments.waiting_list_entries
      (entry_id, patient_id, reason, preferred_from, preferred_to, status, created_at, created_by, version)
    VALUES ('91000000-0000-4000-8000-000000000003', '92000000-0000-4000-8000-000000000002', 'x',
            DATE '2026-11-20', DATE '2026-11-10', 'WAITING', now(), '94000000-0000-4000-8000-000000000001', 1);
    RAISE EXCEPTION 'A reversed preferred window was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    DELETE FROM appointments.waiting_list_entries;
    RAISE EXCEPTION 'The runtime role can delete waiting-list entries';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO appointments.appointment_types (code, label, color, active, sort_order)
    VALUES ('NUEVO', 'Nuevo', '#000000', true, 99);
    RAISE EXCEPTION 'The runtime role can change the type catalog';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
-- A withdrawn entry frees the slot for a new WAITING entry.
UPDATE appointments.waiting_list_entries SET status = 'WITHDRAWN', resolved_at = now(),
  resolved_by = '94000000-0000-4000-8000-000000000001', version = 2
 WHERE entry_id = '91000000-0000-4000-8000-000000000001';
INSERT INTO appointments.waiting_list_entries
  (entry_id, patient_id, dentist_id, reason, status, created_at, created_by, version)
VALUES ('91000000-0000-4000-8000-000000000004', '92000000-0000-4000-8000-000000000001',
        '93000000-0000-4000-8000-000000000001', 'De nuevo', 'WAITING', now(),
        '94000000-0000-4000-8000-000000000001', 1);
INSERT INTO appointments.idempotency_keys
  (actor_user_id, operation, idempotency_key, request_hash, resource_type, resource_id, response_status, created_at)
VALUES ('94000000-0000-4000-8000-000000000001', 'CREATE_WAITING_LIST_ENTRY', 'wait-key-0001', repeat('a', 64),
        'WaitingListEntry', '91000000-0000-4000-8000-000000000004', 201, now());
RESET ROLE;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'appointments'
                   AND table_name = 'appointments' AND column_name = 'type_code' AND is_nullable = 'YES') THEN
    RAISE EXCEPTION 'appointments.type_code is missing or not nullable';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_appointments_type_code') THEN
    RAISE EXCEPTION 'appointments.type_code does not reference the type catalog';
  END IF;
END $$;
ROLLBACK;
