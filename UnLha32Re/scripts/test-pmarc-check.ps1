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
$runner = Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe'
$Workspace = [IO.Path]::GetFullPath($Workspace)
if (Test-Path -LiteralPath $Workspace) { throw '新しい検証用ディレクトリーを指定してください' }
if (!(Test-Path -LiteralPath $runner -PathType Leaf)) { throw 'DesktopRunner が必要です' }
New-Item -ItemType Directory -Path $Workspace | Out-Null
$hashes = @{}
foreach ($path in $TestProgram,$runner,$Oracle,$Candidate) {
    $hashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    Write-Host "PMarc environment: $path, SHA256=$($hashes[$path])"
}
Write-Host "PMarc check workspace: $Workspace"
$seed = Join-Path $Workspace 'seed.lzh'
[IO.File]::WriteAllBytes($seed,[Convert]::FromHexString('20DD2D6C68302D01000000010000008360225820000A6D656D6265722E747874C0304100'))
$literal = Join-Path $Workspace 'literal'
$boundary = Join-Path $Workspace 'boundary'
$mixed = Join-Path $Workspace 'mixed'
& (Join-Path $PSScriptRoot 'new-legacy-fixtures.ps1') -SeedArchive $seed -OutputDirectory $literal -Methods lh0,pm0,pm2
& (Join-Path $PSScriptRoot 'new-legacy-boundaries.ps1') -Fixtures $literal -OutputDirectory $boundary -Methods lh0,pm0,pm2
New-Item -ItemType Directory -Path $mixed | Out-Null
$good = [IO.File]::ReadAllBytes((Join-Path $literal 'lh0-9.lzh'))
$goodMember = [byte[]]$good[0..($good.Length-2)]
$fakeLarge = [byte[]]$goodMember.Clone()
[BitConverter]::GetBytes([uint32]0x10000000).CopyTo($fakeLarge,7)
$sum = 0
for ($i=2; $i -lt $fakeLarge[0]+2; $i++) { $sum = ($sum+$fakeLarge[$i]) -band 255 }
$fakeLarge[1] = $sum
foreach ($method in 'pm0','pm2') {
    $unsupported = [IO.File]::ReadAllBytes((Join-Path $literal "$method-9.lzh"))
    $member = [byte[]]$unsupported[0..($unsupported.Length-2)]
    $sequences = [ordered]@{
        first = [byte[]]($member+$goodMember+0)
        middle = [byte[]]($goodMember+$member+$goodMember+0)
        last = [byte[]]($goodMember+$member+0)
    }
    # 本文内の偽ヘッダーで、復旧探索が次の宣言位置から始まることを区別する。
    # PM2 は原版の非対応判定を検証する任意本文であり、正常な PM2 圧縮試料ではない。
    $header = [byte[]]$unsupported[0..($unsupported[0]+1)]
    [BitConverter]::GetBytes([uint32]$fakeLarge.Length).CopyTo($header,7)
    [BitConverter]::GetBytes([uint32]$fakeLarge.Length).CopyTo($header,11)
    $sum = 0
    for ($i=2; $i -lt $header.Length; $i++) { $sum = ($sum+$header[$i]) -band 255 }
    $header[1] = $sum
    $sequences['embedded-large'] = [byte[]]($header+$fakeLarge+$goodMember+0)
    foreach ($variant in $sequences.Keys) {
        [IO.File]::WriteAllBytes((Join-Path $mixed "$method-$variant.lzh"),$sequences[$variant])
    }
}
$count = 0
foreach ($group in 'literal','boundary','mixed') {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $Workspace $group) -Filter '*.lzh' -File | Sort-Object Name) {
        $before = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        $snapshots = @()
        foreach ($side in 'oracle','candidate') {
            $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
            # CheckArchive だけを実行し、原版にも既存ファイルの更新・展開をさせない。
            $rows = @(& $runner --timeout-seconds 30 $TestProgram --registry '' --check-existing-archive-probe $dll $file.FullName 2>&1 | ForEach-Object { "$_" })
            $code = $LASTEXITCODE
            [IO.File]::WriteAllLines(($file.FullName+".$side.txt"),[string[]]$rows,[Text.UTF8Encoding]::new($false))
            if ($code -ne 0 -or $rows.Count -ne 192 -or @($rows -notmatch '^check\.existing\.[012]\.\d+=[01],error=\d+,system=\d+$').Count) {
                throw "PMarc 検査が異常終了しました: $group/$($file.Name)/$side/exit=$code"
            }
            $keys = @($rows | ForEach-Object { $_.Split('=')[0] } | Sort-Object -Unique)
            if ($keys.Count -ne 192) { throw 'PMarc の API・モード記録が重複しています' }
            if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -cne $before) { throw '参照書庫が変更されました' }
            $snapshots += ,$rows
        }
        $difference = @(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
        if ($difference.Count) {
            throw "PMarc の戻り値・エラー・システム状態が一致しません: $group/$($file.Name)`n$($difference | Select-Object -First 12 | Out-String -Width 2000)"
        }
        $count++
        if ($count % 10 -eq 0) { Write-Host "PMarc check: $count archives, $($count*192) comparisons passed" }
    }
}
if ($count -ne 134) { throw "PMarc の試料数が違います: $count" }
foreach ($path in $hashes.Keys) {
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $hashes[$path]) { throw "検証中に実行ファイルが変更されました: $path" }
}
Write-Host "PMarc check: $count fixtures, $($count*192) exact original mode/API result/error/system comparisons passed"
