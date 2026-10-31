#requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$BinaryPath,
    [Parameter(Mandatory)][string]$GroupPath,
    [Parameter(Mandatory)][string]$WorkDirectory,
    [string]$RustcPath = 'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
)

# 静的区間coverのfailure-first CLI診断。実frame・速度・OS peak・holdoutは検査しない。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$buildPrefix = [IO.Path]::GetFullPath((Join-Path $root 'build')) + [IO.Path]::DirectorySeparatorChar
$work = [IO.Path]::GetFullPath($WorkDirectory)
$fixedHash = '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'
$fixedSize = 2811006L
$invocations = [Collections.Generic.List[object]]::new()
$checks = [Collections.Generic.List[object]]::new()
$identities = [Collections.Generic.List[object]]::new()
$owned = [Collections.Generic.List[string]]::new()
$locks = [Collections.Generic.List[IO.FileStream]]::new()

function Assert-NoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point rejected: $current" }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}
function Get-Identity([string]$Path) {
    Assert-NoReparse $Path
    $item = Get-Item -LiteralPath $Path -Force
    if ($item -isnot [IO.FileInfo]) { throw "Expected regular file: $Path" }
    [pscustomobject]@{ path = $item.FullName; bytes = $item.Length; sha256 = (Get-FileHash -LiteralPath $item.FullName).Hash }
}
function Lock-Identity([string]$Path, [string]$Role) {
    $id = Get-Identity $Path
    $locks.Add([IO.File]::Open($id.path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
    $id = Get-Identity $id.path
    $row = [pscustomobject]@{ role = $Role; path = $id.path; before_bytes = $id.bytes; before_sha256 = $id.sha256; after_bytes = $null; after_sha256 = $null }
    $identities.Add($row)
    return $row
}
function Write-New([string]$Path, [byte[]]$Data) {
    Assert-NoReparse $Path
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($Data, 0, $Data.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    $owned.Add($Path)
}
function Add-Check([string]$Name, [object]$Evidence) {
    $checks.Add([pscustomobject]@{ name = $Name; passed = $true; evidence = $Evidence })
}
function Invoke-Cli([string]$Name, [string[]]$Argv, [int]$ExpectedExit) {
    $info = [Diagnostics.ProcessStartInfo]::new($binary.path)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.WorkingDirectory = $work
    foreach ($arg in $Argv) { $info.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $row = [ordered]@{ name = $Name; program = $binary.path; argv = $Argv; expected_exit = $ExpectedExit; exit = $null; stdout = ''; stderr = ''; timeout = $false; diagnostic = $null }
    $invocations.Add($row)
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) { throw 'Process start failed.' }
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { $row.timeout = $true; throw "CLI timeout: $Name" }
        $row.stdout = $outTask.GetAwaiter().GetResult()
        $row.stderr = $errTask.GetAwaiter().GetResult()
        $row.exit = $process.ExitCode
        if ($row.exit -ne $ExpectedExit) { throw "CLI $Name exit $($row.exit), expected $ExpectedExit : $($row.stderr)" }
        if ($ExpectedExit -eq 0) {
            if ($row.stderr.Length -ne 0 -or @($row.stdout.Trim() -split '\r?\n').Count -ne 1) { throw "Unexpected CLI output: $Name" }
            $row.diagnostic = $row.stdout | ConvertFrom-Json
        } elseif ($row.stdout.Length -ne 0) { throw "Rejected CLI wrote stdout: $Name" }
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
    return [pscustomobject]$row
}
function Assert-Number([object]$Value, [string]$Name, [double]$Min, [double]$Max, [bool]$Integer = $true) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) { throw "Missing/non-numeric $Name" }
    $number = [double]$Value
    if (-not [double]::IsFinite($number) -or $number -lt $Min -or $number -gt $Max -or ($Integer -and [Math]::Truncate($number) -ne $number)) { throw "Invalid numeric $Name" }
}
function Assert-Diagnostic([object]$Json, [long]$InputBytes) {
    if ($Json.kind -cne 'bwt_static_interval_cover_ideal_size_diagnostic') { throw 'Diagnostic kind mismatch.' }
    Assert-Number $Json.input_bytes 'input bytes' 0 8388608
    Assert-Number $Json.bwt_symbols 'BWT length' 1 8388609
    if ($Json.input_bytes -ne $InputBytes -or $Json.bwt_symbols -ne $InputBytes + 1) { throw 'Diagnostic input/BWT counts mismatch.' }
    $n = $InputBytes + 1
    Assert-Number $Json.primary 'primary' 0 ($n - 1)
    Assert-Number $Json.sa_nodes 'tree nodes' ($n + 1) (2 * $n)
    Assert-Number $Json.selected_segment_count 'segments' 1 $n
    # 12桁JSONへ丸めた値が理論最大を微小に超える場合を区別する。
    Assert-Number $Json.ideal_payload_bits 'ideal payload' 0 ($n * [Math]::Log2(257) + 1e-6) $false
    Assert-Number $Json.metadata_bytes 'metadata' (7 * $Json.selected_segment_count) (2590 * $Json.selected_segment_count)
    Assert-Number $Json.ideal_total_frame_bytes 'ideal total' 0 1e10 $false
    Assert-Number $Json.whole_bwt_ideal_frame_bytes 'whole BWT total' 0 1e10 $false
    Assert-Number $Json.histogram_merge_entries 'merge entries' 0 ([long]::MaxValue)
    Assert-Number $Json.histogram_nonzero_entries_processed 'processed histogram entries' $Json.sa_nodes (257 * $Json.sa_nodes)
    Assert-Number $Json.max_owned_buffer_bytes 'owned capacity' 1 1073741824
    Assert-Number $Json.entropy_negative_clamps 'negative clamps' 0 $Json.sa_nodes
    Assert-Number $Json.segment_summary.min_symbols 'minimum segment' 1 $n
    Assert-Number $Json.segment_summary.max_symbols 'maximum segment' $Json.segment_summary.min_symbols $n
    if ($Json.segment_summary.fnv1a64_interval_depth_metadata -cnotmatch '^[0-9a-f]{16}$') { throw 'Segment digest format mismatch.' }
    if ($Json.header_bytes -ne 36 -or $Json.threshold -ne 483599 -or $Json.actual_coder_termination_quantization_bytes -ne 0 -or $Json.input_dependent_segment_tables_charged -isnot [bool] -or -not $Json.input_dependent_segment_tables_charged) { throw 'Fixed model contract mismatch.' }
    $recomputed = 36.0 + $Json.ideal_payload_bits / 8.0 + $Json.metadata_bytes
    if ([Math]::Abs($recomputed - $Json.ideal_total_frame_bytes) -gt 1e-6 -or $Json.ideal_total_frame_bytes - $Json.whole_bwt_ideal_frame_bytes -gt 1e-6) { throw 'Diagnostic cost mismatch.' }
    if ($Json.estimated_threshold_passed -isnot [bool] -or $Json.estimated_threshold_passed -ne ($recomputed -le 483599)) { throw 'Estimated size gate mismatch.' }
    foreach ($flag in @('bounded_regular_input', 'sa_permutation', 'sentinel_primary', 'inverse_bwt_reverse_full_input', 'tree_depth_interval_coverage', 'histogram_count_entropy_metadata', 'selected_sorted_full_coverage', 'dp_global_cost_conservation', 'owned_capacity_cap')) {
        if ($Json.checks.$flag -isnot [bool] -or -not $Json.checks.$flag) { throw "Missing/failed diagnostic check: $flag" }
    }
    $small = $n -le 4096
    if ($Json.checks.naive_sa_lcp_performed -isnot [bool] -or $Json.checks.naive_sa_lcp_performed -ne $small) { throw 'Naive comparison boundary mismatch.' }
    if ($small) {
        if ($Json.checks.naive_sa_lcp -isnot [bool] -or -not $Json.checks.naive_sa_lcp) { throw 'Naive SA/LCP mismatch.' }
    } elseif ($null -ne $Json.checks.naive_sa_lcp) { throw 'Unperformed naive comparison claimed.' }
}
function Assert-Rejected([string]$Name, [string[]]$Argv, [string]$ExpectedReason) {
    $row = Invoke-Cli $Name $Argv 1
    if ($row.stderr.Trim() -cne "rejected: $ExpectedReason") { throw "Unexpected rejection reason: $Name : $($row.stderr)" }
    Add-Check $Name ([pscustomobject]@{ exit = $row.exit; stdout_empty = $true; expected_reason = $ExpectedReason; observed_reason = $row.stderr.Trim() })
}
function Assert-Group([byte[]]$Data) {
    if ($Data.LongLength -ne $fixedSize -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Data)) -cne $fixedHash) { throw 'Fixed group identity mismatch.' }
    $collections = @(Get-Content -LiteralPath $manifest.path -Raw | ConvertFrom-Json | Where-Object { $_.name -ceq 'canterbury-development' -and $_.role -ceq 'development' })
    if ($collections.Count -ne 1 -or @($collections[0].files).Count -ne 11) { throw 'Manifest boundary mismatch.' }
    $expected = @($collections[0].files)
    $names = [string[]]@($expected | ForEach-Object { $_.name })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $stream = [IO.MemoryStream]::new($Data, $false)
    $reader = [IO.BinaryReader]::new($stream, [Text.UTF8Encoding]::new($false, $true), $false)
    $entries = [Collections.Generic.List[object]]::new()
    try {
        if ([Convert]::ToHexString($reader.ReadBytes(8)) -cne '4B48534752503000' -or $reader.ReadUInt32() -ne 11 -or $reader.ReadUInt32() -ne 0) { throw 'Group magic/count/flags mismatch.' }
        for ($i = 0; $i -lt 11; $i++) {
            $len = $reader.ReadUInt16(); $size = $reader.ReadUInt64()
            if ($len -lt 1 -or $len -gt 255 -or $size -gt $fixedSize) { throw 'Group metadata bounds mismatch.' }
            $nameBytes = $reader.ReadBytes($len)
            if ($nameBytes.Length -ne $len) { throw 'Truncated group name.' }
            $name = [Text.UTF8Encoding]::new($false, $true).GetString($nameBytes)
            $match = @($expected | Where-Object { $_.name -ceq $names[$i] })
            if ($match.Count -ne 1 -or $name -cne $names[$i] -or $size -ne $match[0].bytes) { throw 'Group metadata/order mismatch.' }
            $entries.Add([pscustomobject]@{ name = $name; bytes = [long]$size; expected_sha256 = [string]$match[0].sha256; observed_sha256 = $null })
        }
        foreach ($entry in $entries) {
            $body = $reader.ReadBytes([int]$entry.bytes)
            $entry.observed_sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($body))
            if ($body.LongLength -ne $entry.bytes -or $entry.observed_sha256 -cne $entry.expected_sha256) { throw "Group body mismatch: $($entry.name)" }
        }
        if ($stream.Position -ne $stream.Length) { throw 'Trailing group bytes.' }
    } finally { $reader.Dispose() }
    return $entries.ToArray()
}

if (-not $work.StartsWith($buildPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'WorkDirectory must be below UnLhaRe/build.' }
Assert-NoReparse $work
if (Test-Path -LiteralPath $work) { throw 'WorkDirectory must be new.' }
$null = New-Item -ItemType Directory -Path $work
$owned.Add($work)
$report = [ordered]@{
    status = 'failed'; started_utc = [DateTime]::UtcNow.ToString('o'); error = $null
    environment = [ordered]@{ os = [Runtime.InteropServices.RuntimeInformation]::OSDescription; architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString(); powershell = $PSVersionTable.PSVersion.ToString(); cwd = $PWD.Path }
    fixed_gate = [ordered]@{ input_bytes = $fixedSize; input_sha256 = $fixedHash; maximum_archive_bytes = 483599; maximum_encode_ms_exclusive = 574.5624 }
    provenance = $identities; invocations = $invocations; checks = $checks; owned_paths = $owned; entries = @()
    fixed_candidate = $null; estimated_size_gate_passed = $false; estimated_size_delta_bytes = $null; timing_used = $false; actual_frame_created = $false
    limits = @('Optimistic specified static model proxy, not a general lower bound or a compressed frame.', 'Coder quantization, rounding, padding and termination charged zero; segment frequency tables charged exactly.', 'Owned buffer capacities exclude allocator metadata, stack and OS peak memory.', 'Full-byte inverse BWT is checked inside the diagnostic; no external restored file is published.', 'Fixed single orientation/configuration; no parameter/transform sweep, timing or holdout.', 'Size pass would require a separate real coder/decoder, full frame and speed/memory/generalization verification.')
}
$failure = $null
try {
    $binary = Lock-Identity ([IO.Path]::GetFullPath($BinaryPath)) 'binary'
    $source = Lock-Identity (Join-Path $PSScriptRoot 'boosting_probe.rs') 'source'
    $group = Lock-Identity ([IO.Path]::GetFullPath($GroupPath)) 'fixed-input'
    $manifest = Lock-Identity (Join-Path $PSScriptRoot 'CORPUS_MANIFEST.json') 'manifest'
    $null = Lock-Identity $PSCommandPath 'harness'
    $rustc = Lock-Identity ([IO.Path]::GetFullPath($RustcPath)) 'rustc'
    $report.environment['rustc_version'] = @(& $rustc.path --version --verbose)
    if ($LASTEXITCODE -ne 0 -or $report.environment.rustc_version[0] -cnotmatch '^rustc 1\.98\.1 ') { throw 'Rust toolchain identity mismatch.' }
    $report.environment['cpu'] = @(Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors)
    $report.environment['source_last_write_utc'] = (Get-Item -LiteralPath $source.path).LastWriteTimeUtc.ToString('o')
    $report.environment['compile_arguments'] = @('boosting_probe.rs', '--edition=2024', '-C', 'opt-level=3', '-C', 'panic=abort')
    if ($group.before_bytes -ne $fixedSize -or $group.before_sha256 -cne $fixedHash) { throw 'Fixed input provenance mismatch.' }
    $report.entries = @(Assert-Group ([IO.File]::ReadAllBytes($group.path)))
    Add-Check 'fixed-input-11entries' $report.entries
    Write-Host "Static cover ideal size only: source=$($source.before_sha256) binary=$($binary.before_sha256) input=$fixedHash"
    $fixtures = [ordered]@{ empty = [byte[]]@(); single = [byte[]]@(42); single_high = [byte[]]@(255); repeated = [byte[]]::new(1024); periodic = [byte[]]::new(1024); all_bytes = [byte[]](0..255); seeded_mixed = [byte[]]::new(1024) }
    [Array]::Fill($fixtures.repeated, [byte]65)
    for ($i = 0; $i -lt $fixtures.periodic.Length; $i++) { $fixtures.periodic[$i] = [byte](@(0,1,2,255,3,3,7,8,0,13,27)[$i % 11]) }
    # 固定xorshift32。ランタイムのRandom実装にfixtureを依存させない。
    $seed = [uint32]20260930
    for ($i = 0; $i -lt $fixtures.seeded_mixed.Length; $i++) {
        $seed = $seed -bxor [uint32](([uint64]$seed -shl 13) -band [uint64]4294967295)
        $seed = $seed -bxor ($seed -shr 17)
        $seed = $seed -bxor [uint32](([uint64]$seed -shl 5) -band [uint64]4294967295)
        $fixtures.seeded_mixed[$i] = if ($i % 7 -lt 4) { [byte]($i % 11) } else { [byte]($seed -band 255) }
    }
    foreach ($name in $fixtures.Keys) {
        $path = Join-Path $work "$name.input"
        Write-New $path $fixtures[$name]
        $fixture = Lock-Identity $path "fixture-$name"
        $first = Invoke-Cli "$name-first" @($path) 0
        $second = Invoke-Cli "$name-repeat" @($path) 0
        Assert-Diagnostic $first.diagnostic $fixture.before_bytes
        Assert-Diagnostic $second.diagnostic $fixture.before_bytes
        if ($first.stdout -cne $second.stdout) { throw "JSON non-determinism: $name" }
        if ($name -ceq 'empty' -and ($first.diagnostic.ideal_total_frame_bytes -ne 43 -or $first.diagnostic.metadata_bytes -ne 7 -or $first.diagnostic.ideal_payload_bits -ne 0 -or $first.diagnostic.selected_segment_count -ne 1 -or $first.diagnostic.segment_summary.fnv1a64_interval_depth_metadata -cne 'f2e1f010affb6f23')) { throw 'Empty independent ground truth / tie-parent mismatch.' }
        if ($name -ceq 'single' -and ($first.diagnostic.ideal_total_frame_bytes -ne 45.25 -or $first.diagnostic.metadata_bytes -ne 9 -or $first.diagnostic.ideal_payload_bits -ne 2 -or $first.diagnostic.selected_segment_count -ne 1 -or $first.diagnostic.segment_summary.fnv1a64_interval_depth_metadata -cne 'd281db347213fdbe')) { throw 'Single independent ground truth mismatch.' }
        if ($name -ceq 'single_high' -and ($first.diagnostic.ideal_total_frame_bytes -ne 46.25 -or $first.diagnostic.metadata_bytes -ne 10 -or $first.diagnostic.ideal_payload_bits -ne 2 -or $first.diagnostic.selected_segment_count -ne 1 -or $first.diagnostic.segment_summary.fnv1a64_interval_depth_metadata -cne '32872f2c1bde412d')) { throw 'High single ULEB-width ground truth mismatch.' }
        Add-Check "$name-inverse-naive-cost-and-determinism" ([pscustomobject]@{ input = $fixture; diagnostic = $first.diagnostic; stdout_sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($first.stdout))) })
    }
    Assert-Rejected 'missing-argument' @() 'expected one INPUT'
    Assert-Rejected 'extra-argument' @($group.path, 'extra') 'expected one INPUT'
    Assert-Rejected 'missing-file' @((Join-Path $work 'does-not-exist')) 'input open failed'
    # WindowsではdirectoryのFile::openが拒否される。regular-file条件以前の拒否を偽装しない。
    Assert-Rejected 'directory-input' @($work) 'input open failed'
    $oversize = Join-Path $work 'oversize.input'
    $stream = [IO.File]::Open($oversize, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.SetLength(8388609); $stream.Flush($true) } finally { $stream.Dispose() }
    $owned.Add($oversize)
    $null = Lock-Identity $oversize 'fixture-oversize'
    Assert-Rejected 'oversize-input' @($oversize) 'input must be regular file <=8 MiB'
    $fixedFirst = Invoke-Cli 'fixed-first' @($group.path) 0
    $fixedSecond = Invoke-Cli 'fixed-repeat' @($group.path) 0
    Assert-Diagnostic $fixedFirst.diagnostic $fixedSize
    Assert-Diagnostic $fixedSecond.diagnostic $fixedSize
    if ($fixedFirst.stdout -cne $fixedSecond.stdout) { throw 'Fixed group JSON non-determinism.' }
    $report.fixed_candidate = $fixedFirst.diagnostic
    $report.estimated_size_gate_passed = $fixedFirst.diagnostic.estimated_threshold_passed
    $report.estimated_size_delta_bytes = $fixedFirst.diagnostic.ideal_total_frame_bytes - 483599
    Add-Check 'fixed-inverse-cover-cost-and-determinism' $fixedFirst.diagnostic
    # 読み取り専用CLIが、既知fixture以外の出力を密かに生成しなかったことを照合。
    $observedFiles = @(Get-ChildItem -LiteralPath $work -Force -File)
    $expectedFiles = @($owned | Where-Object { $_ -cne $work })
    if ($observedFiles.Count -ne $expectedFiles.Count -or @(Get-ChildItem -LiteralPath $work -Force -Directory).Count -ne 0) { throw 'Read-only CLI produced unexpected artifacts.' }
    foreach ($file in $observedFiles) { if ($file.FullName -cnotin $expectedFiles) { throw 'Unexpected CLI output path.' } }
    Add-Check 'read-only-cli-no-published-frame' ([pscustomobject]@{ known_fixture_files = $expectedFiles.Count; actual_frame_absent = $true })
    foreach ($row in $identities) {
        $after = Get-Identity $row.path
        $row.after_bytes = $after.bytes; $row.after_sha256 = $after.sha256
        if ($row.before_bytes -ne $row.after_bytes -or $row.before_sha256 -cne $row.after_sha256) { throw "Provenance changed: $($row.role)" }
    }
    Add-Check 'all-locked-inputs-sources-tools-unchanged' $identities
    $report.status = if ($report.estimated_size_gate_passed) { 'diagnostic_correctness_and_optimistic_size_passed_not_a_codec' } else { 'diagnostic_correctness_passed_optimistic_size_no_go' }
} catch { $report.error = $_.Exception.ToString(); $failure = $_ }
finally {
    foreach ($held in $locks) { $held.Dispose() }
    $report['completed_utc'] = [DateTime]::UtcNow.ToString('o')
    $reportPath = Join-Path $work 'report.json'
    Write-New $reportPath ([Text.UTF8Encoding]::new($false).GetBytes(($report | ConvertTo-Json -Depth 18)))
}
if ($null -ne $failure) { throw $failure }
Write-Host "E2E $($report.status): $($checks.Count) checks; $($invocations.Count) CLI; ideal=$($report.fixed_candidate.ideal_total_frame_bytes); report=$reportPath"
