# Validate effective Compose configuration, without contacting a database.
function Assert-FixtureIsolation($Config, [string]$Project, [string]$Repo) {
    if (($Config.services.PSObject.Properties.Name | Sort-Object) -join ',' -cne 'liquibase,postgres') { throw 'Unexpected fixture services' }
    if ($Config.name -cne $Project) { throw 'Unexpected Compose project' }
    if ($Config.PSObject.Properties['volumes']) { throw 'Persistent volumes forbidden' }
    if (@($Config.networks.PSObject.Properties).Count -ne 1 -or !$Config.networks.default.internal -or
        $Config.networks.default.name -cne "${Project}_default" -or $Config.networks.default.PSObject.Properties['external']) { throw 'Require isolated internal project network' }
    foreach ($service in @($Config.services.postgres,$Config.services.liquibase)) {
        foreach ($unsafe in @('ports','network_mode','container_name','external_links','volumes_from','env_file')) {
            if ($service.PSObject.Properties[$unsafe]) { throw "Forbidden Compose option: $unsafe" }
        }
        if (($service.networks.PSObject.Properties.Name -join ',') -cne 'default') { throw 'Unexpected service network' }
    }
    if ($Config.services.postgres.image -cne 'postgres:16.13' -or $Config.services.liquibase.image -cne 'liquibase/liquibase:4.33.0') { throw 'Fixture requires the documented fixed test images' }
    if (($Config.services.postgres.tmpfs -join ',') -cne '/var/lib/postgresql/data') { throw 'Database storage must be tmpfs' }
    $expectedMounts = @(
        @($Config.services.postgres,'deploy/init-test.sql','/docker-entrypoint-initdb.d/001-metadata.sql'),
        @($Config.services.liquibase,'.','/liquibase/changelog'))
    foreach ($item in $expectedMounts) {
        $mounts = @($item[0].volumes)
        if ($mounts.Count -ne 1) { throw 'Unexpected fixture mounts' }
        $mount = $mounts[0]
        if ($mount.type -cne 'bind' -or !$mount.read_only -or $mount.target -cne $item[2] -or
            [IO.Path]::GetFullPath($mount.source) -ne [IO.Path]::GetFullPath((Join-Path $Repo $item[1]))) { throw 'Only repository read-only mounts allowed' }
    }
    $pg = $Config.services.postgres.environment
    $lb = $Config.services.liquibase.environment
    if ($pg.POSTGRES_DB -cne 'appointments_bootstrap_test' -or $pg.POSTGRES_USER -cne 'bootstrap_test' -or
        $lb.LIQUIBASE_COMMAND_URL -cne 'jdbc:postgresql://postgres:5432/appointments_bootstrap_test' -or
        $lb.LIQUIBASE_COMMAND_USERNAME -cne 'bootstrap_test' -or $lb.LIQUIBASE_COMMAND_PASSWORD -cne $pg.POSTGRES_PASSWORD) { throw 'External connection or unexpected fixture credentials' }
}

# Linux paths are case-sensitive. Accept only the fixture's exact data directory.
function Assert-DisposablePostgresStorage($Inspection) {
    $data = '/var/lib/postgresql/data'
    if ($null -eq $Inspection -or !$Inspection.PSObject.Properties['Mounts'] -or
        $null -eq $Inspection.HostConfig -or $null -eq $Inspection.Config) { throw 'Incomplete container storage inspection' }
    $pgdata = @($Inspection.Config.Env | Where-Object { $_ -clike 'PGDATA=*' })
    if ($pgdata.Count -ne 1 -or $pgdata[0] -cne "PGDATA=$data") { throw 'Unexpected PostgreSQL PGDATA path' }
    $proven = $false
    $hostMounts = $Inspection.HostConfig.PSObject.Properties['Mounts']
    $sources = @(
        @{ Entries = $Inspection.Mounts; Key = 'Destination' },
        @{ Entries = $(if ($null -ne $hostMounts) { $hostMounts.Value }); Key = 'Target' })
    foreach ($source in $sources) {
        $matchesAtData = 0
        foreach ($mount in @($source.Entries)) {
            if ($null -eq $mount) { continue }
            $path = [string]$mount.($source.Key)
            if (!$path.StartsWith('/',[StringComparison]::Ordinal)) { throw 'Unrecognized container mount path' }
            if ($path -ceq $data -or $path.StartsWith($data+'/',[StringComparison]::Ordinal) -or
                ($data+'/').StartsWith($path.TrimEnd('/')+'/',[StringComparison]::Ordinal)) {
                if ($path -cne $data -or [string]$mount.Type -cne 'tmpfs') { throw "Persistent or unexpected mount intersects PGDATA: $path" }
                $sourceProperty = $mount.PSObject.Properties['Source']
                if ($null -ne $sourceProperty -and [string]$sourceProperty.Value -cne '') { throw 'tmpfs must not reference persistent source storage' }
                $matchesAtData++
                $proven = $true
            }
        }
        if ($matchesAtData -gt 1) { throw 'Ambiguous duplicate data mounts' }
    }
    $tmpfsProperty = $Inspection.HostConfig.PSObject.Properties['Tmpfs']
    if ($null -ne $tmpfsProperty -and $null -ne $tmpfsProperty.Value) {
        $map = $tmpfsProperty.Value
        if ($map -isnot [Collections.IDictionary] -and $map -isnot [pscustomobject]) { throw 'Unrecognized HostConfig.Tmpfs map' }
        $keys = if ($map -is [Collections.IDictionary]) { @($map.Keys) } else { @($map.PSObject.Properties.Name) }
        foreach ($path in $keys) {
            $options = if ($map -is [Collections.IDictionary]) { $map[$path] } else { $map.PSObject.Properties[$path].Value }
            if ($path -isnot [string] -or !$path.StartsWith('/',[StringComparison]::Ordinal) -or $options -isnot [string]) { throw 'Invalid tmpfs path/options' }
            if ($path -ceq $data) { $proven = $true }
            elseif ($path.StartsWith($data+'/',[StringComparison]::Ordinal) -or
                ($data+'/').StartsWith($path.TrimEnd('/')+'/',[StringComparison]::Ordinal)) { throw "Unexpected nested/parent tmpfs: $path" }
        }
    }
    $bindsProperty = $Inspection.HostConfig.PSObject.Properties['Binds']
    if ($null -ne $bindsProperty) {
        foreach ($bind in @($bindsProperty.Value)) {
            if ($null -eq $bind) { continue }
            if ($bind -notmatch ':(/[^:]+)(?::[^:]*)?$') { throw 'Unrecognized Docker bind specification' }
            $path = $Matches[1]
            if ($path -ceq $data -or $path.StartsWith($data+'/',[StringComparison]::Ordinal) -or
                ($data+'/').StartsWith($path.TrimEnd('/')+'/',[StringComparison]::Ordinal)) { throw 'Host bind intersects PostgreSQL data' }
        }
    }
    if (!$proven) { throw "Disposable storage not proven: no tmpfs at $data in Mounts or HostConfig.Tmpfs" }
}
