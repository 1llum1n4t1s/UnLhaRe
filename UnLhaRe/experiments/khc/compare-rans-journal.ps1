param(
    [Parameter(Mandatory)][string]$ReferenceLabPath,
    [Parameter(Mandatory)][string]$LabPath,
    [Parameter(Mandatory)][string]$GroupPath,
    [Parameter(Mandatory)][string]$WorkDirectory,
    [ValidateRange(1, 31)][int]$PairsPerOrder = 7,
    [ValidateRange(1, 31)][int]$MemoryRepeats = 5
)

# 同じrANS出力を作る二つのRelease実体を比較する。時間とmemoryは別processで採取する。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$sourceRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$buildRoot = [IO.Path]::GetFullPath((Join-Path $sourceRoot 'build')) + [IO.Path]::DirectorySeparatorChar
$work = [IO.Path]::GetFullPath($WorkDirectory)
if (-not $work.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'WorkDirectory must be below build.' }
if (Test-Path -LiteralPath $work) { throw 'WorkDirectory must be new.' }
function Assert-NoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if ((Test-Path -LiteralPath $current) -and
            (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Reparse point is not allowed: $current"
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}
Assert-NoReparse $work
$labs = @{
    reference = (Resolve-Path -LiteralPath $ReferenceLabPath).Path
    candidate = (Resolve-Path -LiteralPath $LabPath).Path
}
$group = (Resolve-Path -LiteralPath $GroupPath).Path
foreach ($path in @($labs.reference, $labs.candidate, $group)) { Assert-NoReparse $path }
$identities = @(foreach ($side in @('reference', 'candidate')) {
    [pscustomobject]@{ side = $side; path = $labs[$side]; sha256 = (Get-FileHash -LiteralPath $labs[$side]).Hash }
})
$groupHash = (Get-FileHash -LiteralPath $group).Hash
if ($groupHash -cne '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76') { throw 'Unexpected fixed group.' }
$sourceHashes = @(@((Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter '*.rs').FullName) +
    @((Join-Path $sourceRoot 'examples/khc_lab.rs'), (Join-Path $sourceRoot 'Cargo.toml'),
      (Join-Path $sourceRoot 'Cargo.lock'), $PSCommandPath) | ForEach-Object {
        [pscustomobject]@{ path = $_; sha256 = (Get-FileHash -LiteralPath $_).Hash }
    })
$cpu = @(Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors)
$null = New-Item -ItemType Directory -Path $work
Write-Host "Fixed Canterbury rANS journal comparison: $($cpu[0].Name); pairs/order=$PairsPerOrder; memory repeats=$MemoryRepeats"
$identities | Format-Table side, sha256 | Out-Host

function Invoke-Lab([string]$Side, [string]$Mode, [string]$Backend, [bool]$SampleMemory = $false) {
    $info = [Diagnostics.ProcessStartInfo]::new($labs[$Side])
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in @($Mode, $group, '--algorithm', 'beam', '--beam-width', '2',
        '--beam-block', '8192', '--beam-model', 'blended', '--beam-matches', 'bt5',
        '--dictionary-mib', '64', '--entropy-backend', $Backend, '--repeats', '1')) {
        $info.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $sink = [IO.MemoryStream]::new()
    $started = $false
    $copy = $null
    $errorTask = $null
    $peakWorking = 0L
    $peakPrivate = 0L
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $started = $process.Start()
        if (-not $started) { throw 'Cannot start lab.' }
        $copy = $process.StandardOutput.BaseStream.CopyToAsync($sink)
        $errorTask = $process.StandardError.ReadToEndAsync()
        while (-not $process.WaitForExit(5)) {
            if ($watch.Elapsed.TotalSeconds -gt 120) { throw '120 second deadline exceeded.' }
            if ($SampleMemory) {
                $process.Refresh()
                $peakWorking = [Math]::Max($peakWorking, $process.PeakWorkingSet64)
                $peakPrivate = [Math]::Max($peakPrivate, $process.PrivateMemorySize64)
            }
        }
        $null = $copy.GetAwaiter().GetResult()
        $stderr = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "$Side $Mode exit $($process.ExitCode): $stderr" }
        if ($Mode -eq 'group-encode') {
            return [pscustomobject]@{
                side = $Side; backend = $Backend; frame_bytes = $sink.Length
                frame_sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($sink.ToArray()))
            }
        }
        $result = [Text.Encoding]::UTF8.GetString($sink.ToArray()) | ConvertFrom-Json
        foreach ($entry in @{
            algorithm = 'Beam'; beam_width = 2; beam_block = 8192; beam_model = 'Blended'
            beam_matches = 'Bt5'; dictionary = 67108864; input_bytes = 2811006
            frame_bytes = 483197; entropy_backend = 'Rans'
        }.GetEnumerator()) {
            if ($result.($entry.Key) -ne $entry.Value) { throw "Unexpected $($entry.Key)." }
        }
        if ($result.samples.Count -ne 1 -or $result.solid_group.Count -ne 11) { throw 'Incomplete E2E sample.' }
        return [pscustomobject]@{
            side = $Side; encode_ms = $result.samples[0].encode_ms; decode_ms = $result.samples[0].decode_ms
            peak_working_sampled = $(if ($SampleMemory) { $peakWorking } else { $null })
            peak_private_sampled = $(if ($SampleMemory) { $peakPrivate } else { $null })
            e2e = $result
        }
    }
    finally {
        if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        if ($null -ne $copy) { try { $null = $copy.GetAwaiter().GetResult() } catch { } }
        if ($null -ne $errorTask) { try { $null = $errorTask.GetAwaiter().GetResult() } catch { } }
        $sink.Dispose()
        $process.Dispose()
    }
}

function Get-Median([double[]]$Values) {
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { throw 'Missing samples.' }
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 0) { return ($sorted[$middle - 1] + $sorted[$middle]) / 2 }
    return $sorted[$middle]
}

$hashes = @(foreach ($side in @('reference', 'candidate')) {
    foreach ($backend in @('range', 'rans')) {
        $row = Invoke-Lab $side 'group-encode' $backend
        $expected = if ($backend -eq 'range') { 'CF4F107BE32E35B603FCA9CE05AC8A5C5C3F4211A4BC0B68236A383F8029447D' }
                    else { 'CF0EDE563B015BD8B2DD08F048BD79FCC4A90FB6B3EA4FF24FED0C757ECAD5F8' }
        if ($row.frame_sha256 -cne $expected) { throw 'Frame differs from registered baseline.' }
        $row
    }
})
$hashes | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $work 'frame-hashes.json') -Encoding utf8
$pairs = [Collections.Generic.List[object]]::new()
foreach ($first in @('reference', 'candidate')) {
    $order = if ($first -eq 'reference') { @('reference', 'candidate') } else { @('candidate', 'reference') }
    for ($pair = 1; $pair -le $PairsPerOrder; $pair++) {
        $cases = @{}
        foreach ($side in $order) {
            $cases[$side] = Invoke-Lab $side 'group-bench' 'rans'
            $cases[$side] | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $work "$first-first-$pair-$side.json") -Encoding utf8
        }
        $pairs.Add([pscustomobject]@{
            first = $first; pair = $pair
            reference_encode_ms = $cases.reference.encode_ms; candidate_encode_ms = $cases.candidate.encode_ms
            reference_decode_ms = $cases.reference.decode_ms; candidate_decode_ms = $cases.candidate.decode_ms
            encode_reduction_pct = 100.0 * ($cases.reference.encode_ms - $cases.candidate.encode_ms) / $cases.reference.encode_ms
            decode_reduction_pct = 100.0 * ($cases.reference.decode_ms - $cases.candidate.decode_ms) / $cases.reference.decode_ms
        })
        Write-Host "$first-first $pair/$PairsPerOrder complete"
    }
}
$memory = [Collections.Generic.List[object]]::new()
for ($repeat = 1; $repeat -le $MemoryRepeats; $repeat++) {
    $order = if ($repeat % 2 -eq 1) { @('reference', 'candidate') } else { @('candidate', 'reference') }
    foreach ($side in $order) {
        $row = Invoke-Lab $side 'group-bench' 'rans' $true
        $memory.Add($row)
        $row | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $work "memory-$repeat-$side.json") -Encoding utf8
    }
}
foreach ($identity in @($identities) + @($sourceHashes)) {
    if ((Get-FileHash -LiteralPath $identity.path).Hash -cne $identity.sha256) { throw 'Source or binary changed.' }
}
if ((Get-FileHash -LiteralPath $group).Hash -cne $groupHash) { throw 'Group changed.' }
$summary = @(foreach ($first in @('reference', 'candidate')) {
    $rows = @($pairs | Where-Object first -EQ $first)
    [pscustomobject]@{
        first = $first; pairs = $rows.Count
        reference_encode_ms = Get-Median $rows.reference_encode_ms; candidate_encode_ms = Get-Median $rows.candidate_encode_ms
        reference_decode_ms = Get-Median $rows.reference_decode_ms; candidate_decode_ms = Get-Median $rows.candidate_decode_ms
        encode_reduction_pct = Get-Median $rows.encode_reduction_pct; decode_reduction_pct = Get-Median $rows.decode_reduction_pct
    }
})
$memorySummary = @(foreach ($side in @('reference', 'candidate')) {
    $rows = @($memory | Where-Object side -EQ $side)
    [pscustomobject]@{
        side = $side; peak_working_sampled = Get-Median $rows.peak_working_sampled
        peak_private_sampled = Get-Median $rows.peak_private_sampled
    }
})
$report = [pscustomobject]@{
    status = 'Fixed development group journal comparison, not a holdout or overall 7-Zip claim'
    measured_utc = [DateTime]::UtcNow.ToString('o'); binaries = $identities
    group_sha256 = $groupHash; candidate_source_sha256 = $sourceHashes; cpu = $cpu
    os = [Environment]::OSVersion.VersionString; architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    memory_note = '5ms sampled process peaks during separate group-bench runs; no hard cap enforced'
    timing_note = 'Internal codec wall time; one warmup per process; pair-relative difference medians'
    frame_hashes = $hashes; summary = $summary; memory_summary = $memorySummary; pairs = $pairs.ToArray()
}
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $work 'report.json') -Encoding utf8
$report | Select-Object summary, memory_summary | ConvertTo-Json -Depth 6
