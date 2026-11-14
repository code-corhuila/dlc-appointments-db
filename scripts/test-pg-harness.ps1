# Transport/control tests only: these child processes are NOT PostgreSQL sessions.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'pg-test-harness.ps1')
$child = @'
$held=$null; $hold=$false; $state='00000'
while ($null -ne ($line=[Console]::ReadLine())) {
    if ($line -eq '\q') { break }
    if ($line -eq 'CLOSE') { exit 1 }
    if ($line -eq 'HOLD') { $hold=$true; continue }
    if ($line -eq 'RELEASE') { $hold=$false; [Console]::WriteLine($held); continue }
    if ($line -eq 'FAIL') { $state='42601'; continue }
    if ($line -eq 'RESULT') {
        [Console]::Error.WriteLine('NOTICE: unit-result:{"sqlstate":"23514","constraint":"probe"}')
    }
    if ($line.StartsWith('\echo ')) {
        $reply=$line.Substring(6).Replace(':SQLSTATE',$state)
        if ($hold) { $held=$reply } else { [Console]::WriteLine($reply) }
    }
}
'@
$a = $b = $null
try {
    $exe = (Get-Process -Id $PID).Path
    $a = New-PgHarnessProcess $exe @('-NoProfile','-NonInteractive','-Command',$child)
    $b = New-PgHarnessProcess $exe @('-NoProfile','-NonInteractive','-Command',$child)
    $processIds=@($a.Process.Id,$b.Process.Id)
    if ($a.Process.Id -eq $b.Process.Id) { throw 'Transport processes must be independent' }
    [void](Invoke-PgHarnessCommand $a 'READY')
    Send-PgHarnessCommand $a 'HOLD'
    $timedOut=$false
    try { [void](Receive-PgHarnessCommand $a 100) } catch [TimeoutException] { $timedOut=$true }
    if (!$timedOut -or !$a.Token) { throw 'Deadline must fail and preserve outstanding command' }
    $a.Process.StandardInput.WriteLine('RELEASE')
    [void](Receive-PgHarnessCommand $a)
    $a.ResultMarker='unit-result:'
    Send-PgHarnessCommand $a 'RESULT'
    Assert-PgHarnessResult (Receive-PgHarnessResult $a) '23514' 'probe'
    $rejected=$false
    try { Assert-PgHarnessResult ([pscustomobject]@{sqlstate='23P01';constraint='wrong'}) '23P01' 'expected' }
    catch { $rejected=$true }
    if (!$rejected) { throw 'Constraint mismatch accepted' }
    $timedOut=$false
    try { Wait-PgHarnessBlocked $a @{Backend=11} @{Backend=22} 100 } catch [TimeoutException] { $timedOut=$true }
    if (!$timedOut) { throw 'Unobserved blocker accepted' }
    if ($a.Token) { [void](Receive-PgHarnessCommand $a 3000) }
    $rejected=$false
    try { [void](Invoke-PgHarnessCommand $b 'FAIL') } catch { $rejected=$true }
    if (!$rejected) { throw 'Outer SQL error accepted' }
    $rejected=$false
    try { [void](Invoke-PgHarnessCommand $b 'CLOSE') } catch { $rejected=$true }
    if (!$rejected) { throw 'Unexpected process exit accepted' }
    Send-PgHarnessCommand $a 'HOLD' # Exercise forced process cleanup with an outstanding command.
} finally {
    try { Stop-PgHarnessSession $b $null } finally { Stop-PgHarnessSession $a $null }
}
if (@(Get-Process -Id $processIds -ErrorAction SilentlyContinue).Count) { throw 'Transport cleanup left child processes' }
Write-Host 'TRANSPORT PASS: startup, independent processes, barriers, deadline/recovery, diagnostics, failures and shutdown. PostgreSQL UNTESTED.'
