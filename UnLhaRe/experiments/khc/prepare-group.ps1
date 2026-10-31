param([Parameter(Mandatory)][string]$WorkDirectory)
# 固定開発集合のみ。外部の書庫や任意パスを展開する入口ではない。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$work = [IO.Path]::GetFullPath($WorkDirectory)
$build = [IO.Path]::GetFullPath((Join-Path $root 'build')) + [IO.Path]::DirectorySeparatorChar
if (-not $work.StartsWith($build, [StringComparison]::OrdinalIgnoreCase)) { throw 'WorkDirectory must be below build.' }
if (Test-Path -LiteralPath $work) { throw 'WorkDirectory must be new.' }
function Assert-NoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point is not a corpus path: $current" }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}
Assert-NoReparse $work
$manifestPath = Join-Path $PSScriptRoot 'CORPUS_MANIFEST.json'
$manifestHash = (Get-FileHash -LiteralPath $manifestPath).Hash
$scriptHash = (Get-FileHash -LiteralPath $PSCommandPath).Hash
$collections = @(Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json | Where-Object name -eq 'canterbury-development')
if ($collections.Count -ne 1 -or $collections[0].files.Count -ne 11) { throw 'Expected fixed development corpus.' }
$entries = @($collections[0].files)
$names = [string[]]@($entries | ForEach-Object name)
[Array]::Sort($names, [StringComparer]::Ordinal)
$snapshots = @()
$total = 16L
$contentBytes = 0L
$previous = $null
foreach ($name in $names) {
    # この作成器は固定ASCII basenameだけを扱う。Rust parserはUTF-8も検証する。
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $name -ceq $previous) { throw 'Invalid or duplicate corpus name.' }
    $previous = $name
    $entry = @($entries | Where-Object { $_.name -ceq $name })
    if ($entry.Count -ne 1 -or $entry[0].bytes -lt 0 -or $entry[0].bytes -gt 64MB) { throw 'Invalid corpus entry.' }
    $path = Join-Path $root "build/khc-corpus/canterbury-development/$name"
    Assert-NoReparse $path
    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -ne $entry[0].bytes) { throw 'Corpus length mismatch.' }
        $bytes = [byte[]]::new([int]$stream.Length)
        $stream.ReadExactly($bytes, 0, $bytes.Length)
        if ($stream.ReadByte() -ne -1) { throw 'Corpus grew during read.' }
    } finally { $stream.Dispose() }
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    if ($hash -ne $entry[0].sha256) { throw "Corpus SHA-256 mismatch: $name" }
    $nameBytes = [Text.Encoding]::UTF8.GetBytes($name)
    if ($nameBytes.Length -gt 255) { throw 'Name too long.' }
    $total += 10 + $nameBytes.Length + $bytes.Length
    $contentBytes += $bytes.Length
    if ($total -gt 64MB) { throw 'Group exceeds codec input limit.' }
    $snapshots += [pscustomobject]@{ name=$name; name_bytes=$nameBytes; data=$bytes; sha256=$hash }
}
if ((Get-FileHash -LiteralPath $manifestPath).Hash -ne $manifestHash) { throw 'Manifest changed.' }
$null = New-Item -ItemType Directory -Path $work
$groupPath = Join-Path $work 'all.group'
$stream = [IO.File]::Open($groupPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
$writer = [IO.BinaryWriter]::new($stream, [Text.Encoding]::UTF8, $false)
try {
    $writer.Write([byte[]](75,72,83,71,82,80,48,0))
    $writer.Write([uint32]$snapshots.Count)
    $writer.Write([uint32]0)
    foreach ($entry in $snapshots) {
        $writer.Write([uint16]$entry.name_bytes.Length)
        $writer.Write([uint64]$entry.data.Length)
        $writer.Write([byte[]]$entry.name_bytes)
    }
    foreach ($entry in $snapshots) { $writer.Write([byte[]]$entry.data) }
} finally { $writer.Dispose() }
if ((Get-Item -LiteralPath $groupPath).Length -ne $total) { throw 'Group length mismatch.' }
$report = [ordered]@{
    status='development solid-group input; not a product archive or final evaluation'
    utc=[DateTime]::UtcNow.ToString('o'); format='KHSGRP0'; order='ordinal ASCII basename'
    group_path=$groupPath; group_bytes=$total; content_bytes=$contentBytes; metadata_bytes=$total-$contentBytes
    group_sha256=(Get-FileHash -LiteralPath $groupPath).Hash
    manifest_sha256=$manifestHash; script_sha256=$scriptHash
    entries=@($snapshots | ForEach-Object { [pscustomobject]@{name=$_.name;bytes=$_.data.Length;sha256=$_.sha256} })
}
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $work 'manifest.json') -Encoding utf8
Write-Host "Prepared $groupPath ($total bytes, $($total-$contentBytes) bytes metadata); all 11 source hashes verified."
