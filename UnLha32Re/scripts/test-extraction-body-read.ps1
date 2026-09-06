[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [Parameter(Mandatory)][string]$BodyDirectory,
    [ValidateSet('ascii','japanese')][string[]]$Families=@('ascii','japanese'),
    [ValidateSet(0,2)][int[]]$Methods=@(0,2),
    [ValidateSet('e','x')][string[]]$Commands=@('e','x'),
    [ValidateSet(0,1,2)][int[]]$NameModes=@(1),
    [ValidateSet(0,1)][int]$UnicodeMode=1,
    [string]$DestinationName='output',
    [switch]$UnicodeArchivePath,
    [switch]$ExistingFiles,
    [switch]$IncludeCrcErrors,
    [string[]]$ProfileNames=@('w64','a32','w32','a64','legacy','reject','missing','rename','raw-W','raw-A-1','raw-A','raw-legacy','abort-begin','abort-missing'),
    [string[]]$CaseNames=@()
)
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath($Workspace)
if(Test-Path -LiteralPath $workspace){throw '既存の検証領域は上書きしません'}
if([IO.Path]::GetFileName($DestinationName) -cne $DestinationName -or $DestinationName -in '','.','..'){throw '出力先名は領域内の単一ディレクトリ名に限定します'}
$TestProgram=(Resolve-Path -LiteralPath $TestProgram).Path
$runner=(Resolve-Path -LiteralPath (Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe')).Path
$oracle=(Resolve-Path -LiteralPath $Oracle).Path
$candidate=(Resolve-Path -LiteralPath $Candidate).Path
$BodyDirectory=(Resolve-Path -LiteralPath $BodyDirectory).Path
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'test-enum-state.ps1'),[ref]$null,[ref]$null)
$helper=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-EnumProbe'},$true)
if(!$helper){throw '隔離・30 秒上限付きプローブ関数が見つかりません'}
. ([scriptblock]::Create($helper.Extent.Text))
$profiles=@{
    w64=@{Api='W';Layout='w64';Selected='1';Replacement='';Pattern='*';Capacity=0}
    a32=@{Api='A';Layout='a32';Selected='1';Replacement='';Pattern='*';Capacity=0}
    w32=@{Api='W';Layout='w32';Selected='1';Replacement='';Pattern='*';Capacity=0}
    a64=@{Api='A';Layout='a64';Selected='1';Replacement='';Pattern='*';Capacity=0}
    legacy=@{Api='legacy';Layout='a64';Selected='1';Replacement='';Pattern='*';Capacity=0}
    'W-A32'=@{Api='W';Layout='a32';Selected='1';Replacement='';Pattern='*';Capacity=0}
    'W-A64'=@{Api='W';Layout='a64';Selected='1';Replacement='';Pattern='*';Capacity=0}
    reject=@{Api='W';Layout='w64';Selected='0';Replacement='';Pattern='*';Capacity=0}
    missing=@{Api='W';Layout='w64';Selected='1';Replacement='';Pattern='missing';Capacity=0}
    rename=@{Api='W';Layout='w64';Selected='1';Replacement='renamed.txt';Pattern='*';Capacity=0}
    'abort-begin'=@{Api='W';Layout='w64';Selected='1';Replacement='';Pattern='*';Capacity=0;Abort=0}
    'abort-missing'=@{Api='W';Layout='w64';Selected='1';Replacement='';Pattern='missing';Capacity=0;Abort=0}
    'raw-W'=@{Api='W';Pattern='*';Capacity=4096}
    'raw-W-1'=@{Api='W';Pattern='*';Capacity=1}
    'raw-A-1'=@{Api='A';Pattern='*';Capacity=1}
    'raw-A'=@{Api='A';Pattern='*';Capacity=4096}
    'raw-legacy'=@{Api='legacy';Pattern='*';Capacity=4096}
}
foreach($name in $ProfileNames){if(!$profiles.ContainsKey($name)){throw "未知のプローブ構成です: $name"}}
New-Item -ItemType Directory -Path $workspace | Out-Null
$fixtures=[Collections.Generic.List[object]]::new()
foreach($family in $Families){foreach($method in $Methods){
    $paths=@(Get-ChildItem -LiteralPath (Join-Path $BodyDirectory "$family-jm$method") -Filter '*.lzh' | Where-Object {$_.BaseName -eq 'good' -or $_.BaseName -match '^body[01]-cut\d+$' -or ($IncludeCrcErrors -and $_.BaseName -in 'crc-first','crc-middle','crc-last','crc-all')} | Sort-Object Name)
    if('good' -notin $paths.BaseName -or @($paths.BaseName -match '^body0-').Count -lt 7 -or @($paths.BaseName -match '^body1-').Count -lt 7){throw '正常対照と各本文の 7 切断点が必要です'}
    foreach($name in $CaseNames){if($name -notin $paths.BaseName){throw "未知の本文入力です: $family/jm$method/$name"}}
    foreach($path in $paths){
        if($CaseNames.Count -and $path.BaseName -notin $CaseNames){continue}
        $inputPath=$path.FullName
        if($UnicodeArchivePath){
            $inputRoot=Join-Path $workspace "Ā-input/$family-jm$method"
            New-Item -ItemType Directory -Path $inputRoot -Force | Out-Null
            $inputPath=Join-Path $inputRoot $path.Name
            Copy-Item -LiteralPath $path.FullName -Destination $inputPath
        }
        $fixtures.Add([pscustomobject]@{Name="$family-jm$method-$($path.BaseName)";Variant=$path.BaseName;Path=$inputPath;Source=$path.FullName})
    }
}}
$hashes=@{}
$stamps=@{}
foreach($path in @($TestProgram,$runner,$oracle,$candidate)+@($fixtures.Path)+@($fixtures.Source)){
    $hashes[$path]=(Get-FileHash -LiteralPath $path).Hash
    $stamps[$path]=[IO.File]::GetLastWriteTimeUtc($path)
}
Write-Host "Extraction body read: candidate SHA256=$($hashes[$candidate]), oracle SHA256=$($hashes[$oracle])"
$observations=[Collections.Generic.List[object]]::new()
$expectedTotal=$fixtures.Count*$Commands.Count*$NameModes.Count*$ProfileNames.Count
foreach($fixture in $fixtures){foreach($command in $Commands){foreach($mode in $NameModes){foreach($profileName in $ProfileNames){
    $profile=$profiles[$profileName]
    $aborting=$profile.ContainsKey('Abort') -and $mode -ne 0
    $label="$($fixture.Name)-$command-n$mode-$profileName"
    $snapshots=@()
    foreach($side in 'oracle','reimpl'){
        # 削除・上書きの観測対象は、この比較だけの新規領域へ閉じる。
        $root=Join-Path $workspace ('case-{0:D4}-{1}' -f $observations.Count,$side)
        $destination=Join-Path $root $DestinationName
        New-Item -ItemType Directory -Path $destination | Out-Null
        if($ExistingFiles){
            foreach($name in 'a.txt','m.txt','z.txt'){
                $path=Join-Path $destination $name
                [IO.File]::WriteAllText($path,"previous-$name",[Text.UTF8Encoding]::new($false))
                [IO.File]::SetLastWriteTimeUtc($path,[datetime]'2010-01-02T03:04:06Z')
            }
        }
        $dll=if($side -eq 'oracle'){$oracle}else{$candidate}
        $line="$command -+ -gm1 -y1 -n$mode `"$($fixture.Path)`" `"$($destination.Replace('\','/'))/`" `"$($profile.Pattern)`""
        $arguments=if($profile.Capacity){@('--command-raw-probe',$dll,$line,$profile.Api,[string]$profile.Capacity)}
            else{@('--command-enum-probe',$dll,$line,$profile.Layout,$profile.Selected,$profile.Replacement,'1041',[string]$UnicodeMode,$profile.Api,'1')}
        if($profile.Capacity -and $UnicodeMode){$arguments+=,'utf8'}
        if($profile.ContainsKey('Abort')){$arguments+=,[string]$profile.Abort}
        $rows=@(Invoke-EnumProbe (Join-Path $root 'command') $arguments)
        if(@($rows -match '^result=').Count -ne 1){throw "戻り値行が不足しています: $label/$side"}
        if($fixture.Variant -eq 'good'){
            $expected=if($aborting){32800}else{0}
            if(!@($rows -match "^result=$expected(?:,|$)").Count){throw "正常対照が失敗しました: $label/$side"}
        }
        if($profile.Capacity){
            $units=@((($rows[0] -split 'raw=',2)[1]).TrimEnd(',').Split(','))
            $guard=if($profile.Api -eq 'W'){'cccc'}else{'cc'}
            if($units.Count -ne $profile.Capacity+16 -or @($units[0..7] -cne $guard).Count -or @($units[($profile.Capacity+8)..($profile.Capacity+15)] -cne $guard).Count){throw '生バッファの境界が変更されました'}
        }
        # ANSI コールバックが非表現文字を置換した兄弟ディレクトリも比較する。
        # プローブのログは直下、展開先はサブディレクトリなので区別できる。
        $files=@(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object DirectoryName -ne $root | Sort-Object FullName | ForEach-Object {
            "file=$([IO.Path]::GetRelativePath($root,$_.FullName).Replace('\','/')),size=$($_.Length),sha256=$((Get-FileHash -LiteralPath $_.FullName).Hash),attributes=$([int]$_.Attributes),write=$($_.LastWriteTimeUtc.Ticks)"
        })
        if($fixture.Variant -eq 'good' -and $profileName -in 'w64','w32' -and $files.Count -ne 3){throw '正常展開の 3 ファイルがありません'}
        $directories=@(Get-ChildItem -LiteralPath $root -Recurse -Directory | Sort-Object FullName | ForEach-Object {
            "directory=$([IO.Path]::GetRelativePath($root,$_.FullName).Replace('\','/')),attributes=$([int]$_.Attributes)"
        })
        $effects=@($files)+@($directories)
        [IO.File]::WriteAllLines((Join-Path $root 'effects.txt'),[string[]]$effects)
        $snapshots+=,@((@($rows)+$effects) | ForEach-Object {$_.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>')})
        if((Get-FileHash -LiteralPath $fixture.Path).Hash -cne $hashes[$fixture.Path] -or [IO.File]::GetLastWriteTimeUtc($fixture.Path) -ne $stamps[$fixture.Path]){throw '入力書庫が変更されました'}
    }
    $difference=@(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
    if($difference.Count){$difference | Export-Csv -LiteralPath (Join-Path $workspace "$label-diff.tsv") -Delimiter "`t" -NoTypeInformation}
    $observations.Add([pscustomobject]@{Case=$observations.Count;Fixture=$fixture.Name;Command=$command;Mode=$mode;Profile=$profileName;Differences=$difference.Count})
}}}
    $observations | Export-Csv -LiteralPath (Join-Path $workspace 'observations.tsv') -Delimiter "`t" -NoTypeInformation
    Write-Host "$($fixture.Name) comparisons=$($observations.Count)"
}
foreach($path in $hashes.Keys){if((Get-FileHash -LiteralPath $path).Hash -cne $hashes[$path] -or [IO.File]::GetLastWriteTimeUtc($path) -ne $stamps[$path]){throw "検証中に入力またはバイナリーが変更されました: $path"}}
if(!$expectedTotal -or $observations.Count -ne $expectedTotal){throw '本文途中欠落の比較件数が不足しています'}
$failures=@($observations | Where-Object Differences -ne 0)
if($failures.Count){$failures | Format-Table -AutoSize | Out-String -Width 200 | Write-Host; throw '本文途中欠落のログ・通知・状態・ファイルが一致しません'}
Write-Host "Extraction body read: $($observations.Count) exact comparisons, buffer and immutable-input guards passed"
