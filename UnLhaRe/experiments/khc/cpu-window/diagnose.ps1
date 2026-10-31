#requires -Version 7.2
param(
    [ValidateRange(1,3)][int]$Trials = 3,
    [string]$BinaryPath,
    [string]$GroupPath,
    [string]$WorkDirectory
)

# 診断前に列挙した失敗: reparse/既存root、identity変更、proof不成立、native API異常、
# counter後退/zero/idle超過/不正CPU数/1秒未満、子timeout/非zero終了/frame不一致。
# busy値は拒否せず記録する。この入口は性能採用や原因確定を行わない。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
if (-not $BinaryPath) { $BinaryPath = Join-Path $root 'build/khc-bwt-causal-bayes-sais-20260930/candidate.exe' }
if (-not $GroupPath) { $GroupPath = Join-Path $root 'build/khc-current-source-native-solid-20260923-group/all.group' }
if (-not $WorkDirectory) { $WorkDirectory = Join-Path $root 'build/khc-cpu-window-20260930' }
$work = [IO.Path]::GetFullPath($WorkDirectory)
$allowedWork = [IO.Path]::GetFullPath((Join-Path $root 'build/khc-cpu-window-20260930'))
$locks = [Collections.Generic.List[IO.FileStream]]::new()
$tracked = [Collections.Generic.List[object]]::new()
$identities = @{}
$runs = [Collections.Generic.List[object]]::new()
$report = [ordered]@{
    status = 'failed'; started_utc = [DateTime]::UtcNow.ToString('o'); completed_utc = $null; error = $null
    decision = 'diagnostic_only_no_adoption_no_causal_conclusion'
    settings = [ordered]@{ trials = $Trials; timeout_seconds = 120; requested_raw_window_ms = 1000; old_threshold_percent = 15; candidate_threads = 1 }
    environment = [ordered]@{ os = [Runtime.InteropServices.RuntimeInformation]::OSDescription; powershell = $PSVersionTable.PSVersion.ToString(); stopwatch_frequency = [Diagnostics.Stopwatch]::Frequency; stopwatch_high_resolution = [Diagnostics.Stopwatch]::IsHighResolution; logical_processors = $null; cpu = @() }
    fixed = [ordered]@{ binary_sha256 = '9AC5CA8F200611454F2AC7E482737518FA90842353F26B750F3A0420E07E7FBA'; input_bytes = 2811006L; input_sha256 = '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'; frame_bytes = 483468L; frame_sha256 = 'B4F17DEFF3B39FF26E5DBD38454B51FB1196FFEB1B5252E93E65D5E4B9A3824A' }
    provenance = $tracked; trials = $runs
    limits = @(
        'Old CIM formatted sampling window is opaque; a disagreement does not establish self-residue or background-load causality.',
        'Background CPU can change between observations. This report cannot establish ordinary performance, paired medians or any goal gate.',
        'Raw PInvoke counters include all processors only for the recorded 1..64 logical CPUs; kernel includes idle.',
        'Child CPU/total and background residual are diagnostics with different lifetime, API and stdout-drain boundaries and counter quantization; residual is never clamped.',
        'During spans shorter than 1000 ms retain raw evidence with null derived metrics and an explicit diagnostic error.',
        'No normal quiet guard is changed; one-second windows cannot guarantee detection of every codec-time load spike.'
    )
}

function Assert-NoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point refused: $current" }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}

function Get-Identity([string]$Path) {
    Assert-NoReparse $Path
    $file = Get-Item -LiteralPath $Path -Force
    if ($file -isnot [IO.FileInfo]) { throw "Regular file required: $Path" }
    [pscustomobject]@{ path = $file.FullName; bytes = $file.Length; sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
}

function Lock-File([string]$Path, [string]$Role, [string]$ExpectedHash = '', [long]$ExpectedBytes = -1) {
    $full = [IO.Path]::GetFullPath($Path)
    Assert-NoReparse $full
    if (-not $identities.ContainsKey($full)) {
        # 内容を読む前にwrite/delete共有を禁止する。
        $locks.Add([IO.File]::Open($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
        $identity = Get-Identity $full
        $row = [pscustomobject]@{ role = $Role; path = $identity.path; before_bytes = $identity.bytes; before_sha256 = $identity.sha256; after_bytes = $null; after_sha256 = $null }
        $tracked.Add($row)
        $identities[$full] = $row
    }
    $row = $identities[$full]
    if ($ExpectedHash -and $row.before_sha256 -cne $ExpectedHash) { throw "Pinned SHA mismatch: $Role" }
    if ($ExpectedBytes -ge 0 -and $row.before_bytes -ne $ExpectedBytes) { throw "Pinned length mismatch: $Role" }
    return $row
}

function Write-NewReport {
    Assert-NoReparse $work
    $path = Join-Path $work 'report.json'
    Assert-NoReparse $path
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($report | ConvertTo-Json -Depth 24))
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}

function Get-OldCim([string]$Phase) {
    $row = [ordered]@{ phase = $Phase; query = "Win32_PerfFormattedData_PerfOS_Processor Name='_Total'"; window = 'opaque_formatted_counter'; start_utc = [DateTime]::UtcNow.ToString('o'); start_ticks = [Diagnostics.Stopwatch]::GetTimestamp(); end_utc = $null; end_ticks = $null; percent = $null; maximum_allowed_percent = 15; old_guard_would_pass = $null; error = $null }
    try {
        $values = @(Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop)
        if ($values.Count -ne 1) { throw 'CIM total unavailable or ambiguous.' }
        $cpu = [double]$values[0].PercentProcessorTime
        if (-not [double]::IsFinite($cpu) -or $cpu -lt 0 -or $cpu -gt 100) { throw 'Invalid CIM CPU percentage.' }
        $row.percent = $cpu; $row.old_guard_would_pass = ($cpu -le 15)
    } catch { $row.error = $_.Exception.Message; throw }
    finally { $row.end_ticks = [Diagnostics.Stopwatch]::GetTimestamp(); $row.end_utc = [DateTime]::UtcNow.ToString('o'); $script:currentTrial.cim.Add([pscustomobject]$row) }
    return [pscustomobject]$row
}

function Measure-RawWindow([string]$Phase) {
    $row = [ordered]@{ phase = $Phase; start = $null; end = $null; delta = $null; threshold_percent = 15; raw_would_pass = $null; error = $null }
    $script:currentTrial.raw_windows.Add($row)
    try {
        $row.start = [KhcCpuWindow.NativeTimes]::Capture($script:logical)
        [Threading.Thread]::Sleep(1000)
        $row.end = [KhcCpuWindow.NativeTimes]::Capture($script:logical)
        $row.delta = [KhcCpuWindow.NativeTimes]::Calculate($row.start, $row.end)
        $row.raw_would_pass = $row.delta.AtOrBelow15PercentExact
    } catch { $row.error = $_.Exception.Message; throw }
    return $row
}

function Assert-Proof([string]$Path, [string]$Hash, [string]$Kind) {
    $pin = Lock-File $Path "$Kind-proof" $Hash
    $proof = Get-Content -LiteralPath $pin.path -Raw | ConvertFrom-Json
    if ($Kind -ceq 'full') {
        if ($proof.status -cne 'correctness_and_size_passed_not_timed' -or @($proof.checks).Count -ne 36 -or @($proof.invocations).Count -ne 61 -or @($proof.checks | Where-Object { -not $_.passed }).Count -ne 0) { throw 'Full proof incomplete.' }
        $pins = @($proof.provenance)
    } else {
        if ($proof.status -cne 'verified' -or @($proof.checks).Count -ne 147 -or @($proof.invocations).Count -ne 301 -or @($proof.checks | Where-Object { -not $_.passed }).Count -ne 0 -or @($proof.invocations | Where-Object { $_.timed_out -or $_.exit_code -ne $_.expected_exit }).Count -ne 0) { throw 'BWT proof incomplete.' }
        $pins = @($proof.identities)
    }
    foreach ($id in $pins) {
        if ($id.before_sha256 -cne $id.after_sha256 -or $id.before_sha256 -cnotmatch '^[0-9A-F]{64}$') { throw "Proof has unstable identity: $($id.path)" }
        $expectedBytes = -1L
        if ($Kind -ceq 'full') {
            if ($id.before_bytes -ne $id.after_bytes) { throw 'Full proof length changed.' }
            $expectedBytes = [long]$id.before_bytes
        }
        $null = Lock-File $id.path "$Kind-current-proof-pin" $id.before_sha256 $expectedBytes
    }
}

function Invoke-Trial([int]$Trial) {
    $script:currentTrial = [ordered]@{
        trial = $Trial; cim = [Collections.Generic.List[object]]::new(); raw_windows = [Collections.Generic.List[object]]::new()
        program = $candidate.path; argv = @('encode', $group.path, (Join-Path $work "trial-$Trial.bayes")); working_directory = $work
        launch_before_ticks = $null; launch_before_utc = $null; launch_after_ticks = $null; launch_after_utc = $null
        exited_and_drained_ticks = $null; exited_and_drained_utc = $null; wall_ms = $null; cpu_ms = $null
        pid = $null; process_start_utc = $null; process_exit_utc = $null; exit_code = $null; timed_out = $false; stdout = ''; stderr = ''; error = $null
        during = [ordered]@{ start = $null; end = $null; delta = $null; diagnostic_error = $null; child_cpu_to_total_percent = $null; background_residual_percent = $null; boundary = 'raw surrounds launch through stdout/stderr drain; child CPU is process lifetime; residual includes harness and background' }
        before_window_nonoverlap = $null; after_window_nonoverlap = $null; frame_bytes = $null; frame_sha256 = $null
    }
    $row = $script:currentTrial
    $runs.Add($row)
    $before = $null; $after = $null
    $process = [Diagnostics.Process]::new()
    $started = $false; $stdoutTask = $null; $stderrTask = $null; $watch = [Diagnostics.Stopwatch]::new()
    try {
        $null = Get-OldCim "trial-$Trial-before"
        $before = Measure-RawWindow "trial-$Trial-before"
        $output = $row.argv[2]
        Assert-NoReparse $output
        if (Test-Path -LiteralPath $output) { throw 'Output already exists.' }
        $info = [Diagnostics.ProcessStartInfo]::new($candidate.path)
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true; $info.WorkingDirectory = $work
        foreach ($arg in $row.argv) { $info.ArgumentList.Add($arg) }
        $process.StartInfo = $info
        $row.during.start = [KhcCpuWindow.NativeTimes]::Capture($script:logical)
        $row.launch_before_utc = [DateTime]::UtcNow.ToString('o'); $row.launch_before_ticks = [Diagnostics.Stopwatch]::GetTimestamp()
        $watch.Start()
        $started = $process.Start()
        if (-not $started) { throw 'Child did not start.' }
        $row.launch_after_ticks = [Diagnostics.Stopwatch]::GetTimestamp(); $row.launch_after_utc = [DateTime]::UtcNow.ToString('o'); $row.pid = $process.Id
        $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
        $remaining = [Math]::Max(0, [int][Math]::Floor(120000 - $watch.Elapsed.TotalMilliseconds))
        if (-not $process.WaitForExit($remaining)) { $row.timed_out = $true; throw 'Own child exceeded 120 seconds.' }
        # 非同期回収も同じ120秒予算内。外部process停止は行わない。
        $remaining = [Math]::Max(0, [int][Math]::Floor(120000 - $watch.Elapsed.TotalMilliseconds))
        $drains = [Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]@($stdoutTask, $stderrTask))
        if (-not $drains.Wait($remaining)) { $row.timed_out = $true; throw 'Child stdout/stderr drain exceeded 120 seconds.' }
        $row.stdout = $stdoutTask.GetAwaiter().GetResult(); $row.stderr = $stderrTask.GetAwaiter().GetResult()
        $row.exited_and_drained_ticks = [Diagnostics.Stopwatch]::GetTimestamp(); $row.exited_and_drained_utc = [DateTime]::UtcNow.ToString('o')
        $watch.Stop(); $row.wall_ms = $watch.Elapsed.TotalMilliseconds
        $row.during.end = [KhcCpuWindow.NativeTimes]::Capture($script:logical)
        $null = Get-OldCim "trial-$Trial-after-immediate"
        $after = Measure-RawWindow "trial-$Trial-after"
        $null = Get-OldCim "trial-$Trial-after-raw-window"
        $row.exit_code = $process.ExitCode; $row.cpu_ms = $process.TotalProcessorTime.TotalMilliseconds
        $row.process_start_utc = $process.StartTime.ToUniversalTime().ToString('o'); $row.process_exit_utc = $process.ExitTime.ToUniversalTime().ToString('o')
        try { $row.during.delta = [KhcCpuWindow.NativeTimes]::Calculate($row.during.start, $row.during.end) }
        catch {
            $span = 1000.0 * ($row.during.end.ApiStartTicks - $row.during.start.ApiEndTicks) / [Diagnostics.Stopwatch]::Frequency
            if ($span -ge 0 -and $span -lt 1000 -and $_.Exception.Message -like '*at least 1000 ms*') { $row.during.diagnostic_error = $_.Exception.Message }
            else { throw }
        }
        if ($null -ne $row.during.delta) {
            $totalMs = [double]::Parse($row.during.delta.Total100ns, [Globalization.CultureInfo]::InvariantCulture) / 10000.0
            $row.during.child_cpu_to_total_percent = 100.0 * $row.cpu_ms / $totalMs
            $row.during.background_residual_percent = $row.during.delta.BusyPercent - $row.during.child_cpu_to_total_percent
            if (-not [double]::IsFinite($row.during.child_cpu_to_total_percent) -or -not [double]::IsFinite($row.during.background_residual_percent)) { throw 'Non-finite diagnostic child ratio.' }
        }
        $row.before_window_nonoverlap = ($before.end.ApiEndTicks -le $row.launch_before_ticks)
        $row.after_window_nonoverlap = ($after.start.ApiStartTicks -ge $row.exited_and_drained_ticks -and $after.start.ApiStartTicks -ge $row.during.end.ApiEndTicks)
        if (-not $row.before_window_nonoverlap -or -not $row.after_window_nonoverlap) { throw 'Quiet window overlaps child boundaries.' }
        if ($row.exit_code -ne 0) { throw "Child exited $($row.exit_code)." }
        $frame = Lock-File $output "trial-$Trial-frame" $report.fixed.frame_sha256 $report.fixed.frame_bytes
        $row.frame_bytes = $frame.before_bytes; $row.frame_sha256 = $frame.before_sha256
    } catch { $row.error = $_.Exception.Message; throw }
    finally {
        try {
            if ($started) {
                # この入口が開始した直接の子だけを停止する。
                if (-not $process.HasExited) { $process.Kill(); if (-not $process.WaitForExit(5000)) { throw 'Own child did not exit after timeout cleanup.' } }
                if ($null -ne $stdoutTask -and $stdoutTask.IsCompletedSuccessfully) { $row.stdout = $stdoutTask.GetAwaiter().GetResult() }
                if ($null -ne $stderrTask -and $stderrTask.IsCompletedSuccessfully) { $row.stderr = $stderrTask.GetAwaiter().GetResult() }
                try { $row.exit_code = $process.ExitCode; $row.cpu_ms = $process.TotalProcessorTime.TotalMilliseconds } catch { }
            }
        } catch {
            $row.error = (@($row.error, "Cleanup: $($_.Exception.Message)") | Where-Object { $_ }) -join '; '
            throw
        } finally {
            if ($watch.IsRunning) { $watch.Stop() }; if ($null -eq $row.wall_ms -and $started) { $row.wall_ms = $watch.Elapsed.TotalMilliseconds }
            $process.Dispose()
        }
    }
}

# 新rootの確保失敗時は既存の内容へreportを書かない。
if (-not $work.Equals($allowedWork, [StringComparison]::OrdinalIgnoreCase)) { throw 'Only the fixed new build/khc-cpu-window-20260930 root is allowed.' }
Assert-NoReparse $work
if (Test-Path -LiteralPath $work) { throw 'Diagnostic root already exists; refusing all overwrites.' }
$parent = [IO.Path]::GetDirectoryName($work)
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Existing build parent required.' }
$null = New-Item -ItemType Directory -Path $work -ErrorAction Stop
$failure = $null
try {
    Assert-NoReparse $work
    $rootLock = [IO.File]::Open((Join-Path $work 'diagnostic.lock'), [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $locks.Add($rootLock)
    $null = Lock-File $PSCommandPath 'diagnostic-harness'
    $native = Lock-File (Join-Path $PSScriptRoot 'native-times.cs') 'native-helper'
    $null = Lock-File (Join-Path $PSScriptRoot '../CPU_WINDOW_CONTRACT_20260930.md') 'diagnostic-contract'
    $null = Lock-File (Join-Path $PSScriptRoot '../causal-bayes-float-cts/quiet-host.ps1') 'frozen-old-quiet-helper' 'E66D39AE8BCDAD63BC7D3FC467D4C85E950261749D457D33C4BFA9D3ED13FFBF'
    $candidate = Lock-File $BinaryPath 'fixed-sais-candidate' $report.fixed.binary_sha256 209920
    $group = Lock-File $GroupPath 'fixed-group' $report.fixed.input_sha256 $report.fixed.input_bytes
    Assert-Proof (Join-Path $root 'build/khc-bwt-causal-bayes-sais-20260930/full-e2e-retry1/report.json') '0AD5477093E2984B2D3B2024531EB8DA3FD69F0DCC0F79F41ECD986DE6274ABF' 'full'
    Assert-Proof (Join-Path $root 'build/khc-bwt-causal-bayes-sais-20260930/bwt-e2e/report.json') '413B1CB2CA66D1C1AF0BAF12C755B7483AC076B9847FD99ED8619D31E8A6BB6F' 'bwt'
    $report.environment.cpu = @(Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors)
    $script:logical = [int]($report.environment.cpu | Measure-Object NumberOfLogicalProcessors -Sum).Sum
    if ($script:logical -lt 1 -or $script:logical -gt 64) { throw 'Logical CPU count must be 1..64.' }
    $report.environment.logical_processors = $script:logical
    if ('KhcCpuWindow.NativeTimes' -as [type]) { throw 'Native helper already loaded; use a fresh PowerShell process.' }
    Add-Type -TypeDefinition (Get-Content -LiteralPath $native.path -Raw) -Language CSharp
    for ($trial = 1; $trial -le $Trials; $trial++) { Invoke-Trial $trial }
    $report.status = 'diagnostic_completed_no_adoption'
} catch { $failure = $_; $report.error = $_.Exception.Message }
finally {
    foreach ($file in $tracked) {
        try {
            $afterIdentity = Get-Identity $file.path
            $file.after_bytes = $afterIdentity.bytes; $file.after_sha256 = $afterIdentity.sha256
            if ($file.before_bytes -ne $file.after_bytes -or $file.before_sha256 -cne $file.after_sha256) { throw "Identity changed: $($file.path)" }
        } catch {
            $report.status = 'failed'; $report.error = (@($report.error, $_.Exception.Message) | Where-Object { $_ }) -join '; '
            if ($null -eq $failure) { $failure = $_ }
        }
    }
    $report.completed_utc = [DateTime]::UtcNow.ToString('o')
    try { Write-NewReport } finally { foreach ($held in $locks) { $held.Dispose() } }
}
if ($null -ne $failure) { throw $failure }
Write-Host "Diagnostic completed without adoption or causal conclusion: $(Join-Path $work 'report.json')"
