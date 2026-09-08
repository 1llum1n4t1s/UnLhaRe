[CmdletBinding(DefaultParameterSetName='Run')]
param(
    [Parameter(Mandatory,ParameterSetName='Run')][string]$TestProgram,
    [Parameter(Mandatory,ParameterSetName='Run')][string]$RunnerPath,
    [Parameter(Mandatory,ParameterSetName='Run')][string]$Oracle,
    [Parameter(Mandatory,ParameterSetName='Run')][string]$Candidate,
    [Parameter(Mandatory,ParameterSetName='Run')][string]$SeedArchive,
    [Parameter(Mandatory,ParameterSetName='Run')][string]$Workspace,
    [Parameter(Mandatory,ParameterSetName='Plan')][switch]$PlanOnly,
    [string]$Member='folder/nested.txt',
    [switch]$Directory,
    [string[]]$CaseLabels=@()
)
$ErrorActionPreference='Stop'
$all=@(foreach($api in 'legacy','A','W'){foreach($language in 1041,1033){
    foreach($owner in 'none','hidden','visible','child','offscreen'){foreach($protected in $(if($Directory){@($false)}else{@($false,$true)})){
        $kind=if($Directory){'directory'}elseif($protected){'protected'}else{'normal'}
        [pscustomobject]@{Label="$api-$language-$owner-$kind";Api=$api;Language=$language;Owner=$owner;Protected=$protected}
    }}
}})
foreach($label in $CaseLabels){if($label -cnotin $all.Label){throw "未知の画面比較条件: $label"}}
$plan=@($all | Where-Object {!$CaseLabels.Count -or $_.Label -cin $CaseLabels})
if($PlanOnly){Write-Host "Overwrite layout plan: $($plan.Count) comparisons; NOT RUN";return $plan}
$leaf=[IO.Path]::GetFileName($Member.Replace('/','\'))
if(!$leaf -or $leaf -in '.','..'){throw '通常ファイルのメンバー名が必要です'}
foreach($name in 'TestProgram','RunnerPath','Oracle','Candidate','SeedArchive'){
    Set-Variable -Name $name -Value (Resolve-Path -LiteralPath (Get-Variable -Name $name -ValueOnly)).Path
}
$Workspace=[IO.Path]::GetFullPath($Workspace)
if(Test-Path -LiteralPath $Workspace){throw '既存の検証領域は上書きしません'}
New-Item -ItemType Directory -Path $Workspace | Out-Null
$hashes=@{}
foreach($path in $TestProgram,$RunnerPath,$Oracle,$Candidate,$SeedArchive,$PSCommandPath){$hashes[$path]=(Get-FileHash -LiteralPath $path).Hash}
[IO.File]::WriteAllText((Join-Path $Workspace 'environment.json'),($hashes | ConvertTo-Json))
[IO.File]::WriteAllText((Join-Path $Workspace 'plan.json'),($plan | ConvertTo-Json))
$done=0
foreach($item in $plan){
    $snapshots=@{}
    foreach($side in 'oracle','reimpl'){
        $root=Join-Path $Workspace "$($item.Label)/$side"
        $output=Join-Path $root 'output'
        New-Item -ItemType Directory -Path $output | Out-Null
        $archive=Join-Path $root 'source.lzh'
        Copy-Item -LiteralPath $SeedArchive -Destination $archive
        $existing=Join-Path $output $leaf
        if(!$Directory){
            [IO.File]::WriteAllText($existing,'SAFE',[Text.UTF8Encoding]::new($false))
            $file=Get-Item -LiteralPath $existing
            $file.CreationTimeUtc=$file.LastWriteTimeUtc=$file.LastAccessTimeUtc=[datetime]'2020-01-02T03:04:06Z'
            $file.Attributes=if($item.Protected){33}else{32}
        }
        $switches=if($item.Protected){'-m1'}else{''}
        $command='e -n1 -c1 '+$switches+' "'+$archive+'" "'+$output+'/" "'+$Member+'"'
        if($Directory){$command='x -n1 -m0 "'+$archive+'" "'+$output+'/" "'+$Member+'"'}
        $response=if($item.Owner -eq 'none'){'inspect-layout'}else{'inspect-layout:'+$item.Owner}
        $dll=if($side -eq 'oracle'){$Oracle}else{$Candidate}
        $arguments=@('--command-dialog-probe',$dll,$command,$response,'none','0',$item.Api,'1041',"$($item.Language)")
        $rows=@(& $RunnerPath --timeout-seconds 30 $TestProgram --registry '' @arguments 2>&1 | ForEach-Object {"$_"})
        $code=$LASTEXITCODE
        [IO.File]::WriteAllLines((Join-Path $root 'command.log'),[string[]]$rows)
        if($code -ne 125 -or @($rows -ceq 'command dialog observation completed').Count -ne 1){
            throw "画面観測 $($item.Label)/$side が予期しない状態で終了しました: $code"
        }
        # 観測専用終了の標準エラーは別ストリームのため、画面自身の順序付き全22行を比較する。
        $snapshot=@($rows | Where-Object {$_ -match '^(dialog\.|control\.|command-dialog\.)'})
        if($snapshot.Count -ne 22 -or 'command-dialog.begin=0' -cnotin $snapshot -or
            'command-dialog.end=0' -cnotin $snapshot -or @($snapshot -match '^control.geometry=').Count -ne 8){
            throw "画面観測 $($item.Label)/$side の項目が不足しています"
        }
        $snapshots[$side]=@($snapshot | ForEach-Object {$_.Replace($root.Replace('\','\\'),'<case>').Replace($root.Replace('\','/'),'<case>').Replace($root,'<case>')})
        $preserved=if($Directory){@(Get-ChildItem -LiteralPath $output -Force).Count -eq 0}else{[IO.File]::ReadAllText($existing) -ceq 'SAFE'}
        if(!$preserved -or
            (Get-FileHash -LiteralPath $archive).Hash -cne $hashes[$SeedArchive]){throw '未応答の画面観測で入力・出力先が変化しました'}
    }
    $difference=@(Compare-Object $snapshots.oracle $snapshots.reimpl -SyncWindow 0)
    if($difference.Count){
        [IO.File]::WriteAllText((Join-Path $Workspace "$($item.Label).diff.log"),($difference | Format-List | Out-String -Width 2000))
        throw "ファイル確認画面の位置・内容・フォント・配置が一致しません: $($item.Label)"
    }
    $done++
    if($done % 10 -eq 0){"Overwrite layout progress: $done/$($plan.Count) compatible"}
}
foreach($path in $hashes.Keys){if((Get-FileHash -LiteralPath $path).Hash -cne $hashes[$path]){throw '画面比較中に入力・実行物が変更されました'}}
"Overwrite layout: $done exact 22-row snapshots compatible; input and unconfirmed output preserved"
