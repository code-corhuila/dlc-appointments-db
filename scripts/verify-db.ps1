param(
    [switch]$StaticOnly,
    [ValidateSet('DB01','DB02')][string]$Baseline = 'DB01',
    [string]$ExpectedManifest = 'scripts/fixtures/db03-expected.json'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'fixture-isolation.ps1')
. (Join-Path $PSScriptRoot 'pg-test-harness.ps1')
. (Join-Path $PSScriptRoot 'fixtures/appointment-tests.ps1')
$entry = Join-Path $repo 'changelog/changelog-master.yaml'
$seen = [Collections.Generic.HashSet[string]]::new()
$id = '001-appointments-create-schema'
$author = 'bsbedoya'
$schemaFile = '01_ddl/01_schemas/changelog.yaml'
$identities = [Collections.Generic.List[string]]::new()
function Identity($Changesets) {
    (@($Changesets) | ForEach-Object { "$($_.id)|$($_.author)|$($_.filename)" }) -join "`n"
}
$target = Get-Content -LiteralPath (Join-Path $repo $ExpectedManifest) -Raw | ConvertFrom-Json
$baselineState = if ($Baseline -eq 'DB02') {
    Get-Content -LiteralPath (Join-Path $repo 'scripts/fixtures/db02-expected.json') -Raw | ConvertFrom-Json
} else { [pscustomobject]@{changesets=@();schemaPresent=$false;schemaOwner='bootstrap_test';relations=@()} }
if ($target.schemaPresent -isnot [bool] -or $target.schemaOwner -ne 'bootstrap_test') { throw 'Invalid test schema expectation' }
foreach ($name in $target.relations) { if ($name -notmatch '^appointments\.[a-z_][a-z0-9_]*:[rSipvmfc]$') { throw 'Relations must be explicitly Appointments-owned' } }
$targetKeys = @(Identity $target.changesets) -join "`n"
$baselineKeys = Identity $baselineState.changesets
if ($baselineKeys -and $targetKeys -ne $baselineKeys -and !$targetKeys.StartsWith($baselineKeys+"`n")) { throw 'Baseline is not a prefix of target history' }

function Check-Changelog([string]$Path) {
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not $resolved.StartsWith($repo + [IO.Path]::DirectorySeparatorChar)) {
        throw "Changelog outside repository: $Path"
    }
    if (-not $seen.Add($resolved)) { throw "Repeated include: $Path" }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Missing: $Path" }
    $lines = @(Get-Content -LiteralPath $resolved)
    $content = $lines -join "`n"
    if ($resolved -eq (Join-Path $repo $schemaFile)) {
        $required = @('  - changeSet:', "      id: $id", "      author: $author",
            '      labels: "HU-APT-001,ddl,schemas"', '        - onFail: HALT', '        - onError: HALT',
            '            type: postgresql', '            expectedResult: "0"', '      rollback:')
        foreach ($token in $required) { if ($token -cnotin $lines) { throw "Missing changeset field: $token" } }
        if ($content -notmatch '(?m)^      comment: ".+"$') { throw 'Quote the changeset comment' }
        $paths = @([regex]::Matches($content, '(?m)^            path: (.+)$') | ForEach-Object { $_.Groups[1].Value })
        if ($paths.Count -ne 2) { throw 'Expected migration and external rollback SQL' }
        if (($paths -join '|') -cne '001_create_schema_appointments.sql|../../05_rollbacks/01_ddl/01_schemas/001_create_schema_appointments.rollback.sql') { throw 'Unexpected SQL migration/rollback mapping' }
        foreach ($sql in $paths) {
            $target = [IO.Path]::GetFullPath((Join-Path (Split-Path $resolved) $sql))
            if (!$target.StartsWith($repo + [IO.Path]::DirectorySeparatorChar) -or !(Test-Path -LiteralPath $target)) { throw "Invalid SQL path: $sql" }
        }
        if (@($lines | Where-Object { $_ -eq '            relativeToChangelogFile: true' }).Count -ne 2 -or
            @($lines | Where-Object { $_ -eq '            splitStatements: false' }).Count -ne 2) { throw 'Invalid SQL file options' }
        $identities.Add("$id|$author|$schemaFile")
        return
    }
    if ($content -match '^databaseChangeLog:\s*\[\]\s*$') { return }
    if ($content -match '(?m)^  - changeSet:') {
        if ($lines[0] -ne 'databaseChangeLog:' -or $content -match '(?m)^  - include:') { throw 'Unsupported mixed changelog' }
        foreach ($block in ([regex]::Split($content, '(?m)(?=^  - changeSet:)') | Select-Object -Skip 1)) {
            $fields = @{}
            foreach ($key in @('id','author')) {
                $matchesForKey = [regex]::Matches($block, "(?m)^      ${key}: ([a-zA-Z0-9_.-]+)$")
                if ($matchesForKey.Count -ne 1) { throw "Missing/duplicate $key in $Path" }
                $fields[$key] = $matchesForKey[0].Groups[1].Value
            }
            foreach ($pattern in @('(?m)^      comment: ".+"$', '(?m)^      labels: ".+"$', '(?m)^      changes:$', '(?m)^      rollback:$')) {
                if ($block -notmatch $pattern) { throw "Missing changeset declaration: $Path" }
            }
            $paths = @([regex]::Matches($block, '(?m)^            path: (.+)$'))
            if ($paths.Count -lt 2 -or ([regex]::Matches($block,'(?m)^            relativeToChangelogFile: true$')).Count -ne $paths.Count -or
                ([regex]::Matches($block,'(?m)^            splitStatements: false$')).Count -ne $paths.Count) { throw 'Require relative external SQL and rollback' }
            foreach ($sql in $paths) {
                $resolvedSql = [IO.Path]::GetFullPath((Join-Path (Split-Path $resolved) $sql.Groups[1].Value))
                if (!$resolvedSql.StartsWith($repo+[IO.Path]::DirectorySeparatorChar) -or !(Test-Path -LiteralPath $resolvedSql -PathType Leaf)) { throw 'Invalid SQL reference' }
            }
            $filename = [IO.Path]::GetRelativePath($repo,$resolved).Replace('\','/')
            $identities.Add("$($fields.id)|$($fields.author)|$filename")
        }
        return
    }
    if ($lines[0] -ne 'databaseChangeLog:') { throw "Unexpected root: $Path" }
    $files = @($lines | Where-Object { $_ -match '^      file: ' })
    $relative = @($lines | Where-Object { $_ -eq '      relativeToChangelogFile: true' })
    $includes = @($lines | Where-Object { $_ -eq '  - include:' })
    if (!$files.Count -or $files.Count -ne $relative.Count -or $files.Count -ne $includes.Count) {
        throw "Invalid include structure: $Path"
    }
    foreach ($line in $lines | Select-Object -Skip 1) {
        if ($line.Trim() -and $line -notmatch '^(  - include:|      file: .+|      relativeToChangelogFile: true)$') {
            throw "Unsupported changelog grammar (not a general YAML validator): $Path"
        }
    }
    foreach ($file in $files) {
        Check-Changelog (Join-Path (Split-Path $resolved) ($file -replace '^      file: ', ''))
    }
}

Check-Changelog $entry
$all = @(Get-ChildItem -LiteralPath $repo -File -Recurse -Filter '*.yaml' |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' })
foreach ($file in $all) {
    if (!$seen.Contains($file.FullName)) { throw "Unreachable changelog: $($file.FullName)" }
}
$ddl = Get-Content -LiteralPath (Join-Path $repo '01_ddl/changelog.yaml') -Raw
$expected = @('00_extensions','01_schemas','02_types','03_tables','04_alter','05_views',
    '06_materialized_views','07_functions','08_procedures','09_triggers','10_indexes')
$actual = @([regex]::Matches($ddl, 'file: ([^/]+)/changelog.yaml') | ForEach-Object { $_.Groups[1].Value })
if (($actual -join ',') -ne ($expected -join ',')) { throw 'DDL order differs from Annex A' }
$schema = Get-Content -LiteralPath (Join-Path $repo $schemaFile) -Raw
if ($schema -notmatch [regex]::Escape('sql: "SELECT count(*) FROM pg_namespace WHERE nspname = ''appointments''"')) { throw 'Missing absent-schema precondition' }
if (($identities -join "`n") -cne $targetKeys) { throw 'Changelogs differ from explicit expected identities/order' }
$ids = @($identities | ForEach-Object { ($_ -split '\|')[0] })
if (@($ids | Select-Object -Unique).Count -ne $ids.Count) { throw 'Duplicate changeset ID' }
foreach ($pair in @(
    @('01_ddl/01_schemas/001_create_schema_appointments.sql','CREATE SCHEMA appointments AUTHORIZATION CURRENT_USER;'),
    @('05_rollbacks/01_ddl/01_schemas/001_create_schema_appointments.rollback.sql','DROP SCHEMA appointments RESTRICT;'))) {
    $sql = @(Get-Content -LiteralPath (Join-Path $repo $pair[0]) | Where-Object { $_.Trim() -and $_ -notmatch '^\s*--' }) -join ' '
    if ($sql -cne $pair[1]) { throw "Unexpected SQL scope: $($pair[0])" }
}
if ((Get-Content -LiteralPath (Join-Path $repo 'scripts/fixtures/db01-baseline.yml') -Raw).Trim() -ne 'databaseChangeLog: []') { throw 'DB-01 baseline must remain empty' }
$baselineFixture = (Get-Content -LiteralPath (Join-Path $repo 'scripts/fixtures/db02-baseline.yml') -Raw).Replace("`r`n","`n").Trim()
if ($baselineFixture -cne "databaseChangeLog:`n  - include:`n      file: 01_ddl/01_schemas/changelog.yaml`n      relativeToChangelogFile: false") {
    throw 'DB-02 baseline must reference the canonical schema changelog without SQL copies'
}

# DB-03B-B structural safeguards; real SQL/catalog validation still requires PostgreSQL.
$appointmentChange = Get-Content -LiteralPath (Join-Path $repo '01_ddl/03_tables/changelog.yaml') -Raw
foreach ($field in @('id: 002-appointments-create-appointments','author: bsbedoya','runInTransaction: true','onFail: HALT','onError: HALT','pg_catalog.pg_extension','pg_catalog.pg_opclass','pg_catalog.pg_depend','has_schema_privilege')) {
    if (!$appointmentChange.Contains($field)) { throw "Missing appointment dependency/transaction declaration: $field" }
}
$appointmentSql = Get-Content -LiteralPath (Join-Path $repo '01_ddl/03_tables/001_create_appointments.sql') -Raw
foreach ($required in @('CREATE TABLE appointments.appointments','INTO STRICT extension_schema','%I.gist_uuid_ops','NOT DEFERRABLE',"tstzrange(start_at,end_at,'[)')",'ck_appointments_interval','ck_appointments_reminder_due')) {
    if (!$appointmentSql.Contains($required)) { throw "Missing atomic appointment DDL: $required" }
}
if ($appointmentSql -match '(?i)\bDEFAULT\b|\bREFERENCES\b|\b(?:CREATE|ALTER|DROP)\s+EXTENSION\b') { throw 'Unexpected business default, FK or extension mutation' }
if ((Get-Content -LiteralPath (Join-Path $repo '05_rollbacks/01_ddl/03_tables/001_create_appointments.rollback.sql') -Raw).Trim() -cne 'DROP TABLE appointments.appointments RESTRICT;') { throw 'Unexpected appointment rollback scope' }
Write-Host "STATIC PASS: $($seen.Count) reachable changelogs; $($identities.Count) expected changesets."
Write-Host 'Static checks cover supported external-SQL grammar plus DB-02 invariants; Liquibase validates YAML at runtime.'
if ($StaticOnly) { return }

$compose = Join-Path $repo 'deploy/compose.yml'
$previousPassword = $env:DB_TEST_PASSWORD
$env:DB_TEST_PASSWORD = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
function Invoke-Compose {
    & docker compose --project-name $project --file $compose @args
    if ($LASTEXITCODE -ne 0) { throw "Docker Compose failed (exit $LASTEXITCODE)" }
}
function Query([string]$Sql) {
    $result = @(Invoke-Compose exec -T postgres psql -X -A -t -v ON_ERROR_STOP=1 -U bootstrap_test -d appointments_bootstrap_test -c $Sql)
    return ($result -join "`n").Trim()
}
function Assert-TestExtension {
    $installed = Query "SELECT count(*) FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace WHERE e.extname='btree_gist' AND n.nspname='appointments_extensions' AND pg_get_userbyid(e.extowner)='bootstrap_test' AND pg_get_userbyid(n.nspowner)='bootstrap_test';"
    if ($installed -ne '1') { throw 'Missing extension or unexpected technical namespace/owner' }
    $member = Query "SELECT count(*) FROM pg_opclass c JOIN pg_am a ON a.oid=c.opcmethod JOIN pg_namespace n ON n.oid=c.opcnamespace JOIN pg_depend d ON d.classid='pg_opclass'::regclass AND d.objid=c.oid AND d.deptype='e' AND d.refclassid='pg_extension'::regclass JOIN pg_extension e ON e.oid=d.refobjid WHERE e.extname='btree_gist' AND a.amname='gist' AND c.opcname='gist_uuid_ops' AND c.opcintype='uuid'::regtype AND c.opcdefault AND n.nspname='appointments_extensions' AND pg_get_userbyid(c.opcowner)='bootstrap_test' AND has_schema_privilege(current_user,n.oid,'USAGE');"
    if ($member -ne '1') { throw 'GiST UUID opclass membership, ownership or qualified resolution failed' }
    $visible = @(Invoke-Compose exec -T postgres psql -X -q -A -t -v ON_ERROR_STOP=1 -U bootstrap_test -d appointments_bootstrap_test -c 'BEGIN; SET LOCAL search_path=pg_catalog,appointments_extensions;' -c "SELECT pg_opclass_is_visible(oid) FROM pg_opclass WHERE opcname='gist_uuid_ops' AND opcnamespace='appointments_extensions'::regnamespace;" -c 'ROLLBACK;')
    if (($visible -join "`n").Trim() -cne 't') { throw 'UUID opclass not resolvable in explicit test search_path' }
}
function Assert-State($Expected) {
    Assert-TestExtension
    $Present = $Expected.schemaPresent
    $owner = Query "SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname='appointments';"
    if (($Present -and $owner -ne $Expected.schemaOwner) -or (!$Present -and $owner -ne '')) { throw 'Unexpected schema existence/owner' }
    $objects = Query "SELECT n.nspname||'.'||c.relname||':'||c.relkind::text FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema','appointments_liquibase') AND n.nspname NOT LIKE 'pg_toast%' AND n.nspname NOT LIKE 'pg_temp%' ORDER BY n.nspname,c.relname;"
    $other = Query "SELECT count(*) FROM pg_namespace WHERE nspname IN ('iam','patients','billing');"
    if ($objects -cne ((@($Expected.relations) | Sort-Object) -join "`n") -or $other -ne '0') { throw 'Unexpected business object or unrelated owner schema' }
    if ((Query 'SELECT current_database();') -ne 'appointments_bootstrap_test') { throw 'Wrong test database' }
    if ((Query $isolationSql) -cne $initialIsolation) { throw 'Unrelated namespace/extension changed' }
}
function Get-MetadataIdentity {
    Query "SELECT oid::text FROM pg_class WHERE oid IN (to_regclass('appointments_liquibase.databasechangelog'),to_regclass('appointments_liquibase.databasechangeloglock')) ORDER BY oid;"
}
function Assert-History($Expected) {
    $actual = Query 'SELECT id||''|''||author||''|''||filename FROM appointments_liquibase.databasechangelog ORDER BY orderexecuted;'
    if ($actual -cne (Identity $Expected.changesets)) { throw 'Unexpected history identity/order; rollback forbidden' }
    if ((Query "SELECT count(*) FROM appointments_liquibase.databasechangelog WHERE exectype <> 'EXECUTED';") -ne '0') { throw 'Unexpected execution type' }
}
function Snapshot-History([int]$Count) {
    Query "SELECT coalesce(json_agg(d ORDER BY orderexecuted)::text,'[]') FROM (SELECT * FROM appointments_liquibase.databasechangelog ORDER BY orderexecuted LIMIT $Count) d;"
}
$isolationSql = "SELECT (SELECT coalesce(json_agg(s ORDER BY nspname)::text,'[]') FROM (SELECT nspname,nspowner,nspacl FROM pg_namespace WHERE nspname NOT IN ('appointments','appointments_liquibase')) s) || (SELECT coalesce(json_agg(e ORDER BY extname)::text,'[]') FROM (SELECT oid,extname,extowner,extnamespace,extversion FROM pg_extension) e);"
try {
    & docker info --format '{{.ServerVersion}}'
    if ($LASTEXITCODE -ne 0) { throw 'Docker daemon inaccessible; no migration tests executed' }
    foreach ($scenario in @('empty','upgrade')) {
        $project = 'apt-verify-' + [guid]::NewGuid().ToString('N').Substring(0,12)
        $started = $false
        try {
            $config = (Invoke-Compose --profile tools config --format json) -join "`n" | ConvertFrom-Json
            Assert-FixtureIsolation $config $project $repo
            if (@(Invoke-Compose ps --all --quiet).Count) { throw 'Refuse existing project containers' }
            $started = $true
            Invoke-Compose up -d --wait --wait-timeout 90 postgres
            $container = (Invoke-Compose ps --quiet postgres).Trim()
            $inspectJson = & docker inspect --type container --format '{{json .}}' $container
            if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect PostgreSQL container' }
            $inspection = ($inspectJson -join "`n") | ConvertFrom-Json
            if ($LASTEXITCODE -ne 0 -or $inspection.Config.Labels.'com.docker.compose.project' -cne $project) { throw 'Wrong fixture container identity' }
            Assert-DisposablePostgresStorage $inspection
            $filesystem = (Invoke-Compose exec -T postgres stat -f -c '%T' /var/lib/postgresql/data | Out-String).Trim()
            if ($filesystem -cne 'tmpfs') { throw "Refuse PostgreSQL data filesystem: $filesystem (expected tmpfs)" }
            if ((Query 'SHOW data_directory;') -cne '/var/lib/postgresql/data') { throw 'Unexpected effective PostgreSQL data_directory' }
            Assert-TestExtension # Provisioning is complete BEFORE any verification snapshot.
            $initialIsolation = Query $isolationSql
            Assert-State ([pscustomobject]@{schemaPresent=$false;schemaOwner='bootstrap_test';relations=@()})
            $before = [pscustomobject]@{changesets=@();schemaPresent=$false;schemaOwner='bootstrap_test';relations=@()}
            $preservedHistory = '[]'
            if ($scenario -eq 'upgrade') {
                $before = $baselineState
                $fixture = if ($Baseline -eq 'DB02') {'scripts/fixtures/db02-baseline.yml'} else {'scripts/fixtures/db01-baseline.yml'}
                Invoke-Compose run --rm liquibase update "--changelog-file=$fixture"
                Assert-History $before
                $preservedHistory = Snapshot-History @($before.changesets).Count
                Assert-State $before
                $baselineMetadata = Get-MetadataIdentity
                if (@($baselineMetadata -split "`n").Count -ne 2) { throw 'Baseline metadata missing' }
            }
            Invoke-Compose run --rm liquibase validate
            Invoke-Compose run --rm liquibase update
            Assert-History $target
            Assert-State $target
            $metadata = Get-MetadataIdentity
            if (@($metadata -split "`n").Count -ne 2) { throw 'Metadata tables missing' }
            if ($scenario -eq 'upgrade' -and $metadata -cne $baselineMetadata) { throw 'Upgrade replaced baseline metadata' }
            Invoke-PgHarnessSelfTest $container
            Assert-State $target
            Invoke-AppointmentTests $container
            Assert-State $target
            $historyBefore = Snapshot-History @($target.changesets).Count

            Invoke-Compose run --rm liquibase update
            Assert-History $target
            if ((Snapshot-History @($target.changesets).Count) -cne $historyBefore) { throw 'Second update changed history' }
            Assert-History $target # Exact identities/order checked immediately before rollback.
            $rollbackCount = @($target.changesets).Count - @($before.changesets).Count
            if ($rollbackCount -gt 0) {
                Invoke-Compose run --rm liquibase rollback-count "--count=$rollbackCount"
                Assert-State $before
                Assert-History $before
                if ((Snapshot-History @($before.changesets).Count) -cne $preservedHistory) { throw 'Rollback changed baseline history' }
                if ((Get-MetadataIdentity) -cne $metadata) { throw 'Rollback replaced/deleted metadata' }
                Invoke-Compose run --rm liquibase update
                Assert-State $target
                Assert-History $target
                if ((Get-MetadataIdentity) -cne $metadata) { throw 'Reconstruction replaced metadata' }
            } else { Write-Host 'NO NEW CHANGESETS: baseline equals target; rollback/reconstruction not exercised here.' }
            if ((Snapshot-History @($before.changesets).Count) -cne $preservedHistory) { throw 'Upgrade/reconstruction changed baseline history' }
            Write-Host "PASS: $scenario expected target, repeat update and isolation verified; rollback delta=$rollbackCount."
        } finally {
            if ($started) {
                & docker compose --project-name $project --file $compose down --volumes --remove-orphans
                if ($LASTEXITCODE -ne 0) { throw "Fixture cleanup failed: $project" }
                $leftContainers = @(& docker ps -a -q --filter "label=com.docker.compose.project=$project")
                if ($LASTEXITCODE -ne 0) { throw 'Cannot check container cleanup' }
                $leftNetworks = @(& docker network ls -q --filter "label=com.docker.compose.project=$project")
                if ($LASTEXITCODE -ne 0 -or $leftContainers.Count -or $leftNetworks.Count) { throw 'Fixture cleanup left resources' }
                $leftVolumes = @(& docker volume ls -q --filter "label=com.docker.compose.project=$project")
                if ($LASTEXITCODE -ne 0 -or $leftVolumes.Count) { throw 'Fixture cleanup left project volumes' }
            }
        }
    }
} finally { $env:DB_TEST_PASSWORD = $previousPassword }
