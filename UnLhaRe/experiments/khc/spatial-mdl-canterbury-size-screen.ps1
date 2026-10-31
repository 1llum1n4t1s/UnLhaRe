#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkDirectory,
    [Parameter(Mandatory)][string]$InputRecoveryZip,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$InputRecoveryZipSha256,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedSourceManifestSha256,
    [Parameter(Mandatory)][string]$KhcExecutable,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$KhcExecutableSha256,
    [Parameter(Mandatory)][string]$SevenZipPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$SevenZipSha256
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force
Assert-KhcStorageContext -WorkDirectory $WorkDirectory
$record = Get-Content -LiteralPath $env:KHC_STORAGE_RUN_RECORD -Raw | ConvertFrom-Json
if ([long]$record.max_bytes -ne 32MB -or [int]$record.max_entries -ne 96) {
    throw 'This Canterbury11 size screen requires exactly 32 MiB / 96 entries.'
}

function Get-PlainPath([string]$Path) {
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw "Absolute path required: $Path" }
    $full = [IO.Path]::GetFullPath($Path)
    for ($part = $full; $part; $part = [IO.Path]::GetDirectoryName($part)) {
        if ((Test-Path -LiteralPath $part) -and
            ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Reparse point: $part"
        }
    }
    return $full
}
function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath (Get-PlainPath $Path) -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Assert-WorkChild([string]$Path) {
    $full = Get-PlainPath $Path
    $prefix = $work.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Output escaped registered work directory: $full"
    }
    return $full
}
function New-WorkDirectory([string]$Path) {
    $full = Assert-WorkChild $Path
    if (Test-Path -LiteralPath $full) { throw "Output already exists: $full" }
    $null = [IO.Directory]::CreateDirectory($full)
    return $full
}
function Assert-WorkBudget {
    $items = @(Get-ChildItem -LiteralPath $work -Recurse -Force -ErrorAction Stop)
    $files = @($items | Where-Object { -not $_.PSIsContainer })
    $bytes = [long](($files | Measure-Object -Property Length -Sum).Sum)
    if ($null -eq $bytes) { $bytes = 0L }
    if ($bytes -gt [long]$record.max_bytes) { throw "Run bytes exceeded: $bytes > $($record.max_bytes)" }
    if ($items.Count -gt [int]$record.max_entries) { throw "Run entries exceeded: $($items.Count) > $($record.max_entries)" }
    return [pscustomobject]@{ bytes = $bytes; entries = $items.Count }
}
function Save-Report {
    $report.commands = $commands.ToArray()
    $report.archives = $archivesReport.ToArray()
    $report.restores = $restoresReport.ToArray()
    $json = ConvertTo-Json -InputObject $report -Depth 16
    $encoded = [Text.UTF8Encoding]::new($false).GetBytes($json)
    if ($encoded.Length -gt 512KB) { throw 'Report exceeded the fixed 512 KiB limit.' }
    [IO.File]::WriteAllBytes($reportPath, $encoded)
    $null = Assert-WorkBudget
}
function Invoke-Tool(
    [string]$Executable,
    [string[]]$Arguments,
    [string]$Label,
    [string]$WorkingDirectory
) {
    $exe = Get-PlainPath $Executable
    $cwd = Get-PlainPath $WorkingDirectory
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Tool not found: $exe" }
    if (-not (Test-Path -LiteralPath $cwd -PathType Container)) { throw "Working directory not found: $cwd" }
    $safeLabel = $Label -replace '[^A-Za-z0-9._-]', '_'
    $logPath = Assert-WorkChild (Join-Path $logs "$safeLabel.log")
    if (Test-Path -LiteralPath $logPath) { throw "Log already exists: $logPath" }

    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $exe
    $info.WorkingDirectory = $cwd
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in $Arguments) { $info.ArgumentList.Add([string]$argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $stdout = ''
    $stderr = ''
    $exitCode = -1
    $timedOut = $false
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) { throw "Could not start: $Label" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            $timedOut = $true
            try { $process.Kill($true) } catch { }
            if (-not $process.WaitForExit(5000)) { throw "Process failed to stop after timeout: $Label" }
        }
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
        if ($timedOut) { throw "60-second child timeout: $Label" }
    } finally {
        if ($started -and -not $process.HasExited) {
            try { $process.Kill($true) } catch { }
            if (-not $process.WaitForExit(5000)) { throw "Process remains after cleanup: $Label" }
        }
        $process.Dispose()
    }

    $logText = "--- stdout ---`n$stdout`n--- stderr ---`n$stderr"
    $logBytes = [Text.UTF8Encoding]::new($false).GetBytes($logText)
    if ($logBytes.Length -gt 64KB) { throw "Tool log exceeded 64 KiB: $Label" }
    [IO.File]::WriteAllBytes($logPath, $logBytes)
    $entry = [pscustomobject]@{
        label = $Label
        executable = $exe
        executable_sha256 = Get-Sha256 $exe
        argv = @($Arguments)
        working_directory = [IO.Path]::GetRelativePath($work, $cwd)
        exit_code = $exitCode
        log_path = [IO.Path]::GetRelativePath($work, $logPath)
        log_bytes = $logBytes.Length
    }
    $commands.Add($entry)
    Save-Report
    if ($exitCode -ne 0) { throw "Command failed ($exitCode): $Label" }
    return [pscustomobject]@{ stdout = $stdout; stderr = $stderr; exit_code = $exitCode }
}
function Get-Manifest([string]$Directory) {
    $dir = Get-PlainPath $Directory
    $entries = @(Get-ChildItem -LiteralPath $dir -File -Recurse -Force -ErrorAction Stop)
    $directories = @(Get-ChildItem -LiteralPath $dir -Directory -Recurse -Force -ErrorAction Stop)
    if ($directories.Count -ne 0) { throw "Unexpected subdirectory in extracted tree: $dir" }
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($entry in $entries) {
        $relative = [IO.Path]::GetRelativePath($dir, $entry.FullName).Replace('\', '/')
        $rows.Add([pscustomobject]@{
            name = $relative
            bytes = [long]$entry.Length
            sha256 = Get-Sha256 $entry.FullName
        })
    }
    $names = [string[]]@($rows | ForEach-Object { [string]$_.name })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $byName = @{}
    foreach ($row in $rows) { $byName[[string]$row.name] = $row }
    $builder = [Text.StringBuilder]::new()
    foreach ($name in $names) {
        $row = $byName[$name]
        $null = $builder.Append($name).Append([char]9).Append($row.bytes).Append([char]9).Append($row.sha256).Append([char]10)
    }
    $manifestSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.UTF8Encoding]::new($false).GetBytes($builder.ToString()))).ToLowerInvariant()
    return [pscustomobject]@{ files = $names.Length; bytes = [long](($rows | Measure-Object -Property bytes -Sum).Sum); manifest_sha256 = $manifestSha; entries = $rows.ToArray() }
}
function Assert-MatchingManifest([string]$Directory, [string]$Label) {
    $actual = Get-Manifest $Directory
    if ($actual.files -ne $expectedFiles.Count -or $actual.bytes -ne $inputBytes -or
        $actual.manifest_sha256 -cne $ExpectedSourceManifestSha256) {
        throw "$Label restore manifest mismatch: files=$($actual.files) bytes=$($actual.bytes) sha=$($actual.manifest_sha256)"
    }
    $actualNames = [string[]]@($actual.entries | ForEach-Object { [string]$_.name })
    [Array]::Sort($actualNames, [StringComparer]::Ordinal)
    for ($index = 0; $index -lt $expectedFiles.Count; $index++) {
        $expected = $expectedFiles[$index]
        if ($actualNames[$index] -cne $expected.Name) { throw "$Label filename mismatch at $index." }
        $row = @($actual.entries | Where-Object name -CEQ $expected.Name)[0]
        if ([long]$row.bytes -ne [long]$expected.Bytes -or [string]$row.sha256 -cne $expected.Sha256) {
            throw "$Label file mismatch: $($expected.Name)"
        }
    }
    return $actual
}
function Assert-ArchiveLimit([string]$Path, [string]$Label) {
    $full = Get-PlainPath $Path
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "$Label archive was not created." }
    $item = Get-Item -LiteralPath $full
    if ($item.Length -le 0 -or $item.Length -gt ($inputBytes + 65536)) {
        throw "$Label archive outside the fixed size ceiling: $($item.Length)"
    }
    return [pscustomobject]@{ path = [IO.Path]::GetRelativePath($work, $full); bytes = [long]$item.Length; sha256 = Get-Sha256 $full }
}

$work = Get-PlainPath $WorkDirectory
$expectedRecoveryPath = 'D:\Codex\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\5e93ed1e99ca4f5ab29d490db421e50b\recovery.zip'
$expectedFiles = @(
    [pscustomobject]@{ Name = 'alice29.txt'; Bytes = 152089L; Sha256 = '7467306ee0feed4971260f3c87421154a05be571d944e9cb021a5713700c38f0' },
    [pscustomobject]@{ Name = 'asyoulik.txt'; Bytes = 125179L; Sha256 = 'eaa3526fe53859f34ecdf255712f9ecf0b2c903451d4755b2edaa2e2599cb0fc' },
    [pscustomobject]@{ Name = 'cp.html'; Bytes = 24603L; Sha256 = 'e0cd21cef5b6c4069461e949be100080c3ce887de6f1dd8626c480528efaaf61' },
    [pscustomobject]@{ Name = 'fields.c'; Bytes = 11150L; Sha256 = '85d73e354cc50cec76cb5a50537cf8dc035f8cbb8480f9e1cbe2f7d6c23393c7' },
    [pscustomobject]@{ Name = 'grammar.lsp'; Bytes = 3721L; Sha256 = '1b0805dfc0ae706b35aac2bb4e15f02485efd24dda5dbd29de7b2f84d1a88c15' },
    [pscustomobject]@{ Name = 'kennedy.xls'; Bytes = 1029744L; Sha256 = '9af47239ca29dfe20e633f80bbbb9a4cc9783d0803d7b2b5626f42e4c3790420' },
    [pscustomobject]@{ Name = 'lcet10.txt'; Bytes = 426754L; Sha256 = '5314ba1dbb03f471df88bec6cd120a938ef60d0fd3511c5c1dce61bf7463245f' },
    [pscustomobject]@{ Name = 'plrabn12.txt'; Bytes = 481861L; Sha256 = '07e2e0b461af78c7c647cb53dab39de560198e16f799b4516eccf0fbd69f764c' },
    [pscustomobject]@{ Name = 'ptt5'; Bytes = 513216L; Sha256 = '0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650' },
    [pscustomobject]@{ Name = 'sum'; Bytes = 38240L; Sha256 = 'ee5733cd76ecc2f9d8ff156adc3c02a7a851051dcf43a2d56ff4ee4ff606bdb3' },
    [pscustomobject]@{ Name = 'xargs.1'; Bytes = 4227L; Sha256 = 'c58aeb5d2d1e12751d47e7412b45784405fc30a5671b03d480fa05776e183619' }
)
$inputBytes = 2810784L
$expectedInputManifest = 'bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438'
$expectedInputZipSha = 'b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb'
$expectedKhcSha = '50952a6e7781800b946f85a7493bea7ca0923b5a974f34db1ba2baf32d1de6e3'
$expectedSevenZipSha = '95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53'
$commands = [Collections.Generic.List[object]]::new()
$archivesReport = [Collections.Generic.List[object]]::new()
$restoresReport = [Collections.Generic.List[object]]::new()
$reportPath = Join-Path $work 'spatial-mdl-canterbury-size-screen.json'
$source = Join-Path $work 'source'
$archiveDirectory = Join-Path $work 'archives'
$logs = Join-Path $work 'logs'
$report = [ordered]@{
    schema = 1
    status = 'running'
    scope = 'Canterbury11 development-corpus size/determinism/roundtrip screen only; no timing, CPU, memory, heldout, or general superiority claim.'
    run_id = [IO.Path]::GetFileName($work) -replace '^run-', ''
    input = [ordered]@{ archive = $null; files = 0; bytes = 0; manifest_sha256 = $null; entries = @() }
    tools = [ordered]@{}
    settings = [ordered]@{
        candidate = 'SpatialMdlTrial'; archive_revision = 9
        candidate_command = 'khc-create --strategy spatial-mdl-trial'
        seven_zip_format = '7z'; seven_zip_method = 'LZMA2'; level = 9; requested_dictionary_bytes = 67108864L; threads = 1
        solid = $true; sort_by_type = $false; modification_time = $false; creation_time = $false; access_time = $false
        rounds = 2; operation_order = @('round1:KHC,7-Zip', 'round2:7-Zip,KHC')
        time_measurements_collected = $false; memory_measurements_collected = $false; cpu_gate_used = $false
        child_timeout_seconds = 60; outer_timeout_seconds = 300; max_run_bytes = 32MB; max_entries = 96
        archive_limit_bytes = $inputBytes + 65536L; report_limit_bytes = 512KB; log_limit_bytes = 64KB
    }
    commands = @()
    archives = @()
    restores = @()
    determinism_verified = $false
    restore_verified = $false
    candidate_comparison = $null
    candidate_screen_passed = $null
    candidate_decision = $null
    error = $null
}

if ([IO.Path]::GetFullPath($InputRecoveryZip) -cne $expectedRecoveryPath -or
    $InputRecoveryZipSha256 -cne $expectedInputZipSha -or
    $ExpectedSourceManifestSha256 -cne $expectedInputManifest -or
    $KhcExecutableSha256 -cne $expectedKhcSha -or
    $SevenZipSha256 -cne $expectedSevenZipSha) {
    throw 'The fixed Canterbury11 screen requires the exact preregistered input and tool pins.'
}
$pins = @(
    [pscustomobject]@{ path = $InputRecoveryZip; sha = $expectedInputZipSha },
    [pscustomobject]@{ path = $KhcExecutable; sha = $expectedKhcSha },
    [pscustomobject]@{ path = $SevenZipPath; sha = $expectedSevenZipSha },
    [pscustomobject]@{ path = (Join-Path $PSScriptRoot '..\..\src\khc\mod.rs'); sha = 'c3335017f8905364f66d797f992f10ba54a50707116cb224304acc4470ec41fa' },
    [pscustomobject]@{ path = (Join-Path $PSScriptRoot '..\..\src\main.rs'); sha = '35ee6bd7a7d222db03f92a1647155c678d752b9a69e793b4749a665fa57c72aa' },
    [pscustomobject]@{ path = (Join-Path $PSScriptRoot '..\..\src\khc\block\mod.rs'); sha = '861da675a6eee403e51a7d2130ad80414da765c72a5e37eca6966084067fd748' },
    [pscustomobject]@{ path = (Join-Path $PSScriptRoot '..\..\src\khc\spatial.rs'); sha = '8b508ee1c876c0b581af1bba66cecb0e1b183db3eae31349033fa8a0ec374982' },
    [pscustomobject]@{ path = (Join-Path $PSScriptRoot '..\..\Cargo.toml'); sha = '3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac' },
    [pscustomobject]@{ path = (Join-Path $PSScriptRoot '..\..\Cargo.lock'); sha = 'd8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554' },
    [pscustomobject]@{ path = (Join-Path $PSScriptRoot 'storage-lifecycle.psm1'); sha = '511ac35885416d0ee7deb6367f2f210d6bda3e71ced3001a590dd90426962ac3' },
    [pscustomobject]@{ path = (Join-Path $PSScriptRoot 'disk-budget.ps1'); sha = '506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd' }
)
foreach ($pin in $pins) {
    $path = Get-PlainPath $pin.path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Sha256 $path) -cne $pin.sha) {
        throw "Preregistered source/tool hash mismatch: $path"
    }
}
$khc = Get-PlainPath $KhcExecutable
$seven = Get-PlainPath $SevenZipPath
$recovery = Get-PlainPath $InputRecoveryZip
foreach ($path in @($source, $archiveDirectory, $logs, $reportPath)) {
    if (Test-Path -LiteralPath $path) { throw "Registered output path already exists: $path" }
}
$null = New-WorkDirectory $source
$null = New-WorkDirectory $archiveDirectory
$null = New-WorkDirectory $logs
Save-Report

try {
    if ((Get-Sha256 $recovery) -cne $expectedInputZipSha) { throw 'Canterbury recovery ZIP hash mismatch.' }
    $zip = [IO.Compression.ZipFile]::OpenRead($recovery)
    try {
        $prefix = 'pipeline-e2e/canterbury/'
        $actualMembers = @($zip.Entries | Where-Object {
            $_.FullName.StartsWith($prefix, [StringComparison]::Ordinal) -and
            $_.FullName.Length -gt $prefix.Length -and -not $_.FullName.EndsWith('/')
        })
        if ($actualMembers.Count -ne $expectedFiles.Count) { throw "Expected 11 Canterbury input members, got $($actualMembers.Count)." }
        foreach ($expected in $expectedFiles) {
            $memberName = $prefix + $expected.Name
            $member = $zip.GetEntry($memberName)
            if ($null -eq $member -or [long]$member.Length -ne [long]$expected.Bytes) { throw "Pinned ZIP member mismatch: $memberName" }
            $destination = Join-Path $source $expected.Name
            $inputStream = $member.Open()
            try {
                $outputStream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $inputStream.CopyTo($outputStream); $outputStream.Flush($true) } finally { $outputStream.Dispose() }
            } finally { $inputStream.Dispose() }
            if ((Get-Item -LiteralPath $destination).Length -ne [long]$expected.Bytes -or (Get-Sha256 $destination) -cne $expected.Sha256) {
                throw "Pinned ZIP member bytes/SHA mismatch: $memberName"
            }
        }
    } finally { $zip.Dispose() }
    $sourceManifest = Assert-MatchingManifest $source 'source'
    $report.input = [ordered]@{
        archive = $recovery; archive_bytes = (Get-Item -LiteralPath $recovery).Length; archive_sha256 = $expectedInputZipSha
        member_prefix = 'pipeline-e2e/canterbury/'; files = $sourceManifest.files; bytes = $sourceManifest.bytes
        manifest_sha256 = $sourceManifest.manifest_sha256; entries = $sourceManifest.entries
    }
    $report.tools.input_recovery_zip_sha256 = Get-Sha256 $recovery
    $report.tools.khc_cli_path = $khc
    $report.tools.khc_cli_sha256 = Get-Sha256 $khc
    $report.tools.seven_zip_path = $seven
    $report.tools.seven_zip_sha256 = Get-Sha256 $seven
    $khcVersion = Invoke-Tool $khc @('--version') 'khc-version' $work
    if ($khcVersion.stdout.Trim() -cne 'unlhare 1.0.4') { throw "Unexpected KHC CLI version: $($khcVersion.stdout.Trim())" }
    $sevenVersion = Invoke-Tool $seven @('i', '-sccUTF-8') 'seven-zip-version' $work
    if ($sevenVersion.stdout -cnotmatch '(?m)^7-Zip 26\.04 \(x64\)(?:\s|:)') { throw 'Expected exactly 7-Zip 26.04 x64 runtime.' }
    $report.tools.khc_version = $khcVersion.stdout.Trim()
    $report.tools.seven_zip_version = [regex]::Match($sevenVersion.stdout, '(?m)^7-Zip 26\.04 \(x64\)[^\r\n]*').Value.Trim()
    $report.tools.preregistered_pins = @($pins | ForEach-Object { [pscustomobject]@{ path = (Get-PlainPath $_.path); sha256 = $_.sha } })
    Save-Report

    $orderedNames = [string[]]@($expectedFiles | ForEach-Object { [string]$_.Name })
    [Array]::Sort($orderedNames, [StringComparer]::Ordinal)
    $runs = @(
        [pscustomobject]@{ Round = 1; Order = @('khc', 'seven-zip') },
        [pscustomobject]@{ Round = 2; Order = @('seven-zip', 'khc') }
    )
    foreach ($run in $runs) {
        foreach ($toolName in $run.Order) {
            $extension = if ($toolName -ceq 'khc') { 'khc' } else { '7z' }
            $archive = Join-Path $archiveDirectory "$toolName-round-$($run.Round).$extension"
            if (Test-Path -LiteralPath $archive) { throw "Archive destination already exists: $archive" }
            if ($toolName -ceq 'khc') {
                $created = Invoke-Tool $khc @(
                    'khc-create', $archive, '--source', $source, '--strategy', 'spatial-mdl-trial',
                    '--max-entries', '64', '--max-total-bytes', $inputBytes.ToString([Globalization.CultureInfo]::InvariantCulture)
                ) "khc-create-round-$($run.Round)" $work
            } else {
                $sevenArgs = [Collections.Generic.List[string]]::new()
                foreach ($arg in @('a', '-t7z', '-m0=LZMA2', '-mx=9', '-md=64m', '-mmt=1', '-ms=on', '-mqs=off', '-mtm=off', '-mtc=off', '-mta=off', $archive, '--')) { $sevenArgs.Add($arg) }
                foreach ($name in $orderedNames) { $sevenArgs.Add($name) }
                $created = Invoke-Tool $seven $sevenArgs.ToArray() "seven-create-round-$($run.Round)" $source
            }
            $summary = Assert-ArchiveLimit $archive "$toolName round $($run.Round)"
            if ($toolName -ceq 'khc') {
                $stream = [IO.File]::OpenRead($archive)
                try {
                    $header = [byte[]]::new(9)
                    if ($stream.Read($header, 0, $header.Length) -ne $header.Length -or
                        [Text.Encoding]::ASCII.GetString($header, 0, 8) -cne "KHC1ARC`0" -or $header[8] -ne 9) {
                        throw 'Candidate archive is not KHC archive revision 9.'
                    }
                } finally { $stream.Dispose() }
            }
            $archivesReport.Add([pscustomobject]@{ tool = $toolName; round = $run.Round; path = $summary.path; bytes = $summary.bytes; sha256 = $summary.sha256 })
            Save-Report
        }
    }

    foreach ($toolName in @('khc', 'seven-zip')) {
        $toolArchives = @($archivesReport | Where-Object tool -CEQ $toolName | Sort-Object round)
        if ($toolArchives.Count -ne 2 -or $toolArchives[0].bytes -ne $toolArchives[1].bytes -or $toolArchives[0].sha256 -cne $toolArchives[1].sha256) {
            throw "Non-deterministic archive output for $toolName."
        }
    }
    $report.determinism_verified = $true
    Save-Report

    $sevenListing = Invoke-Tool $seven @('l', '-slt', '-sccUTF-8', (Join-Path $archiveDirectory 'seven-zip-round-1.7z')) 'seven-list-round-1' $work
    $methods = @([regex]::Matches($sevenListing.stdout, '(?m)^Method = (.+)\r?$') | ForEach-Object { $_.Groups[1].Value.Trim() })
    if ($methods.Count -lt 2) { throw 'Missing effective 7-Zip method/dictionary listing.' }
    $dictionaries = @(
        foreach ($method in $methods) {
            if ($method -cnotmatch '^LZMA2:(\d+)([bkm]?)$') { throw "Unexpected effective 7-Zip method: $method" }
            $number = [long]$Matches[1]
            $dictionary = switch ($Matches[2]) {
                'b' { $number }
                'k' { $number * 1KB }
                'm' { $number * 1MB }
                default { if ($number -gt 26) { throw 'Effective dictionary exponent exceeds 64 MiB.' }; [long][Math]::Pow(2, $number) }
            }
            if ($dictionary -le 0 -or $dictionary -gt 64MB) { throw "Unexpected effective dictionary size: $dictionary" }
            $dictionary
        }
    )
    $report.tools.seven_zip_actual_methods = $methods
    $report.tools.seven_zip_effective_dictionary_bytes = $dictionaries
    Save-Report

    foreach ($archiveRecord in @($archivesReport | Sort-Object tool, round)) {
        $toolName = [string]$archiveRecord.tool
        $archive = Join-Path $work $archiveRecord.path
        if ($toolName -ceq 'khc') {
            $null = Invoke-Tool $khc @('khc-test', $archive, '--max-entries', '64', '--max-total-bytes', $inputBytes.ToString([Globalization.CultureInfo]::InvariantCulture)) "khc-test-round-$($archiveRecord.round)" $work
            $restore = Join-Path $work "restore-khc-round-$($archiveRecord.round)"
            $null = New-WorkDirectory $restore
            $null = Invoke-Tool $khc @('khc-extract', $archive, '--output', $restore, '--max-entries', '64', '--max-total-bytes', $inputBytes.ToString([Globalization.CultureInfo]::InvariantCulture)) "khc-extract-round-$($archiveRecord.round)" $work
        } else {
            $null = Invoke-Tool $seven @('t', '-sccUTF-8', $archive) "seven-test-round-$($archiveRecord.round)" $work
            $restore = Join-Path $work "restore-seven-zip-round-$($archiveRecord.round)"
            $null = New-WorkDirectory $restore
            $null = Invoke-Tool $seven @('x', '-sccUTF-8', $archive, "-o$restore", '-y') "seven-extract-round-$($archiveRecord.round)" $work
        }
        $manifest = Assert-MatchingManifest $restore "$toolName round $($archiveRecord.round)"
        $restoresReport.Add([pscustomobject]@{ tool = $toolName; round = $archiveRecord.round; directory = [IO.Path]::GetRelativePath($work, $restore); files = $manifest.files; bytes = $manifest.bytes; manifest_sha256 = $manifest.manifest_sha256 })
        $report.restore_verified = ($restoresReport.Count -eq 4)
        Save-Report
    }

    if (-not $report.restore_verified) { throw 'All four archives must be fully restored and verified.' }
    foreach ($pin in $pins) {
        if ((Get-Sha256 $pin.path) -cne $pin.sha) { throw "Pinned source/tool changed during run: $($pin.path)" }
    }
    $candidate = [long](@($archivesReport | Where-Object { $_.tool -ceq 'khc' } | Select-Object -First 1).bytes)
    $baseline = [long](@($archivesReport | Where-Object { $_.tool -ceq 'seven-zip' } | Select-Object -First 1).bytes)
    $passed = ($candidate * 100L -le $baseline * 95L)
    $report.candidate_comparison = [ordered]@{
        candidate_archive_bytes = $candidate
        seven_zip_archive_bytes = $baseline
        bytes_saved = $baseline - $candidate
        savings_fraction = 1.0 - ([double]$candidate / $baseline)
        required_savings_fraction = 0.05
        exact_gate = 'candidate_archive_bytes * 100 <= seven_zip_archive_bytes * 95'
    }
    $report.candidate_screen_passed = $passed
    $report.candidate_decision = if ($passed) { 'size-only-development-screen-pass; separate performance and heldout preregistration required' } else { 'no-go-for-this-candidate-on-Canterbury11-size-screen' }
    $report.status = 'complete'
    $report.final_work = Assert-WorkBudget
    Save-Report
    Write-Output "SIZE SCREEN COMPLETE: files=$($sourceManifest.files); bytes=$inputBytes; KHC=$candidate; 7z=$baseline; pass=$passed; time/memory not measured"
} catch {
    $report.status = 'failed'
    $report.error = $_.Exception.Message
    try { Save-Report } catch { }
    throw
}
