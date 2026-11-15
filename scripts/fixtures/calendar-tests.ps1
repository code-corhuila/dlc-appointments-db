# Run only from verify-db.ps1 after disposable-fixture validation and migration.
# Proves each approved GET /api/v1/appointments filter/order path can be served by its index (plans only, no rows).
function Invoke-CalendarTests([string]$Container) {
    $session = Start-PgHarnessSession $Container ('apt-harness-' + [guid]::NewGuid().ToString('N') + '-calendar')
    try {
        $definitions = Invoke-PgHarnessCommand $session "SELECT string_agg(indexrelid::regclass::text||'='||pg_get_indexdef(indexrelid), ';' ORDER BY indexrelid::regclass::text COLLATE ""C"") FROM pg_index WHERE indrelid='appointments.appointments'::regclass AND indexrelid::regclass::text LIKE 'appointments.idx_%';"
        $expected = @(
            'appointments.idx_appointments_created_at_appointment_id=CREATE INDEX idx_appointments_created_at_appointment_id ON appointments.appointments USING btree (created_at, appointment_id)',
            'appointments.idx_appointments_dentist_id_start_at=CREATE INDEX idx_appointments_dentist_id_start_at ON appointments.appointments USING btree (dentist_id, start_at)',
            'appointments.idx_appointments_patient_id_start_at=CREATE INDEX idx_appointments_patient_id_start_at ON appointments.appointments USING btree (patient_id, start_at)') -join ';'
        if ($definitions -cne $expected) { throw "Unexpected calendar index definitions: $definitions" }
        $id = { param($prefix,$expr) "('$prefix-0000-0000-0000-'||lpad(($expr)::text,12,'0'))::uuid" }
        $slot = "'2030-01-01T00:00:00Z'::timestamptz + (g/50) * interval '1 hour'"
        $seed = @((& $id '10000000' 'g'), (& $id '20000000' 'g%97'), (& $id '30000000' 'g%50'), $slot, "$slot + interval '30 minutes'",
            "'America/Bogota'", "'Synthetic fixture'", "(ARRAY['PROGRAMADA','CONFIRMADA','FINALIZADA','CANCELADA'])[g%4+1]", "'PENDING'",
            "$slot - interval '24 hours'", "'PENDING'", '1', "'2026-10-28T12:00:00Z'::timestamptz + g * interval '1 second'",
            "'40000000-0000-0000-0000-000000000001'", "'2026-10-28T12:00:00Z'::timestamptz + g * interval '1 second'", "'40000000-0000-0000-0000-000000000001'") -join ', '
        $window = "start_at >= '2030-01-01T00:00:00Z' AND start_at < '2030-02-01T00:00:00Z'"
        $paths = @(
            @('dentist-calendar', "SELECT appointment_id FROM appointments.appointments WHERE dentist_id='30000000-0000-0000-0000-000000000001' AND $window AND status IN ('PROGRAMADA','CONFIRMADA','EN_ATENCION','FINALIZADA')", 'idx_appointments_dentist_id_start_at'),
            @('patient-filter', "SELECT appointment_id FROM appointments.appointments WHERE patient_id='20000000-0000-0000-0000-000000000001' AND $window", 'idx_appointments_patient_id_start_at'),
            @('default-order', 'SELECT appointment_id FROM appointments.appointments ORDER BY created_at, appointment_id LIMIT 20', 'idx_appointments_created_at_appointment_id'))
        foreach ($path in $paths) {
            # Realistic selectivity: 4000 synthetic rows over 50 dentists/97 patients, analyzed and rolled back.
            [void](Invoke-PgHarnessCommand $session "BEGIN; INSERT INTO appointments.appointments SELECT $seed FROM generate_series(1,4000) g; ANALYZE appointments.appointments; SET LOCAL enable_seqscan = off;")
            try {
                $plan = (Invoke-PgHarnessCommand $session "EXPLAIN (COSTS OFF) $($path[1]);") -join ' '
                if ($plan -notmatch "\b$([regex]::Escape($path[2]))\b") { throw "Calendar path $($path[0]) does not use $($path[2]): $plan" }
            } finally { [void](Invoke-PgHarnessCommand $session 'ROLLBACK;') }
        }
    } finally { Stop-PgHarnessSession $session $null }
    Write-Host 'CALENDAR PASS: exact calendar index definitions and three approved query paths served by their indexes.'
}
