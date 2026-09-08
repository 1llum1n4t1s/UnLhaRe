[CmdletBinding(DefaultParameterSetName='Run')]
param(
    [Parameter(Mandatory,ParameterSetName='Run')][string]$TestProgram,
    [Parameter(Mandatory,ParameterSetName='Run')][string]$RunnerPath,
    [Parameter(Mandatory,ParameterSetName='Run')][string]$Oracle,
    [Parameter(Mandatory,ParameterSetName='Run')][string]$Candidate,
    [Parameter(Mandatory,ParameterSetName='Run')][string]$Workspace,
    [Parameter(Mandatory,ParameterSetName='Plan')][switch]$PlanOnly,
    [ValidateSet('legacy','A','W')][string[]]$Apis=@('legacy','A','W'),
    [ValidateSet(1041,1033)][int[]]$Languages=@(1041,1033),
    [string[]]$CaseNames=@(),
    [ValidateSet('auto','none','a32','a64','w32','w64')][string]$EnumLayout='auto',
    [ValidateSet(0,1)][int]$UnicodeMode=0,
    [string]$DestinationSuffix=''
)
$ErrorActionPreference='Stop'
if($DestinationSuffix.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0){throw '出力先の接尾辞はファイル名の文字に限定します'}
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$definitions=@(
    @{Name='yes';Responses='1,1';Written=@(0,1)},
    @{Name='skip';Responses='22:1,22:1';Written=@()},
    @{Name='all';Responses='23:1';Written=@(0,1)},
    @{Name='skip-all';Responses='24:1';Written=@()},
    @{Name='skip-then-yes';Responses='22:1,1';Written=@(1)},
    @{Name='yes-then-cancel';Responses='1,2,2';Written=@(0);Result=32800},
    @{Name='cancel';Responses='2,2';Written=@();Result=32800},
    @{Name='skip-all-new';Responses='24:1';Written=@(1);NewSecond=$true},
    @{Name='m1';Responses='';Written=@(0,1);Extra='-m1'},
    @{Name='y1';Responses='';Written=@(0,1);Extra='-y1'},
    @{Name='y1-m0';Responses='1,1';Written=@(0,1);Extra='-y1 -m0'},
    @{Name='m1-jyo0';Responses='1,1';Written=@(0,1);Extra='-m1 -jyo0'},
    @{Name='jyo0-m1';Responses='';Written=@(0,1);Extra='-jyo0 -m1'},
    @{Name='jyo-toggle';Responses='1,1';Written=@(0,1);Extra='-m0 -jyo -jyo'},
    @{Name='jyc-independent';Responses='1,1';Written=@(0,1);Extra='-m0 -jyc1'},
    @{Name='silent';Responses='';Written=@(0,1);Extra='-gm1'},
    @{Name='future';Responses='';Written=@();Future=$true},
    @{Name='new-only';Responses='';Written=@();Extra='-jn1'},
    @{Name='older-only';Responses='';Written=@();Extra='-u2'},
    @{Name='existing-only';Responses='1';Written=@(0);NewSecond=$true;Extra='-gf1'},
    @{Name='x-query';Responses='1,1';Written=@(0,1);Command='x';Extra='-x0 -m0'},
    @{Name='n0';Responses='1,1';Written=@(0,1);Display=0},
    @{Name='n2';Responses='1,1';Written=@(0,1);Display=2},
    @{Name='reject';Responses='';Written=@();Reject=$true},
    @{Name='ro-yes';Responses='1,1,1,1';Written=@(0,1);Attributes=33},
    @{Name='ro-skip';Responses='1,22:1,1,22:1';Written=@();Attributes=33},
    @{Name='ro-normal-all';Responses='23:1,1,1';Written=@(0,1);Attributes=33},
    @{Name='ro-protected-all';Responses='1,23:1,1';Written=@(0,1);Attributes=33},
    @{Name='ro-both-all';Responses='23:1,23:1';Written=@(0,1);Attributes=33},
    @{Name='ro-both-skip';Responses='23:1,24:1';Written=@();Attributes=33},
    @{Name='ro-cancel';Responses='1,2,2';Written=@();Attributes=33;Result=32800},
    @{Name='ro-m1';Responses='1,1';Written=@(0,1);Attributes=33;Extra='-m1'},
    @{Name='ro-y1';Responses='1,1';Written=@(0,1);Attributes=33;Extra='-y1'},
    @{Name='ro-ga1';Responses='1,1';Written=@(0,1);Attributes=33;Extra='-ga1'},
    @{Name='ro-ga2';Responses='1,1';Written=@();Attributes=33;Extra='-ga2'},
    @{Name='ro-silent';Responses='';Written=@();Attributes=33;Extra='-gm1'},
    @{Name='hidden';Responses='1,1,1,1';Written=@(0,1);Attributes=34},
    @{Name='system';Responses='1,1,1,1';Written=@(0,1);Attributes=36},
    @{Name='all-attributes';Responses='1,1,1,1';Written=@(0,1);Attributes=39}
)
foreach($axis in 'Apis','Languages'){
    $values=@(Get-Variable -Name $axis -ValueOnly)
    if(!$values.Count -or @($values | Select-Object -Unique).Count -ne $values.Count){throw "空または重複した検証軸: $axis"}
}
foreach($name in $CaseNames){if($name -cnotin $definitions.Name){throw "未知の上書き確認ケース: $name"}}
$selected=@($definitions | Where-Object {!$CaseNames.Count -or $_.Name -cin $CaseNames})
$plan=@(foreach($case in $selected){foreach($api in $Apis){foreach($language in $Languages){
    [pscustomobject]@{Name=$case.Name;Api=$api;Language=$language;Case=$case}
}}})
if(!$plan.Count){throw '比較対象がありません'}
if($PlanOnly){"Overwrite dialog plan only: $($plan.Count) sequences; NOT RUN";$plan | Select-Object Name,Api,Language;return}
foreach($name in 'TestProgram','RunnerPath','Oracle','Candidate'){Set-Variable -Name $name -Value (Resolve-Path -LiteralPath (Get-Variable -Name $name -ValueOnly)).Path}
$Workspace=[IO.Path]::GetFullPath($Workspace)
if(Test-Path -LiteralPath $Workspace){throw '既存の検証領域は上書きしません'}
New-Item -ItemType Directory -Path $Workspace | Out-Null
$hashes=@{}
foreach($path in $TestProgram,$RunnerPath,$Oracle,$Candidate,$PSCommandPath){$hashes[$path]=(Get-FileHash -LiteralPath $path).Hash}
[IO.File]::WriteAllText((Join-Path $Workspace 'environment.json'),($hashes | ConvertTo-Json))
[IO.File]::WriteAllText((Join-Path $Workspace 'plan.json'),($plan | Select-Object Name,Api,Language | ConvertTo-Json))
[IO.File]::WriteAllText((Join-Path $Workspace 'options.json'),(@{EnumLayout=$EnumLayout;UnicodeMode=$UnicodeMode;DestinationSuffix=$DestinationSuffix} | ConvertTo-Json))
$source=Join-Path $Workspace 'input'
New-Item -ItemType Directory -Path (Join-Path $source 'folder') | Out-Null
$members=@('folder/nested.txt','other.txt')
$leaves=@('nested.txt','other.txt')
$bodies=@(('A'*100),('B'*77))
$kept=@('SAFE','KEEP')
for($i=0;$i -lt 2;$i++){
    $path=Join-Path $source $members[$i]
    [IO.File]::WriteAllText($path,$bodies[$i],[Text.UTF8Encoding]::new($false))
    $file=Get-Item -LiteralPath $path
    $file.CreationTimeUtc=$file.LastWriteTimeUtc=$file.LastAccessTimeUtc=[datetime]'2024-01-02T03:04:06Z'
}
$seed=Join-Path $Workspace 'seed.lzh'
$line='a -n1 -gm1 -y1 -jm0 -h2 -x1 "'+$seed+'" "'+$source+'/" folder/nested.txt other.txt'
$created=@(& $RunnerPath --timeout-seconds 30 $TestProgram --registry '' --command-probe $Oracle $line 2>&1 | ForEach-Object {"$_"})
[IO.File]::WriteAllLines((Join-Path $Workspace 'seed.log'),[string[]]$created)
if($LASTEXITCODE -ne 0 -or 'result=0' -cnotin $created){throw '上書き確認の入力書庫を作成できません'}
$seedHash=(Get-FileHash -LiteralPath $seed).Hash
$done=0
$watch=[Diagnostics.Stopwatch]::StartNew()
foreach($item in $plan){
    $case=$item.Case
    $label="$($item.Name)-$($item.Api)-$($item.Language)"
    $observed=@{};$effects=@{}
    foreach($side in 'oracle','reimpl'){
        $root=Join-Path $Workspace "$label/$side"
        New-Item -ItemType Directory -Path $root | Out-Null
        $archive=Join-Path $root 'source.lzh'
        Copy-Item -LiteralPath $seed -Destination $archive
        $commands=@()
        foreach($phase in 'first','second'){
            $output=Join-Path $root ($phase+$DestinationSuffix)
            New-Item -ItemType Directory -Path $output | Out-Null
            for($i=0;$i -lt 2;$i++){
                if($phase -eq 'first' -and $case.NewSecond -and $i -eq 1){continue}
                $path=Join-Path $output $leaves[$i]
                [IO.File]::WriteAllText($path,$kept[$i],[Text.UTF8Encoding]::new($false))
                $file=Get-Item -LiteralPath $path
                $time=if($phase -eq 'first' -and $case.Future){[datetime]'2030-01-02T03:04:06Z'}else{[datetime]'2020-01-02T03:04:06Z'}
                $file.CreationTimeUtc=$file.LastWriteTimeUtc=$file.LastAccessTimeUtc=$time
                $file.Attributes=if($phase -eq 'first' -and $case.ContainsKey('Attributes')){$case.Attributes}else{32}
            }
            $display=if($phase -eq 'first' -and $case.ContainsKey('Display')){$case.Display}else{1}
            $command=if($phase -eq 'first' -and $case.Command){$case.Command}else{'e'}
            $extra=if($phase -eq 'first'){$case.Extra}else{''}
            $commands+=($command+' -n'+$display+' '+$extra+' "'+$archive+'" "'+$output+'/" *')
        }
        $responses=if($case.Responses){$case.Responses+',22:1,1'}else{'22:1,1'}
        $expectedDialogs=@($responses.Split(',')).Count
        $layout=if($EnumLayout -ne 'auto'){$EnumLayout}elseif($item.Api -eq 'W'){'w64'}else{'a32'}
        $progressLayout=if($layout -eq 'none'){'w64'}else{$layout}
        $steps=@('@initial-language:'+$item.Language)
        if($case.Reject){$steps+='@reject'}
        $steps+=@($commands[0],('@audit-archive-release:'+$archive),'@accept',$commands[1],('@audit-archive-release:'+$archive),'@cp-state')
        $dll=if($side -eq 'oracle'){$Oracle}else{$Candidate}
        $arguments=@('--sequence-dialog-probe',$dll,$responses,$layout,'1041',"$UnicodeMode",$item.Api,$progressLayout)+$steps
        [IO.File]::WriteAllText((Join-Path $root 'invocation.json'),($arguments | ConvertTo-Json))
        $rows=@(& $RunnerPath --timeout-seconds 60 $TestProgram --registry '' @arguments 2>&1 | ForEach-Object {"$_"})
        $code=$LASTEXITCODE
        [IO.File]::WriteAllLines((Join-Path $root 'command.log'),[string[]]$rows)
        if($code -ne 0){throw "上書き確認 $label/$side が停止しました: $code"}
        $firstResult=if($case.ContainsKey('Result')){$case.Result}else{0}
        $results=@($rows | Where-Object {$_ -match '^result='})
        if([string]::Join('|',$results) -cne "result=$firstResult|result=0" -or
            "command-dialog.count=$expectedDialogs" -cnotin $rows){throw "上書き確認 $label/$side の終了状態・確認件数が異なります"}
        if(@($rows | Where-Object {$_ -ceq 'archive-released=1,error=0'}).Count -ne 2){throw "上書き確認 $label/$side で入力ハンドルが保持されています"}
        if((Get-FileHash -LiteralPath $archive).Hash -cne $seedHash){throw '入力書庫が変更されました'}
        $state=@()
        foreach($phase in 'first','second'){
            for($i=0;$i -lt 2;$i++){
                $path=Join-Path $root "$phase$DestinationSuffix/$($leaves[$i])"
                $written=if($phase -eq 'first'){$i -in $case.Written}else{$i -eq 1}
                if($phase -eq 'first' -and $case.NewSecond -and $i -eq 1 -and !$written){
                    if(Test-Path -LiteralPath $path){throw "上書き確認 $label/$side は対象外の新規ファイルを作成しました"}
                    $state+="$phase/$($leaves[$i]): absent"
                    continue
                }
                $expected=if($written){$bodies[$i]}else{$kept[$i]}
                if([IO.File]::ReadAllText($path) -cne $expected){throw "上書き確認 $label/$side/$phase の本文・保持判定が異なります"}
                $file=Get-Item -LiteralPath $path -Force
                $state+="$phase/$($leaves[$i]): $($file.Length),$([int]$file.Attributes),$($file.CreationTimeUtc.Ticks),$($file.LastWriteTimeUtc.Ticks)"
            }
        }
        if(@(Get-ChildItem -LiteralPath $root -File -Recurse -Force | Where-Object {$_.Name -match '^LHT.*\.TMP$'}).Count){throw '一時ファイルが残りました'}
        $effects[$side]=$state
        [IO.File]::WriteAllLines((Join-Path $root 'effects.log'),[string[]]$state)
        $observed[$side]=@($rows | ForEach-Object {$_.Replace($root.Replace('\','/'),'<case>').Replace($root.Replace('\','\\'),'<case>').Replace($root,'<case>')})
    }
    $difference=@(Compare-Object $observed.oracle $observed.reimpl -SyncWindow 0)
    if($difference.Count -or [string]::Join('|',$effects.oracle) -cne [string]::Join('|',$effects.reimpl)){
        [IO.File]::WriteAllText((Join-Path $Workspace "$label.diff.log"),($difference | Format-List | Out-String -Width 2000))
        throw "上書き確認 $label の通知・画面・ログ・状態・メタデータが一致しません"
    }
    $done++
    if($done % 5 -eq 0){"Overwrite dialogs progress: $done/$($plan.Count) sequences compatible; $([math]::Round($watch.Elapsed.TotalSeconds,1)) seconds"}
}
$race=@(& $RunnerPath --timeout-seconds 30 $TestProgram --registry '' --overwrite-race-probe $Candidate $seed `
    (Join-Path $source $members[0]) (Join-Path $Workspace 'race-guard') 2>&1 | ForEach-Object {"$_"})
[IO.File]::WriteAllLines((Join-Path $Workspace 'race-guard.log'),[string[]]$race)
if($LASTEXITCODE -ne 0 -or 'overwrite.race=preserved,subsequent=passed,input-released=1' -cnotin $race){throw '確認前に現れた既存ファイルの保護・再利用に失敗しました'}
foreach($path in $hashes.Keys){if((Get-FileHash -LiteralPath $path).Hash -cne $hashes[$path]){throw '比較中に実行物が変更されました'}}
if((Get-FileHash -LiteralPath $seed).Hash -cne $seedHash){throw '比較中に入力書庫が変更されました'}
for($i=0;$i -lt 2;$i++){if([IO.File]::ReadAllText((Join-Path $source $members[$i])) -cne $bodies[$i]){throw '圧縮元の本文が変更されました'}}
"Overwrite dialogs: $done first-call and same-DLL retry sequences compatible; bodies, preserved files, dialogs, metadata, callbacks and errors verified"
