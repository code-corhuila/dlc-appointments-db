# Runs deploy/bootstrap.sql and the environment migrator against a disposable PostgreSQL.
# Proves the owner roles, not the fixture superuser, can deploy every environment.
param([ValidateSet('dev','qa','prod')][string[]]$Environments = @('dev','qa','prod'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$postgresImage = 'postgres:16.13'
$migrate = Join-Path $repo 'deploy/compose.migrate.yml'
$bootstrap = Join-Path $repo 'deploy/bootstrap.sql'
$expectedChangesets = 14

function New-Secret { [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)) }
function Assert-Exit([string]$What) { if ($LASTEXITCODE -ne 0) { throw "$What failed with exit $LASTEXITCODE" } }

foreach ($environment in $Environments) {
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $network = "apt-envmig-$suffix"
    $server = "apt-envmig-pg-$suffix"
    $secrets = Join-Path $tempRoot "apt-envmig-$suffix"
    $admin = New-Secret
    $migrator = New-Secret
    $runtime = New-Secret
    function Psql([string]$User, [string]$Password, [string[]]$Arguments) {
        $output = @(& docker exec -e "PGPASSWORD=$Password" $server psql -X -A -t -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -U $User -d di_lucca @Arguments 2>&1)
        [pscustomobject]@{ Exit = $LASTEXITCODE; Text = ($output -join "`n").Trim() }
    }
    function Scalar([string]$User, [string]$Password, [string]$Sql) {
        $result = Psql $User $Password @('-c', $Sql)
        if ($result.Exit -ne 0) { throw "Query failed as ${User}: $($result.Text)" }
        $result.Text
    }
    function Migrate([string]$Command) {
        $env:DLC_ENVIRONMENT = $environment
        $env:DLC_POSTGRES_HOST = 'dlc-postgres'
        $env:DLC_POSTGRES_DB = 'di_lucca'
        $env:DLC_PLATFORM_NETWORK = $network
        $env:APPOINTMENTS_MIGRATOR_PASSWORD_FILE = Join-Path $secrets 'migrator.txt'
        & docker compose --project-name "apt-envmig-$suffix" --file $migrate --profile tooling run --rm appointments-db-migrate $Command
        Assert-Exit "Liquibase $Command ($environment)"
    }
    try {
        [void][IO.Directory]::CreateDirectory($secrets)
        [IO.File]::WriteAllText((Join-Path $secrets 'migrator.txt'), $migrator)
        & docker network create --internal $network | Out-Null; Assert-Exit 'Network creation'
        & docker run -d --name $server --network $network --network-alias dlc-postgres --tmpfs /var/lib/postgresql/data `
            -e POSTGRES_DB=di_lucca -e POSTGRES_USER=dlc_admin -e "POSTGRES_PASSWORD=$admin" $postgresImage | Out-Null
        Assert-Exit 'PostgreSQL start'
        $ready = $false
        foreach ($attempt in 1..45) {
            & docker exec $server pg_isready -h 127.0.0.1 -U dlc_admin -d di_lucca 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $ready = $true; break }
            Start-Sleep -Seconds 2
        }
        if (!$ready) { throw 'PostgreSQL did not become ready' }

        # DBA steps: bootstrap twice (re-runnable), then credentials from the secret manager.
        & docker cp $bootstrap "${server}:/tmp/bootstrap.sql" | Out-Null; Assert-Exit 'Bootstrap copy'
        foreach ($pass in 1..2) {
            $result = Psql 'dlc_admin' $admin @('-f', '/tmp/bootstrap.sql')
            if ($result.Exit -ne 0) { throw "Bootstrap pass $pass failed: $($result.Text)" }
        }
        [void](Scalar 'dlc_admin' $admin "ALTER ROLE appointments_migrator PASSWORD '$migrator'; ALTER ROLE appointments_runtime PASSWORD '$runtime';")

        Migrate 'validate'
        Migrate 'update'
        # Seal: the re-run bootstrap revokes database CREATE once the owner schema exists.
        $seal = Psql 'dlc_admin' $admin @('-f', '/tmp/bootstrap.sql')
        if ($seal.Exit -ne 0) { throw "Bootstrap seal failed: $($seal.Text)" }
        if ((Scalar 'dlc_admin' $admin "SELECT has_database_privilege('appointments_migrator', 'di_lucca', 'CREATE')") -ne 'f') {
            throw 'Migrator kept CREATE on the database after the seal'
        }
        Migrate 'update'

        $applied = Scalar 'dlc_admin' $admin 'SELECT count(*) FROM appointments_liquibase.databasechangelog'
        if ([int]$applied -ne $expectedChangesets) { throw "Expected $expectedChangesets changesets, found $applied" }
        $owner = Scalar 'dlc_admin' $admin "SELECT r.rolname FROM pg_namespace n JOIN pg_roles r ON r.oid = n.nspowner WHERE n.nspname = 'appointments'"
        if ($owner -ne 'appointments_migrator') { throw "Unexpected appointments schema owner: $owner" }
        $foreign = Scalar 'dlc_admin' $admin "SELECT count(*) FROM pg_class c JOIN pg_roles r ON r.oid = c.relowner WHERE c.relnamespace = 'appointments'::regnamespace AND r.rolname <> 'appointments_migrator'"
        if ([int]$foreign -ne 0) { throw 'Appointments objects owned by another role' }

        # Same rule as dlc-infra-postgres scripts/check-owner-scope.sh, run with runtime credentials.
        $scope = Scalar 'appointments_runtime' $runtime @"
SELECT CASE WHEN NOT r.rolsuper AND NOT r.rolcreatedb AND NOT r.rolcreaterole AND NOT r.rolreplication AND NOT r.rolbypassrls
  AND has_schema_privilege(current_user, 'appointments', 'USAGE')
  AND NOT EXISTS (SELECT 1 FROM pg_namespace w WHERE left(w.nspname, 3) <> 'pg_' AND w.nspname <> 'information_schema'
                  AND has_schema_privilege(current_user, w.oid, 'CREATE'))
  THEN 'OWNER_SCOPE_OK' ELSE 'OWNER_SCOPE_FAILED' END
FROM pg_roles r WHERE r.rolname = current_user
"@
        if ($scope -ne 'OWNER_SCOPE_OK') { throw "Runtime owner scope failed: $scope" }

        # Runtime works through the owner grants only, including the GiST exclusions.
        $smoke = Psql 'appointments_runtime' $runtime @('-c', @"
BEGIN;
INSERT INTO appointments.dentist_schedules (schedule_id, dentist_id, version, created_at, created_by, updated_at, updated_by)
VALUES ('00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-0000000000d1', 1, now(), '00000000-0000-4000-8000-0000000000a1', now(), '00000000-0000-4000-8000-0000000000a1');
INSERT INTO appointments.availability_intervals (interval_id, schedule_id, start_at, end_at)
VALUES ('00000000-0000-4000-8000-000000000011', '00000000-0000-4000-8000-000000000001', '2030-01-07 13:00Z', '2030-01-07 15:00Z');
ROLLBACK;
"@)
        if ($smoke.Exit -ne 0) { throw "Runtime DML smoke failed: $($smoke.Text)" }
        foreach ($forbidden in @(
            'CREATE TABLE appointments.runtime_probe (id integer)',
            'DELETE FROM appointments.appointment_status_changes',
            'TRUNCATE appointments.outbox_events',
            'SELECT count(*) FROM appointments_liquibase.databasechangelog'
        )) {
            $denied = Psql 'appointments_runtime' $runtime @('-c', $forbidden)
            if ($denied.Exit -eq 0 -or $denied.Text -notmatch 'permission denied') { throw "Runtime was not denied: $forbidden" }
        }
        $ddl = Psql 'appointments_migrator' $migrator @('-c', 'CREATE EXTENSION IF NOT EXISTS pgcrypto')
        if ($ddl.Exit -eq 0) { throw 'Migrator installed an extension' }
        Write-Host "PASS ($environment): bootstrap x2, validate, update, seal, repeat update, $applied changesets as appointments_migrator, runtime scope and grants."
    } finally {
        foreach ($name in @('DLC_ENVIRONMENT','DLC_POSTGRES_HOST','DLC_POSTGRES_DB','DLC_PLATFORM_NETWORK','APPOINTMENTS_MIGRATOR_PASSWORD_FILE')) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
        & docker rm -f $server 2>&1 | Out-Null
        & docker network rm $network 2>&1 | Out-Null
        $resolved = [IO.Path]::GetFullPath($secrets)
        if (!$resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolved) -notlike 'apt-envmig-*') { throw 'Refuse unsafe secret cleanup path' }
        if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    }
}
