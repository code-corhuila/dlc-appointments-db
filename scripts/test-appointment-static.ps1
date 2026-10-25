# Negative structural probes in a temporary copy; never executes Docker or SQL.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$probe = Join-Path $tempRoot ('apt-db03-static-' + [guid]::NewGuid().ToString('N'))
$exe = (Get-Process -Id $PID).Path
$sql = '01_ddl/03_tables/001_create_appointments.sql'
$yaml = '01_ddl/03_tables/changelog.yaml'
$rollback = '05_rollbacks/01_ddl/03_tables/001_create_appointments.rollback.sql'
$cases = @(
    @($sql,'NOT DEFERRABLE','DEFERRABLE','Missing atomic appointment DDL'),
    @($sql,'version integer NOT NULL','version integer NOT NULL DEFAULT 1','Unexpected business default'),
    @($sql,'END $migration$;','END $migration$; CREATE EXTENSION btree_gist;','extension mutation'),
    @($yaml,'runInTransaction: true','runInTransaction: false','Missing appointment dependency/transaction'),
    @($yaml,'pg_catalog.pg_depend','pg_catalog.pg_class','Missing appointment dependency/transaction'),
    @($yaml,'author: bsbedoya','author: unapproved','Changelogs differ'),
    @($rollback,'RESTRICT','CASCADE','Unexpected appointment rollback')
)
try {
    [void][IO.Directory]::CreateDirectory($probe)
    foreach ($dir in @('01_ddl','02_dml','03_dcl','04_tcl','05_rollbacks','changelog','scripts')) {
        Copy-Item -LiteralPath (Join-Path $repo $dir) -Destination $probe -Recurse
    }
    foreach ($case in $cases) {
        $path = Join-Path $probe $case[0]
        $original = [IO.File]::ReadAllText($path)
        if (!$original.Contains($case[1])) { throw "Probe anchor missing: $($case[1])" }
        try {
            [IO.File]::WriteAllText($path,$original.Replace($case[1],$case[2]))
            $output = & $exe -NoProfile -File (Join-Path $probe 'scripts/verify-db.ps1') -StaticOnly 2>&1
            if ($LASTEXITCODE -eq 0 -or ($output -join ' ') -notmatch [regex]::Escape($case[3])) {
                throw "Probe failed or rejected for the wrong reason: $($case[1]); $($output -join ' ')"
            }
        } finally { [IO.File]::WriteAllText($path,$original) }
    }
    Write-Host "STATIC NEGATIVE PASS: $($cases.Count) unsafe mutations rejected; no PostgreSQL tests executed."
} finally {
    $resolved = [IO.Path]::GetFullPath($probe)
    if (!$resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notlike 'apt-db03-static-*') { throw 'Refuse unsafe probe cleanup path' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
