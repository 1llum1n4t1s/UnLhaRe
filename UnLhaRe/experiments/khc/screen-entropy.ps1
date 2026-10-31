param(
    [Parameter(Mandatory)][string]$LabPath,
    [Parameter(Mandatory)][string]$GroupPath,
    [Parameter(Mandatory)][string]$WorkDirectory,
    [ValidateRange(1, 31)][int]$PairsPerOrder = 7,
    [ValidateRange(1, 31)][int]$MemoryRepeats = 5
)

# 固定groupのE2Eを通してentropy backendだけを交互比較する。製品・holdoutの合格判定ではない。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$sourceRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$buildRoot = [IO.Path]::GetFullPath((Join-Path $sourceRoot 'build')) + [IO.Path]::DirectorySeparatorChar
$work = [IO.Path]::GetFullPath($WorkDirectory)
if (-not $work.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'WorkDirectory must be below build.'
}
if (Test-Path -LiteralPath $work) { throw 'WorkDirectory must be new.' }
function Assert-NoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse point is not allowed: $current"
            }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}
Assert-NoReparse $work
$lab = (Resolve-Path -LiteralPath $LabPath).Path
$group = (Resolve-Path -LiteralPath $GroupPath).Path
Assert-NoReparse $lab
Assert-NoReparse $group
$labHash = (Get-FileHash -LiteralPath $lab -Algorithm SHA256).Hash
$groupHash = (Get-FileHash -LiteralPath $group -Algorithm SHA256).Hash
if ($groupHash -cne '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76') {
    throw 'This screen is registered only for the fixed Canterbury development group.'
}
$sourceHashes = @(@((Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.rs' -File).FullName) +
    @((Join-Path $sourceRoot 'examples/khc_lab.rs'), $PSCommandPath) | ForEach-Object {
        [pscustomobject]@{ path = $_; sha256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }
    })
$null = New-Item -ItemType Directory -Path $work

function Invoke-Case([string]$Backend, [string]$Name, [bool]$SampleMemory = $false) {
    $info = [Diagnostics.ProcessStartInfo]::new($lab)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in @('group-bench', $group, '--algorithm', 'beam', '--beam-width', '2',
        '--beam-block', '8192', '--beam-model', 'blended', '--beam-matches', 'bt5',
        '--dictionary-mib', '64', '--entropy-backend', $Backend, '--repeats', '1')) {
        $info.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $started = $false
    $stdoutTask = $null
    $stderrTask = $null
    $peakWorking = 0L
    $peakPrivate = 0L
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $started = $process.Start()
        if (-not $started) { throw 'Failed to start lab.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        while (-not $process.WaitForExit(5)) {
            if ($watch.Elapsed.TotalSeconds -gt 120) { throw '120 second deadline exceeded.' }
            if ($SampleMemory) {
                $process.Refresh()
                $peakWorking = [Math]::Max($peakWorking, $process.PeakWorkingSet64)
                $peakPrivate = [Math]::Max($peakPrivate, $process.PrivateMemorySize64)
            }
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Lab exit $($process.ExitCode): $stderr" }
        $result = $stdout | ConvertFrom-Json
        if ($result.input_bytes -ne 2811006 -or $result.solid_group.Count -ne 11 -or $result.samples.Count -ne 1) {
            throw 'Unexpected group or sample count.'
        }
        if ($result.entropy_backend -ine $Backend) { throw 'Wrong entropy backend.' }
        if (($Backend -eq 'range' -and $result.frame_bytes -ne 483130) -or
            ($Backend -eq 'rans' -and $result.frame_bytes -gt 483599)) {
            throw 'Registered frame size gate failed.'
        }
        $row = [pscustomobject]@{
            backend = $Backend
            frame_bytes = $result.frame_bytes
            encode_ms = $result.samples[0].encode_ms
            decode_ms = $result.samples[0].decode_ms
            peak_working_sampled = $(if ($SampleMemory) { $peakWorking } else { $null })
            peak_private_sampled = $(if ($SampleMemory) { $peakPrivate } else { $null })
            e2e = $result
        }
        $row | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $work "$Name.json") -Encoding utf8
        return $row
    }
    finally {
        if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        if ($null -ne $stdoutTask) { try { $null = $stdoutTask.GetAwaiter().GetResult() } catch { } }
        if ($null -ne $stderrTask) { try { $null = $stderrTask.GetAwaiter().GetResult() } catch { } }
        $process.Dispose()
    }
}

function Get-Median([double[]]$Values) {
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { throw 'No samples.' }
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 0) { return ($sorted[$middle - 1] + $sorted[$middle]) / 2 }
    return $sorted[$middle]
}
$pairs = [Collections.Generic.List[object]]::new()
foreach ($order in @('range-first', 'rans-first')) {
    for ($pair = 1; $pair -le $PairsPerOrder; $pair++) {
        $cases = @{}
        $backends = if ($order -eq 'range-first') { @('range', 'rans') } else { @('rans', 'range') }
        foreach ($backend in $backends) { $cases[$backend] = Invoke-Case $backend "$order-$pair-$backend" }
        $pairs.Add([pscustomobject]@{
            order = $order
            pair = $pair
            range_encode_ms = $cases.range.encode_ms
            rans_encode_ms = $cases.rans.encode_ms
            range_decode_ms = $cases.range.decode_ms
            rans_decode_ms = $cases.rans.decode_ms
            encode_reduction_pct = 100.0 * ($cases.range.encode_ms - $cases.rans.encode_ms) / $cases.range.encode_ms
            decode_reduction_pct = 100.0 * ($cases.range.decode_ms - $cases.rans.decode_ms) / $cases.range.decode_ms
        })
        Write-Host "$order $pair/$PairsPerOrder complete"
    }
}
$memory = [Collections.Generic.List[object]]::new()
for ($repeat = 1; $repeat -le $MemoryRepeats; $repeat++) {
    $order = if ($repeat % 2 -eq 1) { @('range', 'rans') } else { @('rans', 'range') }
    foreach ($backend in $order) { $memory.Add((Invoke-Case $backend "memory-$repeat-$backend" $true)) }
}
if ((Get-FileHash -LiteralPath $lab -Algorithm SHA256).Hash -cne $labHash -or
    (Get-FileHash -LiteralPath $group -Algorithm SHA256).Hash -cne $groupHash) { throw 'Input or lab changed.' }
foreach ($source in $sourceHashes) {
    if ((Get-FileHash -LiteralPath $source.path -Algorithm SHA256).Hash -cne $source.sha256) { throw 'Source changed.' }
}
$summaries = @(foreach ($order in @('range-first', 'rans-first')) {
    $rows = @($pairs | Where-Object order -EQ $order)
    [pscustomobject]@{
        order = $order
        pairs = $rows.Count
        range_encode_ms = Get-Median $rows.range_encode_ms
        rans_encode_ms = Get-Median $rows.rans_encode_ms
        range_decode_ms = Get-Median $rows.range_decode_ms
        rans_decode_ms = Get-Median $rows.rans_decode_ms
        encode_reduction_pct = Get-Median $rows.encode_reduction_pct
        decode_reduction_pct = Get-Median $rows.decode_reduction_pct
    }
})
$memorySummary = @(foreach ($backend in @('range', 'rans')) {
    $rows = @($memory | Where-Object backend -EQ $backend)
    [pscustomobject]@{
        backend = $backend
        frame_bytes = @($rows.frame_bytes | Sort-Object -Unique)
        peak_working_sampled = Get-Median $rows.peak_working_sampled
        peak_private_sampled = Get-Median $rows.peak_private_sampled
    }
})
$report = [pscustomobject]@{
    status = 'Fixed development group entropy screen; not a holdout or overall 7-Zip claim'
    measured_utc = [DateTime]::UtcNow.ToString('o')
    lab_sha256 = $labHash
    group_sha256 = $groupHash
    source_sha256 = $sourceHashes
    os = [Environment]::OSVersion.VersionString
    architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    timings = 'group-bench internal codec wall time; one warmup per process; memory samples are separate runs'
    memory_note = '5ms sampled process memory during group-bench; no hard memory ceiling enforced'
    summary = $summaries
    memory_summary = $memorySummary
    pairs = $pairs.ToArray()
}
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $work 'report.json') -Encoding utf8
$report | Select-Object summary, memory_summary | ConvertTo-Json -Depth 6
