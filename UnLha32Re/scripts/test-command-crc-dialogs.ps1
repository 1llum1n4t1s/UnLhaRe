[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$RunnerPath,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [Parameter(Mandatory)][string]$BodyDirectory,
    [ValidateSet('ascii','japanese')][string[]]$Families=@('ascii','japanese'),
    [ValidateSet(0,2)][int[]]$Methods=@(0,2),
    [ValidateSet('e','x','p','t')][string[]]$Commands=@('e','x','p','t'),
    [string[]]$Variants=@('good','crc-first','crc-middle','crc-last','crc-all'),
    [ValidateSet('silent','delete-continue','keep-continue','delete-stop','keep-stop','jy-continue')]
    [string[]]$Policies=@('silent','delete-continue','keep-continue','delete-stop','keep-stop'),
    [ValidateSet('w64','w32','a32','a64','legacy','W-A32','none')][string[]]$Profiles=@('w64','a32'),
    [int[]]$Languages=@(1041,1033),
    [ValidateSet(0,1)][int]$UnicodeMode=1,
    [ValidateSet(0,1,2)][int]$NameMode=1,
    [string]$DestinationName='output',
    [switch]$ExistingFiles,
    [switch]$AuditRelease
)
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath($Workspace)
if(Test-Path -LiteralPath $workspace){throw '既存の検証領域は上書きしません'}
if([IO.Path]::GetFileName($DestinationName) -cne $DestinationName -or $DestinationName -in '','.','..'){throw '出力先は単一のディレクトリ名に限定します'}
$TestProgram=(Resolve-Path -LiteralPath $TestProgram).Path
$runner=(Resolve-Path -LiteralPath $RunnerPath).Path
$oracle=(Resolve-Path -LiteralPath $Oracle).Path
$candidate=(Resolve-Path -LiteralPath $Candidate).Path
$BodyDirectory=(Resolve-Path -LiteralPath $BodyDirectory).Path
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'test-enum-state.ps1'),[ref]$null,[ref]$null)
$helper=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-EnumProbe'},$true)
if(!$helper){throw '隔離・時間制限付きプローブがありません'}
. ([scriptblock]::Create($helper.Extent.Text))
$fixtures=@(foreach($family in $Families){foreach($method in $Methods){foreach($variant in $Variants){
    [pscustomobject]@{Family=$family;Method=$method;Variant=$variant;Path=(Resolve-Path -LiteralPath (Join-Path $BodyDirectory "$family-jm$method/$variant.lzh")).Path}
}}})
$hashes=@{}
$stamps=@{}
foreach($path in @($TestProgram,$runner,$oracle,$candidate)+@($fixtures.Path)){
    $hashes[$path]=(Get-FileHash -LiteralPath $path).Hash
    $stamps[$path]=[IO.File]::GetLastWriteTimeUtc($path)
}
New-Item -ItemType Directory -Path $workspace | Out-Null
Write-Host "Command CRC dialogs: candidate SHA256=$($hashes[$candidate]), oracle SHA256=$($hashes[$oracle])"
$observations=[Collections.Generic.List[object]]::new()
foreach($fixture in $fixtures){foreach($command in $Commands){foreach($policy in $Policies){foreach($profile in $Profiles){foreach($language in $Languages){
    $responses=switch($policy){
        'silent'{'6'}
        'delete-continue'{'6,6,6,6,6,6'}
        'jy-continue'{'6,6,6,6,6,6'}
        'keep-continue'{'7,6,7,6,7,6'}
        'delete-stop'{'6,7,2'}
        'keep-stop'{'7,7,2'}
    }
    $switches=if($policy -eq 'silent'){'-gm1 -y1'}elseif($policy -eq 'jy-continue'){'-gm0 -y1 -jyd1'}else{'-gm0 -y1'}
    $api=if($profile -in 'w64','w32','W-A32','none'){'W'}elseif($profile -eq 'legacy'){'legacy'}else{'A'}
    $layout=if($profile -in 'legacy','W-A32'){'a32'}else{$profile}
    $label="$($fixture.Family)-jm$($fixture.Method)-$($fixture.Variant)-$command-$policy-$profile-$language"
    $snapshots=@()
    $bad=$fixture.Variant -ne 'good'
    $stopping=$bad -and $command -ne 't' -and $policy -in 'delete-stop','keep-stop'
    $expectedResult=if($stopping){32780}else{0}
    $expectedDialogs=if(!$bad -or $command -eq 't' -or $policy -eq 'silent'){0}elseif($stopping){3}elseif($fixture.Variant -eq 'crc-all'){6}else{2}
    foreach($side in 'oracle','reimpl'){
        $root=Join-Path $workspace ('case-{0:D4}-{1}' -f $observations.Count,$side)
        $destination=Join-Path $root $DestinationName
        New-Item -ItemType Directory -Path $destination | Out-Null
        if($ExistingFiles){foreach($name in $(if($fixture.Family -eq 'japanese'){@('a-資料.txt','m-日本語.txt','z-空.txt')}else{@('a.txt','m.txt','z.txt')})){
            $path=Join-Path $destination $name
            [IO.File]::WriteAllText($path,"previous-$name",[Text.UTF8Encoding]::new($false))
            [IO.File]::SetLastWriteTimeUtc($path,[datetime]'2010-01-02T03:04:06Z')
        }}
        $dll=if($side -eq 'oracle'){$oracle}else{$candidate}
        $archive=$fixture.Path
        if($AuditRelease){$archive=Join-Path $root 'input.lzh'; Copy-Item -LiteralPath $fixture.Path -Destination $archive}
        $line="$command -+ $switches -n$NameMode `"$archive`" `"$($destination.Replace('\','/'))/`" *"
        # p の空の削除対象も含め、カレントディレクトリをこの試験専用領域に限定する。
        $arguments=@('--command-dialog-probe',$dll,$line,$responses,$layout,[string]$UnicodeMode,$api,'1041',[string]$language)
        if($AuditRelease){$arguments+=,$archive}
        $rows=@(Invoke-EnumProbe (Join-Path $root 'command') $arguments $root)
        $results=@($rows -match '^result=')
        if(!$results.Count -or $results[0] -cne "result=$expectedResult" -or $results.Count -ne $(if($AuditRelease){2}else{1})){throw "終了コードが違います: $label/$side"}
        if($AuditRelease -and ($results[1] -cne 'result=0' -or @($rows -ceq 'archive-released=1,error=0').Count -ne 2)){throw "書庫解放または後続の正常処理が失敗しました: $label/$side"}
        if((Get-FileHash -LiteralPath $archive).Hash -cne $hashes[$fixture.Path]){throw '入力書庫が変更されました'}
        if(@($rows -match '^command-dialog.count=').Count -ne 1 -or "command-dialog.count=$expectedDialogs" -notin $rows){throw "ダイアログの完了記録が違います: $label/$side"}
        foreach($kind in 'enum','progress'){
            $counts=@($rows -match "^$kind.count=")
            if($counts.Count -ne 1 -or @($rows -match "^$kind.entry=").Count -ne [int]($counts[0].Split('=')[1])){throw "通知の完了記録が違います: $label/$side/$kind"}
        }
        $effects=@(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object DirectoryName -ne $root | Sort-Object FullName | ForEach-Object {
            "file=$([IO.Path]::GetRelativePath($root,$_.FullName).Replace('\','/')),size=$($_.Length),sha256=$((Get-FileHash -LiteralPath $_.FullName).Hash),attributes=$([int]$_.Attributes),write=$($_.LastWriteTimeUtc.Ticks)"
        })
        if(!$bad -and $command -in 'e','x' -and $effects.Count -ne 3){throw '正常対照の展開数が違います'}
        $effects+=@(Get-ChildItem -LiteralPath $root -Recurse -Directory | Sort-Object FullName | ForEach-Object {
            "directory=$([IO.Path]::GetRelativePath($root,$_.FullName).Replace('\','/')),attributes=$([int]$_.Attributes)"
        })
        [IO.File]::WriteAllLines((Join-Path $root 'effects.txt'),[string[]]$effects)
        $snapshots+=,@((@($rows)+$effects) | ForEach-Object {$_.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>')})
    }
    $difference=@(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
    if($difference.Count){$difference | Export-Csv -LiteralPath (Join-Path $workspace "$label-diff.tsv") -Delimiter "`t" -NoTypeInformation}
    $observations.Add([pscustomobject]@{Case=$observations.Count;Label=$label;Differences=$difference.Count})
}}}}
    $observations | Export-Csv -LiteralPath (Join-Path $workspace 'observations.tsv') -Delimiter "`t" -NoTypeInformation
    Write-Host "$($fixture.Family)-jm$($fixture.Method)-$($fixture.Variant) comparisons=$($observations.Count)"
}
foreach($path in $hashes.Keys){if((Get-FileHash -LiteralPath $path).Hash -cne $hashes[$path] -or [IO.File]::GetLastWriteTimeUtc($path) -ne $stamps[$path]){throw "検証入力・バイナリーが変更されました: $path"}}
$expected=$fixtures.Count*$Commands.Count*$Policies.Count*$Profiles.Count*$Languages.Count
if(!$expected -or $observations.Count -ne $expected){throw '比較件数が不足しています'}
$failures=@($observations | Where-Object Differences -ne 0)
if($failures.Count){$failures | Format-Table -AutoSize | Out-String -Width 200 | Write-Host; throw 'CRC の確認内容・出力・通知・状態・ファイルが一致しません'}
Write-Host "Command CRC dialogs: $($observations.Count) exact comparisons and immutable-input guards passed"
