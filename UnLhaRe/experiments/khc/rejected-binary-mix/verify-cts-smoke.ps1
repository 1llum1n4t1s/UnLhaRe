#requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$ProbeBinary,
    [Parameter(Mandatory)][string]$PlainBinary,
    [Parameter(Mandatory)][string]$ReferenceBinary,
    [Parameter(Mandatory)][string]$WorkDirectory,
    [switch]$RequireBayesShadow
)
# 小入力の別process決定性・primary不変・旧reference復元を残すCLI E2E。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$build = [IO.Path]::GetFullPath((Join-Path $root 'build')) + [IO.Path]::DirectorySeparatorChar
$work = [IO.Path]::GetFullPath($WorkDirectory)
$locks = [Collections.Generic.List[IO.FileStream]]::new()
$provenance = [Collections.Generic.List[object]]::new()
$calls = [Collections.Generic.List[object]]::new()
$checks = [Collections.Generic.List[object]]::new()
function Assert-NoReparse([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and (((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Reparse point rejected.' }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
}
function Identity([string]$Path) {
    Assert-NoReparse $Path
    $item = Get-Item -LiteralPath $Path -Force
    if ($item -isnot [IO.FileInfo]) { throw 'Expected regular file.' }
    [pscustomobject]@{ path = $item.FullName; bytes = $item.Length; sha256 = (Get-FileHash -LiteralPath $item.FullName).Hash }
}
function Lock-File([string]$Path, [string]$Role) {
    $id = Identity $Path
    $locks.Add([IO.File]::Open($id.path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
    $id = Identity $id.path
    $row = [pscustomobject]@{ role = $Role; path = $id.path; before_bytes = $id.bytes; before_sha256 = $id.sha256; after_bytes = $null; after_sha256 = $null }
    $provenance.Add($row)
    return $row
}
function Write-New([string]$Path, [byte[]]$Bytes) {
    Assert-NoReparse $Path
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($Bytes); $stream.Flush($true) } finally { $stream.Dispose() }
}
function Call-Codec([string]$Name, [string]$Program, [string[]]$Argv) {
    if (Test-Path -LiteralPath $Argv[2]) { throw 'Refusing existing output.' }
    $info = [Diagnostics.ProcessStartInfo]::new($Program)
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true; $info.WorkingDirectory = $work
    foreach ($arg in $Argv) { $info.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    $row = [ordered]@{ name = $Name; program = $Program; argv = $Argv; exit = $null; stdout = ''; stderr = ''; output = $null }
    $calls.Add($row); $started = $false
    try {
        $started = $process.Start(); if (-not $started) { throw 'Start failed.' }
        $outTask = $process.StandardOutput.ReadToEndAsync(); $errTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { throw "CLI deadline exceeded: $Name" }
        $row.exit = $process.ExitCode; $row.stdout = $outTask.GetAwaiter().GetResult(); $row.stderr = $errTask.GetAwaiter().GetResult()
        if ($row.exit -ne 0 -or $row.stderr.Length -ne 0) { throw "CLI failed: $Name $($row.stderr)" }
        $row.output = Identity $Argv[2]
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
    return [pscustomobject]$row
}
if (-not $work.StartsWith($build, [StringComparison]::OrdinalIgnoreCase)) { throw 'WorkDirectory must be below build.' }
Assert-NoReparse $work
if (Test-Path -LiteralPath $work) { throw 'WorkDirectory must be new.' }
$null = New-Item -ItemType Directory -Path $work
$report = [ordered]@{
    status = 'failed'; error = $null; started_utc = [DateTime]::UtcNow.ToString('o')
    kind = 'cts_shadow_small_cli_e2e'; provenance = $provenance; invocations = $calls; checks = $checks
    timing_used = $false; auxiliary_decoder_verified = $false; holdout_used = $false
    environment = [ordered]@{ os = [Runtime.InteropServices.RuntimeInformation]::OSDescription; powershell = $PSVersionTable.PSVersion.ToString(); cwd = $PWD.Path }
    owned_root = $work; note = 'Primary frames only are restored; CTS auxiliary payload is not a complete codec.'
}
$failure = $null
try {
    $probe = Lock-File ([IO.Path]::GetFullPath($ProbeBinary)) 'probe'
    $plain = Lock-File ([IO.Path]::GetFullPath($PlainBinary)) 'plain'
    $reference = Lock-File ([IO.Path]::GetFullPath($ReferenceBinary)) 'verified-reference'
    if ($reference.before_sha256 -cne 'F8293F13A701B3CA7589A3A5561152F6AA7E50D00F64F8BE48033A223CD3E254') { throw 'Reference hash mismatch.' }
    foreach ($sourceName in @('codec.rs', 'cts_probe.rs', '../range.rs')) { $null = Lock-File (Join-Path $PSScriptRoot $sourceName) $sourceName }
    if ($RequireBayesShadow) {
        foreach ($sourceName in @('bayes_probe.rs', 'packed_alphabet.rs', 'validate-bayes-json.ps1', '../CAUSAL_BAYES_PACKED_CONTRACT_20260930.md')) { $null = Lock-File (Join-Path $PSScriptRoot $sourceName) $sourceName }
        . (Join-Path $PSScriptRoot 'validate-bayes-json.ps1')
        $report['require_bayes_shadow'] = $true
        $report.note = 'Primary frames are restored; Bayes auxiliary payload is not decoded. Packed metadata is independently decoded with exact BigInteger arithmetic.'
    }
    $null = Lock-File $PSCommandPath 'harness'
    $rustc = Lock-File 'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe' 'rustc'
    $report.environment['rustc_version'] = @(& $rustc.path --version --verbose)
    if ($LASTEXITCODE -ne 0 -or $report.environment.rustc_version[0] -cnotmatch '^rustc 1\.98\.1 ') { throw 'Rust toolchain mismatch.' }
    $fixtures = [ordered]@{ empty = [byte[]]@(); single = [byte[]]@(42); single_high = [byte[]]@(255); repeated = [byte[]]::new(1024); periodic = [byte[]]::new(1024); all_bytes = [byte[]](0..255); mixed = [byte[]]::new(1024) }
    [Array]::Fill($fixtures.repeated, [byte]65)
    $seed = [uint32]20260930
    for ($i = 0; $i -lt 1024; $i++) {
        $fixtures.periodic[$i] = [byte](@(0,1,2,255,3,3,7,8,0,13,27)[$i % 11])
        $seed = $seed -bxor [uint32](([uint64]$seed -shl 13) -band [uint64]4294967295)
        $seed = $seed -bxor ($seed -shr 17)
        $seed = $seed -bxor [uint32](([uint64]$seed -shl 5) -band [uint64]4294967295)
        $fixtures.mixed[$i] = if ($i % 7 -lt 4) { [byte]($i % 11) } else { [byte]($seed -band 255) }
    }
    foreach ($name in $fixtures.Keys) {
        $inputPath = Join-Path $work "$name.input"
        Write-New $inputPath $fixtures[$name]
        $original = Lock-File $inputPath "fixture-$name"
        $encoded = Call-Codec "$name-probe" $probe.path @('encode', $inputPath, (Join-Path $work "$name.frame"))
        $repeat = Call-Codec "$name-repeat" $probe.path @('encode', $inputPath, (Join-Path $work "$name.repeat.frame"))
        $normal = Call-Codec "$name-plain" $plain.path @('encode', $inputPath, (Join-Path $work "$name.plain.frame"))
        if ($encoded.stdout -cne $repeat.stdout -or $encoded.output.sha256 -cne $repeat.output.sha256 -or $encoded.output.sha256 -cne $normal.output.sha256) { throw "Probe non-determinism / primary change: $name" }
        $lines = @($encoded.stdout.Trim() -split '\r?\n')
        if ($lines.Count -ne 2) { throw 'Expected primary JSON and site diagnostic JSON.' }
        $primary = $lines[0] | ConvertFrom-Json
        $diagnostic = $lines[1] | ConvertFrom-Json
        $shadow = $diagnostic.cts_shadow
        if ($primary.input_bytes -ne $original.before_bytes -or $primary.output_bytes -ne $encoded.output.bytes -or $primary.operation -cne 'encode' -or
            $diagnostic.kind -cne 'site_loss_diagnostic' -or @($diagnostic.sites).Count -ne 7 -or @($shadow.classes).Count -ne 7 -or
            $shadow.depth -ne 16 -or $shadow.precision_bits -ne 48 -or $shadow.total_node_capacity -ne 917497 -or $shadow.state_capacity_bytes -ne 14679952 -or
            $shadow.self_checks.passed -isnot [bool] -or -not $shadow.self_checks.passed -or $shadow.self_checks.cases -lt 6) { throw 'Small CTS shape/selfcheck mismatch.' }
        $totalBits = 0L; $totalActive = 0L; $rawBits = 0.0; $q15Bits = 0.0; $ktBits = 0.0
        for ($i = 0; $i -lt 7; $i++) {
            $class = $shadow.classes[$i]
            if ($class.class -ne $i -or $class.bits -ne $diagnostic.sites[$i].bits -or $class.node_visits -ne 17L * $class.bits -or $class.active_nodes -lt 0 -or $class.active_nodes -gt 131071) { throw 'Small CTS class conservation mismatch.' }
            foreach ($loss in @($class.raw_ideal_bits, $class.q15_ideal_bits, $class.root_kt_ideal_bits)) { if (-not [double]::IsFinite([double]$loss) -or $loss -lt 0) { throw 'Small CTS loss mismatch.' } }
            $totalBits += $class.bits; $totalActive += $class.active_nodes
            $rawBits += $class.raw_ideal_bits; $q15Bits += $class.q15_ideal_bits; $ktBits += $class.root_kt_ideal_bits
        }
        if ($shadow.total_bits_calls -ne $totalBits -or $shadow.node_visits -ne 17L * $totalBits -or $shadow.active_nodes -ne $totalActive -or
            [Math]::Abs($rawBits - $shadow.raw_ideal_bits_total) -gt 0.01 -or [Math]::Abs($q15Bits - $shadow.q15_ideal_bits_total) -gt 0.01 -or
            [Math]::Abs($ktBits - $shadow.root_kt_ideal_bits_total) -gt 0.01 -or $shadow.payload_bytes -lt 5 -or
            $shadow.estimated_frame_bytes -ne $shadow.payload_bytes + 36 + 2 * $primary.alphabet_symbols -or
            $shadow.self_checks.max_abs_prediction_error -gt 1e-6 -or $shadow.self_checks.max_abs_weight_error -gt 1e-6) { throw 'Small CTS aggregate/header/reference mismatch.' }
        $restored = Call-Codec "$name-reference-decode" $reference.path @('decode', $encoded.output.path, (Join-Path $work "$name.restored"))
        if ($RequireBayesShadow) {
            $bayes = Assert-BayesPackedDiagnostic $diagnostic $primary $encoded.output.path
            $checks.Add([pscustomobject]@{ name = "$name-causal-bayes-packed-accounting"; passed = $true; observations = $bayes })
            if ($name -ceq 'all_bytes') {
                $rejections = Assert-BayesDiagnosticRejectsCorruption $diagnostic $primary $encoded.output.path
                foreach ($rejection in $rejections) { $checks.Add($rejection) }
            }
        }
        if ($restored.output.bytes -ne $original.before_bytes -or $restored.output.sha256 -cne $original.before_sha256) { throw 'Small old-reference roundtrip mismatch.' }
        $checks.Add([pscustomobject]@{ name = "$name-primary-unchanged-roundtrip-cts-deterministic"; passed = $true; fixture = $original; primary_frame = $encoded.output; restored = $restored.output; cts_shadow = $shadow })
    }
    foreach ($row in $provenance) {
        $after = Identity $row.path; $row.after_bytes = $after.bytes; $row.after_sha256 = $after.sha256
        if ($row.before_bytes -ne $after.bytes -or $row.before_sha256 -cne $after.sha256) { throw 'Provenance changed.' }
    }
    $report.status = 'small_primary_unchanged_and_cts_deterministic'
} catch { $report.error = $_.Exception.ToString(); $failure = $_ }
finally {
    foreach ($held in $locks) { $held.Dispose() }
    $report['completed_utc'] = [DateTime]::UtcNow.ToString('o')
    Write-New (Join-Path $work 'report.json') ([Text.UTF8Encoding]::new($false).GetBytes(($report | ConvertTo-Json -Depth 15)))
}
if ($null -ne $failure) { throw $failure }
Write-Host "CTS small CLI E2E: $($checks.Count) checks / $($calls.Count) CLI; report=$(Join-Path $work 'report.json')"
