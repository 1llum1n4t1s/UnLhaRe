#requires -Version 7.0
param([ValidateRange(1, 3)][int]$Trials = 3)

# 実装前に列挙した失敗条件:
# 既存root・reparse祖先・非通常file、凍結SHA違反、734件でない/型不正/pin不一致、
# lock/read/hash失敗・前後変更、native失敗・CPU数範囲外・counter/時刻後退、
# zero total・idle>total・1秒未満・非finite、自己CPU後退・負残差、120秒超過、
# CreateNew失敗。負残差は整数を保持してwindow invalid、残trialは続行する。
# CIM失敗/高busyは観測だけ。圧縮/展開/7z/外部childの起動は一切行わない。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work = Join-Path $root 'build/khc-bwt-causal-bayes-q32-20260930/preparation-cpu'
$proofPath = Join-Path $root 'build/khc-bwt-causal-bayes-q32-20260930/performance/report.json'
$helperPath = Join-Path $PSScriptRoot '../cpu-window/native-times.cs'
$contractPath = Join-Path $PSScriptRoot '../Q32_PREPARATION_CPU_CONTRACT_20260930.md'
$comparePath = Join-Path $PSScriptRoot 'compare.ps1'
$logical = [Environment]::ProcessorCount
$selfProcess = [Diagnostics.Process]::GetCurrentProcess()
$frequency = [Diagnostics.Stopwatch]::Frequency
$runs = [Collections.Generic.List[object]]::new()
$setupControls = [Collections.Generic.List[object]]::new()
$errors = [Collections.Generic.List[string]]::new()
$report = [ordered]@{
    status = 'failed'; started_utc = [DateTime]::UtcNow.ToString('o'); completed_utc = $null
    error = $null; errors = $errors; actual_children = 0; performance_adoption = $false
    environment = [ordered]@{
        os = [Runtime.InteropServices.RuntimeInformation]::OSDescription
        architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        powershell = $PSVersionTable.PSVersion.ToString(); logical_processors = $logical
        stopwatch_frequency = $frequency; cwd = (Get-Location).Path
        process_id = $PID; process_path = $selfProcess.MainModule.FileName; cpu = @(); cpu_error = $null
    }
    settings = [ordered]@{ trials = $Trials; trial_seconds_max = 120; idle_seconds = 1; expected_pins = 734 }
    control_provenance = $setupControls; trials = $runs
    limitations = @(
        'Only the original 734-pin preparation scan is replayed; this is not a complete replay of original preparation.',
        'The current experiment cannot attribute the historical 65% observation or opaque CIM sampling window.',
        'CIM is observation only, outside raw windows; high busy and CIM errors do not reject the diagnosis.',
        'Native and self-process boundaries are adjacent, not atomic; negative residuals are retained and invalid, never clamped.',
        '120-second deadlines are cooperative checks around each pin and phase; blocking filesystem or CIM calls cannot be forcibly bounded without a child.',
        'The 734 original pins retain their order; diagnostic source/contract/helper/report/compare controls are separately recorded and never added to that pin set.',
        'A scan shorter than one second is invalid under the frozen helper, without artificial scan-window padding.',
        'Raw CPU ticks are 100ns integer values; decimal strings preserve exact integers for independent recalculation.'
    )
}

function Assert-NoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Reparse point refused: $current"
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}
function Assert-Deadline([long]$Start) {
    if (([Diagnostics.Stopwatch]::GetTimestamp() - $Start) / [double]$frequency -gt 120) {
        throw 'Trial exceeded cooperative 120-second deadline.'
    }
}
function Get-LockedIdentity([string]$Path, [string]$Role, $Locks, $Rows) {
    $full = [IO.Path]::GetFullPath($Path)
    Assert-NoReparse $full
    $item = Get-Item -LiteralPath $full -Force
    if ($item -isnot [IO.FileInfo]) { throw "Regular file required: $full" }
    $stream = [IO.File]::Open($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $Locks.Add($stream)
    Assert-NoReparse $full
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [Convert]::ToHexString($sha.ComputeHash($stream)) } finally { $sha.Dispose() }
    $stream.Position = 0
    $row = [pscustomobject]@{
        role = $Role; path = $full; before_bytes = $stream.Length; before_sha256 = $hash
        before_mtime_utc = $item.LastWriteTimeUtc.ToString('o'); before_mtime_ticks = $item.LastWriteTimeUtc.Ticks.ToString()
        after_bytes = $null; after_sha256 = $null; after_mtime_utc = $null; after_mtime_ticks = $null
    }
    $Rows.Add($row)
    return $row
}
function Complete-Identities($Rows, $Locks, [long]$DeadlineStart = 0) {
    for ($i = 0; $i -lt $Rows.Count; $i++) {
        if ($DeadlineStart) { Assert-Deadline $DeadlineStart }
        $row = $Rows[$i]; $stream = $Locks[$i]
        Assert-NoReparse $row.path
        $stream.Position = 0
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $row.after_sha256 = [Convert]::ToHexString($sha.ComputeHash($stream)) } finally { $sha.Dispose() }
        $row.after_bytes = $stream.Length
        $item = Get-Item -LiteralPath $row.path -Force
        $row.after_mtime_utc = $item.LastWriteTimeUtc.ToString('o')
        $row.after_mtime_ticks = $item.LastWriteTimeUtc.Ticks.ToString()
        if ($row.before_bytes -ne $row.after_bytes -or $row.before_sha256 -cne $row.after_sha256 -or $row.before_mtime_ticks -cne $row.after_mtime_ticks) {
            throw "Locked file changed: $($row.path)"
        }
        if ($DeadlineStart) { Assert-Deadline $DeadlineStart }
    }
}
function Lock-Controls($Locks, $Rows) {
    $null = Get-LockedIdentity $PSCommandPath 'diagnostic-source' $Locks $Rows
    $null = Get-LockedIdentity $contractPath 'diagnostic-contract' $Locks $Rows
    $helper = Get-LockedIdentity $helperPath 'frozen-native-helper' $Locks $Rows
    $proof = Get-LockedIdentity $proofPath 'frozen-failed-report' $Locks $Rows
    $compare = Get-LockedIdentity $comparePath 'frozen-comparison-source' $Locks $Rows
    if ($helper.before_sha256 -cne '4838B4D1A1ACFF075D85968DA9FDE1D521253BC2FA6EFD8B78CF03915762AC73') { throw 'Native helper SHA mismatch.' }
    if ($proof.before_sha256 -cne '354840497707DBD40D47387D0A20A840EAB24513FCB468D4CC5B77BA733363EC') { throw 'Failed report SHA mismatch.' }
    if ($compare.before_sha256 -cne '2D5C7D57A4940861D01AD1558D8A3E9A27217B80FF40D716BDB356506C29DD4B') { throw 'Comparison source SHA mismatch.' }
}
function Assert-Pin($Pin) {
    foreach ($name in @('path', 'role', 'before_bytes', 'after_bytes', 'before_sha256', 'after_sha256')) {
        if ($Pin.PSObject.Properties.Name -notcontains $name) { throw "Missing pin field: $name" }
    }
    if ($Pin.path -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($Pin.path) -or $Pin.role -isnot [string]) { throw 'Invalid pin path/role type.' }
    foreach ($name in @('before_bytes', 'after_bytes')) {
        if (($Pin.$name -isnot [long] -and $Pin.$name -isnot [int]) -or $Pin.$name -lt 0) { throw "Invalid pin integer: $name" }
    }
    foreach ($name in @('before_sha256', 'after_sha256')) {
        if ($Pin.$name -isnot [string] -or $Pin.$name -cnotmatch '^[A-F0-9]{64}$') { throw "Invalid pin hash: $name" }
    }
    if ($Pin.before_bytes -ne $Pin.after_bytes -or $Pin.before_sha256 -cne $Pin.after_sha256) { throw 'Original pin before/after mismatch.' }
}
function Get-CimObservation([string]$Phase) {
    $observation = [ordered]@{ phase = $Phase; start_utc = [DateTime]::UtcNow.ToString('o'); start_ticks = [Diagnostics.Stopwatch]::GetTimestamp().ToString(); value = $null; error = $null; end_utc = $null; end_ticks = $null }
    try {
        $value = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -OperationTimeoutSec 2
        $observation.value = $value.PercentProcessorTime.ToString()
    } catch { $observation.error = $_.Exception.Message }
    $observation.end_utc = [DateTime]::UtcNow.ToString('o')
    $observation.end_ticks = [Diagnostics.Stopwatch]::GetTimestamp().ToString()
    return $observation
}
function Get-Boundary {
    $boundary = [ordered]@{ start_utc = [DateTime]::UtcNow.ToString('o'); start_ticks = [Diagnostics.Stopwatch]::GetTimestamp().ToString(); native = $null; self_start_utc = $null; self_start_ticks = $null; self_cpu_100ns = $null; self_end_ticks = $null; self_end_utc = $null; end_ticks = $null; end_utc = $null }
    $boundary.native = [KhcCpuWindow.NativeTimes]::Capture($logical)
    $boundary.self_start_utc = [DateTime]::UtcNow.ToString('o')
    $boundary.self_start_ticks = [Diagnostics.Stopwatch]::GetTimestamp().ToString()
    $selfProcess.Refresh()
    $boundary.self_cpu_100ns = $selfProcess.TotalProcessorTime.Ticks.ToString()
    $boundary.self_end_ticks = [Diagnostics.Stopwatch]::GetTimestamp().ToString()
    $boundary.self_end_utc = [DateTime]::UtcNow.ToString('o')
    $boundary.end_ticks = [Diagnostics.Stopwatch]::GetTimestamp().ToString()
    $boundary.end_utc = [DateTime]::UtcNow.ToString('o')
    return $boundary
}
function Complete-Window($Window) {
    try {
        $selfTicks = [Numerics.BigInteger]::Parse($Window.end.self_cpu_100ns) - [Numerics.BigInteger]::Parse($Window.start.self_cpu_100ns)
        $Window.self_delta_100ns = $selfTicks.ToString()
        $Window.delta = [KhcCpuWindow.NativeTimes]::Calculate($Window.start.native, $Window.end.native)
        $Window.native_valid = $true
        $total = [Numerics.BigInteger]::Parse($Window.delta.Total100ns)
        $busy = [Numerics.BigInteger]::Parse($Window.delta.Busy100ns)
        $residual = $busy - $selfTicks
        $Window.residual_busy_100ns = $residual.ToString()
        $Window.self_percent_total = 100.0 * [double]$selfTicks / [double]$total
        $Window.residual_percent_total = 100.0 * [double]$residual / [double]$total
        if ($busy -gt 0) { $Window.self_fraction_busy = [double]$selfTicks / [double]$busy }
        if ($selfTicks -lt 0 -or $residual -lt 0) { throw 'Negative self delta or residual; adjacent boundaries are not atomic. Values retained without clamping.' }
        if (-not [double]::IsFinite($Window.self_percent_total) -or -not [double]::IsFinite($Window.residual_percent_total)) { throw 'Non-finite self/residual percentage.' }
        $Window.residual_valid = $true; $Window.valid = $true
    } catch { $Window.error = $_.Exception.Message }
}
function New-Window([string]$Phase) {
    return [ordered]@{ phase = $Phase; valid = $false; native_valid = $false; residual_valid = $false; error = $null; start = $null; end = $null; delta = $null; self_delta_100ns = $null; residual_busy_100ns = $null; self_percent_total = $null; residual_percent_total = $null; self_fraction_busy = $null }
}

# 新規rootを確保できなければ、既存rootには失敗reportも書き込まない。
Assert-NoReparse $work
if (Test-Path -LiteralPath $work) { throw "Existing diagnostic root refused: $work" }
$null = New-Item -ItemType Directory -Path $work
Assert-NoReparse $work
$setupLocks = [Collections.Generic.List[IO.FileStream]]::new()
try {
    if (-not $IsWindows -or $logical -lt 1 -or $logical -gt 64) { throw 'Windows and 1..64 logical processors required.' }
    Lock-Controls $setupLocks $setupControls
    $proof = Get-Content -LiteralPath $proofPath -Raw | ConvertFrom-Json
    $pins = @($proof.provenance)
    if ($pins.Count -ne 734) { throw 'Exactly 734 original pins required.' }
    foreach ($pin in $pins) { Assert-Pin $pin }
    # 読込み前にlock/hash済みの凍結helperだけをコンパイルする。
    Add-Type -TypeDefinition (Get-Content -LiteralPath $helperPath -Raw)
    try { $report.environment.cpu = @(Get-CimInstance -ClassName Win32_Processor -OperationTimeoutSec 2 | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors) }
    catch { $report.environment.cpu_error = $_.Exception.Message }
    Complete-Identities $setupControls $setupLocks
    foreach ($stream in $setupLocks) { $stream.Dispose() }
    $setupLocks.Clear()
    for ($trial = 1; $trial -le $Trials; $trial++) {
        $trialStart = [Diagnostics.Stopwatch]::GetTimestamp()
        $pinLocks = [Collections.Generic.List[IO.FileStream]]::new()
        $controlLocks = [Collections.Generic.List[IO.FileStream]]::new()
        $pinRows = [Collections.Generic.List[object]]::new()
        $controlRows = [Collections.Generic.List[object]]::new()
        $windows = [Collections.Generic.List[object]]::new()
        $observations = [Collections.Generic.List[object]]::new()
        $run = [ordered]@{ trial = $trial; status = 'failed'; error = $null; started_utc = [DateTime]::UtcNow.ToString('o'); started_ticks = $trialStart.ToString(); completed_utc = $null; completed_ticks = $null; original_provenance = $pinRows; control_provenance = $controlRows; windows = $windows; cim_observations = $observations }
        $runs.Add($run)
        try {
            Lock-Controls $controlLocks $controlRows
            for ($i = 0; $i -lt $controlRows.Count; $i++) {
                if ($controlRows[$i].before_sha256 -cne $setupControls[$i].before_sha256) { throw 'Diagnostic control changed between trials.' }
            }
            Assert-Deadline $trialStart
            $observations.Add((Get-CimObservation 'before'))
            Assert-Deadline $trialStart
            foreach ($phase in @('idle-before', 'scan', 'idle-after')) {
                $window = New-Window $phase
                $windows.Add($window)
                $window.start = Get-Boundary
                try {
                    if ($phase -eq 'scan') {
                        foreach ($pin in $pins) {
                            Assert-Deadline $trialStart
                            $row = Get-LockedIdentity $pin.path $pin.role $pinLocks $pinRows
                            if ($row.before_bytes -ne $pin.before_bytes -or $row.before_sha256 -cne $pin.before_sha256) { throw "Original pin mismatch: $($pin.path)" }
                            Assert-Deadline $trialStart
                        }
                    } else { Start-Sleep -Milliseconds 1000 }
                } finally {
                    $window.end = Get-Boundary
                    Complete-Window $window
                }
                Assert-Deadline $trialStart
            }
            $observations.Add((Get-CimObservation 'after'))
            Assert-Deadline $trialStart
            if (@($windows | Where-Object { -not $_.valid }).Count) {
                $run.status = 'invalid-windows'; $errors.Add("Trial $trial has invalid raw/residual windows.")
            } else { $run.status = 'completed' }
        } catch { $run.error = $_.Exception.Message; $errors.Add("Trial ${trial}: $($run.error)") }
        finally {
            # 途中失敗でも取得済みpinのafterを試み、deadline超過なら未検証範囲を残す。
            try { Complete-Identities $pinRows $pinLocks $trialStart }
            catch { $run.status = 'failed'; $errors.Add("Trial ${trial} pin finalization: $($_.Exception.Message)") }
            try { Complete-Identities $controlRows $controlLocks }
            catch { $run.status = 'failed'; $errors.Add("Trial ${trial} control finalization: $($_.Exception.Message)") }
            try { Assert-Deadline $trialStart }
            catch { $run.status = 'failed'; $errors.Add("Trial ${trial} final deadline: $($_.Exception.Message)") }
            foreach ($stream in $pinLocks) { $stream.Dispose() }
            foreach ($stream in $controlLocks) { $stream.Dispose() }
            $run.completed_utc = [DateTime]::UtcNow.ToString('o')
            $run.completed_ticks = [Diagnostics.Stopwatch]::GetTimestamp().ToString()
        }
    }
    if ($errors.Count -eq 0) { $report.status = 'completed' }
} catch { $report.error = $_.Exception.Message; $errors.Add($report.error) }
finally {
    if ($setupLocks.Count) {
        try { Complete-Identities $setupControls $setupLocks }
        catch { $errors.Add("Setup control finalization: $($_.Exception.Message)") }
    }
    foreach ($stream in $setupLocks) { $stream.Dispose() }
    $selfProcess.Dispose()
    $report.completed_utc = [DateTime]::UtcNow.ToString('o')
    Assert-NoReparse $work
    $reportPath = Join-Path $work 'report.json'
    Assert-NoReparse $reportPath
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($report | ConvertTo-Json -Depth 30))
    $output = [IO.File]::Open($reportPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $output.Write($bytes, 0, $bytes.Length); $output.Flush($true) } finally { $output.Dispose() }
}
if ($report.status -ne 'completed') { throw "Preparation CPU diagnosis failed; retained report: $reportPath" }
Write-Output $reportPath
