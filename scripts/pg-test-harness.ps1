# PowerShell 7+. Internal helper: use only inside the runner's validated disposable fixture.
function New-PgHarnessProcess([string]$Executable, [string[]]$Arguments) {
    if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'The process harness requires PowerShell 7+' }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    if (!$process.Start()) { throw 'Harness process failed to start' }
    $process.StandardInput.AutoFlush = $true
    [pscustomobject]@{ Process=$process; OutTask=$process.StandardOutput.ReadLineAsync();
        ErrTask=$process.StandardError.ReadLineAsync(); Output=[Collections.Generic.List[string]]::new();
        Errors=[Collections.Generic.List[string]]::new(); Token=''; Backend=0; ResultMarker='' }
}
function Read-PgHarnessStreams($Session) {
    foreach ($pair in @(@('OutTask','Output','StandardOutput'),@('ErrTask','Errors','StandardError'))) {
        $task = $Session.($pair[0])
        if ($null -ne $task -and $task.IsCompleted) {
            $line = $task.GetAwaiter().GetResult()
            if ($null -eq $line) { $Session.($pair[0]) = $null }
            else {
                $Session.($pair[1]).Add($line)
                $Session.($pair[0]) = $Session.Process.($pair[2]).ReadLineAsync()
            }
        }
    }
}
function Send-PgHarnessCommand($Session, [string]$Sql) {
    if ($Session.Token) { throw 'Session already has an outstanding command' }
    if ($Session.Process.HasExited) { throw 'Harness process exited before command' }
    $Session.Output.Clear()
    $Session.Errors.Clear()
    $Session.Token = 'H_DONE_' + [guid]::NewGuid().ToString('N')
    $Session.Process.StandardInput.WriteLine($Sql)
    $Session.Process.StandardInput.WriteLine('\echo ' + $Session.Token + ' :SQLSTATE')
}
function Receive-PgHarnessCommand($Session, [int]$TimeoutMs = 12000) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.ElapsedMilliseconds -lt $TimeoutMs) {
        Read-PgHarnessStreams $Session
        $done = @($Session.Output | Where-Object { $_.StartsWith($Session.Token+' ') })
        if ($done.Count) {
            $token = $Session.Token
            $Session.Token = ''
            if ($done.Count -ne 1 -or $done[0] -cne "$token 00000") {
                throw "Outer SQL failure: $($done -join ','); $($Session.Errors -join ' ')"
            }
            return (@($Session.Output | Where-Object { !$_.StartsWith($token+' ') }) -join [Environment]::NewLine)
        }
        if ($null -eq $Session.OutTask) { throw "Harness stdout closed: $($Session.Errors -join ' ')" }
        Start-Sleep -Milliseconds 10 # Poll completion, never use sleep as a coordination barrier.
    }
    throw [TimeoutException]::new('Harness command deadline exceeded; NOT a conflict result')
}
function Invoke-PgHarnessCommand($Session, [string]$Sql, [int]$TimeoutMs = 12000) {
    Send-PgHarnessCommand $Session $Sql
    Receive-PgHarnessCommand $Session $TimeoutMs
}
function Start-PgHarnessSession([string]$Container, [string]$Name) {
    if ($Container -notmatch '^[a-f0-9]{12,64}$' -or $Name -notmatch '^apt-harness-[a-z0-9-]+$') {
        throw 'Invalid isolated fixture/session identity'
    }
    $session = New-PgHarnessProcess 'docker' @('exec','-i','--env',"PGAPPNAME=$Name",
        '--env','PGCONNECT_TIMEOUT=5','--env','LC_ALL=C',$Container,'psql','-X','-q','-A','-t','-w',
        '-v','ON_ERROR_STOP=0','-U','bootstrap_test','-d','appointments_bootstrap_test')
    try {
        $session.Backend = [int](Invoke-PgHarnessCommand $session "SET statement_timeout='10s'; SELECT pg_backend_pid();")
        if ($session.Backend -le 0) { throw 'Missing PostgreSQL session PID' }
        return $session
    } catch {
        if (!$session.Process.HasExited) { $session.Process.Kill($true); [void]$session.Process.WaitForExit(2000) }
        $session.Process.Dispose()
        throw
    }
}
# Trusted fixture SQL only. Exception subtransactions return structured diagnostics without helper objects.
function Send-PgHarnessStatement($Session, [string]$Sql) {
    $Session.ResultMarker = 'H_RESULT_' + [guid]::NewGuid().ToString('N') + ':'
    $literal = $Sql.Replace("'","''")
    $block = @'
DO $harness$
DECLARE s text := '00000'; c text;
BEGIN
  BEGIN
    EXECUTE '__SQL__';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS s = RETURNED_SQLSTATE, c = CONSTRAINT_NAME;
  END;
  RAISE NOTICE '__MARKER__%', json_build_object('sqlstate',s,'constraint',nullif(c,''));
END $harness$;
'@
    $block = $block.Replace('$harness$', '$h_'+[guid]::NewGuid().ToString('N')+'$')
    Send-PgHarnessCommand $Session ($block.Replace('__MARKER__',$Session.ResultMarker).Replace('__SQL__',$literal))
}
function Receive-PgHarnessResult($Session, [int]$TimeoutMs = 12000) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    [void](Receive-PgHarnessCommand $Session $TimeoutMs)
    while ($clock.ElapsedMilliseconds -lt $TimeoutMs) {
        Read-PgHarnessStreams $Session
        $records = @($Session.Errors | Where-Object { $_.Contains($Session.ResultMarker) })
        if ($records.Count -eq 1) {
            return ($records[0].Substring($records[0].IndexOf($Session.ResultMarker)+$Session.ResultMarker.Length) | ConvertFrom-Json)
        }
        if ($records.Count -gt 1) { throw 'Ambiguous SQL diagnostics' }
        Start-Sleep -Milliseconds 10
    }
    throw [TimeoutException]::new('Missing structured SQL diagnostics')
}
function Assert-PgHarnessResult($Result, [string]$SqlState = '00000', [string]$Constraint = '') {
    if ($Result.sqlstate -cne $SqlState -or [string]$Result.constraint -cne $Constraint) {
        throw "Unexpected SQL result: $($Result | ConvertTo-Json -Compress)"
    }
}
function Wait-PgHarnessBlocked($Observer, $First, $Second, [int]$TimeoutMs = 3000) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.ElapsedMilliseconds -lt $TimeoutMs) {
        $remaining = [Math]::Max(1,$TimeoutMs-[int]$clock.ElapsedMilliseconds)
        $sql = "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid=$($Second.Backend) AND state='active' AND xact_start IS NOT NULL AND $($First.Backend)=ANY(pg_blocking_pids(pid)));"
        if ((Invoke-PgHarnessCommand $Observer $sql $remaining) -ceq 't') { return }
        Start-Sleep -Milliseconds 10
    }
    throw [TimeoutException]::new('Required blocker was not observed')
}
function Stop-PgHarnessSession($Session, $Observer) {
    if ($null -eq $Session) { return }
    try {
        if (!$Session.Process.HasExited) {
            $Session.Process.StandardInput.WriteLine('\q')
            $Session.Process.StandardInput.Close()
            if (!$Session.Process.WaitForExit(1500)) {
                if ($null -ne $Observer -and $Session.Backend -gt 0) {
                    if ($Observer.Token) { [void](Receive-PgHarnessCommand $Observer 3000) }
                    [void](Invoke-PgHarnessCommand $Observer "SELECT pg_terminate_backend($($Session.Backend));" 3000)
                }
                if (!$Session.Process.WaitForExit(1500)) {
                    $Session.Process.Kill($true)
                    if (!$Session.Process.WaitForExit(1500)) { throw 'Harness process cleanup timed out' }
                }
            }
        }
    } finally {
        try {
            if (!$Session.Process.HasExited) {
                $Session.Process.Kill($true)
                if (!$Session.Process.WaitForExit(1500)) { throw 'Harness process survived forced cleanup' }
            }
        } finally { $Session.Process.Dispose() }
    }
}
function Invoke-PgHarnessSelfTest([string]$Container) {
    $observer = $first = $second = $null
    $suffix = [guid]::NewGuid().ToString('N')
    try {
        $observer = Start-PgHarnessSession $Container "apt-harness-$suffix-observer"
        $first = Start-PgHarnessSession $Container "apt-harness-$suffix-first"
        $second = Start-PgHarnessSession $Container "apt-harness-$suffix-second"
        $pids = @($observer.Backend,$first.Backend,$second.Backend)
        if (@($pids | Select-Object -Unique).Count -ne 3) { throw 'Independent PostgreSQL sessions required' }
        foreach ($finish in @('COMMIT','ROLLBACK')) {
            [void](Invoke-PgHarnessCommand $first 'BEGIN; SELECT pg_advisory_xact_lock(732019,1);')
            [void](Invoke-PgHarnessCommand $second 'BEGIN;')
            Send-PgHarnessStatement $second 'SELECT pg_advisory_xact_lock(732019,1)'
            Wait-PgHarnessBlocked $observer $first $second
            $timedOut = $false
            try { [void](Receive-PgHarnessCommand $second 100) }
            catch [TimeoutException] { $timedOut = $true }
            if (!$timedOut) { throw 'Deadline probe completed while blocked' }
            [void](Invoke-PgHarnessCommand $first "$finish;")
            Assert-PgHarnessResult (Receive-PgHarnessResult $second)
            [void](Invoke-PgHarnessCommand $second 'ROLLBACK;')
        }
        [void](Invoke-PgHarnessCommand $second 'BEGIN;')
        Send-PgHarnessStatement $second 'DO $probe$ BEGIN RAISE EXCEPTION USING ERRCODE=''23514'', CONSTRAINT=''harness_diagnostic_probe''; END $probe$'
        $result = Receive-PgHarnessResult $second
        Assert-PgHarnessResult $result '23514' 'harness_diagnostic_probe'
        $rejected = $false
        try { Assert-PgHarnessResult $result } catch { $rejected = $true }
        if (!$rejected) { throw 'Unexpected-error assertion failed open' }
        [void](Invoke-PgHarnessCommand $second 'ROLLBACK;')
    } finally {
        $workers = @($first,$second | Where-Object { $null -ne $_ })
        $backends = @($workers | ForEach-Object { $_.Backend })
        try { Stop-PgHarnessSession $second $observer }
        finally {
            try { Stop-PgHarnessSession $first $observer }
            finally {
                try {
                    if ($null -ne $observer -and $backends.Count) {
                        if ($observer.Token) { [void](Receive-PgHarnessCommand $observer 3000) }
                        $clock = [Diagnostics.Stopwatch]::StartNew()
                        do {
                            $left = Invoke-PgHarnessCommand $observer "SELECT count(*) FROM pg_stat_activity WHERE pid IN ($($backends -join ','));" 1000
                            if ($left -ceq '0') { break }
                            Start-Sleep -Milliseconds 10
                        } while ($clock.ElapsedMilliseconds -lt 3000)
                        if ($left -cne '0') { throw 'Harness cleanup left PostgreSQL sessions' }
                    }
                } finally { Stop-PgHarnessSession $observer $null }
            }
        }
    }
    Write-Host 'HARNESS PASS: sessions, blocking, release, deadlines, diagnostics and cleanup; NOT appointment tests.'
}
