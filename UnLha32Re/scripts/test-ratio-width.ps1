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
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Ratio width workspace: $Workspace"
$source = Join-Path $Workspace 'a.txt'
[IO.File]::WriteAllText($source,'Z',[Text.UTF8Encoding]::new($false))
[IO.File]::SetLastWriteTimeUtc($source,[datetime]::new(2024,1,2,3,4,6,[DateTimeKind]::Utc))
$seed = Join-Path $Workspace 'seed.lzh'
$created = @(& $TestProgram --registry '' --command-probe-a $Oracle "a -+ -h0 -jm0 -gm1 -y1 `"$seed`" `"$Workspace\`" a.txt" A)
if ($LASTEXITCODE -ne 0 -or $created -notcontains 'result=0') { throw '圧縮率の元書庫を作成できません' }
$seedBytes = [IO.File]::ReadAllBytes($seed)
if ($seedBytes[20] -ne 0) { throw 'level-0 の元書庫が必要です' }
$headerSize = [int]$seedBytes[0] + 2
$cases = @(@(0,0),@(1,1),@(65,1),@(66,1),@(131,1),@(132,1),@(1376,21),@(1377,21),@(2048,21),@(65534,1000),@(65535,1000),@(65536,1000),@(65537,1000),@(128,0))
$count = 0
$rowCount = 0
foreach ($case in $cases) {
    $packed = [uint32]$case[0]
    $original = [uint32]$case[1]
    $expected = if ($original -eq 0) { 0 } else { [int64][Math]::Truncate(([int64]$packed * 1000) / $original) -band 65535 }
    # 物理サイズとヘッダー検査和は有効にし、復号せずメタデータの幅だけを検査する。
    $bytes = [byte[]]::new($headerSize + $packed + 1)
    [Array]::Copy($seedBytes,$bytes,$headerSize)
    [BitConverter]::GetBytes($packed).CopyTo($bytes,7)
    [BitConverter]::GetBytes($original).CopyTo($bytes,11)
    $checksum = 0
    for ($offset=2; $offset -lt $headerSize; $offset++) { $checksum = ($checksum + $bytes[$offset]) -band 255 }
    $bytes[1] = [byte]$checksum
    $archive = Join-Path $Workspace "packed-$packed-original-$original.lzh"
    [IO.File]::WriteAllBytes($archive,$bytes)
    $snapshots = @()
    foreach ($side in 'oracle','reimpl') {
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        $root = Join-Path $Workspace ("case-$count-$side")
        $rows = @(& $TestProgram --registry '' --find-state-probe $dll $root $archive)
        if ($LASTEXITCODE -ne 0) { throw "圧縮率の列挙プローブが異常終了しました: $packed/$original/$side" }
        [IO.File]::WriteAllLines((Join-Path $root 'trace.txt'),$rows)
        foreach ($getter in 'UnlhaGetRatio','UnlhaGetArcRatio') {
            if (@($rows -match "^member\.1\.$getter=$expected,error=0,").Count -ne 1) { throw "圧縮率の 16 ビット値が違います: $packed/$original/$getter/$side expected=$expected" }
        }
        $snapshots += ,$rows
    }
    $difference = @(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
    if ($difference.Count) { throw "圧縮率・列挙状態が一致しません: $packed/$original`n$($difference | Select-Object -First 6 | Out-String -Width 1800)" }
    $count++
    $rowCount += $snapshots[0].Count
}
Write-Host "Ratio width: $count metadata boundary comparisons, $rowCount exact Find/getter/state rows compatible"
