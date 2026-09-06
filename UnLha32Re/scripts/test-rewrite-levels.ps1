[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
$runner = Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe'
if (Test-Path -LiteralPath $Workspace) { throw '書き換えレベル試験には新しい作業先が必要です。' }
New-Item -ItemType Directory -Path $Workspace | Out-Null
$binaryHashes = @{}
foreach ($path in $TestProgram,$Oracle,$Candidate) { $binaryHashes[$path] = (Get-FileHash -LiteralPath $path).Hash }

function Invoke-Rewrite([string]$Dll, [string]$Api, [string]$Command, [string]$Log) {
    $probe = if ($Api -eq 'W') { '--command-probe' } else { '--command-probe-a' }
    $arguments = @('--registry', '', $probe, $Dll, $Command)
    if ($Api -eq 'A') { $arguments += 'A' }
    $rows = @(& $runner --timeout-seconds 30 $TestProgram @arguments 2>&1 |
        ForEach-Object { "$_" } | Tee-Object -FilePath $Log)
    if ($LASTEXITCODE -ne 0 -or $rows -notcontains 'result=0') {
        throw "書き換えレベル試験の呼び出しが失敗しました: $Command / $($rows -join ' / ')"
    }
    return $rows
}

function Assert-StoredMembers([byte[]]$Bytes, [int[]]$Levels) {
    $offset = 0
    foreach ($level in $Levels) {
        if ($offset + 24 -gt $Bytes.Length -or $Bytes[$offset + 20] -ne $level -or
            [Text.Encoding]::ASCII.GetString($Bytes, $offset + 2, 5) -cne '-lh0-' -or
            [BitConverter]::ToUInt32($Bytes, $offset + 11) -ne 64) {
            throw '書庫メンバーのレベル・方式・サイズが不正です。'
        }
        $packed = [BitConverter]::ToUInt32($Bytes, $offset + 7)
        $headerSize = if ($level -eq 2) { [BitConverter]::ToUInt16($Bytes, $offset) } else { [int]$Bytes[$offset] + 2 }
        $end = $offset + $headerSize + $packed
        # level 1 の packed は拡張ヘッダーを含む。格納方式の本文は常に末尾の 64 バイト。
        if ($end -ge $Bytes.Length -or $end - 64 -lt $offset + $headerSize) { throw '書庫の境界が不正です。' }
        for ($index = $end - 64; $index -lt $end; $index++) {
            if ($Bytes[$index] -ne 65) { throw '格納本文が元入力と一致しません。' }
        }
        $offset = $end
    }
    if ($offset -ne $Bytes.Length - 1 -or $Bytes[$offset] -ne 0) { throw '書庫の終端が不正です。' }
}

function Get-RewriteCrc([byte[]]$Bytes, [int]$Length) {
    [uint32]$crc = 0
    for ($index = 0; $index -lt $Length; $index++) {
        $crc = $crc -bxor $Bytes[$index]
        for ($bit = 0; $bit -lt 8; $bit++) {
            $crc = if ($crc -band 1) { ($crc -shr 1) -bxor 0xa001 } else { $crc -shr 1 }
        }
    }
    return [uint16]$crc
}

New-Item -ItemType Directory -Path (Join-Path $Workspace 'folder') | Out-Null
$inputPath = Join-Path $Workspace 'folder/input.txt'
[IO.File]::WriteAllText($inputPath, ('A' * 64), [Text.UTF8Encoding]::new($false))
$inputFile = Get-Item -LiteralPath $inputPath
$inputFile.CreationTimeUtc = [datetime]'2024-01-02T03:04:06Z'
$inputFile.LastWriteTimeUtc = [datetime]'2024-01-02T03:04:06Z'
$inputFile.LastAccessTimeUtc = [datetime]'2024-01-02T03:04:06Z'
$seeds = @{}
foreach ($level in 0..2) {
    $seeds[$level] = Join-Path $Workspace "seed-l$level.lzh"
    Invoke-Rewrite $Oracle W ('a -gm1 -y1 -jm0 -x1 -h' + $level + ' "' + $seeds[$level] + '" "' + $Workspace + '/" folder/input.txt') (Join-Path $Workspace "seed-l$level.log") | Out-Null
    Assert-StoredMembers ([IO.File]::ReadAllBytes($seeds[$level])) @($level)
}
$unixSeeds = @{}
foreach ($level in 1,2) {
    # 上流の空 UNIX メンバーに本文を付け、圧縮方式・サイズ・本文 CRC・ヘッダー検査値を更新する。
    $template = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot "../sample/lha-master/tests/lha-test16-l$level.lzh"))
    if ($template.Length -ne 55 -or $template[20] -ne $level) { throw 'UNIX テンプレートの構造が変わっています。' }
    $bytes = [byte[]]::new(119)
    [Array]::Copy($template, $bytes, 54)
    for ($index = 54; $index -lt 118; $index++) { $bytes[$index] = 65 }
    $bytes[5] = 48
    $packed = if ($level -eq 1) { 83 } else { 64 }
    [BitConverter]::GetBytes([uint32]$packed).CopyTo($bytes, 7)
    [BitConverter]::GetBytes([uint32]64).CopyTo($bytes, 11)
    $crcOffset = if ($level -eq 1) { 22 + $bytes[21] } else { 21 }
    [BitConverter]::GetBytes((Get-RewriteCrc ([IO.File]::ReadAllBytes($inputPath)) 64)).CopyTo($bytes, $crcOffset)
    if ($level -eq 1) {
        $sum = 0
        for ($index = 2; $index -lt $bytes[0] + 2; $index++) { $sum = ($sum + $bytes[$index]) -band 255 }
        $bytes[1] = $sum
    } else {
        $bytes[27] = 0; $bytes[28] = 0
        [BitConverter]::GetBytes((Get-RewriteCrc $bytes 54)).CopyTo($bytes, 27)
    }
    $unixSeeds[$level] = Join-Path $Workspace "unix-l$level.lzh"
    [IO.File]::WriteAllBytes($unixSeeds[$level], $bytes)
    Assert-StoredMembers $bytes @($level)
    Invoke-Rewrite $Oracle W ('t -gm1 "' + $unixSeeds[$level] + '"') (Join-Path $Workspace "unix-l$level-check.log") | Out-Null
}
$pairs = 0
foreach ($origin in 'windows','unix') {
    $sourceSeeds = if ($origin -eq 'windows') { $seeds } else { $unixSeeds }
    $sourceLevels = if ($origin -eq 'windows') { @(0,1,2) } else { @(1,2) }
foreach ($api in 'legacy','A','W') {
    foreach ($kind in 'join-new','join-existing','rename','convert-control') {
        foreach ($level in $sourceLevels) {
            $options = @('default','h0','h1','h2')
            foreach ($option in $options) {
                $outputs = @{}
                $logs = @{}
                foreach ($side in 'oracle','candidate') {
                    # 同じ長さのパスを使い、ANSI の output-length も無補正で比較する。
                    $suffix = if ($side -eq 'oracle') { 'oracle' } else { 'reimpl' }
                    $folder = Join-Path $Workspace "$origin-$api-$kind-l$level-$option-$suffix"
                    New-Item -ItemType Directory -Path $folder | Out-Null
                    $source = Join-Path $folder 'source.lzh'
                    Copy-Item -LiteralPath $sourceSeeds[$level] -Destination $source
                    $destination = if ($kind.StartsWith('join')) { Join-Path $folder 'joined.lzh' } else { $source }
                    $oldLevel = ($level + 1) % 3
                    if ($kind -eq 'join-existing') { Copy-Item -LiteralPath $seeds[$oldLevel] -Destination $destination }
                    $command = if ($kind.StartsWith('join')) { 'j' } elseif ($kind -eq 'rename') { 'n' } else { 'y' }
                    $line = $command + ' -gm1 -y1 '
                    if ($option -ne 'default') { $line += '-' + $option + ' ' }
                    $line += '"' + $destination + '"'
                    if ($command -eq 'j') { $line += ' "' + $source + '"' } else { $line += ' *' }
                    if ($command -eq 'n') { $line += ' -grrenamed' }
                    $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
                    $rows = @(Invoke-Rewrite $dll $api $line (Join-Path $folder 'command.log'))
                    $logs[$side] = @($rows | ForEach-Object { $_.Replace($folder.Replace('\','/'), '<ROOT>') })
                    $bytes = [IO.File]::ReadAllBytes($destination)
                    $outputLevel = if ($command -eq 'y') { if ($option -eq 'default') { 2 } else { [int]::Parse($option.Substring(1)) } } else { $level }
                    $levels = if ($kind -eq 'join-existing') { @($oldLevel,$level) } else { @($outputLevel) }
                    Assert-StoredMembers $bytes $levels
                    $outputs[$side] = [Convert]::ToHexString($bytes)
                    if ($command -eq 'j' -and (Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $sourceSeeds[$level]).Hash) {
                        throw '連結元が変更されました。'
                    }
                }
                if ($outputs.oracle -cne $outputs.candidate) { throw "書庫全バイトが一致しません: $api/$kind/$level/$option" }
                if (@(Compare-Object $logs.oracle $logs.candidate -SyncWindow 0).Count) { throw "ログ・終了状態が一致しません: $api/$kind/$level/$option" }
                $pairs++
            }
        }
    }
    Write-Host "Rewrite levels: $origin/$api passed, $pairs exact archive pairs so far"
}
}
foreach ($path in $binaryHashes.Keys) {
    if ((Get-FileHash -LiteralPath $path).Hash -ne $binaryHashes[$path]) { throw '検証中に実行バイナリが変更されました。' }
}
if ($pairs -ne 240) { throw '書き換えレベル試験の件数が不正です。' }
Write-Host 'Rewrite levels: 240 exact archive and command-output pairs; Windows/UNIX metadata, j/n source levels, y conversions, stored payloads, terminators, and join inputs passed'
