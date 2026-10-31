#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkDirectory,
    [Parameter(Mandatory)][string]$KhcExecutable,
    [Parameter(Mandatory)][string]$KhcExecutableSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force
Assert-KhcStorageContext -WorkDirectory $WorkDirectory

$runRecordPath = [IO.Path]::GetFullPath($env:KHC_STORAGE_RUN_RECORD)
$runRecord = Get-Content -LiteralPath $runRecordPath -Raw | ConvertFrom-Json
if ([long]$runRecord.max_bytes -ne 5MB -or [int]$runRecord.max_entries -ne 64) {
    throw 'Historical archive compatibility E2E requires the fixed 5 MiB / 64-entry registration.'
}

function Get-PlainPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    for ($current = $full; $current; $current = [IO.Path]::GetDirectoryName($current)) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Reparse point in compatibility E2E path: $current"
            }
        }
    }
    return $full
}

function Get-ZipEntry([IO.Compression.ZipArchive]$Zip, [string]$Name, [long]$ExpectedBytes) {
    $matches = @($Zip.Entries | Where-Object { [string]::Equals($_.FullName, $Name, [StringComparison]::Ordinal) })
    if ($matches.Count -ne 1) {
        throw "Pinned recovery member is missing or duplicated: $Name"
    }
    if ([long]$matches[0].Length -ne $ExpectedBytes) {
        throw "Pinned recovery member is missing, duplicated, or has an unexpected size: $Name"
    }
    return $matches[0]
}

function Get-ZipEntrySha256([IO.Compression.ZipArchive]$Zip, [string]$Name, [long]$ExpectedBytes) {
    $entry = Get-ZipEntry $Zip $Name $ExpectedBytes
    $stream = $entry.Open()
    try { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() }
    finally { $stream.Dispose() }
}

function Copy-ZipEntryPinned(
    [IO.Compression.ZipArchive]$Zip,
    [string]$Name,
    [long]$ExpectedBytes,
    [string]$ExpectedSha256,
    [string]$Destination
) {
    $entry = Get-ZipEntry $Zip $Name $ExpectedBytes
    $full = Get-PlainPath $Destination
    if (Test-Path -LiteralPath $full) { throw "Compatibility E2E refuses an existing destination: $full" }
    $parent = [IO.Path]::GetDirectoryName($full)
    $null = [IO.Directory]::CreateDirectory($parent)
    $stream = $entry.Open()
    try {
        $output = [IO.FileStream]::new($full, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.CopyTo($output) }
        finally { $output.Dispose() }
    }
    finally { $stream.Dispose() }
    $item = Get-Item -LiteralPath $full -Force
    $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    if ([long]$item.Length -ne $ExpectedBytes -or $hash -cne $ExpectedSha256) {
        throw "Frozen archive member failed size or SHA-256 validation: $Name"
    }
    return $full
}

$taskPaths = Get-KhcStorageTaskPaths
$expectedCli = [IO.Path]::GetFullPath((Join-Path $taskPaths.CargoTargetRoot 'x86_64-pc-windows-msvc\release\unlhare-cli.exe'))
$cli = Get-PlainPath $KhcExecutable
if ($cli -cne $expectedCli -or $KhcExecutableSha256 -cne '3dd0e0503ed6ec11c90ad1ff9ee69b2e34c564f8710871ab182dd684f27b7b4b') {
    throw 'Current Release CLI path or SHA-256 does not match the frozen compatibility-E2E pin.'
}
if (-not (Test-Path -LiteralPath $cli -PathType Leaf)) { throw 'Pinned current Release CLI is missing.' }
if ((Get-FileHash -LiteralPath $cli -Algorithm SHA256).Hash.ToLowerInvariant() -cne $KhcExecutableSha256) {
    throw 'Current Release CLI SHA-256 mismatch.'
}

$recoveryZip = Get-PlainPath 'D:\Codex\TaskArtifacts\UnLhaRe\goal-restore-20261019\storage-lifecycle\runs\e60b9d1bbec149d68208c27485165d9b\recovery.zip'
$expectedRecoverySha256 = 'e20d93ace231af1192153a4cadc0feb43a6922687d2e32a02dcb3ac608c97f28'
if (-not (Test-Path -LiteralPath $recoveryZip -PathType Leaf) -or
    (Get-FileHash -LiteralPath $recoveryZip -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedRecoverySha256) {
    throw 'Historical revision-1-through-9 recovery ZIP is missing or changed.'
}

$work = Get-PlainPath $WorkDirectory
$archiveRoot = Join-Path $work 'archives'
$extractRoot = Join-Path $work 'extracted'
if ((Test-Path -LiteralPath $archiveRoot) -or (Test-Path -LiteralPath $extractRoot)) {
    throw 'Compatibility E2E staging directories must be absent in a fresh registered run.'
}
$null = [IO.Directory]::CreateDirectory($archiveRoot)
$null = [IO.Directory]::CreateDirectory($extractRoot)

$archivePins = @(
    [pscustomobject]@{ Revision = 1; Entry = 'api/legacy-1.khc'; Bytes = 432; Sha256 = 'e0d9968fbe92cb248d1e177ae03dd755accf58c27b1acefdf5b5ae3964d7bfc5'; Files = @('legacy.bin') },
    [pscustomobject]@{ Revision = 2; Entry = 'api/legacy-2.khc'; Bytes = 161; Sha256 = '597cb528c4df6416c4a0e047faf0c4e6d870b9e4ba1a52e7b7039b1281495b07'; Files = @('legacy.bin') },
    [pscustomobject]@{ Revision = 3; Entry = 'api/legacy-3.khc'; Bytes = 235; Sha256 = 'b596d4eb9a545503a5412f4d3c4c10da5ba1214da2a346713442fa47ba5d8000'; Files = @('legacy.bin') },
    [pscustomobject]@{ Revision = 4; Entry = 'api/legacy-4.khc'; Bytes = 235; Sha256 = '0a6cca6c7c79bdce6bf9c0ff1b8dcb3ae9c3e7f2d35d557ae720fe54ca85149c'; Files = @('legacy.bin') },
    [pscustomobject]@{ Revision = 5; Entry = 'api/legacy-5.khc'; Bytes = 248; Sha256 = '5c53fcce0a6a0f2abaf91f5e9223fef95adca9a35377d40161d1f371f691c0da'; Files = @('legacy.bin') },
    [pscustomobject]@{ Revision = 6; Entry = 'api/legacy-6.khc'; Bytes = 238; Sha256 = '98df162d59a0c713177423ba9e0d4126003e6e3950e5161934f2e0284c2a186c'; Files = @('legacy.bin') },
    [pscustomobject]@{ Revision = 7; Entry = 'api/legacy-7.khc'; Bytes = 170; Sha256 = '432fa33c7597905f374960ebf22082b9a6d41d985bd00cdb595fa00e6f43bbff'; Files = @('legacy.bin') },
    [pscustomobject]@{ Revision = 8; Entry = 'api/legacy-8.khc'; Bytes = 238; Sha256 = 'e2654a66c31b8d1379794aaea58e23bc9620ed238419244f667adc3ae1386d2a'; Files = @('legacy.bin') },
    [pscustomobject]@{ Revision = 9; Entry = 'cli-revision-9.khc'; Bytes = 40051; Sha256 = '4abe41073bd9a3098b5cde58585d4f54c434c04e1514c72d533de61972f45fe6'; Files = @('ptt5.bin', 'short.bin') }
)
$expectedFiles = @{
    'legacy.bin' = [pscustomobject]@{ Bytes = 1088; Sha256 = '3152d80f27ad1d7663f85373304e606811d3c421bbb54249b840415811621e71' }
    'ptt5.bin' = [pscustomobject]@{ Bytes = 513216; Sha256 = '0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650' }
    'short.bin' = [pscustomobject]@{ Bytes = 9; Sha256 = '073f8a6663fc49fd74e1e6dfd4d18d0bffb6e9a2af848e7adfbd4a567fbf732c' }
}

$zip = [IO.Compression.ZipFile]::OpenRead($recoveryZip)
try {
    $sourcePins = @(
        [pscustomobject]@{ Entry = 'api/legacy.bin'; Bytes = 1088; Sha256 = '3152d80f27ad1d7663f85373304e606811d3c421bbb54249b840415811621e71' },
        [pscustomobject]@{ Entry = 'cli-source/ptt5.bin'; Bytes = 513216; Sha256 = '0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650' },
        [pscustomobject]@{ Entry = 'cli-source/short.bin'; Bytes = 9; Sha256 = '073f8a6663fc49fd74e1e6dfd4d18d0bffb6e9a2af848e7adfbd4a567fbf732c' }
    )
    foreach ($source in $sourcePins) {
        $sourceHash = Get-ZipEntrySha256 $zip $source.Entry $source.Bytes
        if ($sourceHash -cne $source.Sha256) { throw "Historical reference input SHA-256 mismatch: $($source.Entry)" }
    }

    $results = [Collections.Generic.List[object]]::new()
    foreach ($case in $archivePins) {
        $archivePath = Join-Path $archiveRoot ('revision-{0}.khc' -f $case.Revision)
        $null = Copy-ZipEntryPinned $zip $case.Entry $case.Bytes $case.Sha256 $archivePath
        $header = [IO.File]::ReadAllBytes($archivePath)
        if ($header.Length -lt 9 -or [int]$header[8] -ne $case.Revision) {
            throw "Frozen archive revision byte does not match its pin: $($case.Entry)"
        }

        $testOutput = @(& $cli 'khc-test' $archivePath 2>&1)
        $testExit = $LASTEXITCODE
        if ($testExit -ne 0) { throw "Current reader rejected frozen revision $($case.Revision): $($testOutput -join ' ')" }

        $outputPath = Join-Path $extractRoot ('revision-{0}' -f $case.Revision)
        $null = [IO.Directory]::CreateDirectory($outputPath)
        $extractOutput = @(& $cli 'khc-extract' $archivePath '--output' $outputPath 2>&1)
        $extractExit = $LASTEXITCODE
        if ($extractExit -ne 0) { throw "Current extractor rejected frozen revision $($case.Revision): $($extractOutput -join ' ')" }

        $files = @(Get-ChildItem -LiteralPath $outputPath -File -Recurse -Force)
        $actualNames = [string[]]@($files | ForEach-Object { [IO.Path]::GetRelativePath($outputPath, $_.FullName).Replace('\', '/') })
        $wantedNames = [string[]]$case.Files
        [Array]::Sort($actualNames, [StringComparer]::Ordinal)
        [Array]::Sort($wantedNames, [StringComparer]::Ordinal)
        if ($files.Count -ne $case.Files.Count -or ($actualNames -join "`n") -cne ($wantedNames -join "`n")) {
            throw "Current extractor published an unexpected file set for revision $($case.Revision)."
        }

        $fileResults = [Collections.Generic.List[object]]::new()
        foreach ($file in $files) {
            $null = Get-PlainPath $file.FullName
            if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Extracted output cannot be a reparse point.' }
            $relative = [IO.Path]::GetRelativePath($outputPath, $file.FullName).Replace('\', '/')
            $expected = $expectedFiles[$relative]
            $actualHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            if ([long]$file.Length -ne [long]$expected.Bytes -or $actualHash -cne $expected.Sha256) {
                throw "Current extraction differs from the frozen reference for revision $($case.Revision): $relative"
            }
            $fileResults.Add([pscustomobject]@{ path = $relative; bytes = [long]$file.Length; sha256 = $actualHash })
        }

        $results.Add([pscustomobject]@{
            revision = $case.Revision
            archive_entry = $case.Entry
            archive_bytes = $case.Bytes
            archive_sha256 = $case.Sha256
            khc_test_exit = $testExit
            khc_extract_exit = $extractExit
            restored_files = @($fileResults.ToArray())
        })
        Write-Output ("REVISION_{0}_OK test=0 extract=0 files={1}" -f $case.Revision, $files.Count)
    }
}
finally { $zip.Dispose() }

$report = [pscustomobject]@{
    schema = 1
    kind = 'historical-khc-archive-compatibility-e2e'
    historical_run_id = 'e60b9d1bbec149d68208c27485165d9b'
    historical_archive_sha256 = $expectedRecoverySha256
    historical_writer_source_sha256 = @{
        'src/khc/mod.rs' = 'c3335017f8905364f66d797f992f10ba54a50707116cb224304acc4470ec41fa'
        'src/main.rs' = '35ee6bd7a7d222db03f92a1647155c678d752b9a69e793b4749a665fa57c72aa'
        'src/khc/block/mod.rs' = '861da675a6eee403e51a7d2130ad80414da765c72a5e37eca6966084067fd748'
    }
    current_cli_sha256 = $KhcExecutableSha256
    revisions = @($results.ToArray())
    result = 'pass'
}
$reportPath = Join-Path $work 'historical-archive-compat-e2e.json'
if (Test-Path -LiteralPath $reportPath) { throw 'Compatibility E2E report path already exists.' }
[IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
Write-Output 'HISTORICAL_ARCHIVE_COMPAT_E2E=PASS revisions=1-9 byte_exact=true'
