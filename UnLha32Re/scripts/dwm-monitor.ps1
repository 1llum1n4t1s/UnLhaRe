[CmdletBinding()]
param(
    [int]$SessionId = -1,
    [int]$ParentProcessId = 0,
    [string]$OutputDirectory = '',
    [string]$StopFile = '',
    [ValidateRange(0.0, 60.0)][double]$SampleIntervalSeconds = 2,
    [ValidateRange(0.0, 100000.0)][double]$ThresholdPercent = 80,
    [ValidateRange(1, 1000)][int]$ConsecutiveSamples = 5,
    [ValidateRange(0.0, 60.0)][double]$PostExitSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = [Text.UTF8Encoding]::new($false)
$script:CimOperationTimeoutSeconds = 3
$script:TraceCaptureSeconds = 10
$script:WprStartTimeoutSeconds = 15
$script:WprStopTimeoutSeconds = 30
$script:WprCancelTimeoutSeconds = 10
$script:MaximumSamples = 120
$script:MaximumErrors = 20

function Get-CpuPercentFromRawSample {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$PreviousSample,
        [Parameter(Mandatory)][object]$CurrentSample
    )

    $previousPid = if ($null -ne $PreviousSample.PSObject.Properties['ProcessId']) {
        [int]$PreviousSample.ProcessId
    } else {
        [int]$PreviousSample.IDProcess
    }
    $currentPid = if ($null -ne $CurrentSample.PSObject.Properties['ProcessId']) {
        [int]$CurrentSample.ProcessId
    } else {
        [int]$CurrentSample.IDProcess
    }
    if ($previousPid -ne $currentPid) {
        return $null
    }

    try {
        $processorDelta = [decimal]$CurrentSample.PercentProcessorTime -
            [decimal]$PreviousSample.PercentProcessorTime
        $timestampDelta = [decimal]$CurrentSample.Timestamp_Sys100NS -
            [decimal]$PreviousSample.Timestamp_Sys100NS
    } catch {
        return $null
    }
    if ($processorDelta -lt 0 -or $timestampDelta -le 0) {
        return $null
    }

    # PerfProc の raw 値は全論理プロセッサー分を合算するため、100% は論理 1 コアに相当する。
    return [Math]::Round([double](100 * $processorDelta / $timestampDelta), 3)
}

function Update-HighCpuState {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$CpuPercent,
        [Parameter(Mandatory)][double]$ThresholdPercent,
        [Parameter(Mandatory)][ValidateRange(0, [int]::MaxValue)][int]$CurrentConsecutive,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$RequiredConsecutive
    )

    $nextConsecutive = if ($null -ne $CpuPercent -and [double]$CpuPercent -ge $ThresholdPercent) {
        $CurrentConsecutive + 1
    } else {
        0
    }
    [pscustomobject]@{
        ConsecutiveSamples = $nextConsecutive
        Triggered          = $nextConsecutive -ge $RequiredConsecutive
    }
}

function Get-DwmRawSample {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(0, [int]::MaxValue)][int]$SessionId
    )

    try {
        $processes = @(Get-CimInstance -ClassName Win32_Process `
                -Filter "Name = 'dwm.exe' AND SessionId = $SessionId" `
                -OperationTimeoutSec $script:CimOperationTimeoutSeconds)
        if ($processes.Count -eq 0) {
            return [pscustomobject]@{
                Available  = $false
                SampleUtc  = [DateTime]::UtcNow.ToString('o')
                ProcessId  = $null
                RawSample  = $null
                UnavailableReason = 'dwm-process-not-found'
            }
        }

        $process = $processes | Sort-Object ProcessId | Select-Object -First 1
        $processId = [int]$process.ProcessId
        $rawRows = @(Get-CimInstance -ClassName Win32_PerfRawData_PerfProc_Process `
                -Filter "IDProcess = $processId" `
                -OperationTimeoutSec $script:CimOperationTimeoutSeconds)
        $raw = $rawRows | Where-Object { $_.Name -like 'dwm*' } | Select-Object -First 1
        if ($null -eq $raw) {
            return [pscustomobject]@{
                Available  = $false
                SampleUtc  = [DateTime]::UtcNow.ToString('o')
                ProcessId  = $processId
                RawSample  = $null
                UnavailableReason = 'raw-counter-not-found'
            }
        }

        [pscustomobject]@{
            Available = $true
            SampleUtc = [DateTime]::UtcNow.ToString('o')
            ProcessId = $processId
            RawSample = [pscustomobject]@{
                ProcessId           = $processId
                PercentProcessorTime = [decimal]$raw.PercentProcessorTime
                Timestamp_Sys100NS   = [decimal]$raw.Timestamp_Sys100NS
            }
            UnavailableReason = $null
        }
    } catch {
        [pscustomobject]@{
            Available  = $false
            SampleUtc  = [DateTime]::UtcNow.ToString('o')
            ProcessId  = $null
            RawSample  = $null
            UnavailableReason = "cim-error: $($_.Exception.Message)"
        }
    }
}

function Invoke-WprCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][ValidateRange(1, 120)][int]$TimeoutSeconds
    )

    $command = Get-Command wpr.exe -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return [pscustomobject]@{
            Succeeded     = $false
            ExitCode      = $null
            TimedOut      = $false
            StandardOutput = ''
            StandardError = 'wpr.exe-not-found'
        }
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $command.Source
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'wpr.exe を起動できませんでした。'
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
        if ($timedOut) {
            try {
                $process.Kill($true)
                [void]$process.WaitForExit(5000)
            } catch {
                # タイムアウト結果を優先し、終了処理の失敗は標準エラーへ加える。
            }
        }
        $streamDeadlineUtc = [DateTime]::UtcNow.AddSeconds(2)
        while ((-not $stdoutTask.IsCompleted -or -not $stderrTask.IsCompleted) -and
            [DateTime]::UtcNow -lt $streamDeadlineUtc) {
            [Threading.Thread]::Sleep(25)
        }
        $standardOutput = if ($stdoutTask.IsCompleted) {
            try { $stdoutTask.GetAwaiter().GetResult() } catch { "output-error: $($_.Exception.Message)" }
        } else {
            'output-collection-timed-out'
        }
        $standardError = if ($stderrTask.IsCompleted) {
            try { $stderrTask.GetAwaiter().GetResult() } catch { "error-output-error: $($_.Exception.Message)" }
        } else {
            'error-output-collection-timed-out'
        }
        $exitCode = if ($process.HasExited) { $process.ExitCode } else { $null }
        [pscustomobject]@{
            Succeeded      = -not $timedOut -and $exitCode -eq 0
            ExitCode       = $exitCode
            TimedOut       = $timedOut
            StandardOutput = $standardOutput
            StandardError  = $standardError
        }
    } catch {
        [pscustomobject]@{
            Succeeded      = $false
            ExitCode       = $null
            TimedOut       = $false
            StandardOutput = ''
            StandardError  = $_.Exception.Message
        }
    } finally {
        $process.Dispose()
    }
}

function Limit-MonitorText {
    param(
        [AllowNull()][object]$Text,
        [int]$MaximumLength = 2048
    )
    if ($null -eq $Text) { return '' }
    $value = [string]$Text
    if ($value.Length -le $MaximumLength) { return $value }
    return $value.Substring(0, $MaximumLength)
}

function Write-MonitorJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 8
    $temporaryPath = Join-Path (Split-Path -Parent $Path) `
        ('.{0}.{1}.{2}.tmp' -f ([IO.Path]::GetFileName($Path)), $PID, [Guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($temporaryPath, $json, $script:Utf8NoBom)
        [IO.File]::Move($temporaryPath, $Path, $true)
    } catch {
        # 同一ディレクトリー内の rename が拒否された場合も、最終 JSON は通常書き込みで残す。
        [IO.File]::WriteAllText($Path, $json, $script:Utf8NoBom)
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Get-MonitorEnvironment {
    [CmdletBinding()]
    param()

    $metadataErrors = [Collections.Generic.List[string]]::new()
    $operatingSystem = $null
    $computerSystem = $null
    $videoControllers = @()
    try {
        $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem `
            -OperationTimeoutSec $script:CimOperationTimeoutSeconds |
            Select-Object Caption, Version, BuildNumber, OSArchitecture
    } catch {
        $metadataErrors.Add("operating-system: $($_.Exception.Message)")
    }
    try {
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem `
            -OperationTimeoutSec $script:CimOperationTimeoutSeconds |
            Select-Object Manufacturer, Model, NumberOfLogicalProcessors, TotalPhysicalMemory
    } catch {
        $metadataErrors.Add("computer-system: $($_.Exception.Message)")
    }
    try {
        $videoControllers = @(Get-CimInstance -ClassName Win32_VideoController `
                -OperationTimeoutSec $script:CimOperationTimeoutSeconds |
                Select-Object -First 8 Name, DriverVersion, DriverDate)
    } catch {
        $metadataErrors.Add("video-controller: $($_.Exception.Message)")
    }

    [pscustomobject]@{
        OperatingSystem   = $operatingSystem
        ComputerSystem    = $computerSystem
        VideoControllers  = $videoControllers
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        MetadataErrors    = @($metadataErrors)
    }
}

function Test-MonitorParentAlive {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [AllowNull()][object]$ExpectedStartTimeUtc
    )

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        if ($null -eq $ExpectedStartTimeUtc) { return $true }
        return $process.StartTime.ToUniversalTime() -eq [datetime]$ExpectedStartTimeUtc
    } catch {
        return $false
    }
}

function Add-BoundedItem {
    param(
        [Parameter(Mandatory)][object]$Queue,
        [Parameter(Mandatory)][object]$Item,
        [Parameter(Mandatory)][int]$MaximumCount
    )
    $Queue.Enqueue($Item)
    while ($Queue.Count -gt $MaximumCount) {
        [void]$Queue.Dequeue()
    }
}

function Add-MonitorError {
    param(
        [Parameter(Mandatory)][object]$Errors,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Message
    )
    if ($Errors.Count -ge $script:MaximumErrors) { $Errors.RemoveAt(0) }
    $Errors.Add([pscustomobject]@{
            Utc     = [DateTime]::UtcNow.ToString('o')
            Source  = $Source
            Message = Limit-MonitorText $Message
        })
}

function Invoke-DwmMonitor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$SessionId,
        [Parameter(Mandatory)][int]$ParentProcessId,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$StopFile,
        [Parameter(Mandatory)][double]$SampleIntervalSeconds,
        [Parameter(Mandatory)][double]$ThresholdPercent,
        [Parameter(Mandatory)][int]$ConsecutiveSamples,
        [Parameter(Mandatory)][double]$PostExitSeconds
    )

    if ($SessionId -lt 0) {
        throw 'SessionId には 0 以上の値を指定してください。'
    }
    if ($ParentProcessId -lt 1) {
        throw 'ParentProcessId には 1 以上の値を指定してください。'
    }
    if ([string]::IsNullOrWhiteSpace($OutputDirectory) -or
        -not [IO.Path]::IsPathFullyQualified($OutputDirectory)) {
        throw 'OutputDirectory には絶対パスを指定してください。'
    }
    if ([string]::IsNullOrWhiteSpace($StopFile) -or
        -not [IO.Path]::IsPathFullyQualified($StopFile)) {
        throw 'StopFile には絶対パスを指定してください。'
    }
    $resolvedOutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
    if (-not (Test-Path -LiteralPath $resolvedOutputDirectory -PathType Container)) {
        throw "親が作成した出力ディレクトリーが見つかりません: $resolvedOutputDirectory"
    }
    $resolvedStopFile = [IO.Path]::GetFullPath($StopFile)
    $relativeStopFile = [IO.Path]::GetRelativePath($resolvedOutputDirectory, $resolvedStopFile)
    if ([IO.Path]::IsPathFullyQualified($relativeStopFile) -or
        $relativeStopFile -eq '..' -or
        $relativeStopFile.StartsWith("..$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::Ordinal)) {
        throw 'StopFile は OutputDirectory の内側に置いてください。'
    }

    $readyPath = Join-Path $resolvedOutputDirectory 'ready.json'
    $summaryPath = Join-Path $resolvedOutputDirectory 'summary.json'
    $tracePath = Join-Path $resolvedOutputDirectory 'dwm-high-cpu.etl'
    $instanceName = 'UnLhaRe-Dwm-{0}-{1}' -f $SessionId, [Guid]::NewGuid().ToString('N')
    $startedUtc = [DateTime]::UtcNow
    $completedUtc = $null
    $stopReason = 'unknown'
    $samples = [Collections.Generic.Queue[object]]::new()
    $errors = [Collections.Generic.List[object]]::new()
    $dwmProcessIds = [Collections.Generic.HashSet[int]]::new()
    $sampleCount = 0
    $measuredSampleCount = 0
    $unavailableSampleCount = 0
    $highCpuSampleCount = 0
    $peakCpuPercent = $null
    $currentConsecutive = 0
    $peakConsecutive = 0
    $sustainedHighCpuDetected = $false
    $measurementUnavailable = $false
    $previousRawSample = $null
    $traceAttempted = $false
    $traceOwned = $false
    $traceStartedUtc = $null
    $traceCompletedUtc = $null
    $traceStatus = 'not-triggered'
    $traceCleanupStatus = 'not-needed'
    $traceStartResult = $null
    $traceStopResult = $null
    $wprAvailable = $null -ne (Get-Command wpr.exe -ErrorAction SilentlyContinue)
    $environment = $null
    $parentStartTimeUtc = $null

    try {
        try {
            $parent = Get-Process -Id $ParentProcessId -ErrorAction Stop
            $parentStartTimeUtc = $parent.StartTime.ToUniversalTime()
        } catch {
            Add-MonitorError $errors 'parent' "親プロセスの開始時刻を取得できません: $($_.Exception.Message)"
        }

        $environment = Get-MonitorEnvironment
        $initialSample = Get-DwmRawSample -SessionId $SessionId
        $sampleCount++
        if ($initialSample.Available) {
            $previousRawSample = $initialSample.RawSample
            [void]$dwmProcessIds.Add([int]$initialSample.ProcessId)
            $initialRecord = [pscustomobject]@{
                Utc               = $initialSample.SampleUtc
                Status            = 'baseline'
                DwmProcessId      = [int]$initialSample.ProcessId
                CpuPercent        = $null
                ConsecutiveHighCpu = 0
                Reason            = $null
            }
        } else {
            $measurementUnavailable = $true
            $unavailableSampleCount++
            $initialRecord = [pscustomobject]@{
                Utc               = $initialSample.SampleUtc
                Status            = 'unavailable'
                DwmProcessId      = $initialSample.ProcessId
                CpuPercent        = $null
                ConsecutiveHighCpu = 0
                Reason            = Limit-MonitorText $initialSample.UnavailableReason
            }
        }
        Add-BoundedItem $samples $initialRecord $script:MaximumSamples

        $readyStatus = if ($initialSample.Available) { 'healthy' } else { 'unavailable' }
        Write-MonitorJson $readyPath ([pscustomobject]@{
                SchemaVersion         = 1
                Status                = $readyStatus
                StartedUtc            = $startedUtc.ToString('o')
                SessionId             = $SessionId
                ParentProcessId       = $ParentProcessId
                DwmProcessId          = $initialSample.ProcessId
                WprAvailable          = $wprAvailable
                SampleIntervalSeconds = $SampleIntervalSeconds
                ThresholdPercent      = $ThresholdPercent
                ConsecutiveSamples    = $ConsecutiveSamples
                PostExitSeconds       = $PostExitSeconds
                Error                 = if ($initialSample.Available) { $null } else { $initialSample.UnavailableReason }
            })

        $nextSampleUtc = [DateTime]::UtcNow.AddSeconds($SampleIntervalSeconds)
        $postExitDeadlineUtc = $null
        $postExitSampleCount = 0
        $samplingComplete = $false
        while ($true) {
            $nowUtc = [DateTime]::UtcNow
            if ($null -eq $postExitDeadlineUtc) {
                if (Test-Path -LiteralPath $resolvedStopFile) {
                    $stopReason = 'stop-file'
                    $postExitDeadlineUtc = $nowUtc.AddSeconds($PostExitSeconds)
                } elseif (-not (Test-MonitorParentAlive -ProcessId $ParentProcessId `
                            -ExpectedStartTimeUtc $parentStartTimeUtc)) {
                    $stopReason = 'parent-exited'
                    $postExitDeadlineUtc = $nowUtc.AddSeconds($PostExitSeconds)
                }
            }

            if ($traceOwned -and $null -ne $traceStartedUtc -and
                $nowUtc -ge $traceStartedUtc.AddSeconds($script:TraceCaptureSeconds)) {
                $traceStopResult = Invoke-WprCommand `
                    -Arguments @('-stop', $tracePath, 'DWM sustained high CPU', '-skipPdbGen',
                        '-instancename', $instanceName) `
                    -TimeoutSeconds $script:WprStopTimeoutSeconds
                if ($traceStopResult.Succeeded) {
                    $traceOwned = $false
                    $traceCompletedUtc = [DateTime]::UtcNow
                    $traceStatus = 'captured'
                } else {
                    $traceStatus = 'stop-failed'
                    Add-MonitorError $errors 'wpr-stop' `
                        ("exit={0}; timedOut={1}; {2}" -f $traceStopResult.ExitCode,
                            $traceStopResult.TimedOut, (Limit-MonitorText $traceStopResult.StandardError))
                    $cancelResult = Invoke-WprCommand `
                        -Arguments @('-cancel', '-instancename', $instanceName) `
                        -TimeoutSeconds $script:WprCancelTimeoutSeconds
                    $traceOwned = $false
                    if ($cancelResult.Succeeded) {
                        $traceCleanupStatus = 'cancelled'
                    } else {
                        $traceCleanupStatus = 'failed'
                        Add-MonitorError $errors 'wpr-cancel' `
                            ("exit={0}; timedOut={1}; {2}" -f $cancelResult.ExitCode,
                                $cancelResult.TimedOut, (Limit-MonitorText $cancelResult.StandardError))
                    }
                }
            }

            $postExitDeadlineReached = $null -ne $postExitDeadlineUtc -and
                $nowUtc -ge $postExitDeadlineUtc
            if (-not $samplingComplete -and
                ($nowUtc -ge $nextSampleUtc -or $postExitDeadlineReached)) {
                $observation = Get-DwmRawSample -SessionId $SessionId
                if ($null -ne $postExitDeadlineUtc) { $postExitSampleCount++ }
                $sampleCount++
                $sampleStatus = 'unavailable'
                $cpuPercent = $null
                $reason = $null
                $dwmProcessId = $observation.ProcessId
                if (-not $observation.Available) {
                    $measurementUnavailable = $true
                    $unavailableSampleCount++
                    $previousRawSample = $null
                    $reason = Limit-MonitorText $observation.UnavailableReason
                    $highCpuState = Update-HighCpuState -CpuPercent $null `
                        -ThresholdPercent $ThresholdPercent -CurrentConsecutive $currentConsecutive `
                        -RequiredConsecutive $ConsecutiveSamples
                    $currentConsecutive = $highCpuState.ConsecutiveSamples
                } else {
                    [void]$dwmProcessIds.Add([int]$observation.ProcessId)
                    if ($null -eq $previousRawSample -or
                        [int]$previousRawSample.ProcessId -ne [int]$observation.ProcessId) {
                        $sampleStatus = 'baseline'
                        $currentConsecutive = 0
                    } else {
                        $cpuPercent = Get-CpuPercentFromRawSample `
                            -PreviousSample $previousRawSample -CurrentSample $observation.RawSample
                        if ($null -eq $cpuPercent) {
                            $measurementUnavailable = $true
                            $unavailableSampleCount++
                            $reason = 'raw-counter-delta-invalid'
                            $currentConsecutive = 0
                        } else {
                            $sampleStatus = 'measured'
                            $measuredSampleCount++
                            if ($null -eq $peakCpuPercent -or $cpuPercent -gt $peakCpuPercent) {
                                $peakCpuPercent = $cpuPercent
                            }
                            $highCpuState = Update-HighCpuState -CpuPercent $cpuPercent `
                                -ThresholdPercent $ThresholdPercent -CurrentConsecutive $currentConsecutive `
                                -RequiredConsecutive $ConsecutiveSamples
                            $currentConsecutive = $highCpuState.ConsecutiveSamples
                            if ($cpuPercent -ge $ThresholdPercent) { $highCpuSampleCount++ }
                            if ($currentConsecutive -gt $peakConsecutive) {
                                $peakConsecutive = $currentConsecutive
                            }
                            if ($highCpuState.Triggered) {
                                $sustainedHighCpuDetected = $true
                            }
                        }
                    }
                    $previousRawSample = $observation.RawSample
                }

                Add-BoundedItem $samples ([pscustomobject]@{
                        Utc                = $observation.SampleUtc
                        Status             = $sampleStatus
                        DwmProcessId       = $dwmProcessId
                        CpuPercent         = $cpuPercent
                        ConsecutiveHighCpu = $currentConsecutive
                        Reason             = $reason
                    }) $script:MaximumSamples

                if ($sustainedHighCpuDetected -and -not $traceAttempted) {
                    $traceAttempted = $true
                    if (-not $wprAvailable) {
                        $traceStatus = 'start-failed'
                        Add-MonitorError $errors 'wpr-start' 'wpr.exe-not-found'
                    } else {
                        $traceStartResult = Invoke-WprCommand `
                            -Arguments @('-start', 'CPU.verbose', '-filemode', '-recordtempto',
                                $resolvedOutputDirectory, '-instancename', $instanceName) `
                            -TimeoutSeconds $script:WprStartTimeoutSeconds
                        if ($traceStartResult.Succeeded) {
                            # 成功した名前付き start だけを、このプロセスが停止・cancel できる記録として扱う。
                            $traceOwned = $true
                            $traceStartedUtc = [DateTime]::UtcNow
                            $traceStatus = 'recording'
                        } else {
                            $traceStatus = 'start-failed'
                            Add-MonitorError $errors 'wpr-start' `
                                ("exit={0}; timedOut={1}; {2}" -f $traceStartResult.ExitCode,
                                    $traceStartResult.TimedOut, (Limit-MonitorText $traceStartResult.StandardError))
                            if ($traceStartResult.TimedOut) {
                                # 起動結果だけが不明な場合は、一意な名前に限って残存セッションを回収する。
                                $cancelResult = Invoke-WprCommand `
                                    -Arguments @('-cancel', '-instancename', $instanceName) `
                                    -TimeoutSeconds $script:WprCancelTimeoutSeconds
                                if ($cancelResult.Succeeded) {
                                    $traceCleanupStatus = 'cancelled'
                                } else {
                                    $traceCleanupStatus = 'failed'
                                    Add-MonitorError $errors 'wpr-cancel' `
                                        ("exit={0}; timedOut={1}; {2}" -f $cancelResult.ExitCode,
                                            $cancelResult.TimedOut, (Limit-MonitorText $cancelResult.StandardError))
                                }
                            }
                        }
                    }
                }
                # CIM の取得時間を周期に加算せず、今回の計測開始を基準に予約する。
                $nextSampleUtc = $nowUtc.AddSeconds($SampleIntervalSeconds)
                if ($postExitDeadlineReached -and
                    ($PostExitSeconds -eq 0 -or $postExitSampleCount -ge $ConsecutiveSamples)) {
                    $samplingComplete = $true
                }
                continue
            }

            if ($samplingComplete -and -not $traceOwned) {
                break
            }

            $wakeUtc = if ($samplingComplete) { $nowUtc.AddMilliseconds(250) } else { $nextSampleUtc }
            $pollUtc = $nowUtc.AddMilliseconds(250)
            if ($pollUtc -lt $wakeUtc) { $wakeUtc = $pollUtc }
            if (-not $samplingComplete -and $null -ne $postExitDeadlineUtc -and
                $postExitDeadlineUtc -lt $wakeUtc) {
                $wakeUtc = $postExitDeadlineUtc
            }
            if ($traceOwned -and $null -ne $traceStartedUtc) {
                $traceDeadlineUtc = $traceStartedUtc.AddSeconds($script:TraceCaptureSeconds)
                if ($traceDeadlineUtc -lt $wakeUtc) { $wakeUtc = $traceDeadlineUtc }
            }
            $waitMilliseconds = [Math]::Max(1, [Math]::Ceiling(($wakeUtc - [DateTime]::UtcNow).TotalMilliseconds))
            [Threading.Thread]::Sleep([int]$waitMilliseconds)
        }
    } catch {
        $stopReason = 'monitor-error'
        $measurementUnavailable = $true
        Add-MonitorError $errors 'monitor' $_.Exception.ToString()
    } finally {
        if ($traceOwned) {
            $traceStopResult = Invoke-WprCommand `
                -Arguments @('-stop', $tracePath, 'DWM sustained high CPU', '-skipPdbGen',
                    '-instancename', $instanceName) `
                -TimeoutSeconds $script:WprStopTimeoutSeconds
            if ($traceStopResult.Succeeded) {
                $traceStatus = 'captured'
                $traceCompletedUtc = [DateTime]::UtcNow
                $traceOwned = $false
            } else {
                $traceStatus = 'stop-failed'
                Add-MonitorError $errors 'wpr-stop' `
                    ("exit={0}; timedOut={1}; {2}" -f $traceStopResult.ExitCode,
                        $traceStopResult.TimedOut, (Limit-MonitorText $traceStopResult.StandardError))
                $cancelResult = Invoke-WprCommand `
                    -Arguments @('-cancel', '-instancename', $instanceName) `
                    -TimeoutSeconds $script:WprCancelTimeoutSeconds
                $traceOwned = $false
                if ($cancelResult.Succeeded) {
                    $traceCleanupStatus = 'cancelled'
                } else {
                    $traceCleanupStatus = 'failed'
                    Add-MonitorError $errors 'wpr-cancel' `
                        ("exit={0}; timedOut={1}; {2}" -f $cancelResult.ExitCode,
                            $cancelResult.TimedOut, (Limit-MonitorText $cancelResult.StandardError))
                }
            }
        }

        $completedUtc = [DateTime]::UtcNow
        $status = if ($sustainedHighCpuDetected) {
            'unhealthy'
        } elseif ($measurementUnavailable -or $measuredSampleCount -eq 0) {
            'unavailable'
        } else {
            'healthy'
        }
        $summary = [pscustomobject]@{
            SchemaVersion             = 1
            Status                    = $status
            TraceStatus               = $traceStatus
            TraceCleanupStatus        = $traceCleanupStatus
            TracePath                 = if (Test-Path -LiteralPath $tracePath -PathType Leaf) { $tracePath } else { $null }
            StartedUtc                = $startedUtc.ToString('o')
            CompletedUtc              = $completedUtc.ToString('o')
            DurationSeconds           = [Math]::Round(($completedUtc - $startedUtc).TotalSeconds, 3)
            StopReason                = $stopReason
            SessionId                 = $SessionId
            ParentProcessId           = $ParentProcessId
            DwmProcessIds             = @($dwmProcessIds | Sort-Object)
            SampleIntervalSeconds     = $SampleIntervalSeconds
            ThresholdPercent          = $ThresholdPercent
            ConsecutiveSamplesRequired = $ConsecutiveSamples
            PostExitSeconds           = $PostExitSeconds
            SampleCount               = $sampleCount
            MeasuredSampleCount       = $measuredSampleCount
            UnavailableSampleCount    = $unavailableSampleCount
            HighCpuSampleCount        = $highCpuSampleCount
            PeakCpuPercent            = $peakCpuPercent
            PeakConsecutiveHighCpu    = $peakConsecutive
            SustainedHighCpuDetected  = $sustainedHighCpuDetected
            WprAvailable              = $wprAvailable
            WprInstanceName           = $instanceName
            TraceStartedUtc           = if ($null -ne $traceStartedUtc) { $traceStartedUtc.ToString('o') } else { $null }
            TraceCompletedUtc         = if ($null -ne $traceCompletedUtc) { $traceCompletedUtc.ToString('o') } else { $null }
            TraceStartExitCode        = if ($null -ne $traceStartResult) { $traceStartResult.ExitCode } else { $null }
            TraceStopExitCode         = if ($null -ne $traceStopResult) { $traceStopResult.ExitCode } else { $null }
            Environment               = $environment
            Samples                   = @($samples.ToArray())
            Errors                    = @($errors)
        }
        try {
            Write-MonitorJson $summaryPath $summary
        } catch {
            [Console]::Error.WriteLine("summary.json の書き込みに失敗しました: $($_.Exception.Message)")
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-DwmMonitor -SessionId $SessionId -ParentProcessId $ParentProcessId `
        -OutputDirectory $OutputDirectory -StopFile $StopFile `
        -SampleIntervalSeconds $SampleIntervalSeconds -ThresholdPercent $ThresholdPercent `
        -ConsecutiveSamples $ConsecutiveSamples -PostExitSeconds $PostExitSeconds
}
