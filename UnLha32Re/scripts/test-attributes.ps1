[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [Parameter(Mandatory)][string]$Archive
)

$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
$source = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Archive).Path)
$headerSize = [BitConverter]::ToUInt16($source, 0)
$packedSize = [BitConverter]::ToUInt32($source, 7)
if ($source[20] -ne 2 -or [Text.Encoding]::ASCII.GetString($source, 2, 5) -ne '-lh0-' -or
    $packedSize -ne 3 -or $headerSize + $packedSize -ge $source.Length) {
    throw '属性 fixture には先頭項目が 3 バイトの level-2 lh0 書庫が必要です。'
}

function Invoke-AttributeProbe([string]$Dll, [string[]]$Arguments, [string]$Settings = '') {
    $rows = @(& $TestProgram --registry $Settings $Arguments[0] $Dll $Arguments[1..($Arguments.Count - 1)])
    if ($LASTEXITCODE -ne 0 -or $rows.Count -eq 0) {
        throw "属性試験を実行できません: $Dll / $($Arguments -join ' ')"
    }
    return $rows
}

function Assert-AttributeEqual([object[]]$Expected, [object[]]$Actual, [string]$Label) {
    $difference = @(Compare-Object $Expected $Actual -SyncWindow 0)
    if ($difference.Count -ne 0) {
        $details = $difference | Select-Object -First 6 | ForEach-Object {
            $side = if ($_.SideIndicator -eq '<=') { 'original' } else { 'candidate' }
            "$side`: $($_.InputObject)"
        } | Out-String -Width 1000
        throw "属性が一致しません: $Label`n$details"
    }
}

function Get-AttributeDiskSnapshot([string]$Directory) {
    foreach ($file in (Get-ChildItem -LiteralPath $Directory -File -Recurse -Force | Sort-Object FullName)) {
        $name = [IO.Path]::GetRelativePath($Directory, $file.FullName)
        "file=$name,attributes=$([int]$file.Attributes),size=$($file.Length),time=$($file.LastWriteTimeUtc.Ticks),hash=$((Get-FileHash -LiteralPath $file.FullName).Hash)"
    }
}

function Test-AttributeSelection([string]$Archive, [string]$Label, [string]$Command,
    [string]$Options, [string]$State = 'missing', [string]$Layout = '', [int]$Selected = 1) {
    $results = @()
    foreach ($side in 'original', 'candidate') {
        $dll = if ($side -eq 'original') { $Oracle } else { $Candidate }
        $destination = Join-Path $Workspace "selection-$Label-$side"
        New-Item -ItemType Directory -Path $destination | Out-Null
        if ($State -ne 'missing') {
            $path = Join-Path $destination 'a.txt'
            [IO.File]::WriteAllBytes($path, [byte[]](70, 71))
            $year = if ($State -eq 'newer') { 2025 } else { 2020 }
            [IO.File]::SetLastWriteTimeUtc($path, [datetime]::new($year, 1, 1, 0, 0, 0, [DateTimeKind]::Utc))
            if ($State -eq 'protected') { [IO.File]::SetAttributes($path, [IO.FileAttributes]::ReadOnly) }
        }
        $line = "$Command -gm1 -y1 $Options `"$Archive`" `"$destination\`" a.txt"
        $arguments = if ($Layout) { @('--command-enum-probe', $line, $Layout, "$Selected") }
            else { @('--command-probe', $line) }
        $rows = @(Invoke-AttributeProbe $dll $arguments)
        if ($rows -notcontains 'result=0') { throw "属性による選択試験に失敗しました: $Label / $side" }
        $rows = @($rows | ForEach-Object {
            $_.Replace($destination.Replace('\', '/'), '<DEST>').Replace($destination.Replace('\', '\\'), '<DEST>')
        })
        $rows += @(Get-AttributeDiskSnapshot $destination)
        $results += ,$rows
    }
    Assert-AttributeEqual $results[0] $results[1] "selection / $Label"
}

function New-AttributeFixture([int]$Os, [int]$Attribute, [int]$Level, [int]$UnixMode) {
    if ($Level -eq 0) {
        [byte[]]$bytes = $source[0..20] + [byte[]](5) + [Text.Encoding]::ASCII.GetBytes('a.txt') +
            $source[21..22] + $source[$headerSize..($headerSize + $packedSize - 1)] + [byte[]](0)
        $bytes[0] = 27
        $bytes[19] = [byte]$Attribute
        $bytes[20] = 0
        [Array]::Copy([BitConverter]::GetBytes([uint32]0x58226083), 0, $bytes, 15, 4)
        $checksum = 0
        foreach ($value in $bytes[2..28]) { $checksum += $value }
        $bytes[1] = [byte]($checksum -band 255)
    } else {
        [byte[]]$extensions = [byte[]](5, 0, 0x40) + [BitConverter]::GetBytes([uint16]$Attribute)
        if ($UnixMode -ge 0) {
            $extensions += [byte[]](5, 0, 0x50) + [BitConverter]::GetBytes([uint16]$UnixMode)
        }
        [byte[]]$bytes = $source[0..($headerSize - 3)] + $extensions +
            $source[($headerSize - 2)..($headerSize + $packedSize - 1)] + [byte[]](0)
        $newSize = $headerSize + $extensions.Length
        [Array]::Copy([BitConverter]::GetBytes([uint16]$newSize), 0, $bytes, 0, 2)
        $bytes[23] = [byte]$Os
        $extension = 24
        $crcOffset = -1
        while ($extension + 2 -lt $newSize) {
            $length = [BitConverter]::ToUInt16($bytes, $extension)
            if ($length -eq 0) { break }
            if ($length -lt 3 -or $extension + $length -gt $newSize) { throw '拡張ヘッダーが不正です。' }
            if ($bytes[$extension + 2] -eq 0) { $crcOffset = $extension + 3 }
            $extension += $length
        }
        if ($crcOffset -lt 0) { throw 'ヘッダー CRC が見つかりません。' }
        $bytes[$crcOffset] = $bytes[$crcOffset + 1] = 0
        $crc = 0
        foreach ($value in $bytes[0..($newSize - 1)]) {
            $crc = $crc -bxor $value
            foreach ($bit in 0..7) {
                $crc = if ($crc -band 1) { ($crc -shr 1) -bxor 0xa001 } else { $crc -shr 1 }
            }
        }
        $bytes[$crcOffset] = [byte]($crc -band 255)
        $bytes[$crcOffset + 1] = [byte](($crc -shr 8) -band 255)
    }
    $name = "os-$Os-attr-$Attribute-level-$Level-mode-$UnixMode.lzh"
    $path = Join-Path $Workspace $name
    [IO.File]::WriteAllBytes($path, $bytes)
    return $path
}

$cases = [Collections.Generic.List[object]]::new()
function Add-AttributeCase([int]$Os, [int]$Attribute, [int]$Level = 2, [int]$UnixMode = -1) {
    $cases.Add([pscustomobject]@{ Os=$Os; Attribute=$Attribute; Level=$Level; UnixMode=$UnixMode })
}
$normalAttributes = @(0..7) + @(32..39)
foreach ($os in 77, 50, 87, 119, 85) {
    foreach ($attribute in $normalAttributes) { Add-AttributeCase $os $attribute }
}
foreach ($os in 77, 85) {
    foreach ($attribute in 8, 15, 16, 17, 18, 23, 48, 49, 55, 128, 288, 32803, 65535) {
        Add-AttributeCase $os $attribute
    }
}
foreach ($os in 0, 51, 72, 57, 75, 65, 74, 67, 70, 82, 83, 84, 255) {
    foreach ($attribute in 0, 35) { Add-AttributeCase $os $attribute }
}
foreach ($attribute in $normalAttributes) { Add-AttributeCase 0 $attribute 0 }
foreach ($mode in 0, 0x81a4, 0x8124, 0x41ed, 0x416d, 0xa1ff) {
    foreach ($os in 85, 0, 77, 72) { Add-AttributeCase $os 35 2 $mode }
}

$snapshots = 0
$enumFields = 0
$diskChecks = 0
$progressSnapshots = 0
$selectionChecks = 0
$readChecks = 0
foreach ($case in $cases) {
    $archive = New-AttributeFixture $case.Os $case.Attribute $case.Level $case.UnixMode
    $expected = @(Invoke-AttributeProbe $Oracle @('--attribute-probe', $archive))
    $actual = @(Invoke-AttributeProbe $Candidate @('--attribute-probe', $archive))
    if ($expected.Count -ne 6) { throw "属性 fixture の項目数が不正です: $archive" }
    Assert-AttributeEqual $expected $actual $archive
    $snapshots += $expected.Count

    $command = 'l -gm1 -a1 "' + $archive + '"'
    $expected = @(Invoke-AttributeProbe $Oracle @('--command-probe', $command))
    $actual = @(Invoke-AttributeProbe $Candidate @('--command-probe', $command))
    Assert-AttributeEqual $expected $actual "list / $archive"

    # 列挙通知の属性値と登録・解除・件数を確認する。他の通知フィールドは
    # 既存の列挙試験で比較し、特殊 OS の時刻差を属性の一致に含めない。
    $enumRows = @()
    foreach ($dll in $Oracle, $Candidate) {
        $rows = @(Invoke-AttributeProbe $dll @('--enum-probe', $archive) 'C:ExtractAttribute=1')
        $values = @($rows | ForEach-Object {
            if ($_ -match '^([^=]+\.entry\d+)=.*attributes=(\d+),') { "$($Matches[1])=$($Matches[2])" }
            elseif ($_ -notmatch '\.entry\d+=') { $_ }
        })
        if ($values.Count -ne 20) { throw "列挙通知の件数が不正です: $archive" }
        $enumRows += ,$values
    }
    Assert-AttributeEqual $enumRows[0] $enumRows[1] "enum / $archive"
    $enumFields += 4

    if ($case.Os -ne 77 -or $case.Level -ne 2 -or $case.UnixMode -ne -1 -or
        $case.Attribute -notin $normalAttributes) { continue }
    foreach ($mode in 0, 1, 2) {
        foreach ($api in 'legacy', 'A', 'W') {
          foreach ($command in 'e', 'x') {
            $diskRows = @()
            foreach ($side in 'original', 'candidate') {
                $dll = if ($side -eq 'original') { $Oracle } else { $Candidate }
                $destination = Join-Path $Workspace "disk-$($case.Attribute)-$mode-$api-$command-$side"
                New-Item -ItemType Directory -Path $destination | Out-Null
                $line = "$command -gm1 -y1 -a$mode `"$archive`" `"$destination\`""
                $arguments = if ($api -eq 'W') { @('--command-probe', $line) }
                    elseif ($api -eq 'A') { @('--command-probe-a', $line, 'A') }
                    else { @('--command-probe-a', $line) }
                $rows = @(Invoke-AttributeProbe $dll $arguments)
                if ($rows[0] -ne 'result=0') { throw "属性付き展開に失敗しました: $archive / $api / $mode / $side" }
                $rows += @(Get-AttributeDiskSnapshot $destination)
                $diskRows += ,$rows
            }
            Assert-AttributeEqual $diskRows[0] $diskRows[1] "disk / $archive / $api / $mode / $command"
            $diskChecks++
          }
        }
    }
    if ($case.Attribute -in 0, 1, 34, 39) {
        foreach ($mode in 0, 1) {
            $root = Join-Path $Workspace "progress-$($case.Attribute)-$mode"
            New-Item -ItemType Directory -Path $root | Out-Null
            $expected = @(Invoke-AttributeProbe $Oracle @('--progress-probe', $archive, (Join-Path $root 'original')) "C:ExtractAttribute=$mode")
            $actual = @(Invoke-AttributeProbe $Candidate @('--progress-probe', $archive, (Join-Path $root 'candidate')) "C:ExtractAttribute=$mode")
            Assert-AttributeEqual $expected $actual "progress / $archive / $mode"
            $progressSnapshots += $expected.Count
        }
    }
    if ($case.Attribute -in 2, 4, 33) {
        foreach ($mode in 0, 1, 2) {
            # 読み取り命令では隠し・システム属性を除外しない。
            foreach ($command in 'l', 'v', 't', 'p') {
                $line = "$command -gm1 -a$mode `"$archive`""
                $expected = @(Invoke-AttributeProbe $Oracle @('--command-probe', $line))
                $actual = @(Invoke-AttributeProbe $Candidate @('--command-probe', $line))
                Assert-AttributeEqual $expected $actual "read / $archive / $command / $mode"
                $readChecks++
            }
            foreach ($layout in 'a32', 'w32', 'a64', 'w64') {
                foreach ($selected in 0, 1) {
                    foreach ($command in 'e', 'x') {
                        $label = "$($case.Attribute)-$mode-$layout-$selected-$command"
                        Test-AttributeSelection $archive $label $command "-a$mode" 'missing' $layout $selected
                        $selectionChecks++
                    }
                }
            }
        }
        foreach ($state in 'missing', 'older', 'newer', 'protected') {
            foreach ($option in '', '-c1', '-gf1', '-m2', '-jn1', '-ga1') {
                foreach ($command in 'e', 'x') {
                    $label = "$($case.Attribute)-$state-$option-$command"
                    Test-AttributeSelection $archive $label $command "-a0 $option" $state
                    $selectionChecks++
                }
            }
        }
    }
}
Write-Host "Attributes: $($cases.Count) archives, $snapshots A/W metadata/memory snapshots, $enumFields enum attribute fields, $diskChecks A/W restored-file cases, $progressSnapshots progress snapshots, $selectionChecks selection/callback cases, $readChecks non-extraction cases compatible"
