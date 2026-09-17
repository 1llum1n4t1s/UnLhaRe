function Invoke-DwmMonitoredTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$TestAction,
        [Parameter(Mandatory)][string]$OutputRoot,
        [string]$MonitorPath = (Join-Path $PSScriptRoot 'dwm-monitor.ps1')
    )

    $runDirectory = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ('run-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($runDirectory) | Out-Null
    $stopFile = Join-Path $runDirectory 'stop'
    $readyFile = Join-Path $runDirectory 'ready.json'
    $summaryFile = Join-Path $runDirectory 'summary.json'
    $monitor = [Diagnostics.Process]::new()
    $testFailure = $null
    $monitorFailure = $null
    $started = $false
    $stdout = $null
    $stderr = $null
    try {
        $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in @('-NoProfile', '-File', [IO.Path]::GetFullPath($MonitorPath),
                '-SessionId', [string](Get-Process -Id $PID).SessionId,
                '-ParentProcessId', [string]$PID, '-OutputDirectory', $runDirectory, '-StopFile', $stopFile)) {
            $start.ArgumentList.Add($argument)
        }
        $monitor.StartInfo = $start
        if (-not $monitor.Start()) { throw 'DWM 監視プロセスを起動できません。' }
        $started = $true
        $stdout = $monitor.StandardOutput.ReadToEndAsync()
        $stderr = $monitor.StandardError.ReadToEndAsync()
        $startup = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $readyFile)) {
            if ($monitor.HasExited -or $startup.Elapsed.TotalSeconds -ge 30) {
                throw "DWM 監視の準備を確認できません: $runDirectory"
            }
            Start-Sleep -Milliseconds 100
        }
        $ready = Get-Content -LiteralPath $readyFile -Raw | ConvertFrom-Json
        if ($ready.Status -ne 'healthy') {
            throw "DWM 監視を開始できません: $($ready.Error) ($runDirectory)"
        }
        Write-Host "DWM monitoring: $runDirectory"
        & $TestAction
    } catch {
        $testFailure = $_
    } finally {
        if ($started) {
            try {
                # 試験が例外終了した場合も、停止後の負荷と採取結果を回収する。
                [IO.File]::WriteAllText($stopFile, [DateTime]::UtcNow.ToString('o'))
                $shutdown = [Diagnostics.Stopwatch]::StartNew()
                while (-not $monitor.WaitForExit(1000) -and $shutdown.Elapsed.TotalSeconds -lt 120) { }
                if (-not $monitor.HasExited) {
                    # OS の診断セッションを残さないため、監視を強制終了しない。
                    throw "DWM 監視が終了待ち上限を超えました (PID $($monitor.Id)): $runDirectory"
                }
                [IO.File]::WriteAllText((Join-Path $runDirectory 'monitor.stdout.log'), $stdout.GetAwaiter().GetResult())
                [IO.File]::WriteAllText((Join-Path $runDirectory 'monitor.stderr.log'), $stderr.GetAwaiter().GetResult())
                if (-not (Test-Path -LiteralPath $summaryFile)) {
                    throw "DWM 監視結果を取得できません (exit $($monitor.ExitCode)): $runDirectory"
                }
                $summary = Get-Content -LiteralPath $summaryFile -Raw | ConvertFrom-Json
                if ($summary.status -ne 'healthy') {
                    throw "DWM 監視が正常完了しませんでした (status $($summary.status)): $summaryFile"
                }
                if ($monitor.ExitCode -ne 0) {
                    throw "DWM 監視プロセスが異常終了しました (exit $($monitor.ExitCode)): $runDirectory"
                }
                Write-Host "DWM monitoring passed: $summaryFile"
            } catch {
                $monitorFailure = $_
            }
        }
        $monitor.Dispose()
    }
    if ($testFailure) {
        if ($monitorFailure) { Write-Warning $monitorFailure.Exception.Message }
        $PSCmdlet.ThrowTerminatingError($testFailure)
    }
    if ($monitorFailure) { $PSCmdlet.ThrowTerminatingError($monitorFailure) }
}
