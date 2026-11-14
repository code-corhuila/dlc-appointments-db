# Run only from verify-db.ps1 after disposable-fixture validation and migration.
# Generic integrity engine: every case runs in its own transaction and is rolled back.
function Invoke-SqlCaseSuite([string]$Container, [string]$Label, $Cases, [string[]]$Tables) {
    $observer = $writer = $null
    $prefix = 'apt-harness-' + [guid]::NewGuid().ToString('N')
    $count = "SELECT ($(@($Tables | ForEach-Object { "(SELECT count(*) FROM $_)" }) -join '+'));"
    try {
        $observer = Start-PgHarnessSession $Container "$prefix-observer"
        $writer = Start-PgHarnessSession $Container "$prefix-writer"
        if ((Invoke-PgHarnessCommand $observer $count) -cne '0') { throw "$Label suite requires empty disposable tables" }
        foreach ($case in $Cases) {
            [void](Invoke-PgHarnessCommand $writer 'BEGIN;')
            try {
                foreach ($seed in $case.Seed) {
                    Send-PgHarnessStatement $writer $seed
                    Assert-PgHarnessResult (Receive-PgHarnessResult $writer)
                }
                if ($case.Role) { [void](Invoke-PgHarnessCommand $writer "SET LOCAL ROLE $($case.Role);") }
                Send-PgHarnessStatement $writer $case.Sql
                Assert-PgHarnessResult (Receive-PgHarnessResult $writer) $case.State $case.Constraint
            } catch { throw "$Label/$($case.Name): $($_.Exception.Message)" }
            finally { [void](Invoke-PgHarnessCommand $writer 'ROLLBACK;') }
            if ((Invoke-PgHarnessCommand $observer $count) -cne '0') { throw "$Label/$($case.Name): rolled-back case left rows" }
        }
    } finally {
        $pids = @(@($writer) | Where-Object { $null -ne $_ } | ForEach-Object { $_.Backend })
        try { Stop-PgHarnessSession $writer $observer }
        finally {
            try {
                if ($null -ne $observer -and $pids.Count) {
                    if ($observer.Token) { [void](Receive-PgHarnessCommand $observer 3000) }
                    $clock = [Diagnostics.Stopwatch]::StartNew()
                    do {
                        $left = Invoke-PgHarnessCommand $observer "SELECT count(*) FROM pg_stat_activity WHERE pid IN ($($pids -join ','));" 1000
                        if ($left -ceq '0') { break }
                        Start-Sleep -Milliseconds 10
                    } while ($clock.ElapsedMilliseconds -lt 3000)
                    if ($left -cne '0') { throw "$Label sessions survived cleanup" }
                }
            } finally { Stop-PgHarnessSession $observer $null }
        }
    }
    Write-Host "$Label PASS: $(@($Cases).Count) rolled-back integrity/privilege cases with exact SQLSTATE/constraint."
}

function New-SqlCase($Name, $Sql, $State = '00000', $Constraint = '', $Seed = @(), $Role = '') {
    [pscustomobject]@{ Name=$Name; Sql=$Sql; State=$State; Constraint=$Constraint; Seed=@($Seed); Role=$Role }
}

# Builds an INSERT from ordered template values; overrides must name known columns.
function New-TemplateInsert([string]$Table, $Template, $Overrides = @{}) {
    $values = [ordered]@{}
    foreach ($key in $Template.Keys) { $values[$key] = $Template[$key] }
    foreach ($key in $Overrides.Keys) {
        if (!$values.Contains($key)) { throw "Unknown fixture column: $Table.$key" }
        $values[$key] = $Overrides[$key]
    }
    "INSERT INTO $Table ($($values.Keys -join ',')) VALUES ($($values.Values -join ','));"
}

# Catalog contract: exact owned constraint names/types, all validated and immediate.
function Assert-ConstraintCatalog([string]$Container, [string]$Table, [string]$Expected) {
    $session = Start-PgHarnessSession $Container ('apt-harness-' + [guid]::NewGuid().ToString('N') + '-catalog')
    try {
        $actual = Invoke-PgHarnessCommand $session "SELECT string_agg(conname||':'||contype::text, ',' ORDER BY conname COLLATE ""C"") FROM pg_constraint WHERE conrelid='$Table'::regclass AND contype<>'n' AND convalidated AND NOT condeferrable AND NOT condeferred;"
        if ($actual -cne $Expected) { throw "Unexpected constraints on ${Table}: $actual" }
        $defaults = Invoke-PgHarnessCommand $session "SELECT count(*) FROM pg_attribute WHERE attrelid='$Table'::regclass AND attnum>0 AND NOT attisdropped AND atthasdef;"
        if ($defaults -cne '0') { throw "Unexpected SQL defaults on $Table" }
    } finally { Stop-PgHarnessSession $session $null }
}

function Invoke-SchedulingTests([string]$Container) {
    $actor = "'40000000-0000-0000-0000-000000000001'"
    $now = "'2026-10-28T12:00:00Z'::timestamptz"
    $schedule = [ordered]@{ schedule_id="'50000000-0000-0000-0000-000000000001'"; dentist_id="'30000000-0000-0000-0000-000000000001'"
        version='1'; created_at=$now; created_by=$actor; updated_at=$now; updated_by=$actor }
    $interval = [ordered]@{ interval_id="'60000000-0000-0000-0000-000000000001'"; schedule_id=$schedule.schedule_id
        start_at="'2030-01-02T13:00:00Z'::timestamptz"; end_at="'2030-01-02T17:00:00Z'::timestamptz" }
    $outbox = [ordered]@{ event_id="'70000000-0000-0000-0000-000000000001'"; event_type="'AppointmentScheduled'"; event_version='1'
        aggregate_type="'Appointment'"; aggregate_id="'10000000-0000-0000-0000-000000000001'"; payload="'{""appointmentId"":""10000000-0000-0000-0000-000000000001""}'::jsonb"
        correlation_id="'80000000-0000-0000-0000-000000000001'"; causation_id='NULL'; actor_user_id=$actor; occurred_at=$now; recorded_at=$now
        status="'PENDING'"; attempts='0'; next_attempt_at=$now; published_at='NULL'; last_error_code='NULL' }
    $appointment = [ordered]@{ appointment_id="'10000000-0000-0000-0000-000000000001'"; patient_id="'20000000-0000-0000-0000-000000000001'"
        dentist_id=$schedule.dentist_id; start_at="'2030-01-02T14:00:00Z'::timestamptz"; end_at="'2030-01-02T14:30:00Z'::timestamptz"
        clinic_timezone="'America/Bogota'"; reason="'Synthetic fixture'"; status="'PROGRAMADA'"; confirmation_status="'PENDING'"
        reminder_due_at="'2030-01-01T14:00:00Z'::timestamptz"; reminder_status="'PENDING'"; version='1'; created_at=$now
        created_by=$actor; updated_at=$now; updated_by=$actor }

    Assert-ConstraintCatalog $Container 'appointments.dentist_schedules' 'ck_dentist_schedules_version:c,pk_dentist_schedules:p,uk_dentist_schedules_dentist_id:u'
    Assert-ConstraintCatalog $Container 'appointments.availability_intervals' 'ck_availability_intervals_interval:c,ex_availability_intervals_schedule_overlap:x,fk_availability_intervals_schedule_id:f,pk_availability_intervals:p'
    Assert-ConstraintCatalog $Container 'appointments.blocked_intervals' 'ck_blocked_intervals_interval:c,ex_blocked_intervals_schedule_overlap:x,fk_blocked_intervals_schedule_id:f,pk_blocked_intervals:p'
    Assert-ConstraintCatalog $Container 'appointments.outbox_events' 'ck_outbox_events_aggregate_type:c,ck_outbox_events_attempts:c,ck_outbox_events_error_code:c,ck_outbox_events_event_type:c,ck_outbox_events_event_version:c,ck_outbox_events_payload:c,ck_outbox_events_published:c,ck_outbox_events_status:c,pk_outbox_events:p'

    $baseSchedule = New-TemplateInsert 'appointments.dentist_schedules' $schedule
    $cases = [Collections.Generic.List[object]]::new()
    $cases.Add((New-SqlCase 'schedule-valid' $baseSchedule))
    $cases.Add((New-SqlCase 'schedule-duplicate-dentist' (New-TemplateInsert 'appointments.dentist_schedules' $schedule @{schedule_id="'50000000-0000-0000-0000-000000000002'"}) '23505' 'uk_dentist_schedules_dentist_id' @($baseSchedule)))
    $cases.Add((New-SqlCase 'schedule-version' (New-TemplateInsert 'appointments.dentist_schedules' $schedule @{version='0'}) '23514' 'ck_dentist_schedules_version'))
    foreach ($column in $schedule.Keys) { $cases.Add((New-SqlCase "schedule-null-$column" (New-TemplateInsert 'appointments.dentist_schedules' $schedule @{$column='NULL'}) '23502')) }

    foreach ($table in @('availability_intervals','blocked_intervals')) {
        $name = "appointments.$table"
        $base = New-TemplateInsert $name $interval
        $second = @{interval_id="'60000000-0000-0000-0000-000000000002'"}
        $cases.Add((New-SqlCase "$table-valid" $base '00000' '' @($baseSchedule)))
        $cases.Add((New-SqlCase "$table-overlap" (New-TemplateInsert $name $interval ($second + @{start_at="'2030-01-02T16:59:00Z'"; end_at="'2030-01-02T18:00:00Z'"})) '23P01' "ex_${table}_schedule_overlap" @($baseSchedule,$base)))
        $cases.Add((New-SqlCase "$table-adjacent" (New-TemplateInsert $name $interval ($second + @{start_at="'2030-01-02T17:00:00Z'"; end_at="'2030-01-02T18:00:00Z'"})) '00000' '' @($baseSchedule,$base)))
        foreach ($end in @("'2030-01-02T13:00:00Z'","'2030-01-02T12:00:00Z'","'infinity'")) {
            $cases.Add((New-SqlCase "$table-interval-$end" (New-TemplateInsert $name $interval @{end_at=$end}) '23514' "ck_${table}_interval" @($baseSchedule)))
        }
        $cases.Add((New-SqlCase "$table-orphan" $base '23503' "fk_${table}_schedule_id"))
        $cases.Add((New-SqlCase "$table-restrict-delete" 'DELETE FROM appointments.dentist_schedules;' '23503' "fk_${table}_schedule_id" @($baseSchedule,$base)))
        foreach ($column in $interval.Keys) { $cases.Add((New-SqlCase "$table-null-$column" (New-TemplateInsert $name $interval @{$column='NULL'}) '23502' '' @($baseSchedule))) }
    }
    $cases.Add((New-SqlCase 'available-and-blocked-coexist' (New-TemplateInsert 'appointments.blocked_intervals' $interval) '00000' '' @($baseSchedule,(New-TemplateInsert 'appointments.availability_intervals' $interval))))

    $baseOutbox = New-TemplateInsert 'appointments.outbox_events' $outbox
    $cases.Add((New-SqlCase 'outbox-valid' $baseOutbox))
    $cases.Add((New-SqlCase 'outbox-published' (New-TemplateInsert 'appointments.outbox_events' $outbox @{status="'PUBLISHED'"; attempts='1'; published_at=$now})))
    $cases.Add((New-SqlCase 'outbox-duplicate' $baseOutbox '23505' 'pk_outbox_events' @($baseOutbox)))
    foreach ($bad in @(
        @{status="'PUBLISHED'"; name='published'}, @{published_at=$now; name='published'}, @{status="'SENT'"; name='status'},
        @{attempts='-1'; name='attempts'}, @{event_version='0'; name='event_version'}, @{event_type="'appointment_scheduled'"; name='event_type'},
        @{aggregate_type="'Patient'"; name='aggregate_type'}, @{payload="'[]'::jsonb"; name='payload'}, @{last_error_code="'smtp timeout'"; name='error_code'})) {
        $override = @{}; foreach ($key in $bad.Keys) { if ($key -ne 'name') { $override[$key] = $bad[$key] } }
        $cases.Add((New-SqlCase "outbox-$($bad.name)-$(@($override.Keys) -join '-')" (New-TemplateInsert 'appointments.outbox_events' $outbox $override) '23514' "ck_outbox_events_$($bad.name)"))
    }
    foreach ($column in @('event_id','event_type','event_version','aggregate_type','aggregate_id','payload','correlation_id','occurred_at','recorded_at','status','attempts')) {
        $cases.Add((New-SqlCase "outbox-null-$column" (New-TemplateInsert 'appointments.outbox_events' $outbox @{$column='NULL'}) '23502'))
    }

    # Runtime role: DML on owned tables only; no DDL, deletes of audit-bearing rows or migration metadata.
    $runtime = 'appointments_runtime'
    $baseAppointment = New-TemplateInsert 'appointments.appointments' $appointment
    $baseInterval = New-TemplateInsert 'appointments.availability_intervals' $interval
    $cases.Add((New-SqlCase 'runtime-insert-appointment' $baseAppointment '00000' '' @() $runtime))
    $cases.Add((New-SqlCase 'runtime-update-appointment' "UPDATE appointments.appointments SET status='CONFIRMADA', version=2;" '00000' '' @($baseAppointment) $runtime))
    $cases.Add((New-SqlCase 'runtime-insert-schedule' $baseSchedule '00000' '' @() $runtime))
    $cases.Add((New-SqlCase 'runtime-replace-interval' "DELETE FROM appointments.availability_intervals;" '00000' '' @($baseSchedule,$baseInterval) $runtime))
    $cases.Add((New-SqlCase 'runtime-insert-interval' $baseInterval '00000' '' @($baseSchedule) $runtime))
    $cases.Add((New-SqlCase 'runtime-insert-outbox' $baseOutbox '00000' '' @() $runtime))
    $cases.Add((New-SqlCase 'runtime-update-outbox' "UPDATE appointments.outbox_events SET status='PUBLISHED', attempts=1, published_at=now();" '00000' '' @($baseOutbox) $runtime))
    foreach ($denied in @(
        'DELETE FROM appointments.appointments;', 'DELETE FROM appointments.dentist_schedules;', 'DELETE FROM appointments.outbox_events;',
        'TRUNCATE appointments.appointments;', 'CREATE TABLE appointments.runtime_probe (id integer);',
        'ALTER TABLE appointments.appointments ADD COLUMN runtime_probe integer;', 'DROP TABLE appointments.outbox_events;',
        'SELECT count(*) FROM appointments_liquibase.databasechangelog;')) {
        $cases.Add((New-SqlCase "runtime-denied-$(($denied -replace '[^A-Za-z_]+','-').Trim('-'))" $denied '42501' '' @() $runtime))
    }
    Invoke-SqlCaseSuite $Container 'SCHEDULING' $cases @('appointments.availability_intervals','appointments.blocked_intervals','appointments.dentist_schedules','appointments.outbox_events','appointments.appointments')
}
