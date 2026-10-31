#requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$BinaryPath,
    [Parameter(Mandatory)][string]$PdbPath,
    [Parameter(Mandatory)][string]$GroupPath,
    [Parameter(Mandatory)][string]$WorkDirectory,
    [Parameter(Mandatory)][string]$RustcPath,
    [string]$WprPath = 'C:/Windows/System32/wpr.exe'
)

# 失敗条件を先に固定: 非絶対path/reparse/既存work・出力、不正input/manifest、
# source/binary/PDB変更、通常E2Eのmetadata/本文不一致、frame size/SHA不一致、
# WPR既存録画・status判定不能・start/stop失敗、process timeout/非zero、復号不一致。
# 自分でstart成功を確認したsessionだけfinallyでstopする。cancel/他session停止は禁止。
# この採取は通常経路のCPU帰属用。採取中・group-benchの時間を性能採否へ使わない。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build = [IO.Path]::GetFullPath((Join-Path $root 'build'))
$fixedHash = '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'
$frameHash = 'CF4F107BE32E35B603FCA9CE05AC8A5C5C3F4211A4BC0B68236A383F8029447D'
$fixedOptions = @('--algorithm', 'beam', '--beam-model', 'blended', '--beam-matches', 'bt5', '--beam-width', '2', '--beam-block', '8192', '--dictionary-mib', '64', '--entropy-backend', 'range', '--bt-nice-len', '0')
$locks = [Collections.Generic.List[IO.FileStream]]::new()
$identities = [Collections.Generic.List[object]]::new()
$calls = [Collections.Generic.List[object]]::new()
$frames = [Collections.Generic.List[object]]::new()
$ownedRecording = $false
$stopAttempted = $false
$failure = $null
$report = [ordered]@{
    status = 'failed'; started_utc = [DateTime]::UtcNow.ToString('o'); error = $null
    kind = 'fresh_current_release_cpu_attribution'
    timing_used_for_performance_decision = $false
    fixed_settings = $fixedOptions
    configured_threads = 1
    single_thread_evidence = 'normal_codec_configuration_not_lifetime_verified'
    normal_e2e = $null; encode_runs = $frames; decode = $null
    invocations = $calls; provenance = $identities
    trace = $null
    recording = [ordered]@{
        path = $null; identity = $null; start_confirmed = $false; stop_attempted = $false
        stop_succeeded = $false; recording_may_remain = $false; error = $null
        target_pids = @(); sample_loss = $null; sample_loss_status = 'not_collected_by_capture_script; parent must inspect raw ETL'
        image_base_status = 'parent raw ETL analysis required'
        binary_pdb_pair_status = 'hash-locked pair; PE CodeView/PDB identity validation performed separately by parent'
        symbol_resolution_status = 'parent llvm-symbolizer and raw ETL analysis required'
    }
    environment = [ordered]@{
        os = [Runtime.InteropServices.RuntimeInformation]::OSDescription
        architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        powershell = $PSVersionTable.PSVersion.ToString(); runtime = [Environment]::Version.ToString()
        cwd = $PWD.Path; cpu = @(); rustc = $null
        stopwatch_frequency = [Diagnostics.Stopwatch]::Frequency
    }
    notes = @(
        'Exactly three fresh encode invocations maximum; no setting/count sweep or automatic retry.',
        'group-bench runs before recording with one repeat plus its internal warm-up; successful CLI validates deterministic frame, complete decoded group bytes and solid metadata.',
        'Binary stdout uses BaseStream.CopyToAsync into CreateNew files; no PowerShell text redirection.',
        'Raw ETL is preserved without ETLX conversion or NGEN/PDB generation. PID and process UTC windows are recorded for parent attribution.',
        'Only owned WPR start success permits one stop attempt in finally. No cancel and no existing-session stop.',
        'Flat sampled source lines alone do not prove whole-function duration, exclusive time, lifetime single-thread execution, or the required total encode reduction.'
    )
}

function Assert-Absolute([string]$Path) {
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw "An absolute path is required: $Path" }
}
function Assert-NoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if ((Test-Path -LiteralPath $current) -and (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw "Reparse point rejected: $current" }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}
function Identity([string]$Path) {
    Assert-NoReparse $Path
    $item = Get-Item -LiteralPath $Path -Force
    if ($item -isnot [IO.FileInfo]) { throw "Expected a regular file: $Path" }
    [pscustomobject]@{ path = $item.FullName; bytes = $item.Length; sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash }
}
function Lock-Identity([string]$Path, [string]$Role) {
    Assert-NoReparse $Path
    $locks.Add([IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
    $id = Identity $Path
    $row = [pscustomobject]@{ role = $Role; path = $id.path; before_bytes = $id.bytes; before_sha256 = $id.sha256; after_bytes = $null; after_sha256 = $null; lock = 'read-only FileShare.Read until final identity check' }
    $identities.Add($row)
    return $row
}
function Source-Paths {
    Assert-NoReparse (Join-Path $root 'src')
    $items = @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Force -Recurse)
    foreach ($item in $items) { Assert-NoReparse $item.FullName }
    $paths = @(
        (Join-Path $root 'Cargo.toml')
        (Join-Path $root 'Cargo.lock')
        (Join-Path $root 'examples/khc_lab.rs')
        (Get-ChildItem -LiteralPath $PSScriptRoot -Force -File -Filter '*.rs').FullName
        ($items | Where-Object { $_ -is [IO.FileInfo] -and $_.Extension -ceq '.rs' }).FullName
    )
    foreach ($optional in @('rust-toolchain.toml', 'rust-toolchain')) {
        $path = Join-Path $root $optional
        if (Test-Path -LiteralPath $path) { $paths += $path }
    }
    return [string[]]@($paths | Sort-Object -Unique)
}
function New-Bytes([string]$Path, [byte[]]$Bytes) {
    Assert-NoReparse $Path
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}
function Call-Native([string]$Program, [string[]]$Argv, [string]$Kind, [string]$Output = '') {
    $row = [ordered]@{
        kind = $Kind; program = $Program; argv = $Argv; cwd = $work
        pid = $null; start_utc = $null; end_utc = $null; process_start_utc = $null
        exit_code = $null; stdout = ''; stderr = ''; output = $null; output_path = $Output
        cpu_ms = $null; wall_ms = $null; timed_out = $false; error = $null
    }
    $calls.Add($row)
    $info = [Diagnostics.ProcessStartInfo]::new($Program)
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.WorkingDirectory = $work
    foreach ($argument in $Argv) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    $sink = $null; $stdoutTask = $null; $stderrTask = $null; $started = $false
    $watch = [Diagnostics.Stopwatch]::new()
    try {
        if ($Output) {
            Assert-NoReparse $Output
            $sink = [IO.File]::Open($Output, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        }
        $row.start_utc = [DateTime]::UtcNow.ToString('o')
        $watch.Start()
        $started = $process.Start()
        if (-not $started) { throw 'Process start failed.' }
        $row.pid = $process.Id
        $row.process_start_utc = $process.StartTime.ToUniversalTime().ToString('o')
        $stdoutTask = if ($sink) { $process.StandardOutput.BaseStream.CopyToAsync($sink) } else { $process.StandardOutput.ReadToEndAsync() }
        $stderrTask = $process.StandardError.ReadToEndAsync()
        while (-not $process.WaitForExit(50)) {
            if ($watch.Elapsed.TotalSeconds -ge 60) { $row.timed_out = $true; throw 'Native process 60 second deadline exceeded.' }
            if ($stdoutTask.IsFaulted -or $stderrTask.IsFaulted) { throw 'Native stream drain failed.' }
        }
        if ($sink) { $null = $stdoutTask.GetAwaiter().GetResult(); $sink.Flush($true) }
        else { $row.stdout = $stdoutTask.GetAwaiter().GetResult() }
        $row.stderr = $stderrTask.GetAwaiter().GetResult()
        $watch.Stop()
        $row.end_utc = [DateTime]::UtcNow.ToString('o')
        $row.exit_code = $process.ExitCode
        $row.cpu_ms = $process.TotalProcessorTime.TotalMilliseconds
        if ($row.exit_code -ne 0) { throw "Native process exit $($row.exit_code): $($row.stderr)" }
    } catch { $row.error = $_.Exception.Message; throw }
    finally {
        if ($started) {
            if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
            if ($null -ne $stdoutTask) {
                try { if ($sink) { $null = $stdoutTask.GetAwaiter().GetResult() } else { $row.stdout = $stdoutTask.GetAwaiter().GetResult() } } catch { }
            }
            if ($null -ne $stderrTask) { try { $row.stderr = $stderrTask.GetAwaiter().GetResult() } catch { } }
            try { $row.exit_code = $process.ExitCode; $row.cpu_ms = $process.TotalProcessorTime.TotalMilliseconds } catch { }
        }
        if ($watch.IsRunning) { $watch.Stop() }
        $row.wall_ms = $watch.Elapsed.TotalMilliseconds
        if ($null -eq $row.end_utc) { $row.end_utc = [DateTime]::UtcNow.ToString('o') }
        if ($sink) { $sink.Dispose() }
        if ($Output -and (Test-Path -LiteralPath $Output)) { try { $row.output = Identity $Output } catch { } }
        $process.Dispose()
    }
    return [pscustomobject]$row
}
function Assert-WprIdle([string]$Program) {
    $status = Call-Native $Program @('-status') 'wpr-status'
    # 未録画を明示できないlocale/出力もfail closedで扱う。
    if (($status.stdout + "`n" + $status.stderr) -notmatch '(?im)^\s*WPR is not recording\.?\s*$') { throw 'WPR is recording or idle status is not verifiable; no session will be started or stopped.' }
}
function Read-GroupEntries([string]$Path, [object[]]$Expected) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ne 2811006 -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -cne $fixedHash) { throw 'Fixed group bytes/SHA mismatch.' }
    $reader = [IO.BinaryReader]::new([IO.MemoryStream]::new($bytes, $false), [Text.UTF8Encoding]::new($false, $true), $false)
    $metadata = [Collections.Generic.List[object]]::new()
    try {
        if ([Convert]::ToHexString($reader.ReadBytes(8)) -cne '4B48534752503000' -or $reader.ReadUInt32() -ne 11 -or $reader.ReadUInt32() -ne 0) { throw 'Invalid fixed group header.' }
        for ($i = 0; $i -lt 11; $i++) {
            $length = $reader.ReadUInt16(); $size = $reader.ReadUInt64()
            if ($length -lt 1 -or $length -gt 255 -or $size -gt 64MB) { throw 'Invalid group metadata length.' }
            $rawName = $reader.ReadBytes($length)
            if ($rawName.Length -ne $length) { throw 'Truncated group name.' }
            $name = [Text.UTF8Encoding]::new($false, $true).GetString($rawName)
            if ($name -cne $Expected[$i].name -or $size -ne [long]$Expected[$i].bytes) { throw 'Group metadata differs from fixed manifest.' }
            $metadata.Add([pscustomobject]@{ name = $name; bytes = [long]$size; sha256 = [string]$Expected[$i].sha256 })
        }
        foreach ($entry in $metadata) {
            $body = $reader.ReadBytes([int]$entry.bytes)
            if ($body.Length -ne $entry.bytes -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($body)) -cne $entry.sha256) { throw 'Group body differs from fixed manifest.' }
        }
        if ($reader.BaseStream.Position -ne $reader.BaseStream.Length) { throw 'Trailing group bytes.' }
    } finally { $reader.Dispose() }
    return $metadata.ToArray()
}

foreach ($path in @($BinaryPath, $PdbPath, $GroupPath, $WorkDirectory, $RustcPath, $WprPath)) { Assert-Absolute $path; Assert-NoReparse $path }
$work = [IO.Path]::GetFullPath($WorkDirectory)
if (-not $work.StartsWith($build + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'WorkDirectory must be fresh and below UnLhaRe/build.' }
if (Test-Path -LiteralPath $work) { throw 'WorkDirectory exists; no files will be overwritten.' }
$null = New-Item -ItemType Directory -Path $work
Assert-NoReparse $work
$tracePath = Join-Path $work 'cpu.etl'
$report.recording.path = $tracePath
try {
    $report.environment.cpu = @(Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors)
    $report.environment['power_scheme'] = @(powercfg /getactivescheme)
    $binary = Lock-Identity $BinaryPath 'current-release-binary'
    $pdb = Lock-Identity $PdbPath 'matching-release-pdb'
    $group = Lock-Identity $GroupPath 'fixed-group'
    $wpr = Lock-Identity $WprPath 'wpr-tool'
    $null = Lock-Identity $PSCommandPath 'capture-harness'
    $manifest = Lock-Identity (Join-Path $PSScriptRoot 'CORPUS_MANIFEST.json') 'corpus-manifest'
    $sourcePathsBefore = @(Source-Paths)
    foreach ($path in $sourcePathsBefore) { $null = Lock-Identity $path 'current-source-or-cargo-input' }
    $rustc = [IO.Path]::GetFullPath($RustcPath)
    $null = Lock-Identity $rustc 'rustc-command-binary'
    $compiler = Call-Native $rustc @('--version', '--verbose') 'toolchain-version'
    $report.environment.rustc = $compiler.stdout
    if ($compiler.stdout -notmatch '(?m)^rustc 1\.98\.1\s') { throw 'Expected Rust 1.98.1 toolchain.' }
    if ($binary.before_bytes -le 0 -or $pdb.before_bytes -le 0) { throw 'Binary and PDB must be nonempty.' }
    if ($group.before_bytes -ne 2811006 -or $group.before_sha256 -cne $fixedHash) { throw 'Fixed input identity mismatch.' }
    $collections = @(Get-Content -LiteralPath $manifest.path -Raw | ConvertFrom-Json | Where-Object { $_.name -ceq 'canterbury-development' -and $_.role -ceq 'development' })
    if ($collections.Count -ne 1 -or @($collections[0].files).Count -ne 11) { throw 'Expected fixed 11-entry manifest.' }
    $names = [string[]]@($collections[0].files | ForEach-Object { $_.name })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $expected = @($names | ForEach-Object {
        $name = $_
        $entry = @($collections[0].files | Where-Object { $_.name -ceq $name })
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $entry.Count -ne 1 -or [long]$entry[0].bytes -lt 0 -or [long]$entry[0].bytes -gt 64MB -or [string]$entry[0].sha256 -cnotmatch '^[0-9A-F]{64}$') { throw 'Invalid fixed manifest entry.' }
        $entry[0]
    })
    $entries = @(Read-GroupEntries $group.path $expected)
    Assert-WprIdle $wpr.path
    $benchCall = Call-Native $binary.path (@('group-bench', $group.path) + $fixedOptions + @('--repeats', '1')) 'normal-e2e-before-recording'
    $bench = $benchCall.stdout | ConvertFrom-Json
    if ($bench.input_bytes -ne 2811006 -or $bench.frame_bytes -ne 483130 -or $bench.algorithm -cne 'Beam' -or $bench.beam_model -cne 'Blended' -or $bench.beam_matches -cne 'Bt5' -or $bench.entropy_backend -cne 'Range' -or $bench.beam_width -ne 2 -or $bench.beam_block -ne 8192 -or $bench.dictionary -ne 64MB -or $bench.bt_nice_len -ne 0 -or @($bench.samples).Count -ne 1 -or @($bench.solid_group).Count -ne 11 -or $bench.beam_batch_blocks -ne 1 -or $bench.beam_fixed_boundaries -or $bench.beam_greedy_seeds -or $bench.beam_rep_diverse_third_parent -or $bench.beam_fixed_rep_history -or $bench.beam_history_seeded) { throw 'Normal E2E JSON does not match fixed settings/input/frame.' }
    for ($i = 0; $i -lt 11; $i++) {
        if ($bench.solid_group[$i].name -cne $entries[$i].name -or $bench.solid_group[$i].bytes -ne $entries[$i].bytes) { throw 'Normal E2E solid metadata mismatch.' }
    }
    $report.normal_e2e = [ordered]@{ json = $bench; group_entries = $entries; full_byte_decode_and_metadata_verified_by_cli = $true; timing_used_for_performance_decision = $false }
    New-Bytes (Join-Path $work 'normal-e2e.json') ([Text.UTF8Encoding]::new($false).GetBytes($benchCall.stdout))
    Assert-WprIdle $wpr.path
    if (Test-Path -LiteralPath $tracePath) { throw 'Refusing existing trace output.' }
    try {
        $null = Call-Native $wpr.path @('-start', 'CPU', '-filemode') 'wpr-start'
        $ownedRecording = $true
        $report.recording.start_confirmed = $true
        $report.recording.recording_may_remain = $true
        for ($run = 0; $run -lt 3; $run++) {
            $framePath = Join-Path $work "encode-$run.khc"
            $call = Call-Native $binary.path (@('group-encode', $group.path) + $fixedOptions) 'sampled-group-encode' $framePath
            $frames.Add($call)
            $report.recording.target_pids += $call.pid
            if ($call.output.bytes -ne 483130 -or $call.output.sha256 -cne $frameHash) { throw 'Sampled frame differs from fixed frame identity.' }
        }
    } finally {
        if ($ownedRecording) {
            $stopAttempted = $true
            $report.recording.stop_attempted = $true
            try {
                $null = Call-Native $wpr.path @('-stop', $tracePath) 'wpr-stop'
                $report.recording.stop_succeeded = $true
                $report.recording.recording_may_remain = $false
                $ownedRecording = $false
                $report.trace = Identity $tracePath
                if ($report.trace.bytes -le 0) { throw 'WPR produced an empty trace.' }
            } catch { $report.recording.error = $_.Exception.Message; $report.trace = $null; throw }
        }
    }
    $restoredPath = Join-Path $work 'restored.group'
    $decode = Call-Native $binary.path (@('decode', $frames[0].output.path) + $fixedOptions) 'decode-after-recording' $restoredPath
    if ($decode.output.bytes -ne 2811006 -or $decode.output.sha256 -cne $fixedHash) { throw 'Decoded group differs from fixed input.' }
    $decodedEntries = @(Read-GroupEntries $restoredPath $expected)
    $report.decode = [ordered]@{ invocation = $decode; group_entries = $decodedEntries; full_group_metadata_and_content_verified = $true }
    $report.status = 'capture_verified'
} catch { $failure = $_; $report.error = $_.Exception.Message }
finally {
    # start成功後に例外が起きても必ずowned sessionを止める。stop失敗の再試行/cancelはしない。
    if ($ownedRecording -and -not $stopAttempted) {
        $report.recording.stop_attempted = $true
        try {
            $null = Call-Native $WprPath @('-stop', $tracePath) 'wpr-stop-finally'
            $report.recording.stop_succeeded = $true; $report.recording.recording_may_remain = $false
            $report.trace = Identity $tracePath
        } catch {
            $report.recording.error = $_.Exception.Message; $report.trace = $null
            if ($null -eq $failure) { $failure = $_ }
        }
    }
    if (Test-Path -LiteralPath $tracePath) { try { $report.recording.identity = Identity $tracePath } catch { } }
    $report.encode_runs = @($calls | Where-Object { $_.kind -ceq 'sampled-group-encode' })
    $report.recording.target_pids = @($report.encode_runs | Where-Object { $null -ne $_.pid } | ForEach-Object { $_.pid })
    foreach ($item in $identities) {
        try {
            $after = Identity $item.path
            $item.after_bytes = $after.bytes; $item.after_sha256 = $after.sha256
            if ($after.bytes -ne $item.before_bytes -or $after.sha256 -cne $item.before_sha256) { throw "Identity changed during capture: $($item.path)" }
        } catch {
            $report.error = (@($report.error, $_.Exception.Message) | Where-Object { $_ }) -join '; '
            if ($null -eq $failure) { $failure = $_ }
        }
    }
    if (Get-Variable sourcePathsBefore -ErrorAction SilentlyContinue) {
        try {
            $sourcePathsAfter = @(Source-Paths)
            if (($sourcePathsBefore -join "`n") -cne ($sourcePathsAfter -join "`n")) { throw 'The recorded source file set changed during capture.' }
        } catch {
            $report.error = (@($report.error, $_.Exception.Message) | Where-Object { $_ }) -join '; '
            if ($null -eq $failure) { $failure = $_ }
        }
    }
    foreach ($stream in $locks) { $stream.Dispose() }
    if ($null -ne $failure) { $report.status = 'failed'; if (-not $report.error) { $report.error = $failure.Exception.Message } }
    $report['completed_utc'] = [DateTime]::UtcNow.ToString('o')
    New-Bytes (Join-Path $work 'report.json') ([Text.UTF8Encoding]::new($false).GetBytes(($report | ConvertTo-Json -Depth 18)))
}
if ($null -ne $failure) { throw $failure }
Write-Host "Fresh CPU trace captured: $tracePath; report: $(Join-Path $work 'report.json')"
