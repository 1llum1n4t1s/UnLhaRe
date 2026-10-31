#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkDirectory,
    [Parameter(Mandatory)][ValidateCount(2,16)][string[]]$InputFiles,
    [Parameter(Mandatory)][string]$SevenZipPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force -ErrorAction Stop

function Assert-PlainPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $current = $full
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse point is not permitted: $current"
            }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
    return $full
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Write-NewText([string]$Path, [string]$Text) {
    $null = Assert-PlainPath $Path
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
}

# stdout/stderrは各64KiB、子プロセスは10分で停止。ArgumentListでパスをshellへ渡さない。
function Invoke-BoundedTool([string]$Tool, [string[]]$Arguments, [string]$Label) {
    $null = Assert-PlainPath $Tool
    Assert-KhcStorageContext -WorkDirectory $work
    $info = [Diagnostics.ProcessStartInfo]::new($Tool)
    $info.WorkingDirectory = $work
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    # 子の一時出力も登録work内へ限定する。
    $info.Environment['TEMP'] = $work
    $info.Environment['TMP'] = $work
    $info.Environment['TMPDIR'] = $work
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $captures = @()
    $started = $false
    try {
        if (-not $process.Start()) { throw "Could not start $Label" }
        $started = $true
        foreach ($pipe in @($process.StandardOutput.BaseStream, $process.StandardError.BaseStream)) {
            $buffer = [byte[]]::new(8192)
            $captures += [pscustomobject]@{
                pipe=$pipe; buffer=$buffer; data=[IO.MemoryStream]::new(); done=$false
                pending=$pipe.ReadAsync($buffer, 0, $buffer.Length)
            }
        }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while (-not $process.HasExited -or @($captures | Where-Object { -not $_.done }).Count -gt 0) {
            if ($clock.Elapsed.TotalSeconds -ge 600) { throw "Tool timeout: $Label" }
            foreach ($capture in $captures) {
                if ($capture.done -or -not $capture.pending.IsCompleted) { continue }
                $count = $capture.pending.GetAwaiter().GetResult()
                if ($count -eq 0) { $capture.done = $true; continue }
                if ($capture.data.Length + $count -gt 64KB) { throw "Tool output exceeded 64 KiB: $Label" }
                $capture.data.Write($capture.buffer, 0, $count)
                $capture.pending = $capture.pipe.ReadAsync($capture.buffer, 0, $capture.buffer.Length)
            }
            Start-Sleep -Milliseconds 10
        }
        $process.WaitForExit()
        $stdout = [Text.Encoding]::UTF8.GetString($captures[0].data.ToArray())
        $stderr = [Text.Encoding]::UTF8.GetString($captures[1].data.ToArray())
        Write-NewText (Join-Path $work "$Label.stdout.txt") $stdout
        Write-NewText (Join-Path $work "$Label.stderr.txt") $stderr
        if ($process.ExitCode -ne 0) { throw "$Label exited with $($process.ExitCode); see bounded stdout/stderr in WorkDirectory." }
        return $stdout
    } finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill($true)
            if (-not $process.WaitForExit(10000)) { throw "Could not confirm child termination: $Label" }
        }
        foreach ($capture in $captures) { $capture.data.Dispose() }
        $process.Dispose()
    }
}

$work = Assert-KhcStorageTaskWorkDirectory $WorkDirectory
Assert-KhcStorageContext -WorkDirectory $work
if (Test-Path -LiteralPath $work) { throw 'WorkDirectory must be new.' }
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
foreach ($excludedRoot in @([IO.Path]::GetDirectoryName($repoRoot), (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'), $env:CODEX_HOME)) {
    if (-not $excludedRoot) { continue }
    $excluded = [IO.Path]::GetFullPath($excludedRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ($work.Equals($excluded, [StringComparison]::OrdinalIgnoreCase) -or
        $work.StartsWith($excluded + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'WorkDirectory must be outside the repository and Codex user directory.'
    }
}
$taskPaths = Get-KhcStorageTaskPaths
$lab = Assert-PlainPath (Join-Path $taskPaths.CargoTargetRoot 'release/examples/khc_lab.exe')
$sevenZip = Assert-PlainPath $SevenZipPath
foreach ($tool in @($lab, $sevenZip)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Required prebuilt tool missing: $tool" }
}
$toolRecords = @(@($lab, $sevenZip) | ForEach-Object {
    [ordered]@{path=$_;sha256=(Get-Sha256 $_);file_version=(Get-Item -LiteralPath $_).VersionInfo.FileVersion}
})

# 全入力を検査してから作成する。sourceのSHA、読込snapshotのSHA、copyのSHAを照合する。
$snapshots = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
$total = 16L
$contentBytes = 0L
foreach ($path in $InputFiles) {
    $source = Assert-PlainPath $path
    $item = Get-Item -LiteralPath $source -Force
    if ($item.PSIsContainer -or $item.Length -gt 64MB) { throw "Input must be a regular file <=64 MiB: $source" }
    $name = $item.Name
    if ($name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $name.Length -gt 255 -or
        $name.EndsWith('.') -or $name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)' -or $snapshots.ContainsKey($name)) {
        throw "Unsafe or duplicate ASCII basename: $name"
    }
    $total += 10 + $name.Length + $item.Length
    if ($total -gt 64MB) { throw 'Serialized group exceeds 64 MiB.' }
    $sourceHash = Get-Sha256 $source
    $stream = [IO.File]::Open($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -ne $item.Length) { throw "Source length changed: $source" }
        $data = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $data.Length) {
            $read = $stream.Read($data, $offset, $data.Length - $offset)
            if ($read -eq 0) { throw "Source ended early: $source" }
            $offset += $read
        }
        if ($stream.ReadByte() -ne -1) { throw "Source grew during read: $source" }
    } finally { $stream.Dispose() }
    if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($data)) -cne $sourceHash) {
        throw "Source changed during snapshot: $source"
    }
    $contentBytes += $data.LongLength
    $snapshots.Add($name, [pscustomobject]@{name=$name;source=$source;source_sha256=$sourceHash;data=$data})
}
$names = [string[]]@($snapshots.Keys)
[Array]::Sort($names, [StringComparer]::Ordinal)
# copy/group/archive/extract、5コマンドの上限付き出力、JSONの保守的な事前容量枠。
$projectedBytes = 5L * $total + 2MB
$runRecord = Get-Content -LiteralPath $env:KHC_STORAGE_RUN_RECORD -Raw | ConvertFrom-Json
if ($projectedBytes -gt $runRecord.max_bytes) { throw "Projected work bytes ($projectedBytes) exceed registered run budget ($($runRecord.max_bytes))." }
$null = [IO.Directory]::CreateDirectory($work)
$inputDirectory = Join-Path $work 'inputs'
$null = [IO.Directory]::CreateDirectory($inputDirectory)
$entries = @()
foreach ($name in $names) {
    $entry = $snapshots[$name]
    $copy = Assert-PlainPath (Join-Path $inputDirectory $name)
    $stream = [IO.File]::Open($copy, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($entry.data, 0, $entry.data.Length) } finally { $stream.Dispose() }
    $copyHash = Get-Sha256 $copy
    if ($copyHash -cne $entry.source_sha256) { throw "Copy SHA-256 mismatch: $name" }
    $entries += [ordered]@{name=$name;bytes=$entry.data.LongLength;source=$entry.source;source_sha256=$entry.source_sha256;copy=$copy;copy_sha256=$copyHash}
}
$groupPath = Assert-PlainPath (Join-Path $work 'all.group')
$stream = [IO.File]::Open($groupPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
$writer = [IO.BinaryWriter]::new($stream, [Text.Encoding]::UTF8, $false)
try {
    $writer.Write([byte[]](75,72,83,71,82,80,48,0))
    $writer.Write([uint32]$names.Count)
    $writer.Write([uint32]0)
    foreach ($name in $names) {
        $nameBytes = [Text.Encoding]::UTF8.GetBytes($name)
        $writer.Write([uint16]$nameBytes.Length)
        $writer.Write([uint64]$snapshots[$name].data.LongLength)
        $writer.Write([byte[]]$nameBytes)
    }
    foreach ($name in $names) { $writer.Write([byte[]]$snapshots[$name].data) }
} finally { $writer.Dispose() }
if ((Get-Item -LiteralPath $groupPath).Length -ne $total) { throw 'Group length mismatch.' }
$groupHash = Get-Sha256 $groupPath
Write-NewText (Join-Path $work 'inputs.json') (ConvertTo-Json -Depth 6 -InputObject $entries)

# group-size-screenは固定Canterbury専用。汎用group-benchの最小1反復で全entry往復と決定性を確認する。
$khcArguments = @('group-bench',$groupPath,'--algorithm','beam','--beam-width','2','--beam-block','8192',
    '--beam-model','blended','--beam-matches','bt5','--dictionary-mib','64','--repeats','1')
$khc = Invoke-BoundedTool $lab $khcArguments 'khc-group' | ConvertFrom-Json
if ($khc.input_bytes -ne $total -or $khc.frame_bytes -le 0 -or $khc.algorithm -cne 'Beam' -or
    $khc.beam_width -ne 2 -or $khc.beam_block -ne 8192 -or $khc.beam_model -cne 'Blended' -or
    $khc.beam_matches -cne 'Bt5' -or $khc.dictionary -ne 64MB -or $khc.entropy_backend -cne 'Range' -or
    @($khc.samples).Count -ne 1 -or @($khc.solid_group).Count -ne $names.Count) { throw 'KHC result identity/configuration mismatch.' }
for ($index=0; $index -lt $names.Count; $index++) {
    if ($khc.solid_group[$index].name -cne $names[$index] -or $khc.solid_group[$index].bytes -ne $entries[$index].bytes) {
        throw 'KHC solid entry metadata mismatch.'
    }
}
if ((Get-Sha256 $groupPath) -cne $groupHash) { throw 'Group changed during KHC screen.' }

$versionText = Invoke-BoundedTool $sevenZip @('i') '7z-version'
$archive = Assert-PlainPath (Join-Path $work 'shared-history.7z')
$sevenZipSettings = @('-t7z','-mx=9','-m0=LZMA2:d=64m','-mmt=1','-ms=on','-mqs=off','-mtm=off','-mtc=off','-mta=off')
$archiveArguments = @('a') + $sevenZipSettings + @($archive,'--') + @($entries | ForEach-Object copy)
$null = Invoke-BoundedTool $sevenZip $archiveArguments '7z-create'
$null = Assert-PlainPath $archive
$null = Invoke-BoundedTool $sevenZip @('t',$archive) '7z-test'
$extract = Assert-PlainPath (Join-Path $work 'extracted')
$null = [IO.Directory]::CreateDirectory($extract)
$null = Invoke-BoundedTool $sevenZip @('x',$archive,"-o$extract",'-y') '7z-extract'
$extracted = @(Get-ChildItem -LiteralPath $extract -Force -Recurse)
$extractFiles = @($extracted | Where-Object { -not $_.PSIsContainer })
$extractDirectories = @($extracted | Where-Object { $_.PSIsContainer })
if ($extractFiles.Count -ne $names.Count -or $extractDirectories.Count -ne 0) { throw '7-Zip extracted entry count/path mismatch.' }
foreach ($file in $extractFiles) {
    $null = Assert-PlainPath $file.FullName
    if ($file.DirectoryName -cne $extract -or -not $snapshots.ContainsKey($file.Name) -or
        $file.Name -cne $snapshots[$file.Name].name) { throw '7-Zip extracted unexpected entry name/path.' }
    $expected = $snapshots[$file.Name]
    $actual = [IO.File]::ReadAllBytes($file.FullName)
    if ($file.Length -ne $expected.data.LongLength -or (Get-Sha256 $file.FullName) -cne $expected.source_sha256 -or
        -not [Linq.Enumerable]::SequenceEqual[byte]($actual, [byte[]]$expected.data)) { throw "7-Zip exact content mismatch: $($file.Name)" }
}
foreach ($entry in $entries) {
    if ((Get-Sha256 $entry.copy) -cne $entry.copy_sha256) { throw 'Copied input changed during screen.' }
}
for ($index=0; $index -lt $toolRecords.Count; $index++) {
    if ((Get-Sha256 $toolRecords[$index].path) -cne $toolRecords[$index].sha256) { throw 'Tool changed during screen.' }
}
$report = [ordered]@{
    schema='khc-shared-history-size-screen-v1'; experimental=$true; utc=[DateTime]::UtcNow.ToString('o')
    scope='first-pass size/correctness screen only; no time or memory claim; no superiority claim'
    timing='not evaluated; raw group-bench timing fields are incidental and not comparable to 7-Zip CLI'
    memory='not measured'; script_sha256=(Get-Sha256 $PSCommandPath); tools=$toolRecords
    projected_work_bytes=$projectedBytes; tool_stdout_stderr_limit_each_bytes=64KB; tool_timeout_seconds=600
    seven_zip_version_output=$versionText.Trim(); entries=$entries; content_bytes=$contentBytes
    group=[ordered]@{format='KHSGRP0';order='ordinal ASCII basename';bytes=$total;metadata_bytes=($total-$contentBytes);sha256=$groupHash}
    khc=[ordered]@{arguments=$khcArguments;frame_bytes=$khc.frame_bytes;repeats=1;round_trip_all_entries_and_determinism_verified=$true}
    seven_zip=[ordered]@{arguments=$archiveArguments;archive_bytes=(Get-Item -LiteralPath $archive).Length;archive_sha256=(Get-Sha256 $archive);integrity_verified=$true;exact_names_bytes_sha256_verified=$true}
}
Assert-KhcStorageContext -WorkDirectory $work
$json = $report | ConvertTo-Json -Depth 10
Write-NewText (Join-Path $work 'report.json') $json
Assert-KhcStorageContext -WorkDirectory $work
$json
