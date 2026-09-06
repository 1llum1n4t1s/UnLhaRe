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
$Archive = (Resolve-Path -LiteralPath $Archive).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
$source = [IO.File]::ReadAllBytes($Archive)
$headerSize = [BitConverter]::ToUInt16($source, 0)
$packedSize = [BitConverter]::ToUInt32($source, 7)
if ($source[20] -ne 2 -or $headerSize + $packedSize -ge $source.Length) {
    throw 'Unicode パス fixture には level-2 の単一項目書庫が必要です。'
}
[Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
$cp932 = [Text.Encoding]::GetEncoding(932,
    [Text.EncoderReplacementFallback]::new('_'), [Text.DecoderReplacementFallback]::new('_'))

function New-UnicodePathFixture([string]$Name, [string]$Label, [switch]$RawSafe, [switch]$LeafOnly) {
    $normalized = if ($LeafOnly) { $Name } else { $Name.Replace('\', '/') }
    $separator = if ($LeafOnly) { -1 } else { $normalized.LastIndexOf('/') }
    $leaf = if ($separator -lt 0) { $normalized } else { $normalized.Substring($separator + 1) }
    $directory = if ($separator -lt 0) { '' } else { $normalized.Substring(0, $separator + 1) }
    [byte[]]$rawLeaf = $cp932.GetBytes($(if ($RawSafe) { 'safe.txt' } else { $leaf }))
    [byte[]]$wideLeaf = [Text.Encoding]::Unicode.GetBytes($leaf)
    [byte[]]$extensions = [BitConverter]::GetBytes([uint16]($rawLeaf.Length + 3)) +
        [byte[]](1) + $rawLeaf + [BitConverter]::GetBytes([uint16]($wideLeaf.Length + 3)) +
        [byte[]](0x44) + $wideLeaf
    if ($directory) {
        if (-not $RawSafe) {
            # 0xff は従来ディレクトリ拡張の区切り。CP932 の末尾 0x5c はそのまま保つ。
            [byte[]]$rawDirectory = $cp932.GetBytes($directory)
            for ($index = 0; $index -lt $rawDirectory.Length; $index++) {
                if ($rawDirectory[$index] -eq 0x2f) { $rawDirectory[$index] = 0xff }
            }
            $extensions += [BitConverter]::GetBytes([uint16]($rawDirectory.Length + 3)) +
                [byte[]](2) + $rawDirectory
        }
        [byte[]]$wideDirectory = [Text.Encoding]::Unicode.GetBytes($directory.Replace('/', [char]0xffff))
        $extensions += [BitConverter]::GetBytes([uint16]($wideDirectory.Length + 3)) +
            [byte[]](0x45) + $wideDirectory
    }
    $offset = 24
    while ($offset + 2 -lt $headerSize) {
        $length = [BitConverter]::ToUInt16($source, $offset)
        if ($length -eq 0) { break }
        if ($length -lt 3 -or $offset + $length -gt $headerSize) { throw '拡張ヘッダーが不正です。' }
        if ($source[$offset + 2] -notin 1, 2, 0x44, 0x45) {
            $extensions += $source[$offset..($offset + $length - 1)]
        }
        $offset += $length
    }
    [byte[]]$bytes = $source[0..23] + $extensions + [byte[]](0, 0) +
        $source[$headerSize..($headerSize + $packedSize - 1)] + [byte[]](0)
    $newSize = 26 + $extensions.Length
    [Array]::Copy([BitConverter]::GetBytes([uint16]$newSize), 0, $bytes, 0, 2)
    $offset = 24
    $crcOffset = -1
    while ($offset + 2 -lt $newSize) {
        $length = [BitConverter]::ToUInt16($bytes, $offset)
        if ($length -eq 0) { break }
        if ($bytes[$offset + 2] -eq 0) { $crcOffset = $offset + 3 }
        $offset += $length
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
    $path = Join-Path $Workspace "$Label.lzh"
    [IO.File]::WriteAllBytes($path, $bytes)
    return $path
}

function Get-UnicodePathSnapshot([string]$Root) {
    foreach ($file in (Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Sort-Object FullName)) {
        $name = [IO.Path]::GetRelativePath($Root, $file.FullName)
        "file=$name,attributes=$([int]$file.Attributes),size=$($file.Length),time=$($file.LastWriteTimeUtc.Ticks),hash=$((Get-FileHash -LiteralPath $file.FullName).Hash)"
    }
}

$cases = @('plain.txt', '☃-日本語.txt', '表/表.txt', '補助🙂/変更🗂.txt', '子☃/孫日本語/☃.txt')
$count = 0
for ($case = 0; $case -lt $cases.Count; $case++) {
    $member = $cases[$case]
    $fixture = New-UnicodePathFixture $member "name-$case"
    foreach ($locale in 1033, 1041) {
      foreach ($utf8 in 0, 1) {
       foreach ($api in 'A', 'W') {
        foreach ($layout in 'none', 'w32') {
         foreach ($command in 'e', 'x') {
          foreach ($state in 'new', 'overwrite', 'number') {
            $label = "$case-$locale-$utf8-$api-$layout-$command-$state"
            $results = @()
            foreach ($side in 'oracle', 'reimpl') {
                $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
                $root = Join-Path $Workspace "$label-$side"
                $destination = Join-Path $root 'destination'
                New-Item -ItemType Directory -Path $destination -Force | Out-Null
                if ($state -ne 'new') {
                    $name = if ($command -eq 'e') { ($member -split '/')[-1] } else { $member }
                    $existing = Join-Path $destination $name
                    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($existing)) -Force | Out-Null
                    [IO.File]::WriteAllBytes($existing, [byte[]](70, 71))
                    [IO.File]::SetLastWriteTimeUtc($existing, [datetime]::new(2020, 1, 1, 0, 0, 0, [DateTimeKind]::Utc))
                }
                $mode = switch ($state) { 'overwrite' { 1 } 'number' { 2 } default { 0 } }
                $line = "$command -n1 -gm1 -y1 -a1 -c1 -m$mode `"$fixture`" `"$destination\`" *"
                Push-Location -LiteralPath $root
                try {
                    $rows = @(& $TestProgram --registry '' --command-enum-probe $dll $line $layout 1 '' $locale $utf8 $api 1)
                    $probeExit = $LASTEXITCODE
                } finally { Pop-Location }
                if ($probeExit -ne 0 -or $rows -notcontains 'result=0') {
                    throw "Unicode パス試験に失敗しました: $label / $side`n$($rows -join "`n")"
                }
                $rows = @($rows | ForEach-Object {
                    $_.Replace($root.Replace('\', '/'), '<ROOT>').Replace($root.Replace('\', '\\'), '<ROOT>')
                })
                $rows += @(Get-UnicodePathSnapshot $root)
                $results += ,$rows
            }
            $difference = @(Compare-Object $results[0] $results[1] -SyncWindow 0)
            if ($difference.Count -ne 0) {
                $details = $difference | Select-Object -First 8 | Out-String -Width 1500
                throw "Unicode パスが一致しません: $label`n$details"
            }
            $count++
          }
         }
        }
       }
      }
    }
    Write-Host "Unicode header paths: name $case, $count comparisons passed"
}

$guardCount = 0
$traversals = @('../escape.txt', 'safe/../../escape.txt', '..\escape.txt')
for ($case = 0; $case -lt $traversals.Count; $case++) {
    # 従来名は安全でも Unicode 拡張だけに含まれる親階層参照を検査する。
    $fixture = New-UnicodePathFixture $traversals[$case] "traversal-$case" -RawSafe -LeafOnly:($case -eq 2)
    foreach ($utf8 in 0, 1) {
      foreach ($layout in 'none', 'w32') {
       foreach ($leaf in 'destination', 'Ā-output') {
        # W 入力の専用経路を共通化しても、非 ANSI の出力先から親へ脱出させない。
        $root = Join-Path $Workspace "guard-$case-$utf8-$layout-$leaf"
        $destination = Join-Path $root "working\inside\$leaf"
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        $line = "x -gm1 -y1 -a1 `"$fixture`" `"$destination\`" *"
        Push-Location -LiteralPath $destination
        try {
            $rows = @(& $TestProgram --registry '' --command-enum-probe $Candidate $line $layout 1 '' 1033 $utf8 W 0)
            $probeExit = $LASTEXITCODE
        } finally { Pop-Location }
        $guardErrors = @($rows | Where-Object {
            $_.StartsWith('output="LHa: Error: Possible directory traversal hack attempt in ')
        })
        if ($probeExit -ne 0 -or $rows -notcontains 'result=-1' -or $guardErrors.Count -ne 1 -or
            $rows -notcontains 'enum.count=0' -or @(Get-UnicodePathSnapshot $root).Count -ne 0) {
            throw "Unicode 拡張のパス安全検査に失敗しました: $case / $utf8 / $layout`n$($rows -join "`n")"
        }
        $guardCount++
       }
      }
    }
}
Write-Host "Unicode header paths: $count extraction/overwrite/number comparisons and $guardCount candidate-only traversal guards passed"

$actionCount = 0
# 更新時の再直列化による合成ヘッダーの順序差を混ぜず、原版が生成した書庫を比較する。
$fixture = $Archive
    foreach ($locale in 1033, 1041) {
      foreach ($utf8 in 0, 1) {
       foreach ($api in 'A', 'W') {
        foreach ($layout in 'none', 'w32') {
         foreach ($command in 'c', 'd') {
            $label = "action-$locale-$utf8-$api-$layout-$command"
            $results = @()
            foreach ($side in 'oracle', 'reimpl') {
                $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
                $root = Join-Path $Workspace "$label-$side"
                New-Item -ItemType Directory -Path $root | Out-Null
                $archivePath = Join-Path $root 'archive.lzh'
                Copy-Item -LiteralPath $fixture -Destination $archivePath
                $options = ''
                if ($command -eq 'c') {
                    $comment = Join-Path $root 'comment.txt'
                    # 非 NUL 終端時の原版の読み越しは互換対象外。文字列の終端を明示する。
                    [IO.File]::WriteAllBytes($comment, [byte[]](65, 66, 67, 0))
                    $options = "-jz`"$comment`""
                }
                $line = "$command -n1 -gm1 -y1 $options `"$archivePath`" *"
                Push-Location -LiteralPath $root
                try {
                    $rows = @(& $TestProgram --registry '' --command-enum-probe $dll $line $layout 1 '' $locale $utf8 $api 0)
                    $probeExit = $LASTEXITCODE
                } finally { Pop-Location }
                if ($probeExit -ne 0 -or $rows -notcontains 'result=0') {
                    throw "Unicode ログ試験に失敗しました: $label / $side`n$($rows -join "`n")"
                }
                $rows = @($rows | ForEach-Object {
                    $_.Replace($root.Replace('\', '/'), '<ROOT>').Replace($root.Replace('\', '\\'), '<ROOT>')
                })
                if (Test-Path -LiteralPath $archivePath) {
                    $file = Get-Item -LiteralPath $archivePath
                    $rows += "archive=size=$($file.Length),attributes=$([int]$file.Attributes),hash=$((Get-FileHash -LiteralPath $archivePath).Hash)"
                } else { $rows += 'archive=absent' }
                $results += ,$rows
            }
            $difference = @(Compare-Object $results[0] $results[1] -SyncWindow 0)
            if ($difference.Count -ne 0) {
                $details = $difference | Select-Object -First 8 | Out-String -Width 1500
                throw "Unicode ログが一致しません: $label`n$details"
            }
            $actionCount++
         }
        }
       }
      }
    }
Write-Host "Unicode header logs: $actionCount comment/delete comparisons and archive effects passed"

# 複数項目を同じコマンドで処理し、直前の別名・mkdir・スキップ状態の持ち越しを検査する。
$members = [Collections.Generic.List[byte]]::new()
for ($case = 0; $case -lt $cases.Count; $case++) {
    $member = [IO.File]::ReadAllBytes((Join-Path $Workspace "name-$case.lzh"))
    if ($member[-1] -ne 0) { throw '項目書庫の終端が不正です。' }
    $members.AddRange([byte[]]$member[0..($member.Length - 2)])
}
$members.Add(0)
$multiple = Join-Path $Workspace 'multiple.lzh'
[IO.File]::WriteAllBytes($multiple, $members.ToArray())
foreach ($variant in @(@{ Locale = 1033; Utf8 = $false }, @{ Locale = 1041; Utf8 = $true })) {
    & (Join-Path $PSScriptRoot 'test-enum-paths.ps1') -TestProgram $TestProgram `
        -Oracle $Oracle -Candidate $Candidate -Archive $multiple `
        -Workspace (Join-Path $Workspace "multiple-$($variant.Locale)") `
        -Scope paths -Locale $variant.Locale -UnicodeMode:$variant.Utf8 -Progress `
        -Pattern '*' -Commands e, x -Layouts none, w32
}
Write-Host 'Unicode header sequences: 108 multi-member comparisons passed'
