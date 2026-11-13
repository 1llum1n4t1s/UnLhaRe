#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkDirectory,
    [Parameter(Mandatory)][string]$InputRecoveryZip,
    [Parameter(Mandatory)][string]$InputRecoveryZipSha256,
    [Parameter(Mandatory)][string]$ExpectedSourceManifestSha256,
    [Parameter(Mandatory)][string]$KhcExecutable,
    [Parameter(Mandatory)][string]$KhcExecutableSha256,
    [Parameter(Mandatory)][string]$ProbeExecutable,
    [Parameter(Mandatory)][string]$ProbeExecutableSha256,
    [Parameter(Mandatory)][string]$SevenZipPath,
    [Parameter(Mandatory)][string]$SevenZipSha256,
    [Parameter(Mandatory)][string]$ExpectedScreenSha256
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$expectedLifecycleSha = '511ac35885416d0ee7deb6367f2f210d6bda3e71ced3001a590dd90426962ac3'
$lifecyclePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'storage-lifecycle.psm1'))
if (-not (Test-Path -LiteralPath $lifecyclePath -PathType Leaf) -or
    (Get-FileHash -LiteralPath $lifecyclePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedLifecycleSha) {
    throw 'Portfolio pilot storage lifecycle pin changed.'
}
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force
Assert-KhcStorageContext -WorkDirectory $WorkDirectory
$record = Get-Content -LiteralPath $env:KHC_STORAGE_RUN_RECORD -Raw | ConvertFrom-Json
if ([long]$record.max_bytes -ne 32MB -or [int]$record.max_entries -ne 96) {
    throw 'The portfolio size pilot requires exactly 32 MiB / 96 entries.'
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
function Get-KhcSourceManifest {
    $root = Get-PlainPath (Join-Path $PSScriptRoot '..\..\src\khc')
    $pathsByName = @{}
    foreach ($entry in Get-ChildItem -LiteralPath $root -Filter '*.rs' -File -Recurse -Force -ErrorAction Stop) {
        $full = Get-PlainPath $entry.FullName
        $relative = [IO.Path]::GetRelativePath($root, $full).Replace('\', '/')
        if ($relative.StartsWith('../', [StringComparison]::Ordinal) -or $relative -eq '..') {
            throw "KHC source escaped its root: $relative"
        }
        $pathsByName[$relative] = $full
    }
    $names = [string[]]@($pathsByName.Keys)
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $builder = [Text.StringBuilder]::new()
    foreach ($name in $names) {
        $path = $pathsByName[$name]
        $item = Get-Item -LiteralPath $path -Force
        $null = $builder.Append($name).Append([char]9).Append($item.Length).Append([char]9).Append((Get-Sha256 $path)).Append([char]10)
    }
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.UTF8Encoding]::new($false).GetBytes($builder.ToString()))).ToLowerInvariant()
    return [pscustomobject]@{ files = $names.Length; sha256 = $hash }
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
    $json = ConvertTo-Json -InputObject $report -Depth 16
    $encoded = [Text.UTF8Encoding]::new($false).GetBytes($json)
    if ($encoded.Length -gt 512KB) { throw 'Report exceeded the fixed 512 KiB limit.' }
    [IO.File]::WriteAllBytes($reportPath, $encoded)
    $null = Assert-WorkBudget
}
function Get-Manifest([string]$Directory) {
    $dir = Get-PlainPath $Directory
    $files = @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction Stop)
    $directories = @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction Stop)
    if ($directories.Count -ne 0) { throw 'Canterbury11 extraction unexpectedly contains subdirectories.' }
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($entry in $files) {
        $rows.Add([pscustomobject]@{
            name = $entry.Name
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
    return [pscustomobject]@{
        files = $names.Length
        bytes = [long](($rows | Measure-Object -Property bytes -Sum).Sum)
        manifest_sha256 = $manifestSha
        entries = @($names | ForEach-Object { $byName[$_] })
    }
}
function Invoke-Tool(
    [string]$Executable,
    [string[]]$Arguments,
    [string]$Label,
    [string]$WorkingDirectory,
    [int]$TimeoutSeconds
) {
    $exe = Get-PlainPath $Executable
    $cwd = Get-PlainPath $WorkingDirectory
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Tool not found: $exe" }
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
    $info.Environment['TEMP'] = $paths.TempRoot
    $info.Environment['TMP'] = $paths.TempRoot
    foreach ($argument in $Arguments) { $info.ArgumentList.Add([string]$argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) { throw "Could not start: $Label" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            if (-not $process.WaitForExit(5000)) { throw "Process failed to stop after timeout: $Label" }
            throw "Child timeout after $TimeoutSeconds seconds: $Label"
        }
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $logText = "--- stdout ---`n$stdout`n--- stderr ---`n$stderr"
        $logBytes = [Text.UTF8Encoding]::new($false).GetBytes($logText)
        if ($logBytes.Length -gt 64KB) { throw "Tool log exceeded 64 KiB: $Label" }
        [IO.File]::WriteAllBytes($logPath, $logBytes)
        $report.commands += [pscustomobject]@{
            label = $Label; executable = $exe; executable_sha256 = Get-Sha256 $exe
            argv = @($Arguments); working_directory = [IO.Path]::GetRelativePath($work, $cwd)
            exit_code = $process.ExitCode; log_path = [IO.Path]::GetRelativePath($work, $logPath)
            log_bytes = $logBytes.Length
        }
        Save-Report
        if ($process.ExitCode -ne 0) { throw "Command failed ($($process.ExitCode)): $Label" }
        return [pscustomobject]@{ stdout = $stdout; stderr = $stderr; exit_code = $process.ExitCode }
    } finally {
        if ($started -and -not $process.HasExited) {
            try { $process.Kill($true) } catch { }
            if (-not $process.WaitForExit(5000)) { throw "Process remains after cleanup: $Label" }
        }
        $process.Dispose()
    }
}

$work = Get-PlainPath $WorkDirectory
$paths = Get-KhcStorageTaskPaths
$expectedRecoveryPath = (Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\storage-lifecycle\runs\5e93ed1e99ca4f5ab29d490db421e50b\recovery.zip')
$expectedZipSha = 'b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb'
$expectedManifestSha = 'bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438'
$expectedProbeSha = $ProbeExecutableSha256
$expectedKhcSha = '50952a6e7781800b946f85a7493bea7ca0923b5a974f34db1ba2baf32d1de6e3'
$expectedSevenZipSha = '95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53'
$expectedProbePath = (Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'work\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\examples\khc_portfolio_size_pilot.exe')
$expectedKhcPath = (Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'work\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\unlhare-cli.exe')
$expectedProbeSourceSha = '3f8bf9b6b8aaaca679f70822ec87e4c73d34f14a1542627d2c69b78141922707'
$expectedKhcSourceManifestSha = 'e24f0502e7ecccdd4933fcfc08217bfe11771eb6c229dc46877364a5754ec424'
$expectedMainSha = '35ee6bd7a7d222db03f92a1647155c678d752b9a69e793b4749a665fa57c72aa'
$expectedCargoTomlSha = '3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac'
$expectedCargoLockSha = 'd8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554'
$expectedScreenSha = $ExpectedScreenSha256
$expectedSourceBytes = 2810784L
$expectedBaselineArchiveBytes = 484829L
$historicalBaselineArchiveSha = '648f04505ac91aa1e4e96d82ed26bb85a6ebafcd318bf00273e53ee5fc75cea9'
$expectedSevenZipBytes = 483599L
$referenceSevenZipArchiveSha = 'ea8b4b785c245001ab0efb5aa0a21d0339cdf74d8d62d5ccdee75b5f1b8e4299'
$maxCandidateArchiveBytes = 459419L
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
$commands = @()
$source = Join-Path $work 'source'
$archives = Join-Path $work 'archives'
$logs = Join-Path $work 'logs'
$reportPath = Assert-WorkChild (Join-Path $work 'portfolio-size-pilot.json')
$baselineArchive = Join-Path $archives 'revision9.khc'
$report = [ordered]@{
    schema = 1; status = 'running'; run_id = [IO.Path]::GetFileName($work) -replace '^run-', ''
    scope = 'Canterbury11 exact block-frame size pilot only; no archive revision, time, memory, holdout, or general-superiority result.'
    input = $null; tools = $null; settings = $null; commands = @(); probe = $null
    candidate_decision = $null; error = $null
}
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))

try {
    if ($expectedScreenSha -notmatch '^[0-9a-f]{64}$' -or (Get-Sha256 $PSCommandPath) -cne $expectedScreenSha) {
        throw 'Portfolio screen script SHA mismatch.'
    }
    if ((Get-Sha256 (Join-Path $repo 'examples/khc_portfolio_size_pilot.rs')) -cne $expectedProbeSourceSha -or
        (Get-Sha256 (Join-Path $repo 'src/main.rs')) -cne $expectedMainSha -or
        (Get-Sha256 (Join-Path $repo 'Cargo.toml')) -cne $expectedCargoTomlSha -or
        (Get-Sha256 (Join-Path $repo 'Cargo.lock')) -cne $expectedCargoLockSha -or
        (Get-Sha256 (Join-Path $PSScriptRoot 'storage-lifecycle.psm1')) -cne $expectedLifecycleSha) {
        throw 'Portfolio pilot source/build/lifecycle pins changed.'
    }
    $khcSources = Get-KhcSourceManifest
    if ($khcSources.files -eq 0 -or $khcSources.sha256 -cne $expectedKhcSourceManifestSha) {
        throw 'Portfolio pilot KHC source tree manifest changed.'
    }
    if ([IO.Path]::GetFullPath($InputRecoveryZip) -cne $expectedRecoveryPath -or
        $InputRecoveryZipSha256 -cne $expectedZipSha -or
        $ExpectedSourceManifestSha256 -cne $expectedManifestSha -or
        $KhcExecutableSha256 -cne $expectedKhcSha -or
        $SevenZipSha256 -cne $expectedSevenZipSha -or
        $expectedProbeSha -notmatch '^[0-9a-f]{64}$' -or $ProbeExecutableSha256 -cne $expectedProbeSha) {
        throw 'The fixed Canterbury11 portfolio pilot requires the exact preregistered pins.'
    }

    $cargoRoot = [IO.Path]::GetFullPath($paths.CargoTargetRoot) + [IO.Path]::DirectorySeparatorChar
    $probe = Get-PlainPath $ProbeExecutable
    $khc = Get-PlainPath $KhcExecutable
    $seven = Get-PlainPath $SevenZipPath
    $recovery = Get-PlainPath $InputRecoveryZip
    if ($probe -cne $expectedProbePath -or -not $probe.StartsWith($cargoRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($probe) -cne 'khc_portfolio_size_pilot.exe' -or
        (Get-Sha256 $probe) -cne $expectedProbeSha) { throw 'Only the pinned Cargo portfolio probe is allowed.' }
    if ($khc -cne $expectedKhcPath -or -not $khc.StartsWith($cargoRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($khc) -cne 'unlhare-cli.exe' -or
        (Get-Sha256 $khc) -cne $expectedKhcSha) { throw 'Only the pinned revision-9 CLI is allowed.' }
    if ($seven -cne 'C:\Program Files\7-Zip\7z.exe' -or (Get-Sha256 $seven) -cne $expectedSevenZipSha) {
        throw 'Only the pinned 7-Zip 26.04 x64 control is allowed.'
    }
    if ((Get-Sha256 $recovery) -cne $expectedZipSha) { throw 'Canterbury recovery ZIP SHA mismatch.' }

    $sourcePath = Get-PlainPath $source
    $archivePath = Get-PlainPath $archives
    $logsPath = Get-PlainPath $logs
    $null = New-WorkDirectory $sourcePath
    $null = New-WorkDirectory $archivePath
    $null = New-WorkDirectory $logsPath
    $null = Save-Report

    $zip = [IO.Compression.ZipFile]::OpenRead($recovery)
    try {
        $prefix = 'pipeline-e2e/canterbury/'
        $members = @($zip.Entries | Where-Object {
            $_.FullName.StartsWith($prefix, [StringComparison]::Ordinal) -and
            $_.FullName.Length -gt $prefix.Length -and -not $_.FullName.EndsWith('/')
        })
        if ($members.Count -ne $expectedFiles.Count) { throw "Expected 11 source members, got $($members.Count)." }
        foreach ($expected in $expectedFiles) {
            $memberName = $prefix + $expected.Name
            $matching = @($members | Where-Object { $_.FullName -ceq $memberName })
            if ($matching.Count -ne 1 -or [long]$matching[0].Length -ne [long]$expected.Bytes) {
                throw "Pinned ZIP member mismatch: $memberName"
            }
            $destination = Assert-WorkChild (Join-Path $source $expected.Name)
            $inputStream = $matching[0].Open()
            try {
                $outputStream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try {
                    $inputStream.CopyTo($outputStream)
                    $outputStream.Flush($true)
                } finally { $outputStream.Dispose() }
            } finally { $inputStream.Dispose() }
            if ((Get-Item -LiteralPath $destination).Length -ne [long]$expected.Bytes -or
                (Get-Sha256 $destination) -cne $expected.Sha256) { throw "Source member mismatch: $memberName" }
        }
    } finally { $zip.Dispose() }
    $manifest = Get-Manifest $source
    if ($manifest.files -ne 11 -or $manifest.bytes -ne $expectedSourceBytes -or
        $manifest.manifest_sha256 -cne $expectedManifestSha) { throw 'Canterbury11 source manifest mismatch.' }

    $report.input = [ordered]@{
        archive = $recovery; archive_sha256 = $expectedZipSha; files = $manifest.files
        bytes = $manifest.bytes; manifest_sha256 = $manifest.manifest_sha256
        member_prefix = 'pipeline-e2e/canterbury/'
        entries = @($manifest.entries | ForEach-Object { [pscustomobject]@{ name = $_.name; bytes = $_.bytes; sha256 = $_.sha256 } })
    }
    $report.tools = [ordered]@{
        revision9_cli = $khc; revision9_cli_sha256 = $expectedKhcSha
        portfolio_probe = $probe; portfolio_probe_sha256 = $expectedProbeSha
        seven_zip = $seven; seven_zip_sha256 = $expectedSevenZipSha
        seven_zip_reference_archive_sha256 = $referenceSevenZipArchiveSha
        khc_source_files = $khcSources.files; khc_source_manifest_sha256 = $khcSources.sha256
        portfolio_probe_source_sha256 = $expectedProbeSourceSha
        cargo_toml_sha256 = $expectedCargoTomlSha; cargo_lock_sha256 = $expectedCargoLockSha
        cli_source_sha256 = $expectedMainSha; storage_lifecycle_sha256 = $expectedLifecycleSha
    }
    $report.settings = [ordered]@{
        strategies = @('Mdl', 'SpatialBitsTrial', 'RecordFastTrial', 'RecordAdaptiveTrial')
        tie_break = 'fixed strategy order; replace best only on strictly smaller complete frame'
        block_bytes = 1048576; deterministic_encodes_per_candidate_block = 2
        revision9_archive_bytes = $expectedBaselineArchiveBytes
        seven_zip_archive_bytes = $expectedSevenZipBytes
        candidate_size_gate_bytes_max = $maxCandidateArchiveBytes
        seven_zip = '7z/LZMA2 -mx=9 -md=64m -mmt=1 -ms=on -mqs=off -mtm=off -mtc=off -mta=off; effective LZMA2:3m'
        time_measurements_collected = $false; memory_measurements_collected = $false; cpu_gate_used = $false
        child_timeout_seconds = 60; pilot_child_timeout_seconds = 180
        outer_timeout_seconds = 300; max_run_bytes = 32MB; max_entries = 96
    }
    $null = Save-Report

    $created = Invoke-Tool $khc @(
        'khc-create', $baselineArchive, '--source', $source, '--strategy', 'spatial-mdl-trial',
        '--max-entries', '64', '--max-total-bytes', $expectedSourceBytes.ToString([Globalization.CultureInfo]::InvariantCulture)
    ) 'baseline-revision9-create' $work 60
    $baselineInfo = Get-Item -LiteralPath (Get-PlainPath $baselineArchive)
    $baselineSha = Get-Sha256 $baselineArchive
    if ([long]$baselineInfo.Length -ne $expectedBaselineArchiveBytes) { throw 'Revision-9 archive size differs from the pinned baseline.' }
    $null = Invoke-Tool $khc @(
        'khc-test', $baselineArchive, '--max-entries', '64',
        '--max-total-bytes', $expectedSourceBytes.ToString([Globalization.CultureInfo]::InvariantCulture)
    ) 'baseline-revision9-test' $work 60

    $pilotRun = Invoke-Tool $probe @($source, $baselineArchive) 'portfolio-size-probe' $source 180
    $pilot = $pilotRun.stdout.Trim() | ConvertFrom-Json
    if ([int]$pilot.schema -ne 1 -or [int]$pilot.input_files -ne 11 -or
        [long]$pilot.input_bytes -ne $expectedSourceBytes -or [long]$pilot.revision9_archive_bytes -ne $expectedBaselineArchiveBytes -or
        [long]$pilot.seven_zip_archive_bytes -ne $expectedSevenZipBytes -or
        -not [bool]$pilot.determinism_verified -or -not [bool]$pilot.candidate_roundtrip_verified -or
        -not [bool]$pilot.revision9_size_invariant_passed -or [int]$pilot.strategy_totals.Count -ne 4) {
        throw 'Portfolio probe report failed its fixed integrity assertions.'
    }
    if ([long]$pilot.candidate_archive_bytes -gt $expectedBaselineArchiveBytes) {
        throw 'Portfolio estimate exceeded revision-9 archive bytes.'
    }
    $expectedGate = [long]$pilot.candidate_archive_bytes -le $maxCandidateArchiveBytes
    if ([bool]$pilot.size_gate_passed -ne $expectedGate) { throw 'Portfolio probe reported an inconsistent size gate.' }

    $report.probe = $pilot
    $report.baseline_archive = [ordered]@{
        path = [IO.Path]::GetRelativePath($work, $baselineArchive)
        bytes = [long]$baselineInfo.Length; sha256 = $baselineSha
        pinned_expected_bytes = $expectedBaselineArchiveBytes; historical_reference_sha256 = $historicalBaselineArchiveSha
        test_verified = $true
    }
    if ($expectedGate) {
        $report.status = 'completed'
        $report.candidate_decision = 'go-to-separate-revision-10-integration-and-performance-evaluation'
    } else {
        $report.status = 'completed'
        $report.candidate_decision = 'no-go-for-this-fixed-Canterbury11-size-condition'
    }
    $null = Save-Report
    Write-Output ("decision={0}; candidate_bytes={1}; seven_zip_bytes={2}; report={3}" -f
        $report.candidate_decision, $pilot.candidate_archive_bytes, $expectedSevenZipBytes,
        [IO.Path]::GetRelativePath($work, $reportPath))
} catch {
    $report.status = 'failed'
    $report.error = $_.Exception.Message
    try { $null = Save-Report } catch { }
    throw
}
