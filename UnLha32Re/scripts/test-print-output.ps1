[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [string[]]$ExtraArchive = @()
)

$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
$archives = @()
foreach ($kind in 'stored', 'compressed') {
    $root = Join-Path $Workspace $kind
    $arguments = @('--registry', '', '--create-memory-selection-fixture', $Oracle, $root)
    if ($kind -eq 'compressed') { $arguments += 'compressed' }
    & $TestProgram @arguments
    if ($LASTEXITCODE -ne 0) { throw "p 出力 fixture を作成できません: $kind" }
    $archives += Join-Path $root 'selection.lzh'
}
# lz4 は lh0 と同じ無圧縮データを使う。形式名だけを変更し、ヘッダー CRC を再計算する。
$lz4 = [IO.File]::ReadAllBytes($archives[0])
$offset = 0
while ($offset + 24 -lt $lz4.Length -and $lz4[$offset] -ne 0) {
    if ($lz4[$offset + 20] -ne 2 -or [Text.Encoding]::ASCII.GetString($lz4, $offset + 2, 5) -ne '-lh0-') {
        throw 'lz4 用の元データが level 2 の lh0 ではありません。'
    }
    $size = [BitConverter]::ToUInt16($lz4, $offset)
    $packed = [BitConverter]::ToUInt32($lz4, $offset + 7)
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('-lz4-'), 0, $lz4, $offset + 2, 5)
    $extension = $offset + 24
    $crcOffset = -1
    while ($extension + 2 -lt $offset + $size) {
        $length = [BitConverter]::ToUInt16($lz4, $extension)
        if ($length -eq 0) { break }
        if ($length -lt 3 -or $extension + $length -gt $offset + $size) { throw '拡張ヘッダーが不正です。' }
        if ($lz4[$extension + 2] -eq 0) { $crcOffset = $extension + 3 }
        $extension += $length
    }
    if ($crcOffset -lt 0) { throw 'ヘッダー CRC が見つかりません。' }
    $lz4[$crcOffset] = $lz4[$crcOffset + 1] = 0
    $crc = 0
    foreach ($value in $lz4[$offset..($offset + $size - 1)]) {
        $crc = $crc -bxor $value
        foreach ($bit in 0..7) {
            $crc = if ($crc -band 1) { ($crc -shr 1) -bxor 0xa001 } else { $crc -shr 1 }
        }
    }
    $lz4[$crcOffset] = [byte]($crc -band 255)
    $lz4[$crcOffset + 1] = [byte](($crc -shr 8) -band 255)
    $offset += $size + $packed
}
$lz4Path = Join-Path $Workspace 'lz4.lzh'
[IO.File]::WriteAllBytes($lz4Path, $lz4)
$archives += $lz4Path
$archives += @($ExtraArchive | ForEach-Object { (Resolve-Path -LiteralPath $_).Path })
# 他形式として拒否された場合はデータでなくエラーを返す。判定解除も同じ入力で試す。
$foreignSource = [IO.File]::ReadAllBytes($archives[0])
$foreign = $foreignSource + [byte[]](0x50, 0x4b, 0x01, 0x02) +
    [BitConverter]::GetBytes([uint32]$foreignSource.Length) + [byte[]](0, 0)
$foreignArchive = Join-Path $Workspace 'foreign-tail.lzh'
[IO.File]::WriteAllBytes($foreignArchive, $foreign)
$archives += $foreignArchive
$checks = 0
$safetyChecks = 0
foreach ($archive in $archives) {
    foreach ($api in 'legacy', 'A', 'W') {
        foreach ($utf8 in $false, $true) {
            foreach ($capacity in 0, 1, 3, 4, 8, 38, 64, 256) {
                foreach ($option in '', '-jsg0') {
                    $command = 'p -gm1 ' + $option + ' "' + $archive + '"'
                    $arguments = @('--registry', '', '--command-raw-probe', $Oracle,
                        $command, $api, [string]$capacity)
                    if ($utf8) { $arguments += 'utf8' }
                    $expected = @(& $TestProgram @arguments)
                    $originalExit = $LASTEXITCODE
                    $arguments[3] = $Candidate
                    $actual = @(& $TestProgram @arguments)
                    $candidateExit = $LASTEXITCODE
                    if ($originalExit -ne 0 -or $candidateExit -ne 0 -or
                        $expected.Count -ne 1 -or $actual.Count -ne 1) {
                        throw "p 出力試験が実行できません: $archive / $api / $capacity / exits=$originalExit,$candidateExit"
                    }
                    $rejected = $archive -eq $foreignArchive -and $option -eq ''
                    if ($capacity -eq 0 -and !$utf8 -and $api -ne 'W' -and !$rejected) {
                        # 原版は ANSI 変換時に出力直前へ NUL を書く。前後のガード内で
                        # 位置を確認し、候補はこの範囲外書き込みを再現しないと検証する。
                        $expectedParts = $expected[0] -split ',raw=', 2
                        $actualParts = $actual[0] -split ',raw=', 2
                        $expectedRaw = @(($expectedParts[1] -split ',') | Where-Object { $_ -ne '' })
                        $actualRaw = @(($actualParts[1] -split ',') | Where-Object { $_ -ne '' })
                        if ($expectedParts[0] -ne $actualParts[0] -or $expectedRaw.Count -ne 16 -or
                            $actualRaw.Count -ne 16 -or $expectedRaw[7] -ne '0' -or
                            @($expectedRaw | Where-Object { $_ -ne 'cc' -and $_ -ne '0' }).Count -ne 0 -or
                            @($expectedRaw | Where-Object { $_ -eq '0' }).Count -ne 1 -or
                            @($actualRaw | Where-Object { $_ -ne 'cc' }).Count -ne 0) {
                            throw "p 容量 0 の安全性境界が想定外です: $archive / $api / $option"
                        }
                        $safetyChecks++
                        continue
                    }
                    $difference = @(Compare-Object $expected $actual -SyncWindow 0)
                    if ($difference.Count -ne 0) {
                        throw "p 出力が不一致: $archive / $api / UTF8=$utf8 / $capacity / $option`n$($difference | Out-String -Width 3000)"
                    }
                    $checks++
                }
            }
        }
    }
}
Write-Host "Print output: $checks A/W/legacy/UTF-8/capacity cases compatible, $safetyChecks zero-capacity guard checks safe"

# 終端処理はコマンド共通。ここでは終端と範囲外だけを検査し、p 以外の
# 最初の NUL より後に残るログ内容まで一致したとは扱わない。
$terminationChecks = 0
$commands = @(
    ('l -n1 -gm1 "' + $archives[0] + '"'),
    ('t -gm1 "' + $archives[0] + '"'),
    'p -gm1',
    ('p -gm1 "' + $archives[0] + '.missing"')
)
foreach ($command in $commands) {
    foreach ($api in 'legacy', 'A', 'W') {
        foreach ($utf8 in $false, $true) {
            foreach ($capacity in 0, 1, 32, 1024) {
                $rows = @()
                foreach ($dll in $Oracle, $Candidate) {
                    $arguments = @('--registry', '', '--command-raw-probe', $dll,
                        $command, $api, [string]$capacity)
                    if ($utf8) { $arguments += 'utf8' }
                    $row = @(& $TestProgram @arguments)
                    if ($LASTEXITCODE -ne 0 -or $row.Count -ne 1) {
                        throw "コマンド終端試験が実行できません: $command / $api / $capacity"
                    }
                    $rows += $row[0]
                    $raw = @(($row[0] -split ',raw=', 2)[1] -split ',' | Where-Object { $_ -ne '' })
                    $fill = if ($api -eq 'W') { 'cccc' } else { 'cc' }
                    $guards = @($raw[0..7]) + @($raw[($capacity + 8)..($capacity + 15)])
                    if ($raw.Count -ne $capacity + 16 -or
                        @($guards | Where-Object { $_ -ne $fill }).Count -ne 0 -or
                        ($capacity -gt 0 -and $raw[$capacity + 7] -ne '0')) {
                        throw "コマンド出力の終端・範囲外が不一致です: $command / $api / $capacity"
                    }
                }
                if (($rows[0] -split ',raw=', 2)[0] -cne ($rows[1] -split ',raw=', 2)[0]) {
                    throw "コマンド終端試験の戻り値・エラーが不一致です: $command / $api / $capacity"
                }
                $terminationChecks++
            }
        }
    }
}
Write-Host "Command termination: $terminationChecks A/W/legacy success/failure return-state and buffer-boundary checks compatible"
