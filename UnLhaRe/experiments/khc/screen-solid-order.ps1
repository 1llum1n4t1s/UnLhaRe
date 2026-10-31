param(
    [Parameter(Mandatory)][string]$LabPath,
    [Parameter(Mandatory)][string]$SevenZipPath,
    [Parameter(Mandatory)][string]$WorkDirectory
)

# 固定Canterbury開発集合だけを使い、solid内のfile順序が総byte数へ与える影響を比較する。
# 論理metadata順を保つKHSGRP1と通常のgroup CLIを通し、KHSGRP0 baselineとの結果差を検証する。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$sourceRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$buildRoot = [IO.Path]::GetFullPath((Join-Path $sourceRoot 'build'))
$buildPrefix = $buildRoot + [IO.Path]::DirectorySeparatorChar
$work = [IO.Path]::GetFullPath($WorkDirectory)
if (-not $work.StartsWith($buildPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'WorkDirectory must be strictly below UnLhaRe/build.'
}
if (Test-Path -LiteralPath $work) {
    throw 'WorkDirectory must be new; existing data will not be overwritten.'
}

function Assert-NoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrEmpty($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse point is not allowed in this path: $current"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -ceq $current) { break }
        $current = $parent
    }
}

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Invoke-CheckedProcess(
    [string]$Program,
    [string[]]$Arguments,
    [ValidateSet('capture', 'file', 'hash', 'discard')][string]$OutputMode,
    [string]$OutputPath = '',
    [string]$WorkingDirectory = '',
    [switch]$AllowNonzeroExit
) {
    if ($OutputMode -ceq 'file' -and [string]::IsNullOrEmpty($OutputPath)) {
        throw 'OutputPath is required for file output.'
    }
    if ($OutputMode -cne 'file' -and -not [string]::IsNullOrEmpty($OutputPath)) {
        throw 'OutputPath is only valid for file output.'
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new($Program)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if (-not [string]::IsNullOrEmpty($WorkingDirectory)) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    $stdoutTextTask = $null
    $stdoutCopyTask = $null
    $stderrTask = $null
    $sink = $null
    $hasher = $null
    try {
        $started = $process.Start()
        if (-not $started) { throw "Failed to start: $Program" }
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($OutputMode -ceq 'capture') {
            $stdoutTextTask = $process.StandardOutput.ReadToEndAsync()
        } else {
            $sink = if ($OutputMode -ceq 'file') {
                [IO.File]::Open($OutputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            } elseif ($OutputMode -ceq 'hash') {
                $hasher = [Security.Cryptography.SHA256]::Create()
                [Security.Cryptography.CryptoStream]::new(
                    [IO.Stream]::Null,
                    $hasher,
                    [Security.Cryptography.CryptoStreamMode]::Write,
                    $true
                )
            } else {
                [IO.Stream]::Null
            }
            $stdoutCopyTask = $process.StandardOutput.BaseStream.CopyToAsync($sink)
        }

        $deadline = [DateTime]::UtcNow.AddMinutes(10)
        while (-not $process.WaitForExit(1000)) {
            if ([DateTime]::UtcNow -gt $deadline) {
                throw "Process deadline exceeded: $Program"
            }
            if ($null -ne $stdoutCopyTask -and $stdoutCopyTask.IsFaulted) {
                $null = $stdoutCopyTask.GetAwaiter().GetResult()
            }
        }

        $stdout = $null
        if ($null -ne $stdoutTextTask) {
            $stdout = $stdoutTextTask.GetAwaiter().GetResult()
        }
        if ($null -ne $stdoutCopyTask) {
            $null = $stdoutCopyTask.GetAwaiter().GetResult()
        }
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($null -ne $hasher) { $sink.FlushFinalBlock() }
        if ($process.ExitCode -ne 0 -and -not $AllowNonzeroExit) {
            throw "$Program exit $($process.ExitCode): $stderr"
        }
        [pscustomobject]@{
            stdout = $stdout
            stderr = $stderr
            exit_code = $process.ExitCode
            sha256 = $(if ($null -ne $hasher) { [Convert]::ToHexString($hasher.Hash) } else { $null })
        }
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        if ($null -ne $stdoutTextTask) {
            try { $null = $stdoutTextTask.GetAwaiter().GetResult() } catch { }
        }
        if ($null -ne $stdoutCopyTask) {
            try { $null = $stdoutCopyTask.GetAwaiter().GetResult() } catch { }
        }
        if ($null -ne $stderrTask) {
            try { $null = $stderrTask.GetAwaiter().GetResult() } catch { }
        }
        if ($OutputMode -ceq 'file' -and $null -ne $sink) { $sink.Dispose() }
        if ($null -ne $hasher) {
            $sink.Dispose()
            $hasher.Dispose()
        }
        $process.Dispose()
    }
}

function Get-ConcatenatedHash([object[]]$Entries) {
    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash(
        [Security.Cryptography.HashAlgorithmName]::SHA256
    )
    $buffer = [byte[]]::new(1MB)
    try {
        foreach ($entry in $Entries) {
            $stream = [IO.File]::Open(
                [string]$entry.snapshot_path,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::Read
            )
            try {
                while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $hasher.AppendData($buffer, 0, $count)
                }
            }
            finally { $stream.Dispose() }
        }
        [Convert]::ToHexString($hasher.GetHashAndReset())
    }
    finally { $hasher.Dispose() }
}

function Get-SevenZipListing([string]$Text) {
    $lines = @($Text -split "`r?`n")
    $separator = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -ceq '----------') {
            $separator = $i
            break
        }
    }
    if ($separator -lt 0) { throw '7-Zip technical listing has no entry separator.' }
    $header = @($lines[0..$separator])
    if (@($header | Where-Object { $_ -ceq 'Type = 7z' }).Count -ne 1 -or
        @($header | Where-Object { $_ -ceq 'Blocks = 1' }).Count -ne 1 -or
        @($header | Where-Object { $_ -ceq 'Solid = +' }).Count -ne 1) {
        throw '7-Zip output is not one solid 7z block.'
    }
    $method = @($header | Where-Object { $_ -match '^Method = LZMA2(?::[0-9]+[bkmgt]?)(?:\s+.*)?$' })
    if ($method.Count -ne 1) { throw '7-Zip archive method is not LZMA2.' }
    if (@($lines | Where-Object { $_ -match '^(Modified|Created|Accessed) = \S' }).Count -ne 0) {
        throw '7-Zip archive unexpectedly retained file timestamps.'
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
            if ($null -eq $currentPath -or $null -ne $currentSize) {
                throw 'Unexpected 7-Zip Size field.'
            }
            $currentSize = [long]$Matches[1]
        }
    }
    if ($null -ne $currentPath) {
        if ($null -eq $currentSize) { throw "7-Zip entry has no Size: $currentPath" }
        $records += [pscustomobject]@{ name = $currentPath; bytes = [long]$currentSize }
    }
    [pscustomobject]@{
        method = $method[0].Substring('Method = '.Length)
        entries = $records
        raw_lines = $lines
    }
}

function Assert-ExactOrder([string]$Label, [string[]]$Order, [string[]]$ManifestNames) {
    if ($Order.Count -ne $ManifestNames.Count) {
        throw "Order '$Label' does not contain exactly the manifest entry count."
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $Order) {
        if (-not $seen.Add($name)) { throw "Order '$Label' contains a duplicate: $name" }
    }
    foreach ($name in $ManifestNames) {
        if (-not $seen.Contains($name)) { throw "Order '$Label' is missing: $name" }
    }
}

function Assert-CorpusStable([object[]]$Snapshots) {
    foreach ($entry in $Snapshots) {
        foreach ($path in @([string]$entry.source_path, [string]$entry.snapshot_path)) {
            Assert-NoReparse $path
            $item = Get-Item -LiteralPath $path -Force
            if ($item -isnot [IO.FileInfo] -or
                $item.Length -ne [long]$entry.bytes -or
                (Get-Sha256 $path) -cne [string]$entry.sha256) {
                throw "Corpus source or snapshot drifted: $($entry.name)"
            }
        }
    }
}

function New-OpaqueGroup(
    [string]$Path,
    [string[]]$LogicalOrder,
    [string[]]$PhysicalOrder,
    [Collections.Generic.Dictionary[string, object]]$SnapshotByName
) {
    Assert-ExactOrder 'logical metadata' $LogicalOrder $manifestNames
    Assert-ExactOrder 'physical body' $PhysicalOrder $manifestNames
    $logicalEntries = @($LogicalOrder | ForEach-Object { $SnapshotByName[$_] })
    $physicalEntries = @($PhysicalOrder | ForEach-Object { $SnapshotByName[$_] })
    $hasPhysicalOrderTable = [string]::Join([char]10, $LogicalOrder) -cne
        [string]::Join([char]10, $PhysicalOrder)
    $logicalIndexByName = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    for ($i = 0; $i -lt $LogicalOrder.Count; $i++) { $logicalIndexByName.Add($LogicalOrder[$i], $i) }
    $contentBytes = [decimal]0
    $totalBytes = [decimal]16
    foreach ($entry in $logicalEntries) {
        $nameBytes = [Text.Encoding]::UTF8.GetBytes([string]$entry.name)
        if ($nameBytes.Length -lt 1 -or $nameBytes.Length -gt 255 -or
            $nameBytes.Length -gt [uint16]::MaxValue) {
            throw "Invalid solid-group name length: $($entry.name)"
        }
        if ([long]$entry.bytes -lt 0) { throw 'Negative group entry length.' }
        $contentBytes += [decimal][long]$entry.bytes
        $totalBytes += [decimal](10 + $nameBytes.Length) + [decimal][long]$entry.bytes
    }
    if ($hasPhysicalOrderTable) { $totalBytes += [decimal](2 * $logicalEntries.Count) }
    if ($logicalEntries.Count -gt 1024 -or $logicalEntries.Count -gt [uint32]::MaxValue) {
        throw 'Solid-group entry count exceeds its parser limit.'
    }
    if ($totalBytes -gt [uint64]::MaxValue -or $totalBytes -gt 64MB) {
        throw 'Opaque group size exceeds its integer or codec input limit.'
    }
    $metadataBytes = [long]($totalBytes - $contentBytes)
    $tableOffset = if ($hasPhysicalOrderTable) { $metadataBytes - 2 * $logicalEntries.Count } else { $null }
    $bodyOrderLogicalIndexes = @($PhysicalOrder | ForEach-Object { $logicalIndexByName[$_] })

    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $writer = [IO.BinaryWriter]::new($stream, [Text.Encoding]::UTF8, $true)
    try {
        $magic = if ($hasPhysicalOrderTable) { [byte[]](75, 72, 83, 71, 82, 80, 49, 0) } else { [byte[]](75, 72, 83, 71, 82, 80, 48, 0) }
        $magic = [byte[]]$magic
        $writer.Write([byte[]]$magic)
        $writer.Write([uint32]$logicalEntries.Count)
        $writer.Write([uint32]0)
        foreach ($entry in $logicalEntries) {
            $nameBytes = [Text.Encoding]::UTF8.GetBytes([string]$entry.name)
            $writer.Write([uint16]$nameBytes.Length)
            $writer.Write([uint64][long]$entry.bytes)
            $writer.Write([byte[]]$nameBytes)
        }
        if ($hasPhysicalOrderTable) {
            foreach ($logicalIndex in $bodyOrderLogicalIndexes) { $writer.Write([uint16]$logicalIndex) }
        }
        $writer.Flush()
        foreach ($entry in $physicalEntries) {
            $input = [IO.File]::Open(
                [string]$entry.snapshot_path,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::Read
            )
            try { $input.CopyTo($stream) }
            finally { $input.Dispose() }
        }
        $stream.Flush($true)
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }
    $actualBytes = (Get-Item -LiteralPath $Path).Length
    if ($actualBytes -ne [long]$totalBytes) { throw 'Opaque group length mismatch.' }
    [pscustomobject]@{
        path = $Path
        bytes = $actualBytes
        metadata_bytes = $actualBytes - [long]$contentBytes
        content_bytes = [long]$contentBytes
        format = $(if ($hasPhysicalOrderTable) { 'KHSGRP1' } else { 'KHSGRP0' })
        body_order_table_offset = $tableOffset
        body_order_logical_indexes = $bodyOrderLogicalIndexes
        logical_order = [string[]]$LogicalOrder
        physical_body_order = [string[]]$PhysicalOrder
        sha256 = Get-Sha256 $Path
        concatenated_content_sha256 = Get-ConcatenatedHash $logicalEntries
        entries = @($logicalEntries | ForEach-Object {
            [pscustomobject]@{ name = $_.name; bytes = $_.bytes; sha256 = $_.sha256 }
        })
    }
}

function New-CorruptedPhysicalOrderGroup(
    [string]$SourcePath,
    [string]$Path,
    [long]$TableOffset,
    [ValidateSet('duplicate', 'out-of-range')][string]$Corruption,
    [int]$EntryCount
) {
    if ($EntryCount -lt 2 -or $TableOffset -lt 16) {
        throw 'A KHSGRP1 index table with at least two entries is required.'
    }
    if (Test-Path -LiteralPath $Path) { throw "Corrupt-group output already exists: $Path" }
    Assert-NoReparse $Path
    [IO.File]::Copy($SourcePath, $Path, $false)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $firstIndexBytes = [byte[]]::new(2)
        $stream.Position = $TableOffset
        if ($stream.Read($firstIndexBytes, 0, 2) -ne 2) { throw 'Physical-order table is truncated.' }
        $replacement = if ($Corruption -ceq 'duplicate') {
            [BitConverter]::ToUInt16($firstIndexBytes, 0)
        } else {
            [uint16]$EntryCount
        }
        $stream.Position = if ($Corruption -ceq 'duplicate') { $TableOffset + 2 } else { $TableOffset }
        $writer = [IO.BinaryWriter]::new($stream, [Text.Encoding]::UTF8, $true)
        try {
            $writer.Write([uint16]$replacement)
            $writer.Flush()
            $stream.Flush($true)
        }
        finally { $writer.Dispose() }
    }
    finally { $stream.Dispose() }
    [pscustomobject]@{
        path = $Path
        corruption = $Corruption
        sha256 = Get-Sha256 $Path
    }
}

Assert-NoReparse $buildRoot
Assert-NoReparse $work
$lab = (Resolve-Path -LiteralPath $LabPath).Path
$sevenZip = (Resolve-Path -LiteralPath $SevenZipPath).Path
foreach ($file in @($lab, $sevenZip)) {
    Assert-NoReparse $file
    if ((Get-Item -LiteralPath $file -Force) -isnot [IO.FileInfo]) { throw "Expected a file: $file" }
}

$manifestPath = Join-Path $PSScriptRoot 'CORPUS_MANIFEST.json'
Assert-NoReparse $manifestPath
$scriptHash = Get-Sha256 $PSCommandPath
$manifestHash = Get-Sha256 $manifestPath
$collections = @(Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json | Where-Object {
    $_.name -ceq 'canterbury-development' -and $_.role -ceq 'development'
})
if ($collections.Count -ne 1 -or @($collections[0].files).Count -ne 11) {
    throw 'Expected the fixed 11-file Canterbury development corpus manifest.'
}
$manifestEntries = @($collections[0].files)
$manifestNames = [string[]]@($manifestEntries | ForEach-Object { [string]$_.name })
[Array]::Sort($manifestNames, [StringComparer]::Ordinal)
$previousName = $null
foreach ($name in $manifestNames) {
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or
        ($null -ne $previousName -and $name -ceq $previousName)) {
        throw 'Manifest names must be unique fixed ASCII basenames.'
    }
    $previousName = $name
}

$orders = @(
    [pscustomobject][ordered]@{
        id = 'ordinal-ascii-name'
        description = 'Ordinal ASCII basename order'
        names = [string[]]$manifestNames.Clone()
    },
    [pscustomobject][ordered]@{
        id = 'sum-before-ptt5'
        description = 'Ordinal order with ptt5 and sum swapped'
        names = [string[]]@(
            'alice29.txt', 'asyoulik.txt', 'cp.html', 'fields.c', 'grammar.lsp',
            'kennedy.xls', 'lcet10.txt', 'plrabn12.txt', 'sum', 'ptt5', 'xargs.1'
        )
    },
    [pscustomobject][ordered]@{
        id = 'content-based'
        description = 'Fixed content-based development hypothesis'
        names = [string[]]@(
            'xargs.1', 'asyoulik.txt', 'plrabn12.txt', 'lcet10.txt', 'alice29.txt',
            'cp.html', 'fields.c', 'sum', 'ptt5', 'kennedy.xls', 'grammar.lsp'
        )
    }
)
foreach ($order in $orders) {
    Assert-ExactOrder ([string]$order.id) ([string[]]$order.names) $manifestNames
}

$labHash = Get-Sha256 $lab
$sevenZipHash = Get-Sha256 $sevenZip
$sevenZipProbe = Invoke-CheckedProcess $sevenZip @('i') 'capture'
$sevenZipIdentity = @($sevenZipProbe.stdout -split "`r?`n" | Where-Object { $_ -match '^7-Zip' })
if ($sevenZipIdentity.Count -lt 1 -or
    @($sevenZipIdentity | Where-Object { $_ -match '\b26\.03\b' }).Count -lt 1) {
    throw 'This screen requires a verified 7-Zip 26.03 executable.'
}

$sourceFiles = [string[]]@(
    (Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File -Filter '*.rs').FullName
    (Join-Path $sourceRoot 'examples/khc_lab.rs')
    (Join-Path $sourceRoot 'Cargo.toml')
    (Join-Path $sourceRoot 'Cargo.lock')
    (Join-Path $sourceRoot 'rust-toolchain.toml')
)
$sourceFiles = [string[]]@($sourceFiles | Sort-Object -Unique)
$sourceHashes = @($sourceFiles | ForEach-Object {
    if (-not (Test-Path -LiteralPath $_ -PathType Leaf)) { throw "Missing recorded source file: $_" }
    [pscustomobject]@{
        path = [IO.Path]::GetRelativePath($sourceRoot, $_)
        sha256 = Get-Sha256 $_
    }
})
$gitProbe = Invoke-CheckedProcess 'git' @('-C', $sourceRoot, 'rev-parse', 'HEAD') 'capture'
$revision = $gitProbe.stdout.Trim()
if ($revision -notmatch '^[0-9a-fA-F]{40}$') { throw 'Unable to record the Git revision.' }
$rustc = Join-Path $env:USERPROFILE '.cargo/bin/rustc.exe'
if (-not (Test-Path -LiteralPath $rustc -PathType Leaf)) { throw 'rustc shim was not found.' }
$rustProbe = Invoke-CheckedProcess $rustc @('--version') 'capture' '' $sourceRoot
$rustVersion = $rustProbe.stdout.Trim()
if ($rustVersion -notmatch '^rustc ') { throw 'Unable to record the project-selected Rust version.' }
$cpu = @(Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors)

$null = New-Item -ItemType Directory -Path $work
Assert-NoReparse $work
$inputDirectory = Join-Path $work 'input'
$null = New-Item -ItemType Directory -Path $inputDirectory
$snapshotByName = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
$snapshots = @()
foreach ($name in $manifestNames) {
    $matches = @($manifestEntries | Where-Object { $_.name -ceq $name })
    if ($matches.Count -ne 1) { throw "Missing or duplicate manifest entry: $name" }
    $manifestEntry = $matches[0]
    $entryBytes = [long]$manifestEntry.bytes
    $entryHash = [string]$manifestEntry.sha256
    if ($entryBytes -lt 0 -or $entryBytes -gt 64MB -or $entryHash -notmatch '^[0-9A-F]{64}$') {
        throw "Invalid manifest entry: $name"
    }
    $sourcePath = Join-Path $sourceRoot "build/khc-corpus/canterbury-development/$name"
    Assert-NoReparse $sourcePath
    if ((Get-Item -LiteralPath $sourcePath -Force) -isnot [IO.FileInfo]) {
        throw "Corpus source is not a file: $name"
    }
    $snapshotPath = Join-Path $inputDirectory $name
    $sourceHasher = [Security.Cryptography.IncrementalHash]::CreateHash(
        [Security.Cryptography.HashAlgorithmName]::SHA256
    )
    $sourceStream = [IO.File]::Open(
        $sourcePath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    $snapshotStream = [IO.File]::Open(
        $snapshotPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    $buffer = [byte[]]::new(1MB)
    try {
        if ($sourceStream.Length -ne $entryBytes) { throw "Corpus length mismatch: $name" }
        $copied = 0L
        while (($count = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $sourceHasher.AppendData($buffer, 0, $count)
            $snapshotStream.Write($buffer, 0, $count)
            $copied += $count
        }
        if ($copied -ne $entryBytes -or $sourceStream.Length -ne $entryBytes) {
            throw "Corpus changed while snapshotting: $name"
        }
        $actualSourceHash = [Convert]::ToHexString($sourceHasher.GetHashAndReset())
        if ($actualSourceHash -cne $entryHash) { throw "Corpus SHA-256 mismatch: $name" }
        $snapshotStream.Flush($true)
    }
    finally {
        $snapshotStream.Dispose()
        $sourceStream.Dispose()
        $sourceHasher.Dispose()
    }
    if ((Get-Item -LiteralPath $snapshotPath).Length -ne $entryBytes -or
        (Get-Sha256 $snapshotPath) -cne $entryHash) {
        throw "Snapshot verification failed: $name"
    }
    $snapshot = [pscustomobject]@{
        name = $name
        bytes = $entryBytes
        sha256 = $entryHash
        source_path = $sourcePath
        snapshot_path = $snapshotPath
    }
    $snapshotByName.Add($name, $snapshot)
    $snapshots += $snapshot
}
if ((Get-Sha256 $manifestPath) -cne $manifestHash) {
    throw 'Corpus manifest changed while snapshots were created.'
}

$cases = @()
foreach ($order in $orders) {
    $caseDirectory = Join-Path $work ([string]$order.id)
    $null = New-Item -ItemType Directory -Path $caseDirectory
    $groupPath = Join-Path $caseDirectory 'input.group'
    $group = New-OpaqueGroup $groupPath ([string[]]$manifestNames) ([string[]]$order.names) $snapshotByName
    $cases += [pscustomobject][ordered]@{
        id = $order.id
        description = $order.description
        directory = $caseDirectory
        physical_body_order = [string[]]$order.names
        group = $group
    }
}

# snapshotと原本を全case構築後、最初のcodec起動前にもう一度manifestへ照合する。
Assert-CorpusStable $snapshots
if ((Get-Sha256 $manifestPath) -cne $manifestHash) {
    throw 'Corpus manifest changed before encoding.'
}

$khcArguments = @(
    '--dictionary-mib', '64',
    '--algorithm', 'beam',
    '--beam-width', '2',
    '--beam-block', '8192',
    '--beam-model', 'blended',
    '--beam-matches', 'bt5',
    '--bt-nice-len', '0',
    '--entropy-backend', 'range'
)
$sevenZipCreateArguments = @(
    'a', '-t7z', '-mx=9', '-m0=LZMA2:d=64m', '-mmt=1', '-ms=on', '-mqs=off',
    '-mtm=off', '-mtc=off', '-mta=off', '-bso0', '-bsp0'
)
$mapCase = @($cases | Where-Object { $_.id -ceq 'content-based' -and $_.group.format -ceq 'KHSGRP1' })
if ($mapCase.Count -ne 1) { throw 'Expected exactly one content-based KHSGRP1 case for invalid-map probes.' }
$invalidMapChecks = @()
foreach ($corruption in @('duplicate', 'out-of-range')) {
    $invalidGroupPath = Join-Path ([string]$mapCase[0].directory) "invalid-$corruption.group"
    $invalidGroup = New-CorruptedPhysicalOrderGroup `
        ([string]$mapCase[0].group.path) `
        $invalidGroupPath `
        ([long]$mapCase[0].group.body_order_table_offset) `
        $corruption `
        ([int]$manifestNames.Count)
    $invalidProbe = Invoke-CheckedProcess `
        -Program $lab `
        -Arguments (@('group-encode', [string]$invalidGroup.path) + $khcArguments) `
        -OutputMode 'hash' `
        -AllowNonzeroExit
    if ($invalidProbe.exit_code -eq 0) { throw "KHC accepted a KHSGRP1 $corruption index map." }
    if ($invalidProbe.sha256 -cne 'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855') {
        throw "KHC emitted frame bytes before rejecting a KHSGRP1 $corruption index map."
    }
    if ([string]::IsNullOrWhiteSpace([string]$invalidProbe.stderr)) {
        throw "KHC rejected a KHSGRP1 $corruption index map without a diagnostic."
    }
    $invalidMapChecks += [pscustomobject][ordered]@{
        corruption = $corruption
        group_path = $invalidGroup.path
        group_sha256 = $invalidGroup.sha256
        rejected = $true
        exit_code = $invalidProbe.exit_code
        stdout_empty = $true
        diagnostic_nonempty = $true
    }
}
$results = @()
foreach ($case in $cases) {
    $framePath = Join-Path ([string]$case.directory) 'frame.khc'
    $null = Invoke-CheckedProcess $lab (@('group-encode', [string]$case.group.path) + $khcArguments) 'file' $framePath
    $frameHash = Get-Sha256 $framePath
    $repeatFramePath = Join-Path ([string]$case.directory) 'frame.repeat.khc'
    $null = Invoke-CheckedProcess $lab (@('group-encode', [string]$case.group.path) + $khcArguments) 'file' $repeatFramePath
    if ((Get-Item -LiteralPath $repeatFramePath).Length -ne (Get-Item -LiteralPath $framePath).Length -or
        (Get-Sha256 $repeatFramePath) -cne $frameHash) {
        throw "KHC group encoding is not byte-for-byte deterministic: $($case.id)"
    }
    $khcRawDecoded = Invoke-CheckedProcess $lab (@('decode', $framePath) + $khcArguments) 'hash'
    if ($khcRawDecoded.sha256 -cne [string]$case.group.sha256) {
        throw "KHC raw group round-trip mismatch: $($case.id)"
    }
    $khcListingProbe = Invoke-CheckedProcess $lab (@('group-list', $framePath) + $khcArguments) 'capture'
    try { $khcListing = @($khcListingProbe.stdout | ConvertFrom-Json) }
    catch { throw "KHC group-list returned invalid JSON: $($_.Exception.Message)" }
    if ($khcListing.Count -ne $manifestNames.Count) { throw "KHC group-list entry count mismatch: $($case.id)" }
    for ($i = 0; $i -lt $manifestNames.Count; $i++) {
        $expected = $snapshotByName[$manifestNames[$i]]
        if ([string]$khcListing[$i].name -cne [string]$expected.name -or
            [long]$khcListing[$i].bytes -ne [long]$expected.bytes) {
            throw "KHC logical listing mismatch in '$($case.id)' at entry $i."
        }
    }
    $khcDecoded = Invoke-CheckedProcess $lab (@('group-decode', $framePath) + $khcArguments) 'hash'
    if ($khcDecoded.sha256 -cne [string]$case.group.concatenated_content_sha256) {
        throw "KHC logical-order group-decode mismatch: $($case.id)"
    }

    $archivePath = Join-Path ([string]$case.directory) 'archive.7z'
    $inputNames = [string[]]$case.physical_body_order
    $null = Invoke-CheckedProcess $sevenZip ($sevenZipCreateArguments + @($archivePath) + $inputNames) 'discard' '' $inputDirectory
    $listingProbe = Invoke-CheckedProcess $sevenZip @('l', '-slt', '-bsp0', $archivePath) 'capture'
    $listing = Get-SevenZipListing $listingProbe.stdout
    if ($listing.entries.Count -ne $inputNames.Count) {
        throw "7-Zip entry count mismatch: $($case.id)"
    }
    $sevenZipOrder = [string[]]@($listing.entries | ForEach-Object { [string]$_.name })
    Assert-ExactOrder "$($case.id) 7-Zip listing" $sevenZipOrder $manifestNames
    for ($i = 0; $i -lt $listing.entries.Count; $i++) {
        $actual = $listing.entries[$i]
        $expected = $snapshotByName[[string]$actual.name]
        if ([long]$actual.bytes -ne [long]$expected.bytes) {
            throw "7-Zip Path/Size mismatch in '$($case.id)' at observed entry $i."
        }
    }
    $sevenZipEntries = @($sevenZipOrder | ForEach-Object { $snapshotByName[$_] })
    $sevenZipConcatHash = Get-ConcatenatedHash $sevenZipEntries
    $sevenZipPreservedRequestedOrder = (
        [string]::Join([char]10, $sevenZipOrder) -ceq [string]::Join([char]10, $inputNames)
    )
    $sevenZipMatchesLogicalOrder = (
        [string]::Join([char]10, $sevenZipOrder) -ceq [string]::Join([char]10, $manifestNames)
    )
    $sevenZipDecoded = Invoke-CheckedProcess $sevenZip @('x', '-so', '-bsp0', $archivePath) 'hash'
    if ($sevenZipDecoded.sha256 -cne $sevenZipConcatHash) {
        throw "7-Zip streamed content does not match its observed listing order: $($case.id)"
    }

    $results += [pscustomobject][ordered]@{
        id = $case.id
        description = $case.description
        logical_entry_order = [string[]]$manifestNames
        physical_body_order = [string[]]$case.physical_body_order
        input = [ordered]@{
            entries = $case.group.entries
            content_bytes = $case.group.content_bytes
            concatenated_content_sha256 = $case.group.concatenated_content_sha256
        }
        opaque_group = [ordered]@{
            path = $case.group.path
            bytes = $case.group.bytes
            metadata_bytes = $case.group.metadata_bytes
            format = $case.group.format
            body_order_table_offset = $case.group.body_order_table_offset
            body_order_logical_indexes = $case.group.body_order_logical_indexes
            sha256 = $case.group.sha256
        }
        khc = [ordered]@{
            frame_path = $framePath
            frame_bytes = (Get-Item -LiteralPath $framePath).Length
            frame_sha256 = $frameHash
            repeat_frame_path = $repeatFramePath
            repeat_frame_sha256 = Get-Sha256 $repeatFramePath
            deterministic_encode_verified = $true
            raw_group_sha256_after_decode = $khcRawDecoded.sha256
            raw_group_round_trip_verified = $true
            group_list_entries = $khcListing
            logical_concatenated_content_sha256 = $khcDecoded.sha256
            group_decode_logical_order_verified = $true
        }
        seven_zip = [ordered]@{
            archive_path = $archivePath
            archive_bytes = (Get-Item -LiteralPath $archivePath).Length
            archive_sha256 = Get-Sha256 $archivePath
            method = $listing.method
            listing_entries = $listing.entries
            listing_raw_lines = $listing.raw_lines
            observed_entry_order = $sevenZipOrder
            requested_order_preserved = $sevenZipPreservedRequestedOrder
            same_physical_body_order_as_khc_candidate = $sevenZipPreservedRequestedOrder
            same_logical_listing_order_as_khc = $sevenZipMatchesLogicalOrder
            decoded_concatenated_content_sha256 = $sevenZipDecoded.sha256
            exact_entry_name_size_set_verified = $true
        }
    }
}

# 途中の差替え・source編集・corpus driftを成功reportへ混ぜない。
Assert-CorpusStable $snapshots
if ((Get-Sha256 $lab) -cne $labHash -or (Get-Sha256 $sevenZip) -cne $sevenZipHash) {
    throw 'An executable changed during the screen; no success report was written.'
}
if ((Get-Sha256 $PSCommandPath) -cne $scriptHash -or (Get-Sha256 $manifestPath) -cne $manifestHash) {
    throw 'The script or corpus manifest changed during the screen; no success report was written.'
}
foreach ($source in $sourceHashes) {
    $sourcePath = Join-Path $sourceRoot ([string]$source.path)
    if ((Get-Sha256 $sourcePath) -cne [string]$source.sha256) {
        throw 'A recorded source file changed during the screen; no success report was written.'
    }
}
foreach ($result in $results) {
    if ((Get-Item -LiteralPath $result.opaque_group.path).Length -ne [long]$result.opaque_group.bytes -or
        (Get-Sha256 $result.opaque_group.path) -cne [string]$result.opaque_group.sha256 -or
        (Get-Item -LiteralPath $result.khc.frame_path).Length -ne [long]$result.khc.frame_bytes -or
        (Get-Sha256 $result.khc.frame_path) -cne [string]$result.khc.frame_sha256 -or
        (Get-Item -LiteralPath $result.khc.repeat_frame_path).Length -ne [long]$result.khc.frame_bytes -or
        (Get-Sha256 $result.khc.repeat_frame_path) -cne [string]$result.khc.repeat_frame_sha256 -or
        (Get-Item -LiteralPath $result.seven_zip.archive_path).Length -ne [long]$result.seven_zip.archive_bytes -or
        (Get-Sha256 $result.seven_zip.archive_path) -cne [string]$result.seven_zip.archive_sha256) {
        throw 'A generated group, frame, or archive changed; no success report was written.'
    }
}
Assert-NoReparse $work

$ordinalResult = @($results | Where-Object { $_.id -ceq 'ordinal-ascii-name' })
if ($ordinalResult.Count -ne 1) { throw 'The ordinal baseline result is missing or duplicated.' }
$ordinalKhcBytes = [long]$ordinalResult[0].khc.frame_bytes
$ordinalSevenZipBytes = [long]$ordinalResult[0].seven_zip.archive_bytes
$sizeComparison = @($results | ForEach-Object {
    $khcBytes = [long]$_.khc.frame_bytes
    $sevenZipBytes = [long]$_.seven_zip.archive_bytes
    [pscustomobject][ordered]@{
        order = $_.id
        khc_frame_bytes = $khcBytes
        seven_zip_archive_bytes = $sevenZipBytes
        khc_minus_seven_zip_bytes = $khcBytes - $sevenZipBytes
        khc_delta_from_ordinal_bytes = $khcBytes - $ordinalKhcBytes
        seven_zip_delta_from_ordinal_bytes = $sevenZipBytes - $ordinalSevenZipBytes
        seven_zip_observed_entry_order = $_.seven_zip.observed_entry_order
        same_physical_body_order_as_khc_candidate = $_.seven_zip.same_physical_body_order_as_khc_candidate
        same_logical_listing_order_as_khc = $_.seven_zip.same_logical_listing_order_as_khc
    }
})

$report = [ordered]@{
    status = 'success: size-only Canterbury development solid-order screen; not a product archive or performance claim'
    completed_utc = [DateTime]::UtcNow.ToString('o')
    provenance = [ordered]@{
        os = [Environment]::OSVersion.VersionString
        architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        cpu = $cpu
        invocation_working_directory = [Environment]::CurrentDirectory
        source_root = $sourceRoot
        work_directory = $work
        revision = $revision
        rust_version_from_project_directory = $rustVersion
        script_path = $PSCommandPath
        script_sha256 = $scriptHash
        manifest_path = $manifestPath
        manifest_sha256 = $manifestHash
        lab_path = $lab
        lab_sha256 = $labHash
        seven_zip_path = $sevenZip
        seven_zip_sha256 = $sevenZipHash
        seven_zip_identity = $sevenZipIdentity
        source_sha256 = $sourceHashes
    }
    corpus = [ordered]@{
        collection = 'canterbury-development'
        role = 'development'
        source_directory = (Join-Path $sourceRoot 'build/khc-corpus/canterbury-development')
        snapshots = $snapshots
    }
    settings = [ordered]@{
        khc = [ordered]@{
            input_mode = 'group-encode on KHSGRP0 baseline and KHSGRP1 with ordinal metadata plus a physical-body-order table'
            arguments = @('group-encode', '<group>') + $khcArguments
            dictionary_bytes = 64MB
            algorithm = 'beam'
            beam_width = 2
            beam_block = 8192
            beam_model = 'blended'
            beam_matches = 'bt5'
            entropy_backend = 'range'
        }
        seven_zip = [ordered]@{
            version_required = '26.03'
            arguments = $sevenZipCreateArguments + @('<archive>', '<ordered input basenames>')
            representation = 'the same 11 native files in one solid block; observed archive order is validated and recorded'
        }
        timings_recorded_or_used = $false
    }
    verification = [ordered]@{
        source_and_snapshot_length_sha_checked_before_encoding = $true
        khc_raw_group_sha_checked_after_decode = $true
        khc_group_list_name_size_order_checked = $true
        khc_group_decode_logical_content_sha_checked = $true
        khc_repeated_encode_byte_determinism_checked = $true
        khsgroup1_duplicate_and_out_of_range_indices_rejected_before_output = $true
        invalid_physical_order_map_checks = $invalidMapChecks
        seven_zip_observed_entry_order_and_name_size_set_checked = $true
        seven_zip_order_match_to_khc_candidate_recorded = $true
        seven_zip_streamed_concatenated_content_sha_checked = $true
        generated_outputs_retained = $true
    }
    size_comparison = $sizeComparison
    cases = $results
    notes = @(
        'Only total frame/archive bytes are screened; no timing result is collected or claimed.',
        'KHSGRP0 remains the ordinal baseline. KHSGRP1 keeps logical metadata ordinal and uses a u16 table to select physical body order; it is an internal research group format, not product wire.',
        'All KHC cases pass the normal research solid parser through group-encode, group-list, and group-decode.',
        'This uses only the fixed development corpus. The holdout corpus is not read.',
        '7-Zip observed entry order is recorded and used for streamed-content verification; physical-order mismatch is explicit while logical listing order remains separately verified.'
    )
}
$reportPath = Join-Path $work 'report.json'
$reportJson = $report | ConvertTo-Json -Depth 15
$reportStream = [IO.File]::Open($reportPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
$reportWriter = [IO.StreamWriter]::new($reportStream, [Text.UTF8Encoding]::new($false))
try { $reportWriter.Write($reportJson) }
finally { $reportWriter.Dispose() }

$sizeComparison | ConvertTo-Json
