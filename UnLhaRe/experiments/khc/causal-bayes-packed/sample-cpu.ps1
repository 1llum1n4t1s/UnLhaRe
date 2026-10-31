#requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$BinaryPath,
    [Parameter(Mandatory)][string]$PdbPath,
    [Parameter(Mandatory)][string]$GroupPath,
    [Parameter(Mandatory)][string]$WorkDirectory,
    [Parameter(Mandatory)][string]$RustcPath,
    [switch]$SymbolProfile,
    [string]$WprPath = 'C:/Windows/System32/wpr.exe'
)

# 失敗条件を先に固定: 非絶対path/reparse/既存work・出力、不正input/manifest、
# source/binary/PDB変更、通常E2Eのmetadata/本文不一致、frame size/SHA不一致、
# WPR既存録画・status判定不能・start/stop失敗、process timeout/非zero、復号不一致。
# 自分でstart成功を確認したsessionだけfinallyでstopする。cancel/他session停止は禁止。
# この採取は通常経路のCPU帰属用。採取中・group-benchの時間を性能採否へ使わない。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'capture-proof.ps1')
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$build = [IO.Path]::GetFullPath((Join-Path $root 'build'))
$fixedHash = '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'
$frameHash = 'B4F17DEFF3B39FF26E5DBD38454B51FB1196FFEB1B5252E93E65D5E4B9A3824A'
$fixedOptions = @('encode|decode input output; frozen prior/depth/grammar')
$locks = [Collections.Generic.List[IO.FileStream]]::new()
$identities = [Collections.Generic.List[object]]::new()
$calls = [Collections.Generic.List[object]]::new()
$frames = [Collections.Generic.List[object]]::new()
$ownedRecording = $false
$stopAttempted = $false
$failure = $null
$report = [ordered]@{
    status = 'failed'; started_utc = [DateTime]::UtcNow.ToString('o'); error = $null
    kind = 'fresh_causal_bayes_cpu_attribution'
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
        'Exactly one warmup and one recorded encode; no setting/count sweep or automatic retry.',
        'Verified prior full E2E proof is hash-locked; one encode warmup precedes recording and one encode is recorded.',
        'Binary writes its own no-clobber output file; stdout JSON is separately recorded.',
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
    return [string[]]@('codec.rs','cts_model.rs','bayes_model.rs','../range.rs','../rejected-binary-mix/packed_alphabet.rs','../CAUSAL_BAYES_CPU_CONTRACT_20260930.md' | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $_)) } | Sort-Object -Unique)
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
            if (Test-Path -LiteralPath $Output) { throw 'Refusing existing output.' }
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
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    $report.environment['administrator_token'] = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $report.environment['power_scheme'] = @(powercfg /getactivescheme)
    $binary = Lock-Identity $BinaryPath 'current-release-binary'
    $pdb = Lock-Identity $PdbPath 'matching-release-pdb'
    $group = Lock-Identity $GroupPath 'fixed-group'
    $wpr = Lock-Identity $WprPath 'wpr-tool'
    $null = Lock-Identity $PSCommandPath 'capture-harness'
    $null = Lock-Identity (Join-Path $PSScriptRoot 'capture-proof.ps1') 'capture-json-validation'
    $manifest = Lock-Identity (Join-Path $PSScriptRoot '../CORPUS_MANIFEST.json') 'corpus-manifest'
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
    $proofRelative = if ($SymbolProfile) { 'build/khc-bwt-causal-bayes-symbol-map-20260930/full-e2e/report.json' } else { 'build/khc-bwt-causal-bayes-full-20260930/full-e2e-final/report.json' }
    $proof = Lock-Identity (Join-Path $root $proofRelative) 'full-codec-proof'
    $expectedBinary = if ($SymbolProfile) { '7B843CE202AD0A5493F2868946343F124D5B3CC126C6866CC008B5CCA0A56B0D' } else { '4C4D9D66EA0DE8174BF436D7222BC5CCF8F42BD03EF7A1DCFE030FAAD8322ABD' }
    $expectedPdb = if ($SymbolProfile) { '6C42626057721F5B677EDCD2DC1BF9BD78F6B6195FBCA72ACEB036E15CF77E4E' } else { 'F043C0DEC33A093174DE08908BA735AD3BA2909520EF33584F92F4B9A671467F' }
    $expectedProof = if ($SymbolProfile) { 'A28A747FFF8576946E9B0B274CFAE2784570220482550397442ABED49D10F690' } else { '0AE7EAB04A5E58DE91AB1F74912F332D1FF6F2FC95D3A29DC0030F22A7307E37' }
    if ($binary.before_sha256 -cne $expectedBinary -or $pdb.before_sha256 -cne $expectedPdb -or $proof.before_sha256 -cne $expectedProof) { throw 'Frozen candidate/proof identity mismatch.' }
    $proofJson = Get-Content -LiteralPath $proof.path -Raw | ConvertFrom-Json
    if ($proofJson.status -cne 'correctness_and_size_passed_not_timed' -or @($proofJson.checks).Count -ne 36 -or
        @($proofJson.checks | Where-Object { -not $_.passed }).Count -ne 0 -or @($proofJson.invocations).Count -ne 61 -or
        $proofJson.fixed_candidate.bytes -ne 483468 -or $proofJson.fixed_candidate.sha256 -cne $frameHash) { throw 'Full correctness proof incomplete.' }
    $proofBinary = @($proofJson.provenance | Where-Object role -ceq 'binary')
    if ($proofBinary.Count -ne 1 -or -not $proofBinary[0].path.Equals($binary.path,[StringComparison]::OrdinalIgnoreCase) -or
        $proofBinary[0].before_sha256 -cne $binary.before_sha256 -or $proofBinary[0].after_sha256 -cne $binary.before_sha256) { throw 'Proof binary mismatch.' }
    $report['symbol_profile'] = [bool]$SymbolProfile
    if ($SymbolProfile) { $report.notes += 'Separate debuginfo=2 machine-code profile; not the frozen minimal-debug performance binary and not a remapping of its trace.' }
    foreach ($path in $sourcePathsBefore | Where-Object { [IO.Path]::GetExtension($_) -ceq '.rs' }) {
        $recorded = @($proofJson.provenance | Where-Object { $_.path.Equals($path,[StringComparison]::OrdinalIgnoreCase) })
        if ($recorded.Count -ne 1 -or $recorded[0].before_sha256 -cne (Get-FileHash -LiteralPath $path).Hash -or $recorded[0].after_sha256 -cne $recorded[0].before_sha256) { throw 'Frozen full codec source identity mismatch.' }
    }
    $warmPath = Join-Path $work 'warmup.bayes'
    $warm = Call-Native $binary.path @('encode',$group.path,$warmPath) 'warmup-before-recording' $warmPath
    Assert-CodecReceipt $warm 'encode'
    if ($warm.output.bytes -ne 483468 -or $warm.output.sha256 -cne $frameHash) { throw 'Warmup frame identity mismatch.' }
    $report.normal_e2e = [ordered]@{ proof=$proof; checks=36; cli_invocations=61; group_entries=$entries; warmup=$warm; timing_used_for_performance_decision=$false }
    Assert-WprIdle $wpr.path
    if (Test-Path -LiteralPath $tracePath) { throw 'Refusing existing trace output.' }
    try {
        $null = Call-Native $wpr.path @('-start', 'CPU', '-filemode') 'wpr-start'
        $ownedRecording = $true
        $report.recording.start_confirmed = $true
        $report.recording.recording_may_remain = $true
        for ($run = 0; $run -lt 1; $run++) {
            $framePath = Join-Path $work "encode-$run.bayes"
            $call = Call-Native $binary.path @('encode', $group.path, $framePath) 'sampled-bayes-encode' $framePath
            $frames.Add($call)
            Assert-CodecReceipt $call 'encode'
            $report.recording.target_pids += $call.pid
            if ($call.output.bytes -ne 483468 -or $call.output.sha256 -cne $frameHash) { throw 'Sampled frame differs from fixed frame identity.' }
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
                Assert-WprIdle $wpr.path
                $report.trace = Identity $tracePath
                if ($report.trace.bytes -le 0) { throw 'WPR produced an empty trace.' }
                if ($report.trace.bytes -gt 536870912) { throw 'Raw trace size exceeds 512 MiB analysis budget.' }
            } catch { $report.recording.error = $_.Exception.Message; $report.trace = $null; throw }
        }
    }
    $restoredPath = Join-Path $work 'restored.group'
    $decode = Call-Native $binary.path @('decode', $frames[0].output.path, $restoredPath) 'decode-after-recording' $restoredPath
    Assert-CodecReceipt $decode 'decode'
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
    $report.encode_runs = @($calls | Where-Object { $_.kind -ceq 'sampled-bayes-encode' })
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
