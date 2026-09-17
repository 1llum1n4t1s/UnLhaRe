[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace
)

$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$runner = Join-Path (Split-Path $TestProgram) 'DesktopRunner.exe'
$Workspace = [IO.Path]::GetFullPath($Workspace)
if (Test-Path -LiteralPath $Workspace) { throw '新しい試験領域が必要です。' }
New-Item -ItemType Directory -Path $Workspace | Out-Null

function Get-LhaCrc([byte[]]$Bytes) {
    [uint32]$crc = 0
    foreach ($value in $Bytes) {
        $crc = $crc -bxor $value
        for ($bit = 0; $bit -lt 8; ++$bit) {
            $crc = if ($crc -band 1) { ($crc -shr 1) -bxor 0xa001 } else { $crc -shr 1 }
        }
    }
    return [uint16]$crc
}

function Write-Level0Fixture([string]$Path, [string]$Name, [byte[]]$Body) {
    [byte[]]$leaf = [Text.Encoding]::ASCII.GetBytes($Name)
    [byte[]]$header = @(0, 0) + [Text.Encoding]::ASCII.GetBytes('-lh0-') +
        [BitConverter]::GetBytes([uint32]$Body.Length) + [BitConverter]::GetBytes([uint32]$Body.Length) +
        [byte[]]@(0, 0, 0, 0, 32, 0, $leaf.Length) + $leaf +
        [BitConverter]::GetBytes((Get-LhaCrc $Body))
    $header[0] = $header.Length - 2
    $sum = 0
    foreach ($value in $header[2..($header.Length - 1)]) { $sum = ($sum + $value) -band 255 }
    $header[1] = $sum
    [IO.File]::WriteAllBytes($Path, [byte[]]($header + $Body + [byte[]]@(0)))
}

# OpenArchive は拡張ヘッダーの上限違反を DLL のエラーへ閉じ込め、ホストを終了させない。
$oversized = Join-Path $Workspace 'oversized-extension.lzh'
[byte[]]$bytes = New-Object byte[] 5027
[BitConverter]::GetBytes([uint16]5026).CopyTo($bytes, 0)
[Text.Encoding]::ASCII.GetBytes('-lh0-').CopyTo($bytes, 2)
$bytes[19] = 32
$bytes[20] = 2
[BitConverter]::GetBytes([uint16]5000).CopyTo($bytes, 24)
$bytes[26] = 1
[IO.File]::WriteAllBytes($oversized, $bytes)
$openRows = @(& $runner --timeout-seconds 20 $TestProgram $Candidate $oversized)
if ($LASTEXITCODE -ne 0 -or $openRows -notcontains 'open=0') {
    throw '巨大拡張ヘッダーで OpenArchive のホストが終了しました。'
}

# Windows の予約デバイス名は、拡張子付きでも通常の展開先として開かない。
$deviceRoot = Join-Path $Workspace 'devices'
New-Item -ItemType Directory -Path $deviceRoot | Out-Null
[byte[]]$payload = @(0x73, 0x61, 0x66, 0x65)
foreach ($name in 'CON', 'CON.txt', 'NUL.dat', 'AUX', 'PRN.log', 'COM1.bin', 'LPT9') {
    $caseRoot = Join-Path $deviceRoot ($name.Replace('.', '-'))
    $output = Join-Path $caseRoot 'out'
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $archive = Join-Path $caseRoot 'input.lzh'
    Write-Level0Fixture $archive $name $payload
    $command = 'x -y1 -n1 -gm1 "' + $archive + '" "' + $output.Replace('\', '/') + '/"'
    $rows = @(& $runner --timeout-seconds 20 $TestProgram --command-probe $Candidate $command)
    if ($LASTEXITCODE -ne 0 -or $rows -contains 'result=0' -or
        @(Get-ChildItem -LiteralPath $output -Force).Count -ne 0) {
        throw "予約デバイス名を展開しました: $name / $($rows -join ';')"
    }
}
foreach ($name in 'CONX.txt', 'COM10.bin') {
    $caseRoot = Join-Path $deviceRoot ($name.Replace('.', '-'))
    $output = Join-Path $caseRoot 'out'
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $archive = Join-Path $caseRoot 'input.lzh'
    Write-Level0Fixture $archive $name $payload
    $command = 'x -y1 -n1 -gm1 "' + $archive + '" "' + $output.Replace('\', '/') + '/"'
    $rows = @(& $runner --timeout-seconds 20 $TestProgram --command-probe $Candidate $command)
    if ($LASTEXITCODE -ne 0 -or $rows -notcontains 'result=0' -or
        -not (Test-Path -LiteralPath (Join-Path $output $name))) {
        throw "通常名の展開を拒否しました: $name / $($rows -join ';')"
    }
}

# 32 ビット時刻が負値へ見える level-2 項目も、一覧表示で localtime を参照しない。
$listArchive = Join-Path $Workspace 'negative-list-time.lzh'
[byte[]]$listName = [Text.Encoding]::ASCII.GetBytes('future.txt')
$extensionSize = 1 + $listName.Length + 2
$headerSize = 26 + $extensionSize
[byte[]]$listBytes = New-Object byte[] ($headerSize + 1)
[BitConverter]::GetBytes([uint16]$headerSize).CopyTo($listBytes, 0)
[Text.Encoding]::ASCII.GetBytes('-lh0-').CopyTo($listBytes, 2)
[BitConverter]::GetBytes([Convert]::ToUInt32('ffffffff', 16)).CopyTo($listBytes, 15)
$listBytes[19] = 32
$listBytes[20] = 2
$listBytes[23] = [byte][char]'M'
[BitConverter]::GetBytes([uint16]$extensionSize).CopyTo($listBytes, 24)
$listBytes[26] = 1
$listName.CopyTo($listBytes, 27)
[IO.File]::WriteAllBytes($listArchive, $listBytes)
foreach ($commandName in 'l', 'v') {
    $listCommand = $commandName + ' -gm1 "' + $listArchive + '"'
    $rows = @(& $runner --timeout-seconds 20 $TestProgram --command-probe $Candidate $listCommand)
    if ($LASTEXITCODE -ne 0 -or @($rows -match '^result=').Count -ne 1) {
        throw "範囲外日時の一覧表示に失敗しました: $commandName / $($rows -join ';')"
    }
}

# level 0/1 の DOS 日時は表現範囲へ固定し、localtime の範囲外でもクラッシュしない。
$timeRoot = Join-Path $Workspace 'times'
New-Item -ItemType Directory -Path $timeRoot | Out-Null
$source = Join-Path $timeRoot 'source.txt'
[IO.File]::WriteAllText($source, 'time')
$timeCases = @(
    @{ Name = 'minimum'; Time = [datetime]'1960-01-01T00:00:00Z'; Stamp = [uint32]0 },
    @{ Name = 'maximum'; Time = [datetime]'2200-01-01T00:00:00Z'; Stamp = [Convert]::ToUInt32('ff9fbf7d', 16) }
)
foreach ($case in $timeCases) {
    foreach ($level in 0, 1) {
        [IO.File]::SetLastWriteTimeUtc($source, $case.Time)
        $archive = Join-Path $timeRoot ($case.Name + '-h' + $level + '.lzh')
        $command = 'a -h' + $level + ' -y1 -gm1 "' + $archive + '" "' + $source + '"'
        $rows = @(& $runner --timeout-seconds 20 $TestProgram --command-probe $Candidate $command)
        if ($LASTEXITCODE -ne 0 -or $rows -notcontains 'result=0' -or
            -not (Test-Path -LiteralPath $archive)) {
            throw "範囲外日時の圧縮に失敗しました: $($case.Name)/h$level / $($rows -join ';')"
        }
        [byte[]]$archiveBytes = [IO.File]::ReadAllBytes($archive)
        if ($archiveBytes.Length -lt 21 -or $archiveBytes[20] -ne $level -or
            [BitConverter]::ToUInt32($archiveBytes, 15) -ne $case.Stamp) {
            throw "DOS 日時のクランプ結果が不正です: $($case.Name)/h$level"
        }
    }
}

Write-Host 'Untrusted input safety: oversized extension, 7 reserved devices, 2 boundary names, 2 listing, and 4 DOS timestamp cases passed'
