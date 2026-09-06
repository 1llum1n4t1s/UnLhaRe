[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [Parameter(Mandatory)][string]$ArchiveDirectory,
    [switch]$Warmup
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$ArchiveDirectory = (Resolve-Path -LiteralPath $ArchiveDirectory).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Header CRC command state workspace: $Workspace"
$results = @{ good=0; first=0; middle=32790; last=32790; all=32795 }
$count = 0
foreach ($variant in 'good','first','middle','last','all') {
    $archive = Join-Path $ArchiveDirectory "$variant.lzh"
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    foreach ($commandName in 'l','v','t','p') { foreach ($layout in 'a32','w32','a64','w64') {
        $snapshots = @()
        foreach ($side in 'oracle','reimpl') {
            $root = Join-Path $Workspace ('case-{0:D2}-{1}' -f $count,$side)
            New-Item -ItemType Directory -Path $root | Out-Null
            $source = Join-Path $root 'added.txt'
            [IO.File]::WriteAllText($source,'subsequent new member',[Text.UTF8Encoding]::new($false))
            $stamp = [datetime]::new(2024,1,2,3,4,6,[DateTimeKind]::Utc)
            [IO.File]::SetCreationTimeUtc($source,$stamp)
            [IO.File]::SetLastWriteTimeUtc($source,$stamp)
            [IO.File]::SetLastAccessTimeUtc($source,$stamp)
            $created = Join-Path $root 'new.lzh'
            $read = "$commandName -+ -n1 -gm1 `"$archive`""
            $add = "a -+ -h0 -n1 -gm1 -y1 `"$created`" `"$($root.Replace('\','/'))/`" added.txt"
            $steps = @($read,$add,"@check:$created")
            if ($Warmup) {
                $prime = "a -+ -h0 -n1 -gm1 -y1 `"$(Join-Path $root 'warmup.lzh')`" `"$($root.Replace('\','/'))/`" added.txt"
                $steps = @($prime) + $steps
            }
            $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
            $rows = @(& $TestProgram --registry '' --progress-sequence-probe $dll none 1041 1 W $layout @steps)
            if ($LASTEXITCODE -ne 0) { throw "継続プローブが異常終了しました: $variant/$commandName/$layout/$side" }
            [IO.File]::WriteAllLines((Join-Path $root 'trace.txt'),$rows)
            $actualResults = @($rows -match '^result=')
            $readIndex = if ($Warmup) { 1 } else { 0 }
            if ($actualResults.Count -ne 2 + $readIndex -or ($Warmup -and $actualResults[0] -cne 'result=0') -or $actualResults[$readIndex] -cne "result=$($results[$variant])" -or $actualResults[$readIndex + 1] -cne 'result=0' -or $rows -notcontains 'check=1' -or $rows -notcontains 'progress.kill=1') { throw "読み取り後の追加・状態復帰に失敗しました: $variant/$commandName/$layout/$side" }
            $normalized = @($rows | ForEach-Object {
                $row = $_
                # 原版 DIRECTORY の不定数値と新規入力の実行時アクセス日時は生ログに残す。
                if ($row -match '^progress.entry=.*?,state=5,') { $row = $row -replace ',file=.*?,mode="(?:\\.|[^"\\])*",source=',',metadata=undefined,source=' }
                if ($row -match '^progress.entry=') { $row = $row -replace ',access=\d+',',access=volatile' }
                $row.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>')
            })
            $snapshots += ,$normalized
        }
        $difference = @(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
        if ($difference.Count) { throw "CRC 読取後の継続状態が一致しません: $variant/$commandName/$layout`n$($difference | Select-Object -First 8 | Out-String -Width 2200)" }
        $count++
    } }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $hash) { throw '参照書庫が変更されました' }
    Write-Host "Header CRC command state: $variant, $count comparisons passed"
}
Write-Host "Header CRC command state: $count read/add/check retained-progress and recovery sequences compatible"
