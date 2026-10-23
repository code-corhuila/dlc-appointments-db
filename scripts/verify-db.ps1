param([switch]$StaticOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$entry = Join-Path $repo 'changelog/changelog-master.yaml'
$seen = [Collections.Generic.HashSet[string]]::new()

function Check-Changelog([string]$Path) {
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not $resolved.StartsWith($repo + [IO.Path]::DirectorySeparatorChar)) {
        throw "Changelog outside repository: $Path"
    }
    if (-not $seen.Add($resolved)) { throw "Repeated include: $Path" }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Missing: $Path" }
    $lines = @(Get-Content -LiteralPath $resolved)
    $content = $lines -join "`n"
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
            throw "Unsupported DB-01 YAML (not a general YAML validator): $Path"
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
Write-Host "STATIC PASS: $($seen.Count) reachable changelogs; DB-01 contains zero changesets."
Write-Host 'Static checks cover the current include-only grammar, not Liquibase validation.'
if ($StaticOnly) { return }

$compose = Join-Path $repo 'deploy/compose.yml'
$project = 'apt-db01-' + [guid]::NewGuid().ToString('N').Substring(0,12)
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
function Assert-EmptyBusiness {
    $objects = Query "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema','appointments_liquibase') AND n.nspname NOT LIKE 'pg_toast%' AND n.nspname NOT LIKE 'pg_temp%';"
    $schemas = Query "SELECT count(*) FROM pg_namespace WHERE nspname IN ('appointments','iam','patients','billing');"
    $extensions = Query "SELECT count(*) FROM pg_extension WHERE extname <> 'plpgsql';"
    if ($objects -ne '0' -or $schemas -ne '0' -or $extensions -ne '0') {
        throw 'Unexpected business object/schema or extension in DB-01 fixture'
    }
}
function Assert-ZeroHistory {
    $exists = Query "SELECT to_regclass('appointments_liquibase.databasechangelog') IS NOT NULL;"
    if ($exists -eq 't') {
        if ((Query 'SELECT count(*) FROM appointments_liquibase.databasechangelog;') -ne '0') {
            throw 'DB-01 unexpectedly recorded a changeset'
        }
    } elseif ($exists -ne 'f') { throw 'Could not inspect Liquibase history' }
}
$started = $false
try {
    & docker info --format '{{.ServerVersion}}'
    if ($LASTEXITCODE -ne 0) { throw 'Docker daemon unavailable; no migrations executed' }
    Invoke-Compose config --quiet
    $started = $true
    Invoke-Compose up -d --wait --wait-timeout 90 postgres
    Assert-EmptyBusiness
    Invoke-Compose run --rm liquibase --version
    Invoke-Compose run --rm liquibase validate
    Invoke-Compose run --rm liquibase update
    Assert-ZeroHistory
    Assert-EmptyBusiness
    Invoke-Compose run --rm liquibase update
    Assert-ZeroHistory
    Write-Host 'ROLLBACK NOT APPLICABLE: zero own changesets; no rollback command issued.'
    Invoke-Compose run --rm liquibase update
    Assert-ZeroHistory
    Assert-EmptyBusiness
    Write-Host 'DB-01 PASS: empty changelog lifecycle only; no business persistence proven.'
} finally {
    # Only the unique project created by this invocation can be removed.
    if ($started) {
        & docker compose --project-name $project --file $compose down --volumes --remove-orphans
        if ($LASTEXITCODE -ne 0) { Write-Warning "Fixture cleanup failed: $project" }
    }
    $env:DB_TEST_PASSWORD = $previousPassword
}
