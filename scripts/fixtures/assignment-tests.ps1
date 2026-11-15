# Run only from verify-db.ps1 after disposable-fixture validation and migration.
# Reuses Invoke-SqlCaseSuite, New-SqlCase, New-TemplateInsert and Assert-ConstraintCatalog from scheduling-tests.ps1.
function Invoke-AssignmentTests([string]$Container) {
    $T = 'appointments.clinical_assignments'
    $staff = "'40000000-0000-0000-0000-000000000001'"
    $dentist = "'30000000-0000-0000-0000-000000000001'"
    $assignment = [ordered]@{ assignment_id="'c0000000-0000-0000-0000-000000000001'"; patient_id="'20000000-0000-0000-0000-000000000001'"
        dentist_id=$dentist; status="'ACTIVE'"; reason="'Ongoing orthodontic follow-up'"; started_at="'2026-10-28T12:00:00Z'::timestamptz"
        started_by=$staff; ended_at='NULL'; ended_by='NULL'; end_reason='NULL'; version='1' }
    $ended = @{status="'ENDED'"; ended_at="'2026-11-28T12:00:00Z'"; ended_by=$staff; end_reason="'Treatment plan closed'"; version='2'}

    Assert-ConstraintCatalog $Container $T 'ck_clinical_assignments_ended:c,ck_clinical_assignments_reason:c,ck_clinical_assignments_self_assignment:c,ck_clinical_assignments_status:c,ck_clinical_assignments_version:c,pk_clinical_assignments:p'

    function Assignment($Overrides) { New-TemplateInsert $T $assignment $Overrides }
    function Join-Fixture($Base, $Overrides) { $merged = @{}; foreach ($h in @($Base,$Overrides)) { foreach ($k in $h.Keys) { $merged[$k] = $h[$k] } }; $merged }
    $base = Assignment @{}
    $second = @{assignment_id="'c0000000-0000-0000-0000-000000000002'"}
    $cases = [Collections.Generic.List[object]]::new()
    $cases.Add((New-SqlCase 'assignment-active' $base))
    $cases.Add((New-SqlCase 'assignment-ended' (Assignment $ended)))
    $cases.Add((New-SqlCase 'assignment-second-active-same-pair' (Assignment $second) '23505' 'uk_clinical_assignments_active_patient_dentist' @($base)))
    $cases.Add((New-SqlCase 'assignment-new-active-after-ending' (Assignment $second) '00000' '' @((Assignment $ended))))
    $cases.Add((New-SqlCase 'assignment-other-dentist-same-patient' (Assignment (Join-Fixture $second @{dentist_id="'30000000-0000-0000-0000-000000000002'"})) '00000' '' @($base)))
    $cases.Add((New-SqlCase 'assignment-end-in-place' "UPDATE $T SET status='ENDED', ended_at='2026-11-28T12:00:00Z', ended_by=$staff, end_reason='Treatment plan closed', version=2;" '00000' '' @($base)))
    $cases.Add((New-SqlCase 'assignment-reactivate-conflict' "UPDATE $T SET status='ACTIVE', ended_at=NULL, ended_by=NULL, end_reason=NULL, version=3 WHERE assignment_id='c0000000-0000-0000-0000-000000000001';" '23505' 'uk_clinical_assignments_active_patient_dentist' @((Assignment $ended),(Assignment $second))))
    $cases.Add((New-SqlCase 'assignment-self-assignment' (Assignment @{started_by=$dentist}) '23514' 'ck_clinical_assignments_self_assignment'))
    foreach ($bad in @(
        @{status="'ENDED'"; version='2'; name='ended'}, @{ended_at="'2026-11-28T12:00:00Z'"; name='ended'}, @{end_reason="'x'"; name='ended'},
        @{name='ended'; status="'ENDED'"; ended_at="'2026-10-01T12:00:00Z'"; ended_by=$staff; end_reason="'x'"; version='2'},
        @{name='ended'; status="'ENDED'"; ended_at="'2026-11-28T12:00:00Z'"; ended_by=$staff; end_reason="''"; version='2'},
        @{name='ended'; status="'ENDED'"; ended_at="'2026-11-28T12:00:00Z'"; ended_by=$staff; end_reason="'x'"; version='1'},
        @{status="'REVOKED'"; name='status'}, @{reason="''"; name='reason'}, @{reason="repeat('x',1001)"; name='reason'}, @{version='0'; name='version'})) {
        $o = @{}; foreach ($key in $bad.Keys) { if ($key -ne 'name') { $o[$key] = $bad[$key] } }
        $cases.Add((New-SqlCase "assignment-invalid-$($bad.name)-$(@($o.Keys | Sort-Object) -join '-')-$($cases.Count)" (Assignment $o) '23514' "ck_clinical_assignments_$($bad.name)"))
    }
    foreach ($column in @('assignment_id','patient_id','dentist_id','status','reason','started_at','started_by','version')) {
        $cases.Add((New-SqlCase "assignment-null-$column" (Assignment @{$column='NULL'}) '23502'))
    }

    # Runtime role: create and end in place; never delete relationship history.
    $runtime = 'appointments_runtime'
    $cases.Add((New-SqlCase 'runtime-insert-assignment' $base '00000' '' @() $runtime))
    $cases.Add((New-SqlCase 'runtime-end-assignment' "UPDATE $T SET status='ENDED', ended_at=now(), ended_by=$staff, end_reason='Closed', version=2;" '00000' '' @($base) $runtime))
    foreach ($denied in @("DELETE FROM $T;","TRUNCATE $T;","ALTER TABLE $T ADD COLUMN notes text;")) {
        $cases.Add((New-SqlCase "runtime-denied-$(($denied -replace '[^A-Za-z_]+','-').Trim('-'))" $denied '42501' '' @($base) $runtime))
    }
    Invoke-SqlCaseSuite $Container 'ASSIGNMENT' $cases @($T)
}
