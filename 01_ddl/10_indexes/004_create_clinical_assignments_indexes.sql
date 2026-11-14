-- At most one active ongoing assignment per patient/dentist; ended rows remain as history.
CREATE UNIQUE INDEX uk_clinical_assignments_active_patient_dentist ON appointments.clinical_assignments (patient_id, dentist_id)
    WHERE status = 'ACTIVE';
-- Authorization and list path: current sources by patient, dentist and status.
CREATE INDEX idx_clinical_assignments_patient_id_dentist_id_status ON appointments.clinical_assignments (patient_id, dentist_id, status);
CREATE INDEX idx_clinical_assignments_dentist_id_status ON appointments.clinical_assignments (dentist_id, status);
