#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkDirectory,
    [Parameter(Mandatory)][string]$SourceDirectory,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSourceManifestSha256,
    [ValidateRange(30,900)][int]$TimeoutSeconds = 600
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force
Assert-KhcStorageContext -WorkDirectory $WorkDirectory
$runRecord = Get-Content -LiteralPath $env:KHC_STORAGE_RUN_RECORD -Raw | ConvertFrom-Json
$entryBudget = Get-KhcProductPipelineEntryBudget
if ($runRecord.max_entries -lt $entryBudget.RequiredTreeEntries -or $runRecord.max_bytes -lt 18MB) {
    throw "Canterbury product E2Eは登録時に子孫$($entryBudget.RequiredTreeEntries) entries / 18MiB以上を予約してから実行してください。"
}

function Resolve-PlainPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    for ($current = $full; $current; $current = [IO.Path]::GetDirectoryName($current)) {
        if (Test-Path -LiteralPath $current) {
            if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse point is not allowed: $current"
            }
        }
    }
    return $full
}

function Get-FileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-ProductTool([string]$File, [string[]]$Arguments, [string]$Name) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $File
    $info.WorkingDirectory = $work
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $info.Environment['TMP'] = $work
    $info.Environment['TEMP'] = $work
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $started = $false
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $started = $process.Start()
        if (-not $started) { throw "$Name could not start" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        while (-not $process.WaitForExit(100)) {
            if ($timer.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
                $process.Kill($true)
                $process.WaitForExit()
                throw "$Name timed out after $TimeoutSeconds seconds"
            }
        }
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($stdout.Length + $stderr.Length -gt 32768) { throw "$Name output exceeded 32 KiB" }
        [IO.File]::WriteAllText((Join-Path $work "$Name.stdout"), $stdout, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $work "$Name.stderr"), $stderr, [Text.UTF8Encoding]::new($false))
        if ($process.ExitCode -ne 0) { throw "$Name exited with $($process.ExitCode): $stderr" }
        return [pscustomobject]@{ exit_code = $process.ExitCode; elapsed_ms = [Math]::Round($timer.Elapsed.TotalMilliseconds, 3); stdout = $stdout; stderr = $stderr }
    }
    finally {
        if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
}

$work = Resolve-PlainPath $WorkDirectory
$source = Resolve-PlainPath $SourceDirectory
$tempRoot = Get-KhcLegacyTempRoot
$separator = [IO.Path]::DirectorySeparatorChar
$sourcePrefix = $tempRoot.TrimEnd($separator) + $separator
if (-not $source.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Canterbury source must remain under the existing Temp/Codex/UnLhaRe tree'
}
if (Test-Path -LiteralPath $work) { throw 'Registered work directory must be new' }
if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw 'Canterbury source directory is missing' }

$sourceEntries = @(Get-ChildItem -LiteralPath $source -Force)
if ($sourceEntries.Count -ne 11) { throw "Expected exactly 11 Canterbury files; found $($sourceEntries.Count)" }
foreach ($entry in $sourceEntries) {
    if ($entry -isnot [IO.FileInfo] -or (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "Canterbury source must contain only plain files: $($entry.Name)"
    }
}
$names = [string[]]@($sourceEntries | ForEach-Object { $_.Name })
[Array]::Sort($names, [StringComparer]::Ordinal)
$manifest = [Text.StringBuilder]::new()
$sourceBytes = 0L
foreach ($name in $names) {
    $path = Join-Path $source $name
    $length = (Get-Item -LiteralPath $path).Length
    $sourceBytes += $length
    $null = $manifest.Append($name).Append("`t").Append($length).Append("`t").Append((Get-FileSha256 $path)).Append("`n")
}
$actualManifestSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($manifest.ToString()))).ToLowerInvariant()
if ($sourceBytes -ne 2810784 -or $actualManifestSha256 -ine $ExpectedSourceManifestSha256) {
    throw "Canterbury source pin mismatch: bytes=$sourceBytes manifest=$actualManifestSha256"
}

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$taskPaths = Get-KhcStorageTaskPaths
$releaseRoot = Resolve-PlainPath (Join-Path $taskPaths.CargoTargetRoot 'x86_64-pc-windows-msvc/release')
$cli = Resolve-PlainPath (Join-Path $releaseRoot 'unlhare-cli.exe')
$e2e = Resolve-PlainPath (Join-Path $releaseRoot 'examples/khc_pipeline_e2e.exe')
$releasePrefix = $releaseRoot.TrimEnd($separator) + $separator
foreach ($binary in @($cli, $e2e)) {
    if (-not $binary.StartsWith($releasePrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $binary -PathType Leaf)) {
        throw "Expected release executable is missing or outside the shared Cargo target: $binary"
    }
}

$null = New-Item -ItemType Directory -Path $work
$archive = Join-Path $work 'canterbury.khc'
$e2eRoot = Join-Path $work 'pipeline-e2e'
$create = Invoke-ProductTool $cli @('khc-create', $archive, '--source', $source, '--strategy', 'binary-adaptive') 'khc-create'
if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw 'khc-create did not publish the expected archive' }
$archiveItem = Get-Item -LiteralPath $archive
if ($archiveItem.Length -le 0 -or $archiveItem.Length -gt 8MB) { throw "Unexpected Canterbury archive size: $($archiveItem.Length)" }
$archiveSha256 = Get-FileSha256 $archive
$pipeline = Invoke-ProductTool $e2e @($archive, $source, $e2eRoot) 'pipeline-e2e'
if ($pipeline.stdout -notmatch 'E2E PASS: .*exact Canterbury11, file-CRC publication, corruption precedence, cancellation, empty/directory/1MiB\+17, repeat calls') {
    throw 'Product pipeline E2E did not report its full Canterbury11 pass'
}

$report = [ordered]@{
    schema = 1
    source_directory = $source
    source_files = $sourceEntries.Count
    source_bytes = $sourceBytes
    source_manifest_sha256 = $actualManifestSha256
    cli_path = $cli
    cli_sha256 = Get-FileSha256 $cli
    e2e_path = $e2e
    e2e_sha256 = Get-FileSha256 $e2e
    archive_path = $archive
    archive_bytes = $archiveItem.Length
    archive_sha256 = $archiveSha256
    entry_budget = [ordered]@{
        required_tree_entries = $entryBudget.RequiredTreeEntries
        stable_tree_entries = $entryBudget.StableTreeEntries
        transient_staging_entries = $entryBudget.TransientStagingEntries
        required_inventory_entries = $entryBudget.RequiredInventoryEntries
        breakdown = $entryBudget.Breakdown
    }
    create = $create
    pipeline_e2e = $pipeline
    completed_utc = [DateTime]::UtcNow.ToString('o')
}
[IO.File]::WriteAllText((Join-Path $work 'report.json'), ($report | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
$observedTreeEntries = [Khc.Storage.TreeCounter]::Measure($work,[int]$runRecord.max_entries,512).Entries
if ($observedTreeEntries -ne $entryBudget.StableTreeEntries) {
    throw "Canterbury product E2Eの完了inventoryが出力計画と一致しません。expected=$($entryBudget.StableTreeEntries) descendants, actual=$observedTreeEntries"
}
$report | ConvertTo-Json -Depth 5 -Compress
