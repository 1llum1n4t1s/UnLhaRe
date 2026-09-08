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
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
if($DestinationSuffix.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0){throw '出力先の接尾辞はファイル名の文字に限定します'}
$definitions=@(
    @{Name='yes';Responses='1,1';Written=@(0,1,2,3)},
    @{Name='skip';Responses='22:1,22:1,22:1';Written=@(3)},
    @{Name='all';Responses='23:1';Written=@(0,1,2,3)},
    @{Name='skip-all';Responses='24:1';Written=@(3)},
    @{Name='skip-then-yes';Responses='22:1,1,1';Written=@(1,2,3)},
    @{Name='yes-then-cancel';Responses='1,2,2';Written=@(0,1);Result=32800},
    @{Name='cancel';Responses='2,2';Written=@();Result=32800},
    @{Name='existing-parent';Responses='1';Written=@(0,1,2,3);ExistingParent=$true},
    @{Name='missing-base';Responses='1,1';Written=@(0,1,2,3);MissingBase=$true},
    @{Name='missing-base-skip-all';Responses='24:1';Written=@();MissingBase=$true},
    @{Name='default-x';Responses='';Written=@(0,1,2,3);Switches=''},
    @{Name='m1';Responses='';Written=@(0,1,2,3);Switches='-m1'},
    @{Name='y1';Responses='';Written=@(0,1,2,3);Switches='-m0 -y1'},
    @{Name='y1-m0';Responses='1,1';Written=@(0,1,2,3);Switches='-y1 -m0'},
    @{Name='m0-jyc1';Responses='';Written=@(0,1,2,3);Switches='-m0 -jyc1'},
    @{Name='m1-jyc0';Responses='1,1';Written=@(0,1,2,3);Switches='-m1 -jyc0'},
    @{Name='jyc0-m1';Responses='';Written=@(0,1,2,3);Switches='-jyc0 -m1'},
    @{Name='jyc-toggle';Responses='1,1';Written=@(0,1,2,3);Switches='-m0 -jyc -jyc'},
    @{Name='jyo-independent';Responses='1,1';Written=@(0,1,2,3);Switches='-m0 -jyo1'},
    @{Name='silent';Responses='';Written=@(0,1,2,3);Switches='-m0 -gm1'},
    @{Name='registry';Responses='';Written=@(0,1,2,3);Switches='';Command='e';MissingBase=$true;Registry='L:MakeDirectoryMode=1'},
    @{Name='registry-explicit';Responses='1,1';Written=@(0,1,2,3);Registry='L:MakeDirectoryMode=1'},
    @{Name='registry-bypass';Responses='1';Written=@(0,1,2,3);Switches='-+';Command='e';MissingBase=$true;Registry='L:MakeDirectoryMode=1'},
    @{Name='e-existing';Responses='';Written=@(0,1,2,3);Command='e'},
    @{Name='e-missing';Responses='1';Written=@(0,1,2,3);Command='e';MissingBase=$true},
    @{Name='e-missing-skip';Responses='24:1';Written=@();Command='e';MissingBase=$true},
    @{Name='existing-only';Responses='';Written=@();Switches='-m0 -gf1'},
    @{Name='reject';Responses='';Written=@();Reject=$true},
    @{Name='n0';Responses='1,1';Written=@(0,1,2,3);Display=0},
    @{Name='n2';Responses='1,1';Written=@(0,1,2,3);Display=2}
)
foreach($axis in 'Apis','Languages'){
    $values=@(Get-Variable -Name $axis -ValueOnly)
    if(!$values.Count -or @($values | Select-Object -Unique).Count -ne $values.Count){throw "空または重複した検証軸: $axis"}
}
foreach($name in $CaseNames){if($name -cnotin $definitions.Name){throw "未知のディレクトリ確認ケース: $name"}}
$plan=@(foreach($case in $definitions){if(!$CaseNames.Count -or $case.Name -cin $CaseNames){foreach($api in $Apis){foreach($language in $Languages){
    [pscustomobject]@{Name=$case.Name;Api=$api;Language=$language;Case=$case}
}}}})
if(!$plan.Count){throw '比較対象がありません'}
if($PlanOnly){"Directory dialog plan only: $($plan.Count) sequences; NOT RUN";$plan | Select-Object Name,Api,Language;return}
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
foreach($directory in 'alpha','beta'){New-Item -ItemType Directory -Path (Join-Path $source $directory) | Out-Null}
$members=@('alpha/a.txt','alpha/b.txt','beta/c.txt','root.txt')
$bodies=@(('A'*100),('B'*77),('C'*51),('D'*31))
for($i=0;$i -lt $members.Count;$i++){
    $path=Join-Path $source $members[$i]
    [IO.File]::WriteAllText($path,$bodies[$i],[Text.UTF8Encoding]::new($false))
    $file=Get-Item -LiteralPath $path
    $file.CreationTimeUtc=$file.LastWriteTimeUtc=$file.LastAccessTimeUtc=[datetime]'2024-01-02T03:04:06Z'
}
$seed=Join-Path $Workspace 'seed.lzh'
$line='a -n1 -gm1 -y1 -jm0 -h2 -x1 "'+$seed+'" "'+$source+'/" '+[string]::Join(' ',$members)
$created=@(& $RunnerPath --timeout-seconds 30 $TestProgram --registry '' --command-probe $Oracle $line 2>&1 | ForEach-Object {"$_"})
[IO.File]::WriteAllLines((Join-Path $Workspace 'seed.log'),[string[]]$created)
if($LASTEXITCODE -ne 0 -or 'result=0' -cnotin $created){throw 'ディレクトリ確認の入力書庫を作成できません'}
$seedHash=(Get-FileHash -LiteralPath $seed).Hash
$done=0
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
            if($phase -ne 'first' -or !$case.MissingBase){New-Item -ItemType Directory -Path $output | Out-Null}
            if($phase -eq 'first' -and $case.ExistingParent){New-Item -ItemType Directory -Path (Join-Path $output 'alpha') | Out-Null}
            $display=if($phase -eq 'first' -and $case.ContainsKey('Display')){$case.Display}else{1}
            $command=if($phase -eq 'first' -and $case.Command){$case.Command}else{'x'}
            $switches=if($phase -eq 'first' -and $case.ContainsKey('Switches')){$case.Switches}else{'-m0'}
            $commands+=($command+' -n'+$display+' '+$switches+' "'+$archive+'" "'+$output+'/" *')
        }
        # 次の命令でも新しい親を作らせ、一括回答・中止・設定の持ち越しを検出する。
        $responses=if($case.Responses){$case.Responses+',23:1'}else{'23:1'}
        $expectedDialogs=@($responses.Split(',')).Count
        $layout=if($EnumLayout -ne 'auto'){$EnumLayout}elseif($item.Api -eq 'W'){'w64'}else{'a32'}
        $progressLayout=if($layout -eq 'none'){'w64'}else{$layout}
        $steps=@('@initial-language:'+$item.Language)
        if($case.Reject){$steps+='@reject'}
        $steps+=@($commands[0],('@audit-archive-release:'+$archive),'@accept',$commands[1],('@audit-archive-release:'+$archive),'@cp-state')
        $dll=if($side -eq 'oracle'){$Oracle}else{$Candidate}
        $arguments=@('--sequence-dialog-probe',$dll,$responses,$layout,'1041',"$UnicodeMode",$item.Api,$progressLayout)+$steps
        [IO.File]::WriteAllText((Join-Path $root 'invocation.json'),($arguments | ConvertTo-Json))
        $registry=if($case.Registry){$case.Registry}else{''}
        $rows=@(& $RunnerPath --timeout-seconds 60 $TestProgram --registry $registry @arguments 2>&1 | ForEach-Object {"$_"})
        $code=$LASTEXITCODE
        [IO.File]::WriteAllLines((Join-Path $root 'command.log'),[string[]]$rows)
        if($code -ne 0){throw "ディレクトリ確認 $label/$side が停止しました: $code"}
        $firstResult=if($case.ContainsKey('Result')){$case.Result}else{0}
        $results=@($rows | Where-Object {$_ -match '^result='})
        if([string]::Join('|',$results) -cne "result=$firstResult|result=0" -or "command-dialog.count=$expectedDialogs" -cnotin $rows){throw "ディレクトリ確認 $label/$side の終了状態・確認件数が異なります"}
        if(@($rows -ceq 'archive-released=1,error=0').Count -ne 2){throw '入力ハンドルが保持されています'}
        if((Get-FileHash -LiteralPath $archive).Hash -cne $seedHash){throw '入力書庫が変更されました'}
        $state=@()
        foreach($phase in 'first','second'){
            $output=Join-Path $root ($phase+$DestinationSuffix)
            $expectedFiles=@()
            for($i=0;$i -lt $members.Count;$i++){
                $member=if($phase -eq 'first' -and $case.Command -eq 'e'){[IO.Path]::GetFileName($members[$i])}else{$members[$i]}
                $path=Join-Path $output $member
                $written=$phase -eq 'second' -or $i -in $case.Written
                if(!$written){if(Test-Path -LiteralPath $path){throw "対象外の保存先が作成されました: $label/$side/$phase/$member"};continue}
                $expectedFiles+=$member
                if([IO.File]::ReadAllText($path) -cne $bodies[$i]){throw "本文が異なります: $label/$side/$phase/$member"}
                $file=Get-Item -LiteralPath $path -Force
                $state+="$phase/$member`: $($file.Length),$([int]$file.Attributes),$($file.CreationTimeUtc.Ticks),$($file.LastWriteTimeUtc.Ticks)"
            }
            $actualFiles=@(if(Test-Path -LiteralPath $output){Get-ChildItem -LiteralPath $output -Recurse -Force -File | ForEach-Object {$_.FullName.Substring($output.Length+1).Replace('\','/')}})
            if([string]::Join('|',@($expectedFiles | Sort-Object)) -cne [string]::Join('|',@($actualFiles | Sort-Object))){throw '予定外のファイルが残りました'}
            $state+="$phase/base-exists=$(Test-Path -LiteralPath $output)"
            if(Test-Path -LiteralPath $output){
                $state+=@(Get-ChildItem -LiteralPath $output -Recurse -Force -Directory | Sort-Object FullName | ForEach-Object {"$phase/dir=$($_.FullName.Substring($output.Length+1).Replace('\','/')),attributes=$([int]$_.Attributes)"})
            }
        }
        $effects[$side]=$state
        [IO.File]::WriteAllLines((Join-Path $root 'effects.log'),[string[]]$state)
        $observed[$side]=@($rows | ForEach-Object {$_.Replace($root.Replace('\','/'),'<case>').Replace($root.Replace('\','\\'),'<case>').Replace($root,'<case>')})
    }
    $difference=@(Compare-Object $observed.oracle $observed.reimpl -SyncWindow 0)
    if($difference.Count -or [string]::Join('|',$effects.oracle) -cne [string]::Join('|',$effects.reimpl)){
        [IO.File]::WriteAllText((Join-Path $Workspace "$label.diff.log"),($difference | Format-List | Out-String -Width 2000))
        throw "ディレクトリ確認 $label の通知・画面・ログ・状態・保存結果が一致しません"
    }
    $done++
    if($done % 5 -eq 0){"Directory dialogs progress: $done/$($plan.Count) sequences compatible"}
}
foreach($path in $hashes.Keys){if((Get-FileHash -LiteralPath $path).Hash -cne $hashes[$path]){throw '比較中に実行物が変更されました'}}
if((Get-FileHash -LiteralPath $seed).Hash -cne $seedHash){throw '比較中に入力書庫が変更されました'}
for($i=0;$i -lt $members.Count;$i++){if([IO.File]::ReadAllText((Join-Path $source $members[$i])) -cne $bodies[$i]){throw '圧縮元の本文が変更されました'}}
"Directory dialogs: $done first-call and same-DLL retry sequences compatible; bodies, directory effects, dialogs, callbacks and errors verified"
