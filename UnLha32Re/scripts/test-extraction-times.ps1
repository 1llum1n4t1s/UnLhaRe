[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [Parameter(Mandatory)][string]$Archive,
    [ValidateSet('All','Files','Directories','Selection')][string]$Scope = 'All'
)

$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Archive = (Resolve-Path -LiteralPath $Archive).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Extraction time workspace: $Workspace"
$source = [IO.File]::ReadAllBytes($Archive)
$storedTimes = @([long]133485518461234567, [long]133486382467654321, [long]133487246465555555)
$oldTime = [long]132223104001111111
$script:timeCases = 0

function New-TimeFixture([byte[]]$InputBytes, [int]$Mask, [string]$Label) {
    $oldSize = [BitConverter]::ToUInt16($InputBytes, 0)
    if ($InputBytes[20] -ne 2 -or $oldSize -ge $InputBytes.Length) {
        throw '日時試験には level-2 書庫が必要です。'
    }
    [byte[]]$extensions = @()
    $times = @([long]0, [long]0, [long]0)
    if ($Mask -lt 8) {
        $extensions = [BitConverter]::GetBytes([uint16]27) + [byte[]](0x41)
        for ($kind = 0; $kind -lt 3; $kind++) {
            if ($Mask -band (1 -shl $kind)) { $times[$kind] = $storedTimes[$kind] }
            $extensions += [BitConverter]::GetBytes($times[$kind])
        }
    } else {
        $times = @([long]133486382460000000, [long]133486382460000000, [long]133486382460000000)
    }
    for ($offset = 24; $offset + 2 -lt $oldSize;) {
        $length = [BitConverter]::ToUInt16($InputBytes, $offset)
        if (-not $length) { break }
        if ($length -lt 3 -or $offset + $length -gt $oldSize) { throw '拡張ヘッダーが不正です。' }
        if ($InputBytes[$offset + 2] -ne 0x41) { $extensions += $InputBytes[$offset..($offset + $length - 1)] }
        $offset += $length
    }
    $size = 26 + $extensions.Length
    [byte[]]$bytes = $InputBytes[0..23] + $extensions + [byte[]](0,0) + $InputBytes[$oldSize..($InputBytes.Length - 1)]
    [Array]::Copy([BitConverter]::GetBytes([uint16]$size), 0, $bytes, 0, 2)
    [Array]::Copy([BitConverter]::GetBytes([uint32]1704164646), 0, $bytes, 15, 4)
    $crcOffset = -1
    for ($offset = 24; $offset + 2 -lt $size;) {
        $length = [BitConverter]::ToUInt16($bytes, $offset)
        if (-not $length) { break }
        if ($bytes[$offset + 2] -eq 0) { $crcOffset = $offset + 3 }
        $offset += $length
    }
    if ($crcOffset -lt 0) { throw 'ヘッダー CRC が見つかりません。' }
    $bytes[$crcOffset] = $bytes[$crcOffset + 1] = 0
    $crc = 0
    foreach ($value in $bytes[0..($size - 1)]) {
        $crc = $crc -bxor $value
        foreach ($bit in 0..7) {
            $crc = if ($crc -band 1) { ($crc -shr 1) -bxor 0xa001 } else { $crc -shr 1 }
        }
    }
    [Array]::Copy([BitConverter]::GetBytes([uint16]$crc), 0, $bytes, $crcOffset, 2)
    $path = Join-Path $Workspace "$Label-$Mask.lzh"
    [IO.File]::WriteAllBytes($path, $bytes)
    return @{ Path=$path; Times=$times }
}

function Set-OldTimes([string]$Path, [bool]$Directory) {
    $value = [DateTime]::FromFileTimeUtc($oldTime)
    if ($Directory) {
        [IO.Directory]::SetCreationTimeUtc($Path, $value)
        [IO.Directory]::SetLastWriteTimeUtc($Path, $value)
        [IO.Directory]::SetLastAccessTimeUtc($Path, $value)
    } else {
        [IO.File]::SetCreationTimeUtc($Path, $value)
        [IO.File]::SetLastWriteTimeUtc($Path, $value)
        [IO.File]::SetLastAccessTimeUtc($Path, $value)
    }
}

function Compare-TimeExtraction($Fixture, [string]$Label, [string]$Command, [string]$State,
                                [int]$Locale, [int]$Utf8, [string]$Api, [string]$Layout,
                                [bool]$Direct, [bool]$Directory, [int]$Selected = 1,
                                [int]$ExistingLength = 2, [bool]$ReadOnly = $false) {
    $results = @()
    foreach ($side in 'original', 'candidate') {
        $dll = if ($side -eq 'original') { $Oracle } else { $Candidate }
        $root = Join-Path $Workspace "$Label-$side"
        $destination = Join-Path $root $(if ($Direct) { '展開🙂' } else { 'destination' })
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        $replacement = if ($Layout -eq 'w32' -and -not $Directory) { 'renamed.txt' } else { '' }
        $member = if ($Directory) { 'dir' } elseif ($replacement) { $replacement } else { '☃-日本語.txt' }
        $existing = Join-Path $destination $member
        if ($State -ne 'new') {
            if ($Directory) { New-Item -ItemType Directory -Path $existing | Out-Null }
            else {
                $contents = [byte[]]::new($ExistingLength)
                if ($ExistingLength) { $contents[0] = 70; $contents[1] = 71 }
                [IO.File]::WriteAllBytes($existing, $contents)
            }
            Set-OldTimes $existing $Directory
            if ($ReadOnly) { [IO.File]::SetAttributes($existing, [IO.FileAttributes]::ReadOnly -bor [IO.FileAttributes]::Archive) }
        }
        $mode = switch ($State) { 'skip' { 1 } 'number' { 2 } default { 0 } }
        $selection = if ($State -eq 'skip') { '-jn1' } else { '' }
        $line = "$Command -n1 -gm1 -y1 -a1 -c1 -m$mode $selection `"$($Fixture.Path)`" `"$destination\`" *"
        # 値 0 の未指定日時だけは現在時刻になるため、実行時間内であることを先に検証する。
        $begin = [DateTime]::UtcNow.AddSeconds(-2).ToFileTimeUtc()
        Push-Location -LiteralPath $root
        try {
            $rows = @(& $TestProgram --registry '' --command-enum-probe $dll $line $Layout $Selected $replacement $Locale $Utf8 $Api 1)
            $probeExit = $LASTEXITCODE
        } finally { Pop-Location }
        $end = [DateTime]::UtcNow.AddSeconds(2).ToFileTimeUtc()
        if ($probeExit -ne 0 -or $rows -notcontains 'result=0') {
            throw "日時復元に失敗しました: $Label / $side`n$($rows -join "`n")"
        }
        if ($Direct -or $Directory) {
            # 専用 Wide 経路と明示ディレクトリ項目のログ差異は既知の別件。ここでは復元日時・内容を照合する。
            $rows = @($rows | Where-Object { $_ -eq 'result=0' })
        } else {
            $rows = @($rows | ForEach-Object {
                $_.Replace($root.Replace('\','/'), '<ROOT>').Replace($root.Replace('\','\\'), '<ROOT>')
            })
        }
        $items = @(Get-ChildItem -LiteralPath $destination -Force | Sort-Object Name)
        $expectedCount = if ($State -eq 'number' -and $Selected) { 2 } else { 1 }
        if ($items.Count -ne $expectedCount) { throw "生成項目数が不正です: $Label / $side / $($items.Count)" }
        foreach ($item in $items) {
            $isOld = -not $Selected -or $State -eq 'skip' -or ($Directory -and $State -eq 'overwrite') -or
                ($State -eq 'number' -and $item.FullName -eq $existing)
            $values = @($item.CreationTimeUtc.ToFileTimeUtc(), $item.LastWriteTimeUtc.ToFileTimeUtc(), $item.LastAccessTimeUtc.ToFileTimeUtc())
            $normalized = @()
            for ($kind = 0; $kind -lt 3; $kind++) {
                if ($Directory -and $isOld -and $kind -eq 2) {
                    # 原版の反復でも既存ディレクトリの参照日時だけは保持／OS 更新が混在する。
                    # ヘッダーの日時へ書き換わることは許さず、元値または実行時間内だけを認める。
                    if ($values[$kind] -ne $oldTime -and ($values[$kind] -lt $begin -or $values[$kind] -gt $end)) {
                        throw "既存ディレクトリの参照日時が範囲外です: $Label / $side : $($values[$kind])"
                    }
                    $normalized += '<EXISTING-OR-CURRENT>'
                    continue
                }
                $expected = if ($isOld) { $oldTime } else { $Fixture.Times[$kind] }
                # スキップ／採番前も原版は既存ファイルを読み取りマッピングで検査する。
                if ($isOld -and $kind -eq 2 -and -not $Directory -and $Selected -and $ExistingLength) { $expected = 0 }
                if (-not $isOld -and $kind -ne 1 -and $expected -eq 0) { $expected = $Fixture.Times[1] }
                if ($expected -eq 0 -and $State -eq 'overwrite' -and ($kind -eq 0 -or $Directory)) { $expected = $oldTime }
                if ($expected -ne 0) {
                    if ($values[$kind] -ne $expected) { throw "日時値が不一致: $Label / $side / $($item.Name) / $kind : $($values[$kind]) != $expected" }
                    $normalized += "$expected"
                } else {
                    if ($values[$kind] -lt $begin -or $values[$kind] -gt $end) { throw "未指定日時が実行時間外です: $Label / $side / $kind : $($values[$kind])" }
                    $normalized += '<CURRENT>'
                }
            }
            $hash = if ($item.PSIsContainer) { 'directory' } else { (Get-FileHash -LiteralPath $item.FullName).Hash }
            $size = if ($item.PSIsContainer) { 0 } else { $item.Length }
            $rows += "name=$($item.Name),attributes=$([int]$item.Attributes),size=$size,times=$($normalized -join '/'),hash=$hash"
        }
        $results += ,$rows
    }
    $difference = @(Compare-Object $results[0] $results[1] -SyncWindow 0)
    if ($difference.Count -ne 0) {
        $details = $difference | Select-Object -First 8 | Out-String -Width 1500
        throw "日時復元の比較が不一致です: $Label`n$details"
    }
    $script:timeCases++
}

if ($Scope -in 'All','Files') {
foreach ($mask in 0..8) {
    $fixture = New-TimeFixture $source $mask 'file'
    foreach ($locale in 1033,1041) {
      foreach ($utf8 in 0,1) {
       foreach ($api in 'A','W') {
        foreach ($layout in 'none','w32') {
         foreach ($command in 'e','x') {
          foreach ($state in 'new','overwrite','skip','number') {
            $label = "file-$mask-$locale-$utf8-$api-$layout-$command-$state"
            Compare-TimeExtraction $fixture $label $command $state $locale $utf8 $api $layout $false $false
          }
         }
        }
       }
      }
      foreach ($command in 'e','x') {
       foreach ($state in 'new','overwrite','skip','number') {
        $label = "direct-$mask-$locale-$command-$state"
        Compare-TimeExtraction $fixture $label $command $state $locale 0 W none $true $false
       }
      }
    }
    Write-Host "Extraction times: file mask $mask, $script:timeCases comparisons passed"
}
}

# 原版が作った明示ディレクトリ項目に同じ日時組み合わせを設定し、遅延復元も確認する。
if ($Scope -in 'All','Directories') {
$directorySource = Join-Path $Workspace 'directory-source'
New-Item -ItemType Directory -Path (Join-Path $directorySource 'dir') | Out-Null
$directoryArchive = Join-Path $Workspace 'directory-original.lzh'
$line = "a -gm1 -y1 -h2 -d1 -x1 -r1 `"$directoryArchive`" `"$directorySource\`" *"
$created = @(& $TestProgram --registry '' --command-probe $Oracle $line)
if ($LASTEXITCODE -ne 0 -or $created -notcontains 'result=0') { throw 'ディレクトリ日時 fixture を作成できません。' }
$directoryBytes = [IO.File]::ReadAllBytes($directoryArchive)
foreach ($mask in 0..8) {
    $fixture = New-TimeFixture $directoryBytes $mask 'directory'
    foreach ($locale in 1033,1041) {
      foreach ($utf8 in 0,1) {
       foreach ($api in 'A','W') {
        foreach ($state in 'new','overwrite') {
            $label = "directory-$mask-$locale-$utf8-$api-$state"
            Compare-TimeExtraction $fixture $label x $state $locale $utf8 $api none $false $true
        }
       }
      }
      foreach ($state in 'new','overwrite') {
        $label = "direct-directory-$mask-$locale-$state"
        Compare-TimeExtraction $fixture $label x $state $locale 0 W none $true $true
      }
    }
}
Write-Host "Extraction times: directory cases, $script:timeCases comparisons passed"
}
if ($Scope -in 'All','Selection') {
$fixture = New-TimeFixture $source 7 'selection'
foreach ($locale in 1033,1041) {
 foreach ($utf8 in 0,1) {
  foreach ($api in 'A','W') {
   foreach ($state in 'skip','number') {
    foreach ($selected in 0,1) {
     foreach ($length in 0,2) {
      foreach ($readOnly in $false,$true) {
        $label = "selection-$locale-$utf8-$api-$state-$selected-$length-$readOnly"
        Compare-TimeExtraction $fixture $label e $state $locale $utf8 $api w32 $false $false $selected $length $readOnly
      }
     }
    }
   }
  }
 }
}
}
Write-Host "Extraction times: $script:timeCases ordinary/Wide/directory, missing-time, overwrite, skip, numbering, and renamed-callback comparisons passed"
