[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [ValidateSet(2,3)][int[]]$HeaderLevels = @(2,3)
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'level3-header-fixture.ps1')
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Header CRC search workspace: $Workspace"
# 圧縮サイズと累計が区別できるよう、各項目の長さを変える。最後は空ファイルとする。
$payloads = [ordered]@{ 'a.txt'='first payload'; 'm.txt'=('middle payload' * 20); 'z.txt'='' }
foreach ($name in $payloads.Keys) {
    $path = Join-Path $Workspace $name
    [IO.File]::WriteAllText($path,$payloads[$name],[Text.UTF8Encoding]::new($false))
    [IO.File]::SetLastWriteTimeUtc($path,[datetime]::new(2020,1,2,3,4,6,[DateTimeKind]::Utc))
}
$seed = Join-Path $Workspace 'seed.lzh'
$created = @(& $TestProgram --registry '' --command-probe-a $Oracle "a -h2 -jm0 -gm1 -y1 `"$seed`" `"$Workspace\`" a.txt m.txt z.txt" A)
if ($LASTEXITCODE -ne 0 -or $created -notcontains 'result=0') { throw 'ヘッダー CRC の元書庫を作成できません' }
$bytes = [IO.File]::ReadAllBytes($seed)
$crcPositions = @()
$position = 0
for ($index = 0; $index -lt 3; $index++) {
    if ($position + 26 -gt $bytes.Length -or $bytes[$position + 20] -ne 2) { throw '予期しない元ヘッダーです' }
    $headerSize = [BitConverter]::ToUInt16($bytes,$position)
    $packed = [BitConverter]::ToUInt32($bytes,$position + 7)
    $extension = $position + 26
    $extensionSize = [BitConverter]::ToUInt16($bytes,$position + 24)
    $found = $false
    while ($extensionSize -gt 0) {
        if ($extensionSize -lt 3 -or $extension + $extensionSize -gt $position + $headerSize) { throw '不正な拡張ヘッダー位置です' }
        if ($bytes[$extension] -eq 0) {
            if ($extensionSize -lt 5) { throw 'CRC 領域が不足しています' }
            $crcPositions += $extension + 1
            $found = $true
            break
        }
        $next = $extension + $extensionSize - 2
        $extensionSize = [BitConverter]::ToUInt16($bytes,$next)
        $extension = $next + 2
    }
    if (-not $found) { throw 'CRC 拡張ヘッダーがありません' }
    $position += $headerSize + $packed
}
$variants = [ordered]@{ good=@(); first=@(0); middle=@(1); last=@(2); all=@(0,1,2) }
$count = 0
foreach ($level in $HeaderLevels) {
  $caseRoot = $Workspace
  $levelBytes = $bytes
  $levelCrcPositions = $crcPositions
  if ($level -eq 3) {
    $converted = ConvertTo-Level3HeaderFixture $bytes
    $levelBytes = $converted.Bytes
    $levelCrcPositions = $converted.CrcPositions
    if ($levelCrcPositions.Count -ne 3) { throw 'Level-3 の対照項目が不足しています' }
    $caseRoot = Join-Path $Workspace 'level3'
    New-Item -ItemType Directory -Path $caseRoot | Out-Null
  }
foreach ($variant in $variants.Keys) {
    $damaged = [byte[]]$levelBytes.Clone()
    foreach ($index in $variants[$variant]) { $damaged[$levelCrcPositions[$index]] = $damaged[$levelCrcPositions[$index]] -bxor 1 }
    $archive = Join-Path $caseRoot "$variant.lzh"
    [IO.File]::WriteAllBytes($archive,$damaged)
    $beforeHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    $snapshots = @()
    foreach ($side in 'oracle','reimpl') {
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        # 既存プローブはエラーメッセージ非表示・保存設定無視を指定する。
        $raw = @(& $TestProgram --registry '' --find-pattern-probe $dll $archive utf8 0 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
        [IO.File]::WriteAllLines((Join-Path $caseRoot "$variant-$side-find.txt"),$raw)
        $rows = @($raw -match '^pattern\.')
        if ($variant -eq 'all') {
            if ($exitCode -ne 2 -or $rows.Count -ne 0 -or $raw -notcontains 'find pattern: cannot open fixture') { throw "全項目不良の Open を拒否しませんでした: $side" }
        } else {
            if ($exitCode -ne 0 -or $rows.Count -ne 88) { throw "検索プローブが失敗しました: $variant/$side" }
            $end = if ($variant -in 'middle','last') { 32790 } else { -1 }
            $names = if ($variant -eq 'first') { @('m.txt','z.txt') } elseif ($variant -eq 'middle') { @('a.txt') }
                elseif ($variant -eq 'last') { @('a.txt','m.txt') } else { @('a.txt','m.txt','z.txt') }
            $total = 0
            foreach ($name in $names) { $total += [Text.Encoding]::UTF8.GetByteCount($payloads[$name]) }
            $suffix = "=end=$end,total=$total,names=" + [string]::Join('',@($names | ForEach-Object { '"' + $_ + '";' }))
            if (@($rows | Where-Object { -not $_.EndsWith($suffix,[StringComparison]::Ordinal) }).Count) { throw "停止位置・名前・累計が不正です: $variant/$side" }
        }
        $api = @(& $TestProgram --registry '' --enum-sequence-probe $dll w64 1041 1 W "@count:$archive" "@check:$archive")
        if ($LASTEXITCODE -ne 0) { throw "件数・検査 API が異常終了しました: $variant/$side" }
        [IO.File]::WriteAllLines((Join-Path $caseRoot "$variant-$side-api.txt"),$api)
        if ($api -notcontains $(if ($variant -eq 'good') { 'count=3' } elseif ($variant -eq 'first') { 'count=2' } else { 'count=-1' }) -or
            $api -notcontains $(if ($variant -in 'good','first') { 'check=1' } else { 'check=0' })) { throw "件数・検査の結果が不正です: $variant/$side" }
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $beforeHash) { throw '読み取りで書庫を変更しました' }
        $snapshots += ,(@("exit=$exitCode") + $rows + $api)
    }
    if (Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0) { throw "原版との検索結果が不一致です: $variant" }
    $count += $(if ($variant -eq 'all') { 1 } else { 88 })
    Write-Host "Header CRC search: h$level/$variant, $count comparisons passed"
}
}
Write-Host "Header CRC search: $count A/W/OpenArchive2/mode comparisons, $($HeaderLevels.Count * 5) count/check sequences and archive-unchanged guards passed"
