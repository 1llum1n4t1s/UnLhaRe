#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProbeExecutable,
    [Parameter(Mandatory)][string]$SourceArchive,
    [Parameter(Mandatory)][string]$WorkDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force
Assert-KhcStorageContext -WorkDirectory $WorkDirectory
$record = Get-Content -LiteralPath $env:KHC_STORAGE_RUN_RECORD -Raw | ConvertFrom-Json
if ([long]$record.max_bytes -ne 3MB -or [int]$record.max_entries -ne 64) {
    throw 'KHT1 pilot requires 3 MiB / 64 entries; registered outer runner fixes 120 seconds'
}
function Plain([string]$Path) {
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw 'Absolute path required' }
    $full = [IO.Path]::GetFullPath($Path)
    for ($current = $full; $current; $current = [IO.Path]::GetDirectoryName($current)) {
        if ((Test-Path -LiteralPath $current) -and
            ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Reparse point rejected'
        }
    }
    return $full
}
function Sha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function PositiveSize($Value, [long]$Maximum) {
    if (($Value -isnot [int] -and $Value -isnot [long]) -or $Value -le 0 -or $Value -gt $Maximum) {
        throw 'Invalid serialized byte length'
    }
}
function Digest($Value) {
    if ($Value -isnot [string] -or $Value -cnotmatch '^[0-9a-f]{64}$') { throw 'Invalid SHA-256' }
}
$paths = Get-KhcStorageTaskPaths
$work = Plain $WorkDirectory
$probe = Plain $ProbeExecutable
$sourceZip = Plain $SourceArchive
$pinnedZip = 'D:\Codex\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\0acc17d780a142dcafe88645a07205a5\recovery.zip'
$zipSha = '27030319c3938bdec7df681d8113df43318d9a01ee40eef36e43af3e6f86e898'
$inputSha = 'e0cd21cef5b6c4069461e949be100080c3ce887de6f1dd8626c480528efaaf61'
$entryName = 'pipeline-e2e/canterbury/cp.html'
if (-not $sourceZip.Equals($pinnedZip, [StringComparison]::OrdinalIgnoreCase) -or (Sha $sourceZip) -cne $zipSha) {
    throw 'Pinned source ZIP mismatch'
}
$probeRoot = [IO.Path]::GetFullPath($paths.CargoTargetRoot) + [IO.Path]::DirectorySeparatorChar
if (-not $probe.StartsWith($probeRoot, [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($probe) -cne 'khc_html_span_probe.exe' -or
    -not (Test-Path -LiteralPath $probe -PathType Leaf)) { throw 'Only the registered Cargo probe is allowed' }
if (Test-Path -LiteralPath $work) { throw 'WorkDirectory must be new' }
$sourceCode = Plain ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../examples/khc_html_span_probe.rs')))
$scriptSource = Plain $PSCommandPath
$storageRunner = Plain (Join-Path $PSScriptRoot 'run-storage-experiment.ps1')
$storageModule = Plain (Join-Path $PSScriptRoot 'storage-lifecycle.psm1')
$sourceSha = Sha $sourceCode
$scriptSha = Sha $scriptSource
$runnerSha = Sha $storageRunner
$moduleSha = Sha $storageModule
$probeSha = Sha $probe
# 固定entry以外は展開せず、workは入力とJSON二つだけに限定する。
$null = New-Item -ItemType Directory -Path $work
$inputPath = Plain (Join-Path $work 'cp.html')
$reportPath = Plain (Join-Path $work 'probe.json')
$resultPath = Plain (Join-Path $work 'result.json')
$zip = [IO.Compression.ZipFile]::OpenRead($sourceZip)
try {
    $matches = @($zip.Entries | Where-Object { $_.FullName -ceq $entryName })
    if ($matches.Count -ne 1 -or $matches[0].Length -ne 24603) { throw 'Pinned ZIP entry mismatch' }
    $source = $matches[0].Open()
    try {
        $target = [IO.File]::Open($inputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $buffer = [byte[]]::new(8192)
            $written = 0
            while (($read = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $written += $read
                if ($written -gt 24603) { throw 'ZIP entry exceeds fixed length' }
                $target.Write($buffer, 0, $read)
            }
        } finally { $target.Dispose() }
    } finally { $source.Dispose() }
} finally { $zip.Dispose() }
if ((Get-Item -LiteralPath $inputPath).Length -ne 24603 -or (Sha $inputPath) -cne $inputSha) {
    throw 'Pinned cp.html mismatch'
}
$start = [Diagnostics.ProcessStartInfo]::new($probe)
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.WorkingDirectory = $work
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
$start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
$start.Environment['TEMP'] = $work
$start.Environment['TMP'] = $work
$start.Environment['TMPDIR'] = $work
foreach ($argument in @($inputPath, $reportPath)) { $start.ArgumentList.Add($argument) }
$process = [Diagnostics.Process]::new()
$process.StartInfo = $start
try {
    if (-not $process.Start()) { throw 'Could not start KHT1 probe' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(90000)) {
        $process.Kill($true)
        if (-not $process.WaitForExit(5000)) { throw 'Probe did not stop after timeout' }
        throw 'KHT1 probe exceeded 90 seconds'
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) { throw "KHT1 probe failed (exit $($process.ExitCode)): $stderr" }
    if ($stdout.Length -ne 0 -or $stderr.Length -ne 0) { throw 'Unexpected probe console output' }
} finally { $process.Dispose() }
$reportPath = Plain $reportPath
if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf) -or
    (Get-Item -LiteralPath $reportPath).Length -gt 32768) { throw 'Missing or oversized probe JSON' }
$r = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
$fields = @('schema', 'format', 'input_bytes', 'input_sha256', 'e2e', 'roundtrip', 'deterministic',
    'recognized_tag_bytes', 'candidate_available', 'baseline_bytes', 'baseline_sha256',
    'transform_bytes', 'transform_sha256', 'candidate_bytes', 'candidate_sha256', 'size_gate', 'decision')
if (@($r.PSObject.Properties.Name).Count -ne $fields.Count -or
    @($r.PSObject.Properties.Name | Where-Object { $_ -cnotin $fields }).Count -ne 0) { throw 'Unexpected probe schema' }
if ($r.schema -cne 1 -or $r.format -cne 'KHT1' -or $r.input_bytes -cne 24603 -or
    $r.input_sha256 -cne $inputSha) { throw 'Probe input evidence mismatch' }
$cases = @('empty', 'plain-no-tag', 'simple-tag', 'quoted-angle', 'angle-in-text', 'adjacent-tags-merged',
    'less-than-inside-tag', 'unterminated-less-than', 'unmatched-quote', 'arbitrary-bytes', 'quote-only-in-tag',
    'unterminated-after-tag', 'patterned-1MiB-descriptor-cap', 'raw-over-cap', 'wrong-magic', 'unknown-version',
    'unknown-kind', 'zero-length', 'nonempty-zero-count', 'empty-nonzero-count', 'count-over-raw',
    'sum-mismatch', 'sum-overrun', 'adjacent-same-kind', 'truncated-header', 'truncated-descriptor',
    'truncated-stream', 'trailing-byte', 'empty-trailing-descriptor')
if ($r.e2e.Count -ne $cases.Count) { throw 'Unexpected E2E count' }
for ($i = 0; $i -lt $cases.Count; $i++) {
    $row = $r.e2e[$i]
    if (@($row.PSObject.Properties.Name).Count -ne 2 -or $row.case -cne $cases[$i] -or
        $row.passed -isnot [bool] -or -not $row.passed) { throw 'E2E failed or missing' }
}
if ($r.roundtrip -isnot [bool] -or -not $r.roundtrip -or $r.deterministic -isnot [bool] -or
    -not $r.deterministic -or $r.candidate_available -isnot [bool] -or $r.size_gate -isnot [bool]) {
    throw 'Invalid correctness evidence'
}
if (($r.recognized_tag_bytes -isnot [int] -and $r.recognized_tag_bytes -isnot [long]) -or
    $r.recognized_tag_bytes -lt 0 -or $r.recognized_tag_bytes -gt 24603) { throw 'Invalid tag byte count' }
PositiveSize $r.baseline_bytes 2MB
Digest $r.baseline_sha256
$gate = $false
if ($r.candidate_available) {
    PositiveSize $r.transform_bytes 1MB
    PositiveSize $r.candidate_bytes 2MB
    Digest $r.transform_sha256
    Digest $r.candidate_sha256
    $gate = $r.recognized_tag_bytes -gt 0 -and (20 * [long]$r.candidate_bytes -le 19 * [long]$r.baseline_bytes)
} elseif ($null -ne $r.transform_bytes -or $null -ne $r.transform_sha256 -or
    $null -ne $r.candidate_bytes -or $null -ne $r.candidate_sha256) { throw 'Unavailable candidate carries sizes' }
$decision = if ($gate) { 'go' } else { 'no-go' }
if ($r.size_gate -ne $gate -or $r.decision -cne $decision) { throw 'Size gate mismatch' }
if ((Sha $sourceCode) -cne $sourceSha -or (Sha $scriptSource) -cne $scriptSha -or
    (Sha $storageRunner) -cne $runnerSha -or (Sha $storageModule) -cne $moduleSha -or
    (Sha $probe) -cne $probeSha -or (Sha $sourceZip) -cne $zipSha -or
    (Sha $inputPath) -cne $inputSha -or (Get-Item -LiteralPath $inputPath).Length -ne 24603) {
    throw 'Provenance changed during execution'
}
Assert-KhcStorageContext -WorkDirectory $work
$workFiles = @(Get-ChildItem -LiteralPath $work -Force)
if ($workFiles.Count -ne 2 -or @($workFiles | Where-Object {
            $_.PSIsContainer -or $_.Name -cnotin @('cp.html', 'probe.json')
        }).Count -ne 0) { throw 'Unexpected work contents' }
$result = [ordered]@{
    schema = 1
    scope = 'Fixed cp.html development input only; not holdout; experimental KHT1 size-first pilot'
    source_archive = $sourceZip; source_archive_sha256 = $zipSha
    source_entry = $entryName; source_bytes = 24603; source_sha256 = $inputSha
    probe_source_sha256 = $sourceSha; probe_executable_sha256 = $probeSha
    runner_source_sha256 = $scriptSha; storage_runner_sha256 = $runnerSha; storage_module_sha256 = $moduleSha
    measurement = 'Complete BinaryAdaptive frames; no time, memory, 7-Zip, product, or generalization claim'
    probe = $r
}
$json = $result | ConvertTo-Json -Depth 8
$bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
if ($bytes.Length -gt 32768) { throw 'Result report exceeds 32 KiB' }
$stream = [IO.File]::Open($resultPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $stream.Write($bytes) } finally { $stream.Dispose() }
Write-Output $json
