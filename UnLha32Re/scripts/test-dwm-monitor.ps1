[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-dwm-monitored-test.ps1')
. (Join-Path $PSScriptRoot 'dwm-monitor.ps1')
$passed = 0
function Assert-Monitor([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:passed++
}

# 実際の DWM や ETW セッションを操作せず、子プロセスとの終了契約を確認する。
$testRoot = Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\build'))) ('dwm-monitor-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
try {
    $previous = [pscustomobject]@{ ProcessId = 42; PercentProcessorTime = [decimal]100000000; Timestamp_Sys100NS = [decimal]500000000 }
    $current = [pscustomobject]@{ ProcessId = 42; PercentProcessorTime = [decimal]116000000; Timestamp_Sys100NS = [decimal]520000000 }
    Assert-Monitor ((Get-CpuPercentFromRawSample $previous $current) -eq 80) 'one core CPU scaling'
    $current.PercentProcessorTime = 130000000
    Assert-Monitor ((Get-CpuPercentFromRawSample $previous $current) -eq 150) 'multicore CPU must not be clamped or normalized'
    $current.ProcessId = 43
    Assert-Monitor ($null -eq (Get-CpuPercentFromRawSample $previous $current)) 'PID replacement must reset baseline'
    $current.ProcessId = 42
    $current.Timestamp_Sys100NS = $previous.Timestamp_Sys100NS
    Assert-Monitor ($null -eq (Get-CpuPercentFromRawSample $previous $current)) 'zero elapsed counter'
    $current.Timestamp_Sys100NS = 520000000
    $current.PercentProcessorTime = 1
    Assert-Monitor ($null -eq (Get-CpuPercentFromRawSample $previous $current)) 'counter rollback'
    $consecutive = 0
    for ($index = 1; $index -le 5; $index++) {
        $state = Update-HighCpuState -CpuPercent 80 -ThresholdPercent 80 -CurrentConsecutive $consecutive -RequiredConsecutive 5
        $consecutive = $state.ConsecutiveSamples
        Assert-Monitor ($state.Triggered -eq ($index -eq 5)) "high CPU trigger at sample $index"
    }
    foreach ($cpu in @(79.999, $null)) {
        $state = Update-HighCpuState -CpuPercent $cpu -ThresholdPercent 80 -CurrentConsecutive 4 -RequiredConsecutive 5
        Assert-Monitor ($state.ConsecutiveSamples -eq 0 -and -not $state.Triggered) 'low or missing sample resets consecutive state'
    }
    foreach ($mode in @('cim-denied', 'start-denied', 'start-timeout', 'stop-timeout', 'captured', 'slow-sample')) {
        & {
            param($Mode)
            $caseDirectory = Join-Path $testRoot $Mode
            [IO.Directory]::CreateDirectory($caseDirectory) | Out-Null
            $stopPath = Join-Path $caseDirectory 'stop'
            $fixture = @{ Count = 0; Calls = [Collections.Generic.List[object]]::new() }
            if ($Mode -eq 'slow-sample') { [IO.File]::WriteAllText($stopPath, 'stop') }
            function Get-MonitorEnvironment { [pscustomobject]@{} }
            function Get-Command { param($Name, $ErrorAction) [pscustomobject]@{ Source = 'mock-wpr.exe' } }
            if ($Mode -eq 'cim-denied') {
                function Get-CimInstance {
                    param($ClassName, $Filter, $OperationTimeoutSec)
                    throw [UnauthorizedAccessException]::new('synthetic CIM denied')
                }
                [IO.File]::WriteAllText($stopPath, 'stop')
            } else {
                function Get-DwmRawSample {
                    param($SessionId)
                    $fixture.Count++
                    if ($Mode -eq 'slow-sample') { Start-Sleep -Milliseconds 50 }
                    if ($fixture.Count -gt 8) { throw 'mock sample bound exceeded' }
                    if ($fixture.Count -eq 6) { [IO.File]::WriteAllText($stopPath, 'stop') }
                    [pscustomobject]@{
                        Available = $true; SampleUtc = [DateTime]::UtcNow.ToString('o'); ProcessId = 4242
                        RawSample = [pscustomobject]@{
                            ProcessId = 4242; PercentProcessorTime = [decimal](100 * $fixture.Count)
                            Timestamp_Sys100NS = [decimal](100 * $fixture.Count)
                        }
                        UnavailableReason = $null
                    }
                }
            }
            function Invoke-WprCommand {
                param([string[]]$Arguments, [int]$TimeoutSeconds)
                $fixture.Calls.Add([pscustomobject]@{ Arguments = [string[]]$Arguments.Clone(); Timeout = $TimeoutSeconds })
                $failedStart = $Arguments[0] -eq '-start' -and $Mode -in @('start-denied', 'start-timeout')
                $timedOut = ($Arguments[0] -eq '-stop' -and $Mode -eq 'stop-timeout') -or
                    ($Arguments[0] -eq '-start' -and $Mode -eq 'start-timeout')
                if ($Arguments[0] -eq '-stop' -and -not $timedOut) { [IO.File]::WriteAllText($Arguments[1], 'synthetic trace') }
                [pscustomobject]@{
                    Succeeded = -not ($failedStart -or $timedOut)
                    ExitCode = if ($timedOut) { $null } elseif ($failedStart) { 5 } else { 0 }
                    TimedOut = $timedOut; StandardOutput = ''; StandardError = 'synthetic WPR result'
                }
            }
            $savedDuration = $script:TraceCaptureSeconds
            try {
                $script:TraceCaptureSeconds = if ($Mode -eq 'captured') { 0.25 } else { 0 }
                $interval = if ($Mode -eq 'slow-sample') { 0.1 } else { 0 }
                $postExit = if ($Mode -eq 'slow-sample') { 0.5 } else { 0 }
                Invoke-DwmMonitor -SessionId 0 -ParentProcessId $PID -OutputDirectory $caseDirectory -StopFile $stopPath `
                    -SampleIntervalSeconds $interval -ThresholdPercent 80 -ConsecutiveSamples 5 -PostExitSeconds $postExit
            } finally { $script:TraceCaptureSeconds = $savedDuration }
            $summary = Get-Content -LiteralPath (Join-Path $caseDirectory 'summary.json') -Raw | ConvertFrom-Json
            if ($Mode -eq 'cim-denied') {
                Assert-Monitor ($summary.Status -eq 'unavailable' -and $fixture.Calls.Count -eq 0) 'CIM denied must fail without WPR'
            } else {
                Assert-Monitor ($summary.Status -eq 'unhealthy') "$Mode must preserve high CPU failure"
                foreach ($call in $fixture.Calls) {
                    Assert-Monitor ($call.Arguments[-2] -eq '-instancename' -and $call.Arguments[-1] -ceq $summary.WprInstanceName) "$Mode WPR ownership"
                    if ($call.Arguments[0] -eq '-start') {
                        Assert-Monitor ($call.Arguments[1] -eq 'CPU.verbose') 'WPR profile must enable sampled stacks'
                    }
                }
                $operations = ($fixture.Calls | ForEach-Object { $_.Arguments[0] }) -join ','
                $expected = switch ($Mode) {
                    'start-denied' { '-start' }
                    'start-timeout' { '-start,-cancel' }
                    'stop-timeout' { '-start,-stop,-cancel' }
                    'captured' { '-start,-stop' }
                    'slow-sample' { '-start,-stop' }
                }
                Assert-Monitor ($operations -eq $expected) "$Mode WPR lifecycle: $operations"
                if ($Mode -eq 'captured') {
                    Assert-Monitor ($summary.TraceStatus -eq 'captured' -and [IO.File]::Exists($summary.TracePath)) 'trace result absent'
                    $traceDuration = ([datetime]$summary.TraceCompletedUtc - [datetime]$summary.TraceStartedUtc).TotalSeconds
                    Assert-Monitor ($traceDuration -ge 0.25) 'post-exit deadline truncated trace capture'
                    Assert-Monitor ($fixture.Count -le 8) 'sampling continued after post-exit deadline'
                }
            }
        } $mode
    }
    foreach ($case in @('healthy', 'test-failure', 'unavailable')) {
        $caseRoot = Join-Path $testRoot $case
        [IO.Directory]::CreateDirectory($caseRoot) | Out-Null
        $fake = Join-Path $caseRoot 'monitor.ps1'
        $readyStatus = if ($case -eq 'unavailable') { 'unavailable' } else { 'healthy' }
        $body = @'
param([int]$SessionId,[int]$ParentProcessId,[string]$OutputDirectory,[string]$StopFile)
$ready = '{"Status":"READY_STATUS","Error":"synthetic CIM access denied"}'
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'ready.tmp'), $ready)
[IO.File]::Move((Join-Path $OutputDirectory 'ready.tmp'), (Join-Path $OutputDirectory 'ready.json'))
$timer=[Diagnostics.Stopwatch]::StartNew()
while (-not [IO.File]::Exists($StopFile) -and $timer.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 10 }
if (-not [IO.File]::Exists($StopFile)) { exit 91 }
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'stop-observed'), 'yes')
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'summary.json'), '{"Status":"READY_STATUS"}')
'@
        [IO.File]::WriteAllText($fake, $body.Replace('READY_STATUS', $readyStatus))
        $counter = @{ Value = 0 }
        $failure = $null
        try {
            Invoke-DwmMonitoredTest -OutputRoot $caseRoot -MonitorPath $fake -TestAction {
                $counter.Value++
                if ($case -eq 'test-failure') { throw 'synthetic test failure' }
            } -WarningAction SilentlyContinue
        } catch { $failure = $_ }
        $expectedCount = if ($case -eq 'unavailable') { 0 } else { 1 }
        Assert-Monitor ($counter.Value -eq $expectedCount) "$case action count"
        Assert-Monitor (@(Get-ChildItem -LiteralPath $caseRoot -Recurse -Filter stop-observed).Count -eq 1) "$case stop handshake"
        if ($case -eq 'healthy') {
            Assert-Monitor ($null -eq $failure) 'healthy monitor failed'
        } elseif ($case -eq 'test-failure') {
            Assert-Monitor ($failure.Exception.Message -eq 'synthetic test failure') 'test failure was lost'
        } else {
            Assert-Monitor ($failure.Exception.Message -like '*synthetic CIM access denied*') 'unavailable readiness was ignored'
        }
    }
} finally {
    # この実行専用の配下だけを削除する。共有 build や実計測結果は保持する。
    $resolved = Get-Item -LiteralPath $testRoot
    if ($resolved.LinkType -or $resolved.Parent.FullName -ne [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\build'))) {
        throw "監視試験の清掃範囲が不正です: $testRoot"
    }
    Remove-Item -LiteralPath $resolved.FullName -Recurse -Force
}
Write-Host "DWM monitor contract tests: $passed assertions passed."
