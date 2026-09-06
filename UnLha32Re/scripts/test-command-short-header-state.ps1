[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestProgram,[Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,[Parameter(Mandatory)][string]$Workspace,
    [Parameter(Mandatory)][string]$ArchiveDirectory,
    [ValidateSet(0,1)][int]$UnicodeMode=1,
    [string]$DestinationName='output',
    [ValidateSet('l','v','t','p','e','x')][string[]]$Commands=@('l','v','t','p'),
    [ValidateSet('a32','w32','a64','w64')][string[]]$Layouts=@('a32','w32','a64','w64'),[bool[]]$Warmups=@($false,$true),
    [ValidateSet('good','badEnd','cut1','cut21','cutLast')][string[]]$Variants=@('good','badEnd','cut1','cut21','cutLast'))
$ErrorActionPreference='Stop'
$TestProgram=(Resolve-Path -LiteralPath $TestProgram).Path
$runner=(Resolve-Path -LiteralPath (Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe')).Path
$oracle=(Resolve-Path -LiteralPath $Oracle).Path
$candidate=(Resolve-Path -LiteralPath $Candidate).Path
$ArchiveDirectory=(Resolve-Path -LiteralPath $ArchiveDirectory).Path
$workspace=[IO.Path]::GetFullPath($Workspace)
if(Test-Path -LiteralPath $workspace){throw '既存の診断領域です'}
if([IO.Path]::GetFileName($DestinationName) -cne $DestinationName -or $DestinationName -in '','.','..'){throw '出力先名は領域内の単一ディレクトリ名に限定します'}
New-Item -ItemType Directory -Path $workspace | Out-Null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'test-enum-state.ps1'),[ref]$null,[ref]$null)
$helper=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-EnumProbe'},$true)
if(!$helper){throw '隔離プローブ関数が見つかりません'}
. ([scriptblock]::Create($helper.Extent.Text))
$observations=@()
foreach($level in 0,1,2,3){foreach($variant in $Variants){
    $fixtureRoot=(Resolve-Path -LiteralPath (Join-Path $ArchiveDirectory "h$level")).Path
    $archive=if($variant -eq 'cutLast'){
        (Get-ChildItem -LiteralPath $fixtureRoot -Filter 'cut*.lzh' | Sort-Object {[int]($_.BaseName.Substring(3))} | Select-Object -Last 1).FullName
    }else{(Resolve-Path -LiteralPath (Join-Path $fixtureRoot "$variant.lzh")).Path}
    $hash=(Get-FileHash -LiteralPath $archive).Hash
    $stamp=[IO.File]::GetLastWriteTimeUtc($archive)
    $expected=if($variant -in 'good','badEnd','cut1'){0}else{32834}
    foreach($command in $Commands){foreach($layout in $Layouts){foreach($warmup in $Warmups){
        $label="h$level-$variant-$command-$layout-$warmup"
        $snapshots=@()
        foreach($side in 'oracle','reimpl'){
            $root=Join-Path $workspace "$label-$side"
            New-Item -ItemType Directory -Path $root | Out-Null
            $source=Join-Path $root 'added.txt'
            [IO.File]::WriteAllText($source,'subsequent new member',[Text.UTF8Encoding]::new($false))
            foreach($setter in 'SetCreationTimeUtc','SetLastWriteTimeUtc','SetLastAccessTimeUtc'){[IO.File]::$setter($source,[datetime]'2024-01-02T03:04:06Z')}
            $created=Join-Path $root 'new.lzh'
            $readCommand="$command -gm1 -n1 `"$archive`" *"
            $outputDirectory=Join-Path $root $DestinationName
            if($command -in 'e','x'){
                New-Item -ItemType Directory -Path $outputDirectory | Out-Null
                $readCommand="$command -gm1 -n1 -y1 `"$archive`" `"$($outputDirectory.Replace('\','/'))/`" *"
            }
            $steps=@($readCommand,"a -+ -h0 -n1 -gm1 -y1 `"$created`" `"$($root.Replace('\','/'))/`" added.txt","@check:$created")
            if($warmup){$steps=@("a -+ -h0 -n1 -gm1 -y1 `"$(Join-Path $root 'warmup.lzh')`" `"$($root.Replace('\','/'))/`" added.txt")+$steps}
            $dll=if($side -eq 'oracle'){$oracle}else{$candidate}
            $rows=@(Invoke-EnumProbe (Join-Path $root 'trace') (@('--progress-sequence-probe',$dll,'none','1041',[string]$UnicodeMode,'W',$layout)+$steps))
            $results=@($rows -match '^result=')
            if($results.Count -ne $(if($warmup){3}else{2}) -or $results[-2] -cne "result=$expected" -or $results[-1] -cne 'result=0' -or $rows -notcontains 'check=1' -or $rows -notcontains 'progress.kill=1'){throw "継続処理の状態が不正です: $label/$side"}
            if($warmup -and $results[0] -cne 'result=0'){throw "事前圧縮が失敗しました: $label/$side"}
            if($command -in 'e','x'){
                $files=@(Get-ChildItem -LiteralPath $outputDirectory -Recurse -File | Sort-Object FullName | ForEach-Object {
                    "file=$([IO.Path]::GetRelativePath($outputDirectory,$_.FullName)),size=$($_.Length),sha256=$((Get-FileHash -LiteralPath $_.FullName).Hash),attributes=$([int]$_.Attributes),write=$($_.LastWriteTimeUtc.Ticks)"
                })
                if($files.Count -ne $(if($variant -in 'good','badEnd'){3}else{2})){throw "継続処理の展開数が不正です: $label/$side"}
                [IO.File]::WriteAllLines((Join-Path $root 'effects.txt'),[string[]]$files)
                $rows+=$files
            }
            $snapshots+=,@($rows | ForEach-Object {
                $row=$_
                # DIRECTORY の事前数値は原版で未初期化。後続通知の数値・名前・順序は比較する。
                if($row -match '^progress.entry=.*?,state=5,'){$row=$row -replace ',file=.*?,mode="(?:\\.|[^"\\])*",source=',',metadata=undefined,source='}
                if($row -match '^progress.entry='){$row=$row -replace ',access=\d+',',access=volatile'}
                $row.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>')
            })
        }
        $difference=@(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
        if($difference.Count){$difference | Export-Csv -LiteralPath (Join-Path $workspace "$label-diff.tsv") -Delimiter "`t" -NoTypeInformation}
        $observations+=[pscustomobject]@{Case=$label;Differences=$difference.Count}
    }}}
    if((Get-FileHash -LiteralPath $archive).Hash -cne $hash -or [IO.File]::GetLastWriteTimeUtc($archive) -ne $stamp){throw '読取書庫が変更されました'}
    $observations | Export-Csv -LiteralPath (Join-Path $workspace 'observations.tsv') -Delimiter "`t" -NoTypeInformation
    Write-Host "h$level/$variant observed=$($observations.Count)"
}}
$failures=@($observations | Where-Object Differences -ne 0)
if($observations.Count -ne 4*$Variants.Count*$Commands.Count*$Layouts.Count*$Warmups.Count -or !$observations.Count){throw '継続状態の比較件数が不足しています'}
if($failures.Count){$failures | Format-Table -AutoSize | Out-String | Write-Host;throw '短いヘッダー後の状態が一致しません'}
Write-Host "Short-header state: $($observations.Count) read/add/check sequences and immutable-input guards passed"
