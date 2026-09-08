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
    @{Name='skip';Writes=@('other')},
    @{Name='skip-last';Locked=@('other');Writes=@('nested')},
    @{Name='skip-both';Locked=@('nested','other');Writes=@()},
    @{Name='x-skip';Command='x';Writes=@('other')},
    @{Name='normal';Locked=@();Writes=@('nested','other')},
    @{Name='x-normal';Command='x';Locked=@();Writes=@('nested','other')},
    @{Name='stop1';Switches='-m1 -jse1';Stop=$true;Responses='2';Writes=@()},
    @{Name='stop2-last';Switches='-m1 -jse2';Locked=@('other');Stop=$true;Responses='2';Writes=@('nested')},
    @{Name='x-stop';Command='x';Switches='-m1 -jse1';Stop=$true;Responses='2';Writes=@()},
    @{Name='bare';Switches='-m1 -jse';Stop=$true;Responses='2';Writes=@()},
    @{Name='zero';Switches='-m1 -jse0';Writes=@('other')},
    @{Name='minus';Switches='-m1 -jse-';Writes=@('other')},
    @{Name='plus';Switches='-m1 -jse+';Stop=$true;Responses='2';Writes=@()},
    @{Name='invalid-digit';Switches='-m1 -jse9';Stop=$true;Responses='2';Writes=@()},
    @{Name='disable-last';Switches='-m1 -jse1 -jse0';Writes=@('other')},
    @{Name='enable-last';Switches='-m1 -jse0 -jse1';Stop=$true;Responses='2';Writes=@()},
    @{Name='combined';Switches='-m1 -jse0e1';Stop=$true;Responses='2';Writes=@()},
    @{Name='silent-stop';Switches='-m1 -jse1 -gm1';Stop=$true;Writes=@()},
    @{Name='silent-skip';Switches='-m1 -gm1';Writes=@('other')},
    @{Name='capacity-disabled';Switches='-m1 -f';Writes=@('other')},
    @{Name='injected-skip';InjectedError=5;Locked=@();Writes=@('other')},
    @{Name='injected-stop';InjectedError=5;Locked=@();Switches='-m1 -jse1';Stop=$true;Responses='2';Writes=@()},
    @{Name='injected-full';InjectedError=112;Locked=@();Switches='-m1 -jse2';Stop=$true;Responses='2';Writes=@()},
    @{Name='injected-new';InjectedError=5;Locked=@();New=$true;Writes=@('other')},
    @{Name='injected-x';Command='x';InjectedError=5;Locked=@();Writes=@('other')}
)
foreach($axis in 'Apis','Languages'){
    $values=Get-Variable -Name $axis -ValueOnly
    if(!@($values).Count -or @($values | Select-Object -Unique).Count -ne @($values).Count){throw "空または重複した検証軸: $axis"}
}
foreach($name in $CaseNames){if($name -cnotin $definitions.Name){throw "未知のファイル作成失敗条件: $name"}}
$plan=@(foreach($case in $definitions){if(!$CaseNames.Count -or $case.Name -cin $CaseNames){foreach($api in $Apis){foreach($language in $Languages){
    [pscustomobject]@{Name=$case.Name;Api=$api;Language=$language;Case=$case}
}}}})
if(!$plan.Count){throw '比較対象がありません'}
if($PlanOnly){"Create failure plan only: $($plan.Count) sequences; NOT RUN";$plan | Select-Object Name,Api,Language;return}
foreach($name in 'TestProgram','RunnerPath','Oracle','Candidate'){Set-Variable -Name $name -Value (Resolve-Path -LiteralPath (Get-Variable -Name $name -ValueOnly)).Path}
$Workspace=[IO.Path]::GetFullPath($Workspace)
if(Test-Path -LiteralPath $Workspace){throw '既存の検証領域は上書きしません'}
$source=Join-Path $Workspace 'input'
New-Item -ItemType Directory -Path (Join-Path $source 'folder') | Out-Null
$bodies=@{nested=('A'*100);other=('B'*77)}
foreach($member in 'folder/nested.txt','other.txt'){
    $path=Join-Path $source $member
    [IO.File]::WriteAllText($path,$bodies[$(if($member -match 'nested'){'nested'}else{'other'})],[Text.UTF8Encoding]::new($false))
    $file=Get-Item -LiteralPath $path
    $file.CreationTimeUtc=$file.LastWriteTimeUtc=$file.LastAccessTimeUtc=[datetime]'2024-01-02T03:04:06Z'
}
$hashes=@{}
foreach($path in $TestProgram,$RunnerPath,$Oracle,$Candidate,$PSCommandPath){$hashes[$path]=(Get-FileHash -LiteralPath $path).Hash}
[IO.File]::WriteAllText((Join-Path $Workspace 'environment.json'),($hashes | ConvertTo-Json))
[IO.File]::WriteAllText((Join-Path $Workspace 'plan.json'),($plan | Select-Object Name,Api,Language | ConvertTo-Json))
$seed=Join-Path $Workspace 'seed.lzh'
$line='a -+ -n1 -gm1 -y1 -h2 -x1 -jm0 "'+$seed+'" "'+$source+'/" folder/nested.txt other.txt'
$rows=@(& $RunnerPath --timeout-seconds 30 $TestProgram --registry '' --command-probe $Oracle $line 2>&1 | ForEach-Object {"$_"})
$code=$LASTEXITCODE
[IO.File]::WriteAllLines((Join-Path $Workspace 'seed.log'),[string[]]$rows)
if($code -ne 0 -or 'result=0' -cnotin $rows){throw '作成失敗試験の正常入力を作成できません'}
$hashes[$seed]=(Get-FileHash -LiteralPath $seed).Hash
$done=0
foreach($item in $plan){
    $case=$item.Case;$label="$($item.Name)-$($item.Api)-$($item.Language)"
    $observed=@{};$effects=@{}
    foreach($side in 'oracle','reimpl'){
        $root=Join-Path $Workspace "$label/$side"
        $first=Join-Path $root "first$DestinationSuffix";$second=Join-Path $root "second$DestinationSuffix"
        New-Item -ItemType Directory -Path $first,$second | Out-Null
        $archive=Join-Path $root 'source.lzh';Copy-Item -LiteralPath $seed -Destination $archive
        $recovery=Join-Path $root 'recovery.lzh';Copy-Item -LiteralPath $seed -Destination $recovery
        $command=if($case.Command){$case.Command}else{'e'}
        if($command -eq 'x'){New-Item -ItemType Directory -Path (Join-Path $first 'folder') | Out-Null}
        $paths=@{nested=(Join-Path $first $(if($command -eq 'x'){'folder/nested.txt'}else{'nested.txt'}));other=(Join-Path $first 'other.txt')}
        $expected=@{}
        if(!$case.New){foreach($key in 'nested','other'){
            $expected[$key]='SAFE'
            [IO.File]::WriteAllText($paths[$key],'SAFE',[Text.UTF8Encoding]::new($false))
            $file=Get-Item -LiteralPath $paths[$key]
            $file.CreationTimeUtc=$file.LastWriteTimeUtc=$file.LastAccessTimeUtc=[datetime]'2020-01-02T03:04:06Z'
            $file.Attributes=32
        }}
        $switches=if($case.Switches){$case.Switches}else{'-m1'}
        $line=$command+' -n1 '+$switches+' "'+$archive+'" "'+$first+'/" *'
        # 同じDLLの次命令で、停止状態・エラー・ポリシーを持ち越さないことを確認する。
        $following='e -n1 -m1 "'+$recovery+'" "'+$second+'/" *'
        $steps=@(('@initial-language:'+$item.Language),$line,('@audit-archive-release:'+$archive),$following,('@audit-archive-release:'+$recovery),'@cp-state')
        $layout=if($EnumLayout -ne 'auto'){$EnumLayout}elseif($item.Api -eq 'W'){'w64'}else{'a32'}
        $progressLayout=if($layout -eq 'none'){'w64'}else{$layout}
        $dll=if($side -eq 'oracle'){$Oracle}else{$Candidate}
        $responseText=if($case.Responses){$case.Responses}else{'inspect'}
        $arguments=@('--sequence-dialog-probe',$dll,$responseText,$layout,'1041',"$UnicodeMode",$item.Api,$progressLayout)
        if($case.InjectedError){
            $arguments[0]='--create-failure-sequence-probe'
            $arguments+=@($paths.nested,"$($case.InjectedError)")
        }
        $arguments+=$steps
        [IO.File]::WriteAllText((Join-Path $root 'invocation.json'),($arguments | ConvertTo-Json))
        $locked=if($case.ContainsKey('Locked')){$case.Locked}else{@('nested')}
        $held=@()
        try{
            # 読み取り共有だけを許し、対象ファイルの削除・書込みをOSに拒否させる。
            foreach($key in $locked){$held += [IO.File]::Open($paths[$key],[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)}
            $rows=@(& $RunnerPath --timeout-seconds 60 $TestProgram --registry '' @arguments 2>&1 | ForEach-Object {"$_"})
            $code=$LASTEXITCODE
        }finally{foreach($handle in $held){$handle.Dispose()}}
        [IO.File]::WriteAllLines((Join-Path $root 'command.log'),[string[]]$rows)
        if($code -ne 0){throw "作成失敗 $label/$side が停止しました: $code"}
        $result=if($case.Stop){32781}else{0}
        $expectedSystemError=if($case.Stop){if($case.InjectedError){$case.InjectedError}else{32}}else{38}
        $dialogs=if($case.Responses){@($case.Responses -split ',').Count}else{0}
        if([string]::Join('|',@($rows -match '^result=')) -cne "result=$result|result=0" -or
            [string]::Join('|',@($rows -match '^compat-error=')) -cne "compat-error=$result|compat-error=0" -or
            [string]::Join('|',@($rows -match '^compat-system-error=')) -cne "compat-system-error=$expectedSystemError|compat-system-error=38" -or
            @($rows -ceq 'win32-error=0').Count -ne 2 -or "command-dialog.count=$dialogs" -cnotin $rows -or
            @($rows -ceq 'archive-released=1,error=0').Count -ne 2){throw "作成失敗 $label/$side の結果・確認数・解放状態が不正です"}
        if($case.InjectedError -and "create-failure.calls=1,error=$($case.InjectedError)" -cnotin $rows){throw 'ファイル作成の失敗注入回数が異なります'}
        foreach($key in $case.Writes){$expected[$key]=$bodies[$key]}
        $state=@();$expectedFiles=@()
        foreach($key in @($expected.Keys | Sort-Object)){
            $path=$paths[$key]
            if([IO.File]::ReadAllText($path) -cne $expected[$key]){throw "作成失敗後の本文または保持結果が異なります: $label/$side/$key"}
            $relative=$path.Substring($first.Length+1).Replace('\','/');$expectedFiles+=$relative
            $file=Get-Item -LiteralPath $path -Force
            $preservedTime=([datetime]'2020-01-02T03:04:06Z').ToFileTimeUtc()
            if($key -notin $case.Writes -and ($file.CreationTimeUtc.ToFileTimeUtc() -ne $preservedTime -or
                $file.LastWriteTimeUtc.ToFileTimeUtc() -ne $preservedTime -or [int]$file.Attributes -ne 32)){throw '失敗した既存ファイルの日時・属性が変更されました'}
            $state+="$relative`: $($file.Length),$([int]$file.Attributes),$($file.CreationTimeUtc.Ticks),$($file.LastWriteTimeUtc.Ticks)"
        }
        $actualFiles=@(Get-ChildItem -LiteralPath $first -File -Recurse -Force | ForEach-Object {$_.FullName.Substring($first.Length+1).Replace('\','/')})
        if([string]::Join('|',@($actualFiles | Sort-Object)) -cne [string]::Join('|',@($expectedFiles | Sort-Object))){throw '作成失敗後の出力集合が異なります'}
        foreach($key in 'nested','other'){
            $path=Join-Path $second "$key.txt"
            if([IO.File]::ReadAllText($path) -cne $bodies[$key]){throw '次命令の本文が異なります'}
            $file=Get-Item -LiteralPath $path
            $state+="second/$key`: $($file.Length),$([int]$file.Attributes),$($file.CreationTimeUtc.Ticks),$($file.LastWriteTimeUtc.Ticks)"
        }
        if([string]::Join('|',@(Get-ChildItem -LiteralPath $second -Recurse -Force | ForEach-Object {$_.Name} | Sort-Object)) -cne 'nested.txt|other.txt'){throw '次命令の出力集合が異なります'}
        if((Get-FileHash -LiteralPath $archive).Hash -cne $hashes[$seed] -or (Get-FileHash -LiteralPath $recovery).Hash -cne $hashes[$seed]){throw '作成失敗が入力書庫を変更しました'}
        [IO.File]::WriteAllLines((Join-Path $root 'effects.log'),[string[]]$state);$effects[$side]=$state
        $observed[$side]=@($rows | ForEach-Object {$_.Replace($root.Replace('\','\\'),'<case>').Replace($root.Replace('\','/'),'<case>').Replace($root,'<case>')})
    }
    $difference=@(Compare-Object $observed.oracle $observed.reimpl -SyncWindow 0)
    if($difference.Count -or [string]::Join('|',$effects.oracle) -cne [string]::Join('|',$effects.reimpl)){
        [IO.File]::WriteAllText((Join-Path $Workspace "$label.diff.log"),($difference | Format-List | Out-String -Width 2000))
        throw "作成失敗 $label の画面・通知・本文・メタデータ・エラーが一致しません"
    }
    $done++
    if($done % 5 -eq 0){"Create failure progress: $done/$($plan.Count) verified"}
}
foreach($path in $hashes.Keys){if((Get-FileHash -LiteralPath $path).Hash -cne $hashes[$path]){throw '実行物または入力書庫が変更されました'}}
"Create failure: $done compatible sequences verified; skip, stop, preservation, dialogs, callbacks and reuse verified"
