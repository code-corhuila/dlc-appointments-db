# Run only from verify-db.ps1 after disposable-fixture validation and migration.
# Reuses Invoke-SqlCaseSuite, New-SqlCase, New-TemplateInsert and Assert-ConstraintCatalog from scheduling-tests.ps1.
function Invoke-IdempotencyInboxTests([string]$Container) {
    $runtime = 'appointments_runtime'

    # DB-08 idempotency_keys: one row per actor, operation and key; immutable once written (Norma 5.3.8).
    $keyTable = 'appointments.idempotency_keys'
    Assert-ConstraintCatalog $Container $keyTable 'ck_idempotency_keys_idempotency_key:c,ck_idempotency_keys_operation:c,ck_idempotency_keys_request_hash:c,ck_idempotency_keys_resource_type:c,ck_idempotency_keys_response_status:c,pk_idempotency_keys:p'
    $key = [ordered]@{ actor_user_id="'a9900000-0000-4000-8000-0000000000c1'"; operation="'SCHEDULE_APPOINTMENT'"
        idempotency_key="'retry-key-0001'"; request_hash="repeat('a',64)"; resource_type="'Appointment'"
        resource_id="'a0000000-0000-0000-0000-000000000001'"; response_status='201'; created_at="'2026-11-04T12:00:00Z'::timestamptz" }
    function Key($Overrides) { New-TemplateInsert $keyTable $key $Overrides }
    $base = Key @{}
    $cases = [Collections.Generic.List[object]]::new()
    $cases.Add((New-SqlCase 'key-valid' $base))
    $cases.Add((New-SqlCase 'key-valid-uuid' (Key @{idempotency_key="'6f178b1a-9c0d-4c23-96ad-1e8da3b2ef6d'"})))
    $cases.Add((New-SqlCase 'key-valid-transition' (Key @{operation="'CANCEL_APPOINTMENT'"; response_status='200'})))
    $cases.Add((New-SqlCase 'key-duplicate' $base '23505' 'pk_idempotency_keys' @($base)))
    $cases.Add((New-SqlCase 'key-same-key-other-actor' (Key @{actor_user_id="'a9900000-0000-4000-8000-0000000000a1'"}) '00000' '' @($base)))
    $cases.Add((New-SqlCase 'key-same-key-other-operation' (Key @{operation="'START_CLINICAL_ASSIGNMENT'"; resource_type="'ClinicalAssignment'"}) '00000' '' @($base)))
    foreach ($bad in @(
        @{idempotency_key="repeat('k',7)"; name='idempotency_key'}, @{idempotency_key="repeat('k',129)"; name='idempotency_key'},
        @{operation="'schedule_appointment'"; name='operation'}, @{operation="'S'"; name='operation'},
        @{request_hash="repeat('A',64)"; name='request_hash'}, @{request_hash="repeat('a',63)"; name='request_hash'},
        @{resource_type="'Patient'"; name='resource_type'}, @{response_status='204'; name='response_status'})) {
        $o = @{}; foreach ($field in $bad.Keys) { if ($field -ne 'name') { $o[$field] = $bad[$field] } }
        $cases.Add((New-SqlCase "key-invalid-$($bad.name)-$($cases.Count)" (Key $o) '23514' "ck_idempotency_keys_$($bad.name)"))
    }
    foreach ($column in @($key.Keys)) { $cases.Add((New-SqlCase "key-null-$column" (Key @{$column='NULL'}) '23502')) }
    $cases.Add((New-SqlCase 'runtime-insert-key' $base '00000' '' @() $runtime))
    foreach ($denied in @("UPDATE $keyTable SET response_status=200;","DELETE FROM $keyTable;","TRUNCATE $keyTable;","ALTER TABLE $keyTable ADD COLUMN notes text;")) {
        $cases.Add((New-SqlCase "runtime-denied-key-$(($denied -replace '[^A-Za-z_]+','-').Trim('-'))" $denied '42501' '' @($base) $runtime))
    }
    Invoke-SqlCaseSuite $Container 'IDEMPOTENCY' $cases @($keyTable)

    # DB-08 inbox_events: one row per consumed event; processed_at present if and only if PROCESSED.
    $inboxTable = 'appointments.inbox_events'
    Assert-ConstraintCatalog $Container $inboxTable 'ck_inbox_events_error_code:c,ck_inbox_events_event_type:c,ck_inbox_events_event_version:c,ck_inbox_events_processed:c,ck_inbox_events_producer:c,ck_inbox_events_status:c,pk_inbox_events:p'
    $inboxRow = [ordered]@{ event_id="'e0000000-0000-0000-0000-000000000001'"; event_type="'PatientDeactivated'"; event_version='1'
        producer="'patients-service'"; aggregate_id="'20000000-0000-0000-0000-000000000001'"
        correlation_id="'c0000000-0000-0000-0000-0000000000aa'"; received_at="'2026-11-04T12:00:00Z'::timestamptz"
        processed_at="'2026-11-04T12:00:01Z'::timestamptz"; status="'PROCESSED'"; last_error_code='NULL' }
    function Event($Overrides) { New-TemplateInsert $inboxTable $inboxRow $Overrides }
    $processed = Event @{}
    $failed = @{processed_at='NULL'; status="'FAILED'"; last_error_code="'SCHEMA_INVALID'"}
    $cases = [Collections.Generic.List[object]]::new()
    $cases.Add((New-SqlCase 'inbox-processed' $processed))
    $cases.Add((New-SqlCase 'inbox-failed' (Event $failed)))
    $cases.Add((New-SqlCase 'inbox-duplicate-event' $processed '23505' 'pk_inbox_events' @($processed)))
    $cases.Add((New-SqlCase 'inbox-processed-without-time' (Event @{processed_at='NULL'}) '23514' 'ck_inbox_events_processed'))
    $cases.Add((New-SqlCase 'inbox-failed-with-time' (Event @{status="'FAILED'"}) '23514' 'ck_inbox_events_processed'))
    foreach ($bad in @(
        @{status="'PENDING'"; processed_at='NULL'; name='status'}, @{event_type="'patientDeactivated'"; name='event_type'},
        @{event_version='0'; name='event_version'}, @{producer="'Patients'"; name='producer'},
        @{status="'FAILED'"; processed_at='NULL'; last_error_code="'driver said boom'"; name='error_code'})) {
        $o = @{}; foreach ($field in $bad.Keys) { if ($field -ne 'name') { $o[$field] = $bad[$field] } }
        $cases.Add((New-SqlCase "inbox-invalid-$($bad.name)-$($cases.Count)" (Event $o) '23514' "ck_inbox_events_$($bad.name)"))
    }
    foreach ($column in @('event_id','event_type','event_version','producer','aggregate_id','correlation_id','received_at','status')) {
        $cases.Add((New-SqlCase "inbox-null-$column" (Event @{$column='NULL'}) '23502'))
    }
    $cases.Add((New-SqlCase 'runtime-insert-inbox' $processed '00000' '' @() $runtime))
    $cases.Add((New-SqlCase 'runtime-retry-failed-inbox' "UPDATE $inboxTable SET status='PROCESSED', processed_at=now(), last_error_code=NULL;" '00000' '' @((Event $failed)) $runtime))
    foreach ($denied in @("DELETE FROM $inboxTable;","TRUNCATE $inboxTable;","ALTER TABLE $inboxTable ADD COLUMN notes text;")) {
        $cases.Add((New-SqlCase "runtime-denied-inbox-$(($denied -replace '[^A-Za-z_]+','-').Trim('-'))" $denied '42501' '' @($processed) $runtime))
    }
    Invoke-SqlCaseSuite $Container 'INBOX' $cases @($inboxTable)
}
