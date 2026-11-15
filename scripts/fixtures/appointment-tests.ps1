# Run only from verify-db.ps1 after disposable-fixture validation and migration.
function Invoke-AppointmentTests([string]$Container) {
    $observer = $writer = $other = $null
    $ownsRows = $false
    $prefix = 'apt-harness-' + [guid]::NewGuid().ToString('N')
    $exclusion = 'ex_appointments_dentist_overlap'
    $template = [ordered]@{
        appointment_id="'10000000-0000-0000-0000-000000000001'"; patient_id="'20000000-0000-0000-0000-000000000001'"
        dentist_id="'30000000-0000-0000-0000-000000000001'"; start_at="'2030-01-02T09:00:00Z'::timestamptz"
        end_at="'2030-01-02T09:30:00Z'::timestamptz"; clinic_timezone="'America/Bogota'"; reason="'Synthetic fixture'"
        status="'PROGRAMADA'"; confirmation_status="'PENDING'"; reminder_due_at="'2030-01-01T09:00:00Z'::timestamptz"
        reminder_status="'PENDING'"; version='1'; created_at="'2026-10-25T12:00:00Z'::timestamptz"
        created_by="'40000000-0000-0000-0000-000000000001'"; updated_at="'2026-10-25T12:00:00Z'::timestamptz"
        updated_by="'40000000-0000-0000-0000-000000000001'"
    }
    $id2 = "'10000000-0000-0000-0000-000000000002'"
    function New-AppointmentInsert($Overrides = @{}) {
        $values = [ordered]@{}
        foreach ($key in $template.Keys) { $values[$key] = $template[$key] }
        foreach ($key in $Overrides.Keys) {
            if (!$values.Contains($key)) { throw "Unknown fixture column: $key" }
            $values[$key] = $Overrides[$key]
        }
        "INSERT INTO appointments.appointments ($($values.Keys -join ',')) VALUES ($($values.Values -join ','));"
    }
    function Execute-AppointmentSql($Session, [string]$Sql, $State='00000', $Constraint='') {
        Send-PgHarnessStatement $Session $Sql
        Assert-PgHarnessResult (Receive-PgHarnessResult $Session) $State $Constraint
    }
    function Snapshot-Appointments($Session) {
        Invoke-PgHarnessCommand $Session "SELECT coalesce(json_agg(t ORDER BY appointment_id)::text,'[]') FROM appointments.appointments t;"
    }
    $cases = [Collections.Generic.List[object]]::new()
    function Add-AppointmentCase($Name, $Values, $State='00000', $Constraint='', $Seed=@(), $Sql='') {
        $cases.Add([pscustomobject]@{Name=$Name;Sql=$(if ($Sql) {$Sql} else {New-AppointmentInsert $Values});
            State=$State;Constraint=$Constraint;Seed=@($Seed)})
    }
    $base = New-AppointmentInsert
    Add-AppointmentCase 'valid' @{}
    Add-AppointmentCase 'duplicate' @{} '23505' 'pk_appointments' @($base)
    foreach ($column in $template.Keys) { Add-AppointmentCase "null-$column" @{$column='NULL'} '23502' }
    foreach ($end in @("'2030-01-02T09:00:00Z'","'2030-01-02T08:00:00Z'","'infinity'")) {
        Add-AppointmentCase "interval-$end" @{end_at=$end} '23514' 'ck_appointments_interval'
    }
    Add-AppointmentCase 'infinite-start' @{start_at="'-infinity'"} '23514' 'ck_appointments_interval'
    foreach ($reason in @("''","repeat('x',501)")) {
        Add-AppointmentCase "reason-$reason" @{reason=$reason} '23514' 'ck_appointments_reason'
    }
    foreach ($entry in @(@('status','status'),@('confirmation_status','confirmation'),@('reminder_status','reminder_status'))) {
        Add-AppointmentCase $entry[0] @{$entry[0]="'INVALID'"} '23514' "ck_appointments_$($entry[1])"
    }
    Add-AppointmentCase 'version' @{version='0'} '23514' 'ck_appointments_version'
    Add-AppointmentCase 'reminder-due' @{reminder_due_at="'2030-01-01T08:59:00Z'"} '23514' 'ck_appointments_reminder_due'
    foreach ($status in @('PROGRAMADA','CONFIRMADA','EN_ATENCION')) {
        Add-AppointmentCase "overlap-$status" @{appointment_id=$id2} '23P01' $exclusion @(New-AppointmentInsert @{status="'$status'"})
    }
    $adjacent = @{appointment_id=$id2;start_at="'2030-01-02T09:30:00Z'";end_at="'2030-01-02T10:00:00Z'";reminder_due_at="'2030-01-01T09:30:00Z'"}
    Add-AppointmentCase 'adjacent' $adjacent '00000' '' @($base)
    $different = @{appointment_id=$id2;dentist_id="'30000000-0000-0000-0000-000000000002'"}
    Add-AppointmentCase 'different-dentist' $different '00000' '' @($base)
    foreach ($status in @('FINALIZADA','CANCELADA','NO_ASISTIO')) {
        Add-AppointmentCase "terminal-$status" @{appointment_id=$id2;status="'$status'"} '00000' '' @($base)
        Add-AppointmentCase "release-$status" @{appointment_id=$id2} '00000' '' @($base,"UPDATE appointments.appointments SET status='$status';")
    }
    foreach ($status in @('CONFIRMED','NOT_CONFIRMED')) { Add-AppointmentCase $status @{confirmation_status="'$status'"} }
    foreach ($status in @('SENT','FAILED')) { Add-AppointmentCase $status @{reminder_status="'$status'"} }
    Add-AppointmentCase 'update-conflict' @{} '23P01' $exclusion @($base,(New-AppointmentInsert $different)) "UPDATE appointments.appointments SET dentist_id=$($template.dentist_id) WHERE appointment_id=$id2;"
    Add-AppointmentCase 'reschedule-conflict' @{} '23P01' $exclusion @($base,(New-AppointmentInsert $adjacent)) "UPDATE appointments.appointments SET start_at='2030-01-02T09:15:00Z',end_at='2030-01-02T09:45:00Z',reminder_due_at='2030-01-01T09:15:00Z' WHERE appointment_id=$id2;"
    $terminal = New-AppointmentInsert @{appointment_id=$id2;status="'CANCELADA'"}
    Add-AppointmentCase 'status-conflict' @{} '23P01' $exclusion @($base,$terminal) "UPDATE appointments.appointments SET status='PROGRAMADA' WHERE appointment_id=$id2;"
    try {
        $observer = Start-PgHarnessSession $Container "$prefix-observer"
        $writer = Start-PgHarnessSession $Container "$prefix-writer"
        $other = Start-PgHarnessSession $Container "$prefix-other"
        if (@(@($observer.Backend,$writer.Backend,$other.Backend) | Select-Object -Unique).Count -ne 3) { throw 'Appointment sessions are not independent' }
        if ((Snapshot-Appointments $observer) -cne '[]') { throw 'Appointment suite requires an empty disposable table' }
        $ownsRows = $true
        $columns = Invoke-PgHarnessCommand $observer "SELECT json_agg(json_build_object('name',attname,'type',atttypid::regtype::text,'required',attnotnull,'default',atthasdef) ORDER BY attnum) FROM pg_attribute WHERE attrelid='appointments.appointments'::regclass AND attnum>0 AND NOT attisdropped;"
        $columns = @($columns | ConvertFrom-Json)
        if ($columns.Count -ne 16 -or ($columns.name -join ',') -cne ($template.Keys -join ',')) { throw 'Unexpected appointment columns/order' }
        foreach ($column in $columns) {
            $type = if ($column.name -in @('appointment_id','patient_id','dentist_id','created_by','updated_by')) {'uuid'} elseif ($column.name -eq 'version') {'integer'} elseif ($column.name -in @('start_at','end_at','reminder_due_at','created_at','updated_at')) {'timestamp with time zone'} else {'text'}
            if ($column.type -cne $type -or !$column.required -or $column.default) { throw "Invalid type/null/default: $($column.name)" }
        }
        $constraintCount = Invoke-PgHarnessCommand $observer "SELECT count(*) FROM pg_constraint WHERE conrelid='appointments.appointments'::regclass AND convalidated AND NOT condeferrable AND NOT condeferred AND contype IN ('p','c','x');"
        if ($constraintCount -cne '9') { throw 'Expected PK, seven CHECKs and immediate exclusion' }
        if ((Invoke-PgHarnessCommand $observer "SELECT count(*) FROM pg_constraint WHERE conrelid='appointments.appointments'::regclass AND contype='f';") -cne '0') { throw 'Unexpected foreign keys' }
        $gist = Invoke-PgHarnessCommand $observer "SELECT count(*) FROM pg_constraint k JOIN pg_index i ON i.indexrelid=k.conindid JOIN pg_class idx ON idx.oid=i.indexrelid JOIN pg_am a ON a.oid=idx.relam JOIN pg_opclass c ON c.oid=i.indclass[0] JOIN pg_depend d ON d.classid='pg_opclass'::regclass AND d.objid=c.oid AND d.refclassid='pg_extension'::regclass AND d.deptype='e' JOIN pg_extension e ON e.oid=d.refobjid WHERE k.conrelid='appointments.appointments'::regclass AND k.conname='$exclusion' AND k.contype='x' AND a.amname='gist' AND i.indisvalid AND i.indisready AND i.indpred IS NOT NULL AND c.opcname='gist_uuid_ops' AND e.extname='btree_gist' AND c.opcnamespace=e.extnamespace;"
        if ($gist -cne '1') { throw 'Invalid partial GiST exclusion/opclass dependency' }
        foreach ($case in $cases) {
            [void](Invoke-PgHarnessCommand $writer 'BEGIN;')
            foreach ($seed in $case.Seed) { Execute-AppointmentSql $writer $seed }
            $before = Snapshot-Appointments $writer
            $count = [int](Invoke-PgHarnessCommand $writer 'SELECT count(*) FROM appointments.appointments;')
            try { Execute-AppointmentSql $writer $case.Sql $case.State $case.Constraint } catch { throw "$($case.Name): $($_.Exception.Message)" }
            $after = Snapshot-Appointments $writer
            if ($case.State -cne '00000' -and $after -cne $before) { throw "Failed statement changed rows: $($case.Name)" }
            if ($case.State -ceq '00000') { $count++ }
            [void](Invoke-PgHarnessCommand $writer 'COMMIT;')
            if ((Snapshot-Appointments $observer) -cne $after -or (Invoke-PgHarnessCommand $observer 'SELECT count(*) FROM appointments.appointments;') -ne "$count") { throw "Persisted state mismatch: $($case.Name)" }
            if ($case.Name -eq 'valid') {
                $predicate = @($template.Keys | ForEach-Object { "$_ IS NOT DISTINCT FROM $($template[$_])" }) -join ' AND '
                if ((Invoke-PgHarnessCommand $observer "SELECT count(*) FROM appointments.appointments WHERE $predicate;") -cne '1') { throw 'Contractual values did not round-trip' }
            }
            [void](Invoke-PgHarnessCommand $writer 'DELETE FROM appointments.appointments;')
            if ((Snapshot-Appointments $observer) -cne '[]') { throw 'Case cleanup failed' }
        }
        foreach ($finish in @('COMMIT','ROLLBACK')) {
            [void](Invoke-PgHarnessCommand $writer 'BEGIN;')
            [void](Invoke-PgHarnessCommand $other 'BEGIN;')
            Execute-AppointmentSql $writer $base
            Send-PgHarnessStatement $other (New-AppointmentInsert @{appointment_id=$id2})
            Wait-PgHarnessBlocked $observer $writer $other
            [void](Invoke-PgHarnessCommand $writer "$finish;")
            $result = Receive-PgHarnessResult $other
            if ($finish -eq 'COMMIT') { Assert-PgHarnessResult $result '23P01' $exclusion; $expected=$template.appointment_id }
            else { Assert-PgHarnessResult $result; $expected=$id2 }
            $after = Snapshot-Appointments $other
            [void](Invoke-PgHarnessCommand $other 'COMMIT;')
            if ((Snapshot-Appointments $observer) -cne $after -or (Invoke-PgHarnessCommand $observer "SELECT count(*) FROM appointments.appointments WHERE appointment_id=$expected;") -cne '1' -or (Invoke-PgHarnessCommand $observer 'SELECT count(*) FROM appointments.appointments;') -cne '1') { throw "Concurrent persisted state mismatch: $finish" }
            [void](Invoke-PgHarnessCommand $observer 'DELETE FROM appointments.appointments;')
        }
    } finally {
        $pids = @(@($writer,$other) | Where-Object { $null -ne $_ } | ForEach-Object { $_.Backend })
        try { Stop-PgHarnessSession $other $observer }
        finally {
            try { Stop-PgHarnessSession $writer $observer }
            finally {
                try {
                    if ($null -ne $observer -and $pids.Count) {
                        if ($observer.Token) { [void](Receive-PgHarnessCommand $observer 3000) }
                        $clock = [Diagnostics.Stopwatch]::StartNew()
                        do {
                            $left=Invoke-PgHarnessCommand $observer "SELECT count(*) FROM pg_stat_activity WHERE pid IN ($($pids -join ','));" 1000
                            if ($left -ceq '0') { break }
                            Start-Sleep -Milliseconds 10
                        } while ($clock.ElapsedMilliseconds -lt 3000)
                        if ($left -cne '0') { throw 'Appointment sessions survived cleanup' }
                        if ($ownsRows) { [void](Invoke-PgHarnessCommand $observer 'DELETE FROM appointments.appointments;') }
                        if ((Snapshot-Appointments $observer) -cne '[]') { throw 'Appointment rows survived cleanup' }
                    }
                } finally { Stop-PgHarnessSession $observer $null }
            }
        }
    }
    Write-Host "APPOINTMENT PASS: $($cases.Count) integrity cases, two concurrent insert outcomes, catalogs and cleanup."
}
