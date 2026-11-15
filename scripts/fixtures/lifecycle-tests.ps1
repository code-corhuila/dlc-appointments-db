# Run only from verify-db.ps1 after disposable-fixture validation and migration.
# Reuses Invoke-SqlCaseSuite, New-SqlCase, New-TemplateInsert and Assert-ConstraintCatalog from scheduling-tests.ps1.
function Invoke-LifecycleTests([string]$Container) {
    $actor = "'40000000-0000-0000-0000-000000000001'"
    $now = "'2026-10-28T12:00:00Z'::timestamptz"
    $appointmentId = "'10000000-0000-0000-0000-000000000001'"
    $appointment = [ordered]@{ appointment_id=$appointmentId; patient_id="'20000000-0000-0000-0000-000000000001'"
        dentist_id="'30000000-0000-0000-0000-000000000001'"; start_at="'2030-01-02T14:00:00Z'::timestamptz"; end_at="'2030-01-02T14:30:00Z'::timestamptz"
        clinic_timezone="'America/Bogota'"; reason="'Synthetic fixture'"; status="'PROGRAMADA'"; confirmation_status="'PENDING'"
        reminder_due_at="'2030-01-01T14:00:00Z'::timestamptz"; reminder_status="'PENDING'"; version='1'; created_at=$now
        created_by=$actor; updated_at=$now; updated_by=$actor }
    $change = [ordered]@{ change_id="'90000000-0000-0000-0000-000000000001'"; appointment_id=$appointmentId; appointment_version='1'
        operation="'SCHEDULE'"; from_status='NULL'; to_status="'PROGRAMADA'"; previous_start_at='NULL'; previous_end_at='NULL'
        new_start_at='NULL'; new_end_at='NULL'; reason='NULL'; override='false'; actor_id=$actor; actor_role="'SECRETARY_ASSISTANT'"
        correlation_id="'80000000-0000-0000-0000-000000000001'"; occurred_at=$now }
    $reminder = [ordered]@{ reminder_id="'a0000000-0000-0000-0000-000000000001'"; appointment_id=$appointmentId; appointment_version='1'
        due_at="'2030-01-01T14:00:00Z'::timestamptz"; channel="'EMAIL'"; status="'PENDING'"; attempts='0'; delivery_id='NULL'
        outcome_code='NULL'; outcome_at='NULL'; invalidated_at='NULL'; created_at=$now; updated_at=$now }

    Assert-ConstraintCatalog $Container 'appointments.appointment_status_changes' 'ck_appointment_status_changes_actor_role:c,ck_appointment_status_changes_interval:c,ck_appointment_status_changes_override:c,ck_appointment_status_changes_reason:c,ck_appointment_status_changes_schedule_version:c,ck_appointment_status_changes_transition:c,ck_appointment_status_changes_version:c,fk_appointment_status_changes_appointment_id:f,pk_appointment_status_changes:p,uk_appointment_status_changes_appointment_version:u'
    Assert-ConstraintCatalog $Container 'appointments.appointment_reminders' 'ck_appointment_reminders_attempts:c,ck_appointment_reminders_channel:c,ck_appointment_reminders_due:c,ck_appointment_reminders_invalidated:c,ck_appointment_reminders_outcome:c,ck_appointment_reminders_requested:c,ck_appointment_reminders_status:c,ck_appointment_reminders_version:c,fk_appointment_reminders_appointment_id:f,pk_appointment_reminders:p,uk_appointment_reminders_appointment_version:u,uk_appointment_reminders_delivery_id:u'

    $seed = New-TemplateInsert 'appointments.appointments' $appointment
    $T = 'appointments.appointment_status_changes'
    $R = 'appointments.appointment_reminders'
    $cases = [Collections.Generic.List[object]]::new()
    function Join-Fixture($Base, $Overrides) { $merged = @{}; foreach ($h in @($Base,$Overrides)) { foreach ($k in $h.Keys) { $merged[$k] = $h[$k] } }; $merged }
    function Change($Overrides) { New-TemplateInsert $T $change $Overrides }
    function Next($Operation, $From, $To, $Extra = @{}) {
        Change (@{change_id="'90000000-0000-0000-0000-000000000002'"; appointment_version='2'; operation="'$Operation'"; from_status="'$From'"; to_status="'$To'"} + $Extra)
    }
    $resched = @{previous_start_at="'2030-01-02T14:00:00Z'"; previous_end_at="'2030-01-02T14:30:00Z'"; new_start_at="'2030-01-03T14:00:00Z'"; new_end_at="'2030-01-03T14:30:00Z'"}
    $cases.Add((New-SqlCase 'change-schedule' (Change @{}) '00000' '' @($seed)))
    foreach ($ok in @(
        @('CONFIRM','PROGRAMADA','CONFIRMADA',@{}), @('CANCEL','CONFIRMADA','CANCELADA',@{reason="'Patient called the clinic'"}),
        @('RESCHEDULE','CONFIRMADA','PROGRAMADA',$resched), @('START_ATTENTION','CONFIRMADA','EN_ATENCION',@{}),
        @('NO_SHOW','PROGRAMADA','NO_ASISTIO',@{}), @('COMPLETE','EN_ATENCION','FINALIZADA',@{}))) {
        $cases.Add((New-SqlCase "change-$($ok[0])-$($ok[1])" (Next $ok[0] $ok[1] $ok[2] $ok[3]) '00000' '' @($seed)))
    }
    $override = @{reason="'Clinic emergency'"; override='true'; actor_role="'ADMINISTRATOR'"}
    $cases.Add((New-SqlCase 'change-admin-override-cancel' (Next 'CANCEL' 'PROGRAMADA' 'CANCELADA' $override) '00000' '' @($seed)))
    $cases.Add((New-SqlCase 'change-admin-override-reschedule' (Next 'RESCHEDULE' 'PROGRAMADA' 'PROGRAMADA' ($override + $resched)) '00000' '' @($seed)))
    foreach ($bad in @(
        @('CONFIRM','CONFIRMADA','CONFIRMADA'), @('START_ATTENTION','PROGRAMADA','EN_ATENCION'), @('NO_SHOW','EN_ATENCION','NO_ASISTIO'),
        @('COMPLETE','CONFIRMADA','FINALIZADA'), @('CANCEL','FINALIZADA','CANCELADA'), @('CONFIRM','CANCELADA','CONFIRMADA'),
        @('RESCHEDULE','PROGRAMADA','CONFIRMADA'), @('UNKNOWN','PROGRAMADA','CONFIRMADA'))) {
        $extra = if ($bad[0] -eq 'RESCHEDULE') { $resched } elseif ($bad[0] -eq 'CANCEL') { @{reason="'x'"} } else { @{} }
        $cases.Add((New-SqlCase "change-invalid-$($bad -join '-')" (Next $bad[0] $bad[1] $bad[2] $extra) '23514' 'ck_appointment_status_changes_transition' @($seed)))
    }
    $cases.Add((New-SqlCase 'change-schedule-not-v1' (Change @{appointment_version='2'}) '23514' 'ck_appointment_status_changes_schedule_version' @($seed)))
    $cases.Add((New-SqlCase 'change-v1-not-schedule' (Change @{operation="'CONFIRM'"; from_status="'PROGRAMADA'"; to_status="'CONFIRMADA'"}) '23514' 'ck_appointment_status_changes_schedule_version' @($seed)))
    $cases.Add((New-SqlCase 'change-duplicate-version' (Change @{change_id="'90000000-0000-0000-0000-000000000002'"}) '23505' 'uk_appointment_status_changes_appointment_version' @($seed,(Change @{}))))
    $cases.Add((New-SqlCase 'change-orphan' (Change @{}) '23503' 'fk_appointment_status_changes_appointment_id'))
    $cases.Add((New-SqlCase 'change-reschedule-missing-interval' (Next 'RESCHEDULE' 'PROGRAMADA' 'PROGRAMADA') '23514' 'ck_appointment_status_changes_interval' @($seed)))
    $cases.Add((New-SqlCase 'change-reschedule-same-interval' (Next 'RESCHEDULE' 'PROGRAMADA' 'PROGRAMADA' (Join-Fixture $resched @{new_start_at="'2030-01-02T14:00:00Z'"; new_end_at="'2030-01-02T14:30:00Z'"})) '23514' 'ck_appointment_status_changes_interval' @($seed)))
    $cases.Add((New-SqlCase 'change-reschedule-inverted' (Next 'RESCHEDULE' 'PROGRAMADA' 'PROGRAMADA' (Join-Fixture $resched @{new_end_at="'2030-01-03T13:00:00Z'"})) '23514' 'ck_appointment_status_changes_interval' @($seed)))
    $cases.Add((New-SqlCase 'change-interval-on-confirm' (Next 'CONFIRM' 'PROGRAMADA' 'CONFIRMADA' $resched) '23514' 'ck_appointment_status_changes_interval' @($seed)))
    $cases.Add((New-SqlCase 'change-cancel-without-reason' (Next 'CANCEL' 'PROGRAMADA' 'CANCELADA') '23514' 'ck_appointment_status_changes_reason' @($seed)))
    $cases.Add((New-SqlCase 'change-reason-too-long' (Next 'CANCEL' 'PROGRAMADA' 'CANCELADA' @{reason="repeat('x',1001)"}) '23514' 'ck_appointment_status_changes_reason' @($seed)))
    $cases.Add((New-SqlCase 'change-override-without-reason' (Next 'CANCEL' 'PROGRAMADA' 'CANCELADA' @{override='true'; actor_role="'ADMINISTRATOR'"}) '23514' 'ck_appointment_status_changes_reason' @($seed)))
    $cases.Add((New-SqlCase 'change-override-by-assistant' (Next 'CANCEL' 'PROGRAMADA' 'CANCELADA' @{reason="'x'"; override='true'}) '23514' 'ck_appointment_status_changes_override' @($seed)))
    $cases.Add((New-SqlCase 'change-override-on-confirm' (Next 'CONFIRM' 'PROGRAMADA' 'CONFIRMADA' $override) '23514' 'ck_appointment_status_changes_override' @($seed)))
    $cases.Add((New-SqlCase 'change-dentist-actor' (Change @{actor_role="'DENTIST'"}) '23514' 'ck_appointment_status_changes_actor_role' @($seed)))
    foreach ($column in @('change_id','appointment_id','appointment_version','operation','to_status','override','actor_id','actor_role','correlation_id','occurred_at')) {
        $cases.Add((New-SqlCase "change-null-$column" (Change @{$column='NULL'}) '23502' '' @($seed)))
    }

    $baseReminder = New-TemplateInsert $R $reminder
    function Reminder($Overrides) { New-TemplateInsert $R $reminder $Overrides }
    $delivery = "'b0000000-0000-0000-0000-000000000001'"
    $second = @{reminder_id="'a0000000-0000-0000-0000-000000000002'"; appointment_version='2'}
    $invalidatedV1 = Reminder @{status="'INVALIDATED'"; invalidated_at=$now; delivery_id=$delivery}
    $cases.Add((New-SqlCase 'reminder-pending' $baseReminder '00000' '' @($seed)))
    $cases.Add((New-SqlCase 'reminder-requested' (Reminder @{status="'REQUESTED'"; attempts='1'; delivery_id=$delivery}) '00000' '' @($seed)))
    $cases.Add((New-SqlCase 'reminder-sent' (Reminder @{status="'SENT'"; attempts='1'; delivery_id=$delivery; outcome_at=$now}) '00000' '' @($seed)))
    $cases.Add((New-SqlCase 'reminder-failed' (Reminder @{status="'DELIVERY_FAILED'"; attempts='3'; delivery_id=$delivery; outcome_at=$now; outcome_code="'SMTP_TIMEOUT'"}) '00000' '' @($seed)))
    $cases.Add((New-SqlCase 'reminder-invalidated' (Reminder @{status="'INVALIDATED'"; invalidated_at=$now}) '00000' '' @($seed)))
    $cases.Add((New-SqlCase 'reminder-new-version-after-reschedule' (Reminder ($second + @{due_at="'2030-01-02T14:00:00Z'"})) '00000' '' @($seed,$invalidatedV1)))
    $cases.Add((New-SqlCase 'reminder-duplicate-version' (Reminder @{reminder_id="'a0000000-0000-0000-0000-000000000002'"}) '23505' 'uk_appointment_reminders_appointment_version' @($seed,$baseReminder)))
    $cases.Add((New-SqlCase 'reminder-second-live' (Reminder $second) '23505' 'uk_appointment_reminders_live_appointment_id' @($seed,$baseReminder)))
    $cases.Add((New-SqlCase 'reminder-duplicate-delivery' (Reminder ($second + @{status="'REQUESTED'"; delivery_id=$delivery})) '23505' 'uk_appointment_reminders_delivery_id' @($seed,$invalidatedV1)))
    $cases.Add((New-SqlCase 'reminder-stale-outcome-cannot-revive' "UPDATE $R SET status='SENT', outcome_at=now(), invalidated_at=NULL WHERE appointment_version=1;" '23505' 'uk_appointment_reminders_live_appointment_id' @($seed,$invalidatedV1,(Reminder $second))))
    foreach ($bad in @(
        @{channel="'SMS'"; name='channel'}, @{status="'CANCELLED'"; delivery_id=$delivery; name='status'}, @{attempts='-1'; name='attempts'}, @{appointment_version='0'; name='version'},
        @{due_at="'infinity'"; name='due'}, @{status="'SENT'"; delivery_id=$delivery; name='outcome'}, @{outcome_at=$now; name='outcome'},
        @{status="'DELIVERY_FAILED'"; delivery_id=$delivery; outcome_at=$now; name='outcome'}, @{outcome_code="'smtp timeout'"; name='outcome'},
        @{status="'INVALIDATED'"; name='invalidated'}, @{invalidated_at=$now; name='invalidated'}, @{status="'REQUESTED'"; name='requested'})) {
        $o = @{}; foreach ($key in $bad.Keys) { if ($key -ne 'name') { $o[$key] = $bad[$key] } }
        $cases.Add((New-SqlCase "reminder-invalid-$($bad.name)-$(@($o.Keys | Sort-Object) -join '-')" (Reminder $o) '23514' "ck_appointment_reminders_$($bad.name)" @($seed)))
    }
    foreach ($column in @('reminder_id','appointment_id','appointment_version','due_at','channel','status','attempts','created_at','updated_at')) {
        $cases.Add((New-SqlCase "reminder-null-$column" (Reminder @{$column='NULL'}) '23502' '' @($seed)))
    }
    $cases.Add((New-SqlCase 'appointment-delete-restricted-by-audit' 'DELETE FROM appointments.appointments;' '23503' 'fk_appointment_status_changes_appointment_id' @($seed,(Change @{}))))

    # Runtime role: audit rows are insert-only; reminder rows are updated, never deleted.
    $runtime = 'appointments_runtime'
    $cases.Add((New-SqlCase 'runtime-insert-change' (Change @{}) '00000' '' @($seed) $runtime))
    $cases.Add((New-SqlCase 'runtime-insert-reminder' $baseReminder '00000' '' @($seed) $runtime))
    $cases.Add((New-SqlCase 'runtime-update-reminder' "UPDATE $R SET status='INVALIDATED', invalidated_at=now();" '00000' '' @($seed,$baseReminder) $runtime))
    foreach ($denied in @("UPDATE $T SET reason='rewritten';","DELETE FROM $T;","DELETE FROM $R;","TRUNCATE $T;")) {
        $cases.Add((New-SqlCase "runtime-denied-$(($denied -replace '[^A-Za-z_]+','-').Trim('-'))" $denied '42501' '' @($seed,(Change @{}),$baseReminder) $runtime))
    }
    Invoke-SqlCaseSuite $Container 'LIFECYCLE' $cases @($T,$R,'appointments.appointments')
}
