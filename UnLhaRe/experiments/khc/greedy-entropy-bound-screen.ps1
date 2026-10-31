#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkDirectory,
    [Parameter(Mandatory)][string]$RecoveryZip,
    [Parameter(Mandatory)][string]$RecoveryManifest,
    [Parameter(Mandatory)][string]$ExpectedArchiveSha256,
    [Parameter(Mandatory)][string]$SourceRunId,
    [Parameter(Mandatory)][string]$LabExecutable
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force -ErrorAction Stop
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Assert-PlainPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $current = $full
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse point is not permitted: $current"
            }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
    return $full
}

function Get-Sha256Bytes([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToHexString($sha.ComputeHash($Bytes)).ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-ManifestFile([object]$Manifest, [string]$RelativePath) {
    $matches = @($Manifest.files | Where-Object { $_.path -ceq $RelativePath })
    if ($matches.Count -ne 1) { throw "Recovery manifest must contain exactly one $RelativePath entry." }
    return $matches[0]
}

function Read-ZipEntryBytes([IO.Compression.ZipArchive]$Zip, [string]$Name, [long]$MaximumBytes) {
    $entries = @($Zip.Entries | Where-Object { $_.FullName -ceq $Name })
    if ($entries.Count -ne 1 -or $entries[0].Length -gt $MaximumBytes) {
        throw "Recovery ZIP must contain one bounded $Name entry."
    }
    $source = $entries[0].Open()
    $destination = [IO.MemoryStream]::new([int]$entries[0].Length)
    try { $source.CopyTo($destination); return ,$destination.ToArray() }
    finally { $destination.Dispose(); $source.Dispose() }
}

function Write-NewBytes([string]$Path, [byte[]]$Bytes) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($Bytes, 0, $Bytes.Length) }
    finally { $stream.Dispose() }
}

function Write-NewText([string]$Path, [string]$Text) {
    Write-NewBytes $Path ([Text.UTF8Encoding]::new($false).GetBytes($Text))
}

$work = Assert-KhcStorageTaskWorkDirectory $WorkDirectory
Assert-KhcStorageContext -WorkDirectory $work
if (Test-Path -LiteralPath $work) { throw 'WorkDirectory must be new.' }

$archive = Assert-PlainPath $RecoveryZip
$manifestPath = Assert-PlainPath $RecoveryManifest
$lab = Assert-PlainPath $LabExecutable
if (-not (Test-Path -LiteralPath $archive -PathType Leaf) -or
    -not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $lab -PathType Leaf)) {
    throw 'Required recovery artifact, manifest, or prebuilt lab executable is missing.'
}
$archiveSha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($archiveSha256 -cne $ExpectedArchiveSha256.ToLowerInvariant()) {
    throw 'Recovery ZIP SHA-256 differs from the pre-registered value.'
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.run_id -cne $SourceRunId) { throw 'Recovery manifest run ID mismatch.' }
$groupFile = Get-ManifestFile $manifest 'all.group'
$sourceReportFile = Get-ManifestFile $manifest 'report.json'

$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    $groupBytes = Read-ZipEntryBytes $zip 'all.group' 64MB
    $sourceReportBytes = Read-ZipEntryBytes $zip 'report.json' 64KB
} finally { $zip.Dispose() }
if ($groupBytes.LongLength -ne [long]$groupFile.bytes -or
    (Get-Sha256Bytes $groupBytes) -cne $groupFile.sha256.ToLowerInvariant()) {
    throw 'all.group failed the recovery-manifest length or SHA-256 check.'
}
if ($sourceReportBytes.LongLength -ne [long]$sourceReportFile.bytes -or
    (Get-Sha256Bytes $sourceReportBytes) -cne $sourceReportFile.sha256.ToLowerInvariant()) {
    throw 'Source report failed the recovery-manifest length or SHA-256 check.'
}
$sourceReport = [Text.UTF8Encoding]::new($false, $true).GetString($sourceReportBytes) | ConvertFrom-Json
if ($sourceReport.group.sha256.ToLowerInvariant() -cne $groupFile.sha256.ToLowerInvariant() -or
    $sourceReport.group.bytes -ne [long]$groupFile.bytes -or
    $sourceReport.seven_zip.integrity_verified -ne $true -or
    $sourceReport.seven_zip.exact_names_bytes_sha256_verified -ne $true -or
    $sourceReport.khc.round_trip_all_entries_and_determinism_verified -ne $true) {
    throw 'Prior screen report does not verify this group and its complete-pair comparisons.'
}

$projectedBytes = 5L * [long]$groupFile.bytes + 2MB
$runRecord = Get-Content -LiteralPath $env:KHC_STORAGE_RUN_RECORD -Raw | ConvertFrom-Json
if ($projectedBytes -gt [long]$runRecord.max_bytes) {
    throw "Projected work bytes ($projectedBytes) exceed registered run budget ($($runRecord.max_bytes))."
}
Assert-KhcStorageContext -WorkDirectory $work
$null = [IO.Directory]::CreateDirectory($work)
$groupPath = Join-Path $work 'all.group'
Write-NewBytes $groupPath $groupBytes
$groupBytes = $null
Assert-KhcStorageContext -WorkDirectory $work

$labSha256 = (Get-FileHash -LiteralPath $lab -Algorithm SHA256).Hash.ToLowerInvariant()
$info = [Diagnostics.ProcessStartInfo]::new($lab)
$info.WorkingDirectory = $work
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$info.Environment['TEMP'] = $work
$info.Environment['TMP'] = $work
$info.Environment['TMPDIR'] = $work
foreach ($argument in @(
    'greedy-static-entropy-screen', $groupPath,
    '--dictionary-mib', '64', '--algorithm', 'beam', '--beam-width', '4',
    '--beam-block', '8192', '--beam-model', 'current', '--beam-matches', 'bt5'
)) {
    $info.ArgumentList.Add($argument)
}

$process = [Diagnostics.Process]::new()
$process.StartInfo = $info
$exitCode = -1
try {
    if (-not $process.Start()) { throw 'Could not start the prebuilt khc_lab executable.' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(600000)) {
        $process.Kill($true)
        $process.WaitForExit()
        throw 'Entropy-bound diagnostic exceeded its 600-second process limit.'
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
} finally { $process.Dispose() }
if ([Text.Encoding]::UTF8.GetByteCount($stdout) -gt 64KB -or
    [Text.Encoding]::UTF8.GetByteCount($stderr) -gt 64KB) {
    throw 'Entropy-bound diagnostic output exceeded 64 KiB.'
}
Write-NewText (Join-Path $work 'lab.stdout.txt') $stdout
Write-NewText (Join-Path $work 'lab.stderr.txt') $stderr
if ($exitCode -ne 0) { throw "khc_lab exited with code $exitCode." }

$lines = @($stdout.Trim() -split "`r?`n" | Where-Object { $_.Length -gt 0 })
if ($lines.Count -ne 1) { throw 'Expected one JSON result line from khc_lab.' }
$measurement = $lines[0] | ConvertFrom-Json
if ($measurement.screen -cne 'greedy-static-field-entropy-lower-bound' -or
    $measurement.input_bytes -ne [long]$groupFile.bytes -or
    $measurement.entropy.round_trip_verified_from_copy_distances -ne $true) {
    throw 'Entropy-bound result failed its expected mode, input-size, or reconstruction checks.'
}

$baselineSevenZipBytes = [long]$sourceReport.seven_zip.archive_bytes
$baselineKhcBytes = [long]$sourceReport.khc.frame_bytes
$minimumMarginRatio = 0.05
$requiredMaximumBoundBytes = [long][Math]::Floor($baselineSevenZipBytes * (1.0 - $minimumMarginRatio))
$idealFrameBytes = [long]$measurement.entropy.ideal_frame_bytes_with_existing_header
$report = [ordered]@{
    experiment = '7zr-pair greedy BT5 static-field entropy lower bound'
    source_run_id = $SourceRunId
    source_recovery_zip_sha256 = $archiveSha256
    source_group_sha256 = $groupFile.sha256.ToLowerInvariant()
    source_group_bytes = [long]$groupFile.bytes
    lab_executable_sha256 = $labSha256
    lab_executable_path = $lab
    script_sha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    arguments = @('greedy-static-entropy-screen', 'all.group', '--dictionary-mib', '64', '--algorithm', 'beam', '--beam-width', '4', '--beam-block', '8192', '--beam-model', 'current', '--beam-matches', 'bt5')
    prior_complete_pair = [ordered]@{
        khc_beam_frame_bytes = $baselineKhcBytes
        seven_zip_archive_bytes = $baselineSevenZipBytes
        seven_zip_version = '26.04 x64'
    }
    pre_registered_feasibility_gate = [ordered]@{
        minimum_size_margin_ratio = $minimumMarginRatio
        maximum_ideal_frame_bytes = $requiredMaximumBoundBytes
    }
    ideal_frame_bytes = $idealFrameBytes
    headroom_to_five_percent_margin_bytes = $requiredMaximumBoundBytes - $idealFrameBytes
    result = if ($idealFrameBytes -le $requiredMaximumBoundBytes) {
        'headroom-sufficient-to-justify-one-practical-encoder-probe'
    } else { 'no-go-for-current-greedy-static-field-grammar' }
    measurement = $measurement
    interpretation = 'The free-full-file-per-context frequency tables are not charged, nor are coder termination costs; this is an optimistic lower bound for one greedy BT5 parse, not an achieved frame size or performance comparison.'
}
$reportJson = $report | ConvertTo-Json -Depth 16
Write-NewText (Join-Path $work 'report.json') $reportJson
Write-Output $reportJson
