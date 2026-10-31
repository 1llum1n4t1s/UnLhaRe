param(
    [Parameter(Mandatory)][string]$LabPath,
    [Parameter(Mandatory)][string]$SevenZipPath,
    [Parameter(Mandatory)][string]$GroupPath,
    [Parameter(Mandatory)][string]$WorkDirectory,
    [ValidateRange(1, 100)][int]$Repeats = 5,
    [ValidateSet(1, 2, 3, 4, 8, 16)][int]$BeamWidth = 2,
    [ValidateSet(64, 128, 256, 512, 1024, 2048, 4096, 8192)][int]$BeamBlock = 512,
    [ValidateSet('bt4', 'bt5', 'hybrid')][string]$BeamMatches = 'bt4',
    [ValidateSet('current', 'warm', 'blended')][string]$BeamModel = 'blended',
    [ValidateSet(0, 64)][int]$BtNiceLen = 0,
    [ValidateSet('range', 'rans')][string]$EntropyBackend = 'range',
    [ValidateRange(1, 64)][int]$SevenZipThreads = 1
)

# 固定Canterbury開発集合を、KHCの単一group frameと7-Zip自身の複数file solid書庫で比較する。
# 任意入力を受ける製品書庫ハーネスではない。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force
Assert-KhcStorageContext -WorkDirectory $WorkDirectory -ErrorAction Stop

$sourceRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$work = [IO.Path]::GetFullPath($WorkDirectory)
if (Test-Path -LiteralPath $work) { throw 'WorkDirectory must be new; existing data will not be overwritten.' }

function Assert-NoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse point is not allowed in this path: $current"
            }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}

Assert-NoReparse $work
$lab = (Resolve-Path -LiteralPath $LabPath).Path
$sevenZip = (Resolve-Path -LiteralPath $SevenZipPath).Path
$group = (Resolve-Path -LiteralPath $GroupPath).Path
foreach ($file in @($lab, $sevenZip, $group)) {
    Assert-NoReparse $file
    if ((Get-Item -LiteralPath $file -Force) -isnot [IO.FileInfo]) { throw "Expected a file: $file" }
}

function Invoke-Measured(
    [string]$Program,
    [string[]]$Arguments,
    [string]$StdoutFile = '',
    [string]$ExpectedDecodedHash = '',
    [string]$WorkingDirectory = ''
) {
    if ($StdoutFile -and $ExpectedDecodedHash) { throw 'StdoutFile and ExpectedDecodedHash are mutually exclusive.' }
    $info = [Diagnostics.ProcessStartInfo]::new($Program)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    if ($WorkingDirectory) { $info.WorkingDirectory = $WorkingDirectory }
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    # 両codecの復元出力は同じSHA-256 sinkへ流す。hashのCPU時間もdecode wall時間に含む。
    $hasher = if ($ExpectedDecodedHash) { [Security.Cryptography.SHA256]::Create() } else { $null }
    $sink = if ($hasher) {
        [Security.Cryptography.CryptoStream]::new(
            [IO.Stream]::Null, $hasher, [Security.Cryptography.CryptoStreamMode]::Write, $true
        )
    } elseif ($StdoutFile) {
        [IO.File]::Open($StdoutFile, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    } else {
        [IO.Stream]::Null
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $peakWorking = 0L
    $peakPrivate = 0L
    $started = $false
    $outputTask = $null
    $errorTask = $null
    try {
        $started = $process.Start()
        if (-not $started) { throw "Failed to start: $Program" }
        $outputTask = $process.StandardOutput.BaseStream.CopyToAsync($sink)
        $errorTask = $process.StandardError.ReadToEndAsync()
        while (-not $process.WaitForExit(1)) {
            if ($watch.Elapsed.TotalSeconds -gt 120) { throw 'Per-process 120 second deadline exceeded.' }
            if ($outputTask.IsFaulted) { $null = $outputTask.GetAwaiter().GetResult() }
            $process.Refresh()
            $peakWorking = [Math]::Max($peakWorking, $process.PeakWorkingSet64)
            $peakPrivate = [Math]::Max($peakPrivate, $process.PrivateMemorySize64)
        }
        $null = $outputTask.GetAwaiter().GetResult()
        $stderr = $errorTask.GetAwaiter().GetResult()
        if ($hasher) { $sink.FlushFinalBlock() }
        $watch.Stop()
        $cpuMs = $null
        try { $cpuMs = $process.TotalProcessorTime.TotalMilliseconds } catch { }
        if ($process.ExitCode -ne 0) { throw "$Program exit $($process.ExitCode): $stderr" }
        $decodedHash = if ($hasher) { [Convert]::ToHexString($hasher.Hash) } else { $null }
        if ($hasher -and $decodedHash -cne $ExpectedDecodedHash) { throw 'Restored concatenated SHA-256 mismatch.' }
        [pscustomobject]@{
            wall_ms = $watch.Elapsed.TotalMilliseconds
            cpu_ms = $cpuMs
            peak_working_sampled = $(if ($peakWorking -gt 0) { $peakWorking } else { $null })
            peak_private_sampled = $(if ($peakPrivate -gt 0) { $peakPrivate } else { $null })
            decoded_sha256 = $decodedHash
        }
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        if ($null -ne $outputTask) { try { $null = $outputTask.GetAwaiter().GetResult() } catch { } }
        if ($null -ne $errorTask) { try { $null = $errorTask.GetAwaiter().GetResult() } catch { } }
        if ($StdoutFile -or $hasher) { $sink.Dispose() }
        if ($hasher) { $hasher.Dispose() }
        $process.Dispose()
    }
}

function Invoke-Captured(
    [string]$Program,
    [string[]]$Arguments,
    [string]$WorkingDirectory = ''
) {
    $info = [Diagnostics.ProcessStartInfo]::new($Program)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    if ($WorkingDirectory) { $info.WorkingDirectory = $WorkingDirectory }
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $started = $false
    $stdoutTask = $null
    $stderrTask = $null
    try {
        $started = $process.Start()
        if (-not $started) { throw "Failed to start: $Program" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        while (-not $process.WaitForExit(1)) {
            if ($watch.Elapsed.TotalSeconds -gt 120) { throw 'Per-process 120 second deadline exceeded.' }
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "$Program exit $($process.ExitCode): $stderr" }
        [pscustomobject]@{ stdout = $stdout; stderr = $stderr }
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        if ($null -ne $stdoutTask) { try { $null = $stdoutTask.GetAwaiter().GetResult() } catch { } }
        if ($null -ne $stderrTask) { try { $null = $stderrTask.GetAwaiter().GetResult() } catch { } }
        $process.Dispose()
    }
}

function Get-MedianValue([double[]]$Values) {
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { throw 'Cannot take the median of no samples.' }
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 0) { return ($sorted[$middle - 1] + $sorted[$middle]) / 2 }
    return $sorted[$middle]
}

function Get-ConcatHash([string[]]$Paths) {
    $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $buffer = [byte[]]::new(1MB)
    try {
        foreach ($path in $Paths) {
            $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try {
                while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $hash.AppendData($buffer, 0, $count)
                }
            } finally { $stream.Dispose() }
        }
        return [Convert]::ToHexString($hash.GetHashAndReset())
    }
    finally { $hash.Dispose() }
}

function Get-SevenZipListing([string]$Text) {
    $lines = @($Text -split "`r?`n")
    $separator = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -ceq '----------') { $separator = $i; break }
    }
    if ($separator -lt 0) { throw '7-Zip technical listing has no entry separator.' }
    $header = @($lines[0..$separator])
    if (@($header | Where-Object { $_ -ceq 'Blocks = 1' }).Count -ne 1 -or
        @($header | Where-Object { $_ -ceq 'Solid = +' }).Count -ne 1) {
        throw '7-Zip archive is not one solid block.'
    }
    $records = @()
    $currentPath = $null
    $currentSize = $null
    for ($i = $separator + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^Path = (.*)$') {
            if ($null -ne $currentPath) {
                if ($null -eq $currentSize) { throw "7-Zip entry has no Size: $currentPath" }
                $records += [pscustomobject]@{ name = $currentPath; bytes = [long]$currentSize }
            }
            $currentPath = $Matches[1]
            $currentSize = $null
        } elseif ($line -match '^Size = ([0-9]+)$') {
            if ($null -eq $currentPath -or $null -ne $currentSize) { throw 'Unexpected 7-Zip Size field.' }
            $currentSize = [long]$Matches[1]
        }
    }
    if ($null -ne $currentPath) {
        if ($null -eq $currentSize) { throw "7-Zip entry has no Size: $currentPath" }
        $records += [pscustomobject]@{ name = $currentPath; bytes = [long]$currentSize }
    }
    [pscustomobject]@{ lines = $lines; entries = $records; blocks = 1; solid = $true }
}

$manifestPath = Join-Path $PSScriptRoot 'CORPUS_MANIFEST.json'
Assert-NoReparse $manifestPath
$manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
$collections = @(Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json | Where-Object {
    $_.name -ceq 'canterbury-development' -and $_.role -ceq 'development'
})
if ($collections.Count -ne 1 -or @($collections[0].files).Count -ne 11) {
    throw 'Expected the fixed 11-file Canterbury development corpus manifest.'
}
$manifestEntries = @($collections[0].files)
$names = [string[]]@($manifestEntries | ForEach-Object { $_.name })
[Array]::Sort($names, [StringComparer]::Ordinal)
$previousName = $null
foreach ($name in $names) {
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or ($null -ne $previousName -and $name -ceq $previousName)) {
        throw 'Corpus names must be unique fixed ASCII basenames.'
    }
    $previousName = $name
}

$groupHashBefore = (Get-FileHash -LiteralPath $group -Algorithm SHA256).Hash
$labHash = (Get-FileHash -LiteralPath $lab -Algorithm SHA256).Hash
$sevenZipHash = (Get-FileHash -LiteralPath $sevenZip -Algorithm SHA256).Hash
$sevenZipProbe = Invoke-Captured $sevenZip @('i')
$sevenZipIdentity = @($sevenZipProbe.stdout -split "`r?`n" | Where-Object { $_ -match '^7-Zip' })
if ($sevenZipIdentity.Count -eq 0) { throw 'Unable to verify the 7-Zip executable.' }

$sourceFiles = @(
    (Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter '*.rs').FullName
    (Join-Path $sourceRoot 'examples/khc_lab.rs')
    (Join-Path $sourceRoot 'Cargo.toml')
    (Join-Path $sourceRoot 'Cargo.lock')
    $PSCommandPath
)
$sourceHashes = @($sourceFiles | Sort-Object -Unique | ForEach-Object {
    [pscustomobject]@{
        path = [IO.Path]::GetRelativePath($sourceRoot, $_)
        sha256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash
    }
})
$revision = @(git -C $sourceRoot rev-parse HEAD)
if ($LASTEXITCODE -ne 0 -or $revision.Count -ne 1) { throw 'Unable to record the source revision.' }
$rustc = Join-Path $env:USERPROFILE '.cargo/bin/rustc.exe'
$compiler = @(& $rustc --version)
if ($LASTEXITCODE -ne 0 -or $compiler.Count -ne 1) { throw 'Unable to verify the Rust compiler.' }
$cpu = @(Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors)

$null = New-Item -ItemType Directory -Path $work
$inputDirectory = Join-Path $work 'input'
$null = New-Item -ItemType Directory -Path $inputDirectory
$snapshots = @()
foreach ($name in $names) {
    $entries = @($manifestEntries | Where-Object { $_.name -ceq $name })
    if ($entries.Count -ne 1) { throw "Missing or duplicate manifest entry: $name" }
    $entry = $entries[0]
    if ([long]$entry.bytes -lt 0 -or [long]$entry.bytes -gt 64MB -or
        [string]$entry.sha256 -notmatch '^[0-9A-F]{64}$') {
        throw "Invalid manifest entry: $name"
    }
    $sourcePath = Join-Path $sourceRoot "build/khc-corpus/canterbury-development/$name"
    Assert-NoReparse $sourcePath
    if ((Get-Item -LiteralPath $sourcePath -Force) -isnot [IO.FileInfo]) { throw "Corpus source is not a file: $name" }
    $snapshotPath = Join-Path $inputDirectory $name
    $sourceHash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $sourceStream = [IO.File]::Open($sourcePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $snapshotStream = [IO.File]::Open($snapshotPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $buffer = [byte[]]::new(1MB)
    try {
        if ($sourceStream.Length -ne [long]$entry.bytes) { throw "Corpus length mismatch: $name" }
        $copied = 0L
        while (($count = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $sourceHash.AppendData($buffer, 0, $count)
            $snapshotStream.Write($buffer, 0, $count)
            $copied += $count
        }
        if ($copied -ne [long]$entry.bytes -or $sourceStream.Length -ne [long]$entry.bytes) {
            throw "Corpus changed while snapshotting: $name"
        }
        $actualSourceHash = [Convert]::ToHexString($sourceHash.GetHashAndReset())
        if ($actualSourceHash -cne [string]$entry.sha256) { throw "Corpus SHA-256 mismatch: $name" }
        $snapshotStream.Flush($true)
    }
    finally {
        $snapshotStream.Dispose()
        $sourceStream.Dispose()
        $sourceHash.Dispose()
    }
    $snapshotHash = (Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash
    if ($snapshotHash -cne [string]$entry.sha256 -or (Get-Item -LiteralPath $snapshotPath).Length -ne [long]$entry.bytes) {
        throw "Snapshot verification failed: $name"
    }
    $snapshots += [pscustomobject]@{
        name = $name
        bytes = [long]$entry.bytes
        sha256 = $snapshotHash
        source_path = $sourcePath
        snapshot_path = $snapshotPath
    }
}
if ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -cne $manifestHash) {
    throw 'Corpus manifest changed while snapshots were created.'
}
$snapshotPaths = [string[]]@($snapshots | ForEach-Object { $_.snapshot_path })
$expectedConcatHash = Get-ConcatHash $snapshotPaths
$contentBytes = [long](($snapshots | Measure-Object -Property bytes -Sum).Sum)

$khcArguments = @(
    '--dictionary-mib', '64', '--algorithm', 'beam', '--beam-width', [string]$BeamWidth,
    '--beam-block', [string]$BeamBlock, '--beam-model', $BeamModel, '--beam-matches', $BeamMatches,
    '--bt-nice-len', [string]$BtNiceLen, '--entropy-backend', $EntropyBackend
)
$sevenZipCreateArguments = @(
    'a', '-t7z', '-mx=9', '-m0=LZMA2:d=64m', "-mmt=$SevenZipThreads", '-ms=on', '-mqs=off',
    '-mtm=off', '-mtc=off', '-mta=off', '-bso0', '-bsp0'
)
$samples = @()
$firstHashes = @{}
$khcListing = @()
$sevenZipListing = $null
$metadataVerified = $false

Write-Host ("Native solid comparison: Canterbury 11; KHC matches={0}, model={1}, beam width={2}, block={3}; 7-Zip threads={4}; repeats={5}; {6}" -f $BeamMatches, $BeamModel, $BeamWidth, $BeamBlock, $SevenZipThreads, $Repeats, ($sevenZipIdentity -join ' '))
Write-Host "KHC lab SHA-256: $labHash"
Write-Host "7-Zip SHA-256: $sevenZipHash"
for ($iteration = 0; $iteration -le $Repeats; $iteration++) {
    # 0はwarm-up。以後もKHC/7-Zipの起動順を反転する。
    $order = @('khc-group', '7zip-solid')
    if ($iteration % 2 -ne 0) { [array]::Reverse($order) }
    for ($orderIndex = 0; $orderIndex -lt $order.Count; $orderIndex++) {
        $codec = $order[$orderIndex]
        if ($codec -ceq 'khc-group') {
            $packed = Join-Path $work ("{0}.khc" -f $iteration)
            $encoding = Invoke-Measured $lab (@('group-encode', $group) + $khcArguments) $packed
            if (-not $metadataVerified) {
                $listResult = Invoke-Captured $lab (@('group-list', $packed) + $khcArguments)
                try { $khcListing = @($listResult.stdout | ConvertFrom-Json) }
                catch { throw "KHC group-list returned invalid JSON: $($_.Exception.Message)" }
                if ($khcListing.Count -ne $snapshots.Count) { throw 'KHC group-list entry count mismatch.' }
                for ($i = 0; $i -lt $snapshots.Count; $i++) {
                    if ([string]$khcListing[$i].name -cne $snapshots[$i].name -or
                        [long]$khcListing[$i].bytes -ne $snapshots[$i].bytes) {
                        throw "KHC group-list metadata mismatch at entry $i."
                    }
                }
                $metadataVerified = $true
            }
            $decoding = Invoke-Measured $lab (@('group-decode', $packed) + $khcArguments) '' $expectedConcatHash
        } else {
            $packed = Join-Path $work ("{0}.7z" -f $iteration)
            $inputNames = [string[]]@($snapshots | ForEach-Object { $_.name })
            $encoding = Invoke-Measured $sevenZip ($sevenZipCreateArguments + @($packed) + $inputNames) '' '' $inputDirectory
            if ($null -eq $sevenZipListing) {
                $listingResult = Invoke-Captured $sevenZip @('l', '-slt', '-bsp0', $packed)
                $sevenZipListing = Get-SevenZipListing $listingResult.stdout
                if ($sevenZipListing.entries.Count -ne $khcListing.Count) { throw '7-Zip listing entry count mismatch.' }
                for ($i = 0; $i -lt $khcListing.Count; $i++) {
                    if ([string]$sevenZipListing.entries[$i].name -cne [string]$khcListing[$i].name -or
                        [long]$sevenZipListing.entries[$i].bytes -ne [long]$khcListing[$i].bytes) {
                        throw "7-Zip Path/Size order differs from KHC group-list at entry $i."
                    }
                }
            }
            $decoding = Invoke-Measured $sevenZip @('x', '-so', '-bsp0', $packed) '' $expectedConcatHash
        }
        $archiveHash = (Get-FileHash -LiteralPath $packed -Algorithm SHA256).Hash
        if ($iteration -eq 0) { $firstHashes[$codec] = $archiveHash }
        elseif ($firstHashes[$codec] -cne $archiveHash) { throw "$codec output was not deterministic." }
        $samples += [pscustomobject]@{
            codec = $codec
            iteration = $iteration
            warmup = ($iteration -eq 0)
            order = $orderIndex
            archive_bytes = (Get-Item -LiteralPath $packed).Length
            archive_sha256 = $archiveHash
            encode = $encoding
            decode = $decoding
        }
    }
}
if (-not $metadataVerified -or $null -eq $sevenZipListing) { throw 'Archive metadata verification was not completed.' }

# 実行中の差替えやgroupの書換えを成功reportへ混ぜない。
foreach ($snapshot in $snapshots) {
    foreach ($path in @($snapshot.source_path, $snapshot.snapshot_path)) {
        if ((Get-Item -LiteralPath $path).Length -ne $snapshot.bytes -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $snapshot.sha256) {
            throw 'A corpus source or snapshot changed during the comparison; no success report was written.'
        }
    }
}
$groupHashAfter = (Get-FileHash -LiteralPath $group -Algorithm SHA256).Hash
if ($groupHashAfter -cne $groupHashBefore) { throw 'Group input changed during the comparison; no success report was written.' }
if ((Get-FileHash -LiteralPath $lab -Algorithm SHA256).Hash -cne $labHash -or
    (Get-FileHash -LiteralPath $sevenZip -Algorithm SHA256).Hash -cne $sevenZipHash) {
    throw 'An executable changed during the comparison; no success report was written.'
}
foreach ($source in $sourceHashes) {
    if ((Get-FileHash -LiteralPath (Join-Path $sourceRoot $source.path) -Algorithm SHA256).Hash -cne $source.sha256) {
        throw 'A recorded source file changed during the comparison; no success report was written.'
    }
}
if ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -cne $manifestHash) {
    throw 'Corpus manifest changed during the comparison; no success report was written.'
}

$report = [ordered]@{
    status = 'success: development native solid comparison; not a product archive or overall performance claim'
    measured_utc = [DateTime]::UtcNow.ToString('o')
    parameters = [ordered]@{ repeats = $Repeats; beam_width = $BeamWidth; beam_block = $BeamBlock; seven_zip_threads = $SevenZipThreads; work_directory = $work }
    provenance = [ordered]@{
        os = [Environment]::OSVersion.VersionString
        architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        cpu = $cpu
        power_scheme = @(powercfg /getactivescheme)
        revision = $revision[0]
        compiler = $compiler[0]
        source_state = 'working tree; source files and fixed executable hashes recorded separately'
        source_sha256 = $sourceHashes
        manifest_path = $manifestPath
        manifest_sha256 = $manifestHash
        lab_path = $lab
        lab_sha256 = $labHash
        seven_zip_path = $sevenZip
        seven_zip_sha256 = $sevenZipHash
        seven_zip_identity = $sevenZipIdentity
        group_path = $group
        group_sha256_before = $groupHashBefore
        group_sha256_after = $groupHashAfter
    }
    input = [ordered]@{
        collection = 'canterbury-development'
        order = 'ordinal ASCII basename'
        files = $snapshots
        content_bytes = $contentBytes
        concatenated_sha256 = $expectedConcatHash
    }
    settings = [ordered]@{
        khc = [ordered]@{
            representation = 'one validated KHSGRP0 group inside one KHC frame'
            dictionary_bytes = 64MB
            algorithm = 'beam'
            beam_width = $BeamWidth
            beam_block = $BeamBlock
            beam_model = $BeamModel
            beam_matches = $BeamMatches
            bt_nice_len = $BtNiceLen
            entropy_backend = $EntropyBackend
        }
        seven_zip = [ordered]@{
            representation = '11 native files in one 7z solid block; default header compression retained'
            threads = $SevenZipThreads
            arguments = @('-t7z', '-mx=9', '-m0=LZMA2:d=64m', "-mmt=$SevenZipThreads", '-ms=on', '-mqs=off', '-mtm=off', '-mtc=off', '-mta=off')
        }
        threads = [ordered]@{ khc = 1; seven_zip = $SevenZipThreads }
    }
    verification = [ordered]@{
        khc_group_list = $khcListing
        seven_zip_listing = [ordered]@{
            blocks = $sevenZipListing.blocks
            solid = $sevenZipListing.solid
            entries = $sevenZipListing.entries
            raw_lines = $sevenZipListing.lines
        }
        deterministic_archive_sha256 = $firstHashes
        decode_output = 'Both codecs stream concatenated file content to the same SHA-256 sink; hashing is included in CLI wall time; no decoded copy is created.'
    }
    notes = @(
        'Only flat ASCII basenames and file content are compared; product archive metadata and selective extraction semantics are not evaluated.',
        'Sampled process memory is observational and is not an equal hard memory ceiling.',
        'This is the fixed development corpus, not the unused holdout and not an overall product-performance claim.',
        'Only total archive bytes are compared; no synthetic payload byte count is derived from either container.'
    )
    samples = $samples
}
$reportPath = Join-Path $work 'report.json'
$reportJson = $report | ConvertTo-Json -Depth 12
$reportStream = [IO.File]::Open($reportPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
$reportWriter = [IO.StreamWriter]::new($reportStream, [Text.UTF8Encoding]::new($false))
try { $reportWriter.Write($reportJson) } finally { $reportWriter.Dispose() }

@('khc-group', '7zip-solid') | ForEach-Object {
    $codec = $_
    $rows = @($samples | Where-Object { $_.codec -ceq $codec -and -not $_.warmup })
    [pscustomobject]@{
        codec = $codec
        content_bytes = $contentBytes
        archive_bytes = $rows[0].archive_bytes
        encode_median_ms = Get-MedianValue ([double[]]@($rows | ForEach-Object { $_.encode.wall_ms }))
        decode_median_ms = Get-MedianValue ([double[]]@($rows | ForEach-Object { $_.decode.wall_ms }))
    }
} | ConvertTo-Json
