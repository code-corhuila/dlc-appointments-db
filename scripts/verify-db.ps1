param([switch]$StaticOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$entry = Join-Path $repo 'changelog/changelog-master.yaml'
$seen = [Collections.Generic.HashSet[string]]::new()
$id = '001-appointments-create-schema'
$author = 'bsbedoya'
$schemaFile = '01_ddl/01_schemas/changelog.yaml'

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
        return
    }
    if ($content -match '^databaseChangeLog:\s*\[\]\s*$') { return }
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
if (@($all | Select-String -Pattern '^  - changeSet:').Count -ne 1) { throw 'DB-02 expects one changeset' }
foreach ($pair in @(
    @('01_ddl/01_schemas/001_create_schema_appointments.sql','CREATE SCHEMA appointments AUTHORIZATION CURRENT_USER;'),
    @('05_rollbacks/01_ddl/01_schemas/001_create_schema_appointments.rollback.sql','DROP SCHEMA appointments RESTRICT;'))) {
    $sql = @(Get-Content -LiteralPath (Join-Path $repo $pair[0]) | Where-Object { $_.Trim() -and $_ -notmatch '^\s*--' }) -join ' '
    if ($sql -cne $pair[1]) { throw "Unexpected SQL scope: $($pair[0])" }
}
if ((Get-Content -LiteralPath (Join-Path $repo 'scripts/fixtures/db01-baseline.yml') -Raw).Trim() -ne 'databaseChangeLog: []') { throw 'DB-01 baseline must remain empty' }
Write-Host "STATIC PASS: $($seen.Count) reachable changelogs; one schema-only changeset."
Write-Host 'Static checks cover DB-02 structure and SQL scope; Liquibase validates YAML at runtime.'
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
function Assert-State([bool]$Present) {
    $owner = Query "SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname='appointments';"
    if (($Present -and $owner -ne 'bootstrap_test') -or (!$Present -and $owner -ne '')) { throw 'Unexpected schema existence/owner' }
    $objects = Query "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema','appointments_liquibase') AND n.nspname NOT LIKE 'pg_toast%' AND n.nspname NOT LIKE 'pg_temp%';"
    $other = Query "SELECT count(*) FROM pg_namespace WHERE nspname IN ('iam','patients','billing');"
    if ($objects -ne '0' -or $other -ne '0') { throw 'Unexpected business object or unrelated owner schema' }
    if ((Query 'SELECT current_database();') -ne 'appointments_bootstrap_test') { throw 'Wrong test database' }
    if ((Query $isolationSql) -cne $initialIsolation) { throw 'Unrelated namespace/extension changed' }
}
function Get-MetadataIdentity {
    Query "SELECT oid::text FROM pg_class WHERE oid IN (to_regclass('appointments_liquibase.databasechangelog'),to_regclass('appointments_liquibase.databasechangeloglock')) ORDER BY oid;"
}
function Assert-History([int]$Count) {
    if ((Query 'SELECT count(*) FROM appointments_liquibase.databasechangelog;') -ne "$Count") { throw 'Unexpected history size' }
    if ($Count -eq 1) {
        $match = Query "SELECT count(*) FROM appointments_liquibase.databasechangelog WHERE id='$id' AND author='$author' AND filename='$schemaFile' AND exectype='EXECUTED';"
        if ($match -ne '1') { throw 'Unexpected changeset identity; rollback forbidden' }
    }
}
$isolationSql = "SELECT (SELECT coalesce(json_agg(s ORDER BY nspname)::text,'[]') FROM (SELECT nspname,nspowner,nspacl FROM pg_namespace WHERE nspname NOT IN ('appointments','appointments_liquibase')) s) || (SELECT coalesce(json_agg(e ORDER BY extname)::text,'[]') FROM (SELECT extname,extowner,extnamespace,extversion FROM pg_extension) e);"
try {
    & docker info --format '{{.ServerVersion}}'
    if ($LASTEXITCODE -ne 0) { throw 'Docker daemon inaccessible; no migration tests executed' }
    foreach ($scenario in @('empty','upgrade')) {
        $project = 'apt-db02-' + [guid]::NewGuid().ToString('N').Substring(0,12)
        $started = $false
        try {
            Invoke-Compose config --quiet
            $started = $true
            Invoke-Compose up -d --wait --wait-timeout 90 postgres
            $initialIsolation = Query $isolationSql
            Assert-State $false
            if ($scenario -eq 'upgrade') {
                Invoke-Compose run --rm liquibase update --changelog-file=scripts/fixtures/db01-baseline.yml
                Assert-History 0
                $baselineMetadata = Get-MetadataIdentity
                if (@($baselineMetadata -split "`n").Count -ne 2) { throw 'DB-01 baseline did not initialize metadata' }
                Assert-State $false
            }
            Invoke-Compose run --rm liquibase validate
            Invoke-Compose run --rm liquibase update
            Assert-History 1
            Assert-State $true
            $metadata = Get-MetadataIdentity
            if (@($metadata -split "`n").Count -ne 2) { throw 'Metadata tables missing' }
            if ($scenario -eq 'upgrade' -and $metadata -cne $baselineMetadata) { throw 'Upgrade replaced DB-01 metadata' }
            $historyBefore = Query 'SELECT row_to_json(d)::text FROM appointments_liquibase.databasechangelog d;'
            Invoke-Compose run --rm liquibase update
            Assert-History 1
            if ((Query 'SELECT row_to_json(d)::text FROM appointments_liquibase.databasechangelog d;') -cne $historyBefore) { throw 'Second update changed history' }
            Assert-History 1 # Exact identity and singleton history checked immediately before rollback.
            Invoke-Compose run --rm liquibase rollback-count --count=1
            Assert-State $false
            Assert-History 0
            if ((Get-MetadataIdentity) -cne $metadata) { throw 'Rollback replaced/deleted metadata' }
            Invoke-Compose run --rm liquibase update
            Assert-State $true
            Assert-History 1
            if ((Get-MetadataIdentity) -cne $metadata) { throw 'Reconstruction replaced metadata' }
            Write-Host "PASS: $scenario deployment, repeat update, rollback, reconstruction, isolation."
        } finally {
            if ($started) {
                & docker compose --project-name $project --file $compose down --volumes --remove-orphans
                if ($LASTEXITCODE -ne 0) { throw "Fixture cleanup failed: $project" }
            }
        }
    }
} finally { $env:DB_TEST_PASSWORD = $previousPassword }
