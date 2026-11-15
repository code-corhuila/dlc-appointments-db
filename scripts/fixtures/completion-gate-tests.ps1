# Run only from verify-db.ps1 after disposable-fixture validation and migration.
# Reuses Invoke-SqlCaseSuite, New-SqlCase, New-TemplateInsert and Assert-ConstraintCatalog from scheduling-tests.ps1.
function Invoke-CompletionGateTests([string]$Container) {
    $runtime = 'appointments_runtime'
    $now = "'2026-11-04T12:00:00Z'::timestamptz"
    $actor = "'40000000-0000-0000-0000-000000000001'"
    $appointmentId = "'10000000-0000-0000-0000-000000000009'"
    $appointment = New-TemplateInsert 'appointments.appointments' ([ordered]@{ appointment_id=$appointmentId
        patient_id="'20000000-0000-0000-0000-000000000001'"; dentist_id="'30000000-0000-0000-0000-000000000001'"
        start_at="'2030-01-02T14:00:00Z'::timestamptz"; end_at="'2030-01-02T14:30:00Z'::timestamptz"; clinic_timezone="'America/Bogota'"
        reason="'Synthetic fixture'"; status="'EN_ATENCION'"; confirmation_status="'CONFIRMED'"
        reminder_due_at="'2030-01-01T14:00:00Z'::timestamptz"; reminder_status="'SENT'"; version='3'; created_at=$now
        created_by=$actor; updated_at=$now; updated_by=$actor })

    # DB-09 care_completions: one Dentist declaration per appointment, deduplicated by event id, insert-only.
    $C = 'appointments.care_completions'
    Assert-ConstraintCatalog $Container $C 'ck_care_completions_clinical_version:c,ck_care_completions_times:c,fk_care_completions_appointment_id:f,pk_care_completions:p,uk_care_completions_event_id:u'
    $completion = [ordered]@{ appointment_id=$appointmentId; event_id="'e0000000-0000-0000-0000-000000000009'"
        clinical_record_id="'60000000-0000-0000-0000-000000000001'"; consultation_id="'70000000-0000-0000-0000-000000000001'"
        patient_id="'20000000-0000-0000-0000-000000000001'"; dentist_id="'30000000-0000-0000-0000-000000000001'"
        completed_at=$now; clinical_version='1'; recorded_at=$now }
    function Completion($Overrides) { New-TemplateInsert $C $completion $Overrides }
    $base = Completion @{}
    $cases = [Collections.Generic.List[object]]::new()
    $cases.Add((New-SqlCase 'completion-valid' $base '00000' '' @($appointment)))
    $cases.Add((New-SqlCase 'completion-second-for-appointment' (Completion @{event_id="'e0000000-0000-0000-0000-000000000010'"}) '23505' 'pk_care_completions' @($appointment,$base)))
    $cases.Add((New-SqlCase 'completion-orphan-appointment' $base '23503' 'fk_care_completions_appointment_id'))
    $cases.Add((New-SqlCase 'completion-invalid-version' (Completion @{clinical_version='0'}) '23514' 'ck_care_completions_clinical_version' @($appointment)))
    $cases.Add((New-SqlCase 'completion-infinite-time' (Completion @{completed_at="'infinity'"}) '23514' 'ck_care_completions_times' @($appointment)))
    foreach ($column in @($completion.Keys)) { $cases.Add((New-SqlCase "completion-null-$column" (Completion @{$column='NULL'}) '23502' '' @($appointment))) }
    $cases.Add((New-SqlCase 'runtime-insert-completion' $base '00000' '' @($appointment) $runtime))
    foreach ($denied in @("UPDATE $C SET clinical_version=2;","DELETE FROM $C;","TRUNCATE $C;")) {
        $cases.Add((New-SqlCase "runtime-denied-completion-$(($denied -replace '[^A-Za-z_]+','-').Trim('-'))" $denied '42501' '' @($appointment,$base) $runtime))
    }
    Invoke-SqlCaseSuite $Container 'CARE-COMPLETION' $cases @($C,'appointments.appointments')

    # DB-10 patient_gates and patient_guards: ADR-017 gate, token hash only, unique per operation and caller.
    $G = 'appointments.patient_gates'
    $P = 'appointments.patient_guards'
    Assert-ConstraintCatalog $Container $G 'ck_patient_gates_status:c,ck_patient_gates_version:c,pk_patient_gates:p'
    Assert-ConstraintCatalog $Container $P 'ck_patient_guards_caller_service:c,ck_patient_guards_kind:c,ck_patient_guards_resolved:c,ck_patient_guards_state:c,ck_patient_guards_token_hash:c,fk_patient_guards_patient_id:f,pk_patient_guards:p,uk_patient_guards_patient_operation_caller:u'
    $gateRow = [ordered]@{ patient_id="'20000000-0000-0000-0000-000000000001'"; status="'OPEN'"; version='1'; updated_at=$now }
    function Gate($Overrides) { New-TemplateInsert $G $gateRow $Overrides }
    $guardRow = [ordered]@{ guard_id="'b1000000-0000-0000-0000-000000000001'"; patient_id="'20000000-0000-0000-0000-000000000001'"
        operation_id="'c1000000-0000-0000-0000-000000000001'"; caller_service="'clinical-service'"; kind="'ACTIVITY'"; state="'OPEN'"
        token_hash="repeat('a',64)"; created_at=$now; resolved_at='NULL' }
    function Guard($Overrides) { New-TemplateInsert $P $guardRow $Overrides }
    $gate = Gate @{}
    $guard = Guard @{}
    $cases = [Collections.Generic.List[object]]::new()
    foreach ($status in @('OPEN','BLOCKED','INACTIVE')) { $cases.Add((New-SqlCase "gate-$status" (Gate @{status="'$status'"}))) }
    $cases.Add((New-SqlCase 'gate-duplicate' $gate '23505' 'pk_patient_gates' @($gate)))
    $cases.Add((New-SqlCase 'gate-invalid-status' (Gate @{status="'CLOSED'"}) '23514' 'ck_patient_gates_status'))
    $cases.Add((New-SqlCase 'gate-invalid-version' (Gate @{version='0'}) '23514' 'ck_patient_gates_version'))
    foreach ($column in @($gateRow.Keys)) { $cases.Add((New-SqlCase "gate-null-$column" (Gate @{$column='NULL'}) '23502')) }
    $cases.Add((New-SqlCase 'guard-open' $guard '00000' '' @($gate)))
    $cases.Add((New-SqlCase 'guard-deactivation-finalized' (Guard @{kind="'DEACTIVATION'"; caller_service="'patients-service'"; state="'FINALIZED'"; resolved_at=$now}) '00000' '' @($gate)))
    $cases.Add((New-SqlCase 'guard-aborted' (Guard @{state="'ABORTED'"; resolved_at=$now}) '00000' '' @($gate)))
    $cases.Add((New-SqlCase 'guard-same-operation-other-caller' (Guard @{guard_id="'b1000000-0000-0000-0000-000000000002'"; caller_service="'patients-service'"}) '00000' '' @($gate,$guard)))
    $cases.Add((New-SqlCase 'guard-duplicate-operation' (Guard @{guard_id="'b1000000-0000-0000-0000-000000000002'"}) '23505' 'uk_patient_guards_patient_operation_caller' @($gate,$guard)))
    $cases.Add((New-SqlCase 'guard-without-gate' $guard '23503' 'fk_patient_guards_patient_id'))
    $cases.Add((New-SqlCase 'gate-delete-restricted-by-guard' "DELETE FROM $G;" '23503' 'fk_patient_guards_patient_id' @($gate,$guard)))
    foreach ($bad in @(
        @{kind="'READ'"; name='kind'}, @{state="'COMMITTED'"; resolved_at=$now; name='state'}, @{caller_service="'Clinical'"; name='caller_service'},
        @{token_hash="'plain-token'"; name='token_hash'}, @{token_hash="repeat('A',64)"; name='token_hash'},
        @{state="'FINALIZED'"; name='resolved'}, @{resolved_at=$now; name='resolved'},
        @{state="'ABORTED'"; resolved_at="'2026-11-04T11:00:00Z'::timestamptz"; name='resolved'})) {
        $o = @{}; foreach ($field in $bad.Keys) { if ($field -ne 'name') { $o[$field] = $bad[$field] } }
        $cases.Add((New-SqlCase "guard-invalid-$($bad.name)-$($cases.Count)" (Guard $o) '23514' "ck_patient_guards_$($bad.name)" @($gate)))
    }
    foreach ($column in @('guard_id','patient_id','operation_id','caller_service','kind','state','token_hash','created_at')) {
        $cases.Add((New-SqlCase "guard-null-$column" (Guard @{$column='NULL'}) '23502' '' @($gate)))
    }
    $cases.Add((New-SqlCase 'runtime-insert-gate-guard' "$gate $guard" '00000' '' @() $runtime))
    $cases.Add((New-SqlCase 'runtime-block-gate' "UPDATE $G SET status='BLOCKED', version=2;" '00000' '' @($gate) $runtime))
    $cases.Add((New-SqlCase 'runtime-rotate-and-resolve-guard' "UPDATE $P SET token_hash=repeat('b',64), state='FINALIZED', resolved_at=now();" '00000' '' @($gate,$guard) $runtime))
    foreach ($denied in @("DELETE FROM $P;","DELETE FROM $G;","TRUNCATE $P;","ALTER TABLE $G ADD COLUMN notes text;")) {
        $cases.Add((New-SqlCase "runtime-denied-gate-$(($denied -replace '[^A-Za-z_]+','-').Trim('-'))" $denied '42501' '' @($gate,$guard) $runtime))
    }
    Invoke-SqlCaseSuite $Container 'PATIENT-GATE' $cases @($G,$P)

    # DB-11: a delivered reminder can be invalidated by a reschedule and keep its delivery history.
    $R = 'appointments.appointment_reminders'
    $sent = New-TemplateInsert $R ([ordered]@{ reminder_id="'a0000000-0000-0000-0000-000000000009'"; appointment_id=$appointmentId
        appointment_version='1'; due_at="'2030-01-01T14:00:00Z'::timestamptz"; channel="'EMAIL'"; status="'SENT'"; attempts='1'
        delivery_id="'b0000000-0000-0000-0000-000000000009'"; outcome_code='NULL'; outcome_at=$now; invalidated_at='NULL'
        created_at=$now; updated_at=$now })
    $next = "INSERT INTO $R (reminder_id,appointment_id,appointment_version,due_at,channel,status,attempts,delivery_id,outcome_code,outcome_at,invalidated_at,created_at,updated_at) VALUES ('a0000000-0000-0000-0000-000000000010',$appointmentId,2,'2030-01-05T14:00:00Z','EMAIL','PENDING',0,NULL,NULL,NULL,NULL,$now,$now);"
    $cases = [Collections.Generic.List[object]]::new()
    $cases.Add((New-SqlCase 'reminder-invalidate-sent-keeps-history' "UPDATE $R SET status='INVALIDATED', invalidated_at=now();" '00000' '' @($appointment,$sent) $runtime))
    $cases.Add((New-SqlCase 'reminder-new-version-after-invalidated-sent' $next '00000' '' @($appointment,$sent,"UPDATE $R SET status='INVALIDATED', invalidated_at=now();") $runtime))
    $cases.Add((New-SqlCase 'reminder-sent-still-needs-outcome' "UPDATE $R SET outcome_at=NULL;" '23514' 'ck_appointment_reminders_outcome' @($appointment,$sent)))
    $cases.Add((New-SqlCase 'reminder-pending-cannot-carry-outcome' "UPDATE $R SET status='PENDING', delivery_id=NULL;" '23514' 'ck_appointment_reminders_outcome' @($appointment,$sent)))
    Invoke-SqlCaseSuite $Container 'REMINDER-HISTORY' $cases @($R,'appointments.appointments')
}
