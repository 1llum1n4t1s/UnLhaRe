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
    @{Name='no';Responses='7,7';Writes=@()},
    @{Name='yes';Responses='6,6';Writes=@('nested','other')},
    @{Name='mixed';Responses='7,6';Writes=@('other')},
    @{Name='cancel';Responses='2,2';Writes=@();Queries=1;Result=32773},
    @{Name='later-cancel';Responses='6,2,2';Writes=@('nested');Result=32773},
    @{Name='x-no';Command='x';Responses='7,7';Writes=@()},
    @{Name='x-yes';Command='x';Responses='6,6';Writes=@('nested','other')},
    @{Name='enough';Values='100';Writes=@('nested','other')},
    @{Name='one-short';Values='99';Responses='7';Writes=@('other')},
    @{Name='old-credit';Values='96';Existing=$true;Writes=@('nested','other')},
    @{Name='old-credit-short';Values='95';Existing=$true;Responses='7';Writes=@('other')},
    @{Name='old-preserve';Existing=$true;Responses='7,7';Writes=@()},
    @{Name='protected-preserve';Existing=$true;Attributes=33;Responses='1,7,1,7';Writes=@()},
    @{Name='hidden-preserve';Existing=$true;Attributes=34;Responses='1,7,1,7';Writes=@()},
    @{Name='system-preserve';Existing=$true;Attributes=36;Responses='1,7,1,7';Writes=@()},
    @{Name='protected-auto';Existing=$true;Attributes=39;Switches='-m1 -ga1';Responses='7,7';Writes=@()},
    @{Name='overwrite-no';Existing=$true;Switches='-m0';Responses='22:1,1,7';Writes=@();Queries=1},
    @{Name='silent';Switches='-m1 -gm1';Writes=@()},
    @{Name='f';Switches='-m1 -f';Writes=@('nested','other');Queries=0},
    @{Name='f1';Switches='-m1 -f1';Writes=@('nested','other');Queries=0},
    @{Name='f0';Switches='-m1 -f0';Responses='7,7';Writes=@()},
    @{Name='f-minus';Switches='-m1 -f-';Responses='7,7';Writes=@()},
    @{Name='jyk0';Switches='-m1 -jyk0';Writes=@('nested','other');Queries=0},
    @{Name='jyk1';Switches='-m1 -jyk1';Responses='7,7';Writes=@()},
    @{Name='jyk-toggle';Switches='-m1 -jyk';Writes=@('nested','other');Queries=0},
    @{Name='jyk-twice';Switches='-m1 -jyk2k2';Responses='7,7';Writes=@()},
    @{Name='y1';Switches='-y1';Responses='7,7';Writes=@()},
    @{Name='jd';Switches='-m1 -jd';Responses='7,7';Writes=@()},
    @{Name='jd0';Switches='-m1 -jd0';Responses='7,7';Writes=@()},
    @{Name='jd-minus';Switches='-m1 -jd-';Writes=@('nested','other');Queries=0},
    @{Name='jd100';Switches='-m1 -jd100';Values='199';Responses='7';Writes=@('other')},
    @{Name='jd-boundary';Switches='-m1 -jd100';Values='200';Writes=@('nested','other')},
    @{Name='jd-k';Switches='-m1 -jd1K';Values='1099';Responses='7';Writes=@('other')},
    @{Name='jd-64';Switches='-m1 -jd4294967296';Values='4294967395';Responses='7';Writes=@('other')},
    @{Name='jd-f-reset';Switches='-m1 -jd100 -f0';Values='100';Writes=@('nested','other')},
    @{Name='f-jd-enable';Switches='-m1 -f1 -jd0';Responses='7,7';Writes=@()},
    @{Name='registry-off';Registry='L:DiskSpaceCheck=0';Writes=@('nested','other');Queries=0},
    @{Name='registry-ignore';Registry='L:DiskSpaceCheck=0';Switches='-+ -m1';Responses='7,7';Writes=@()},
    @{Name='registry-override';Registry='L:DiskSpaceCheck=0';Switches='-m1 -jyk1';Responses='7,7';Writes=@()},
    @{Name='reject';Reject=$true;Writes=@();Queries=0},
    @{Name='print';Command='p';Writes=@();Queries=0},
    @{Name='test';Command='t';Writes=@();Queries=0},
    @{Name='print-x0';Command='p';Switches='-m1 -x0';Writes=@();Queries=0},
    @{Name='print-x1';Command='p';Switches='-m1 -x1';Writes=@();Queries=0},
    @{Name='test-x0';Command='t';Switches='-m1 -x0';Writes=@();Queries=0},
    @{Name='test-x1';Command='t';Switches='-m1 -x1';Writes=@();Queries=0},
    @{Name='directory';Directory=$true;Command='x';Writes=@();Queries=0},
    @{Name='overflow-required';Safety=$true;Switches='-m1 -jd18446744073709551615';Values='99';Responses='7,7';Writes=@()},
    @{Name='overflow-decimal';Safety=$true;Switches='-m1 -jd18446744073709551616';Values='100';Responses='7,7';Writes=@()}
)
foreach($axis in 'Apis','Languages'){
    $values=Get-Variable -Name $axis -ValueOnly
    if(!@($values).Count -or @($values | Select-Object -Unique).Count -ne @($values).Count){throw "空または重複した検証軸: $axis"}
}
foreach($name in $CaseNames){if($name -cnotin $definitions.Name){throw "未知の容量確認条件: $name"}}
$plan=@(foreach($case in $definitions){if(!$CaseNames.Count -or $case.Name -cin $CaseNames){foreach($api in $Apis){foreach($language in $Languages){
    [pscustomobject]@{Name=$case.Name;Api=$api;Language=$language;Case=$case}
}}}})
if(!$plan.Count){throw '比較対象がありません'}
if($PlanOnly){"Disk space dialog plan only: $($plan.Count) sequences; NOT RUN";$plan | Select-Object Name,Api,Language;return}
foreach($name in 'TestProgram','RunnerPath','Oracle','Candidate'){Set-Variable -Name $name -Value (Resolve-Path -LiteralPath (Get-Variable -Name $name -ValueOnly)).Path}
$Workspace=[IO.Path]::GetFullPath($Workspace)
if(Test-Path -LiteralPath $Workspace){throw '既存の検証領域は上書きしません'}
$source=Join-Path $Workspace 'input'
foreach($directory in 'folder','empty-dir'){New-Item -ItemType Directory -Path (Join-Path $source $directory) | Out-Null}
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
$seed=Join-Path $Workspace 'seed.lzh';$directorySeed=Join-Path $Workspace 'directory.lzh'
foreach($kind in 'files','directory'){
    $archive=if($kind -eq 'files'){$seed}else{$directorySeed}
    $options=if($kind -eq 'files'){'-x1 -jm0'}else{'-a1 -d1'}
    $members=if($kind -eq 'files'){'folder/nested.txt other.txt'}else{'empty-dir'}
    $line='a -+ -n1 -gm1 -y1 -h2 '+$options+' "'+$archive+'" "'+$source+'/" '+$members
    $rows=@(& $RunnerPath --timeout-seconds 30 $TestProgram --registry '' --command-probe $Oracle $line 2>&1 | ForEach-Object {"$_"})
    $code=$LASTEXITCODE
    [IO.File]::WriteAllLines((Join-Path $Workspace "$kind-seed.log"),[string[]]$rows)
    if($code -ne 0 -or 'result=0' -cnotin $rows){throw '容量確認の正常入力を作成できません'}
    $hashes[$archive]=(Get-FileHash -LiteralPath $archive).Hash
}
$done=0;$safe=0
foreach($item in $plan){
    $case=$item.Case;$label="$($item.Name)-$($item.Api)-$($item.Language)"
    $observed=@{};$effects=@{}
    foreach($side in 'oracle','reimpl'){
        $root=Join-Path $Workspace "$label/$side"
        $first=Join-Path $root "first$DestinationSuffix";$second=Join-Path $root "second$DestinationSuffix"
        New-Item -ItemType Directory -Path $first,$second | Out-Null
        $archive=Join-Path $root 'source.lzh';$input=if($case.Directory){$directorySeed}else{$seed}
        Copy-Item -LiteralPath $input -Destination $archive
        $recovery=Join-Path $root 'recovery.lzh';Copy-Item -LiteralPath $seed -Destination $recovery
        $command=if($case.Command){$case.Command}else{'e'}
        $paths=@{nested=(Join-Path $first $(if($command -eq 'x'){'folder/nested.txt'}else{'nested.txt'}));other=(Join-Path $first 'other.txt')}
        $expected=@{}
        if($case.Existing){
            foreach($key in 'nested','other'){
                $expected[$key]='SAFE'
                [IO.File]::WriteAllText($paths[$key],'SAFE',[Text.UTF8Encoding]::new($false))
                $file=Get-Item -LiteralPath $paths[$key]
                $file.CreationTimeUtc=$file.LastWriteTimeUtc=$file.LastAccessTimeUtc=[datetime]'2020-01-02T03:04:06Z'
                $file.Attributes=if($case.ContainsKey('Attributes')){$case.Attributes}else{32}
            }
        }
        $switches=if($case.Switches){$case.Switches}else{'-m1'}
        $line=$command+' -n1 '+$switches+' "'+$archive+'" "'+$first+'/" *'
        # 同じDLLで初期値へ戻し、先の無効化・予約容量・中断を持ち越さない。
        $following='e -+ -n1 -m1 "'+$recovery+'" "'+$second+'/" *'
        $steps=@('@initial-language:'+$item.Language)
        if($case.Reject){$steps+='@reject'}
        $steps+=@($line,('@audit-archive-release:'+$archive),'@accept',$following,('@audit-archive-release:'+$recovery),'@cp-state')
        $values=if($case.ContainsKey('Values')){$case['Values']}else{'0'}
        $secondResponses=@(foreach($key in 'nested','other'){if([uint64]$values -lt $bodies[$key].Length){'7'}})
        $firstResponses=if($case.Safety -and $side -eq 'oracle'){''}else{$case.Responses}
        $responses=@($firstResponses -split ',' | Where-Object {$_})+$secondResponses
        $layout=if($EnumLayout -ne 'auto'){$EnumLayout}elseif($item.Api -eq 'W'){'w64'}else{'a32'}
        $progressLayout=if($layout -eq 'none'){'w64'}else{$layout}
        $dll=if($side -eq 'oracle'){$Oracle}else{$Candidate}
        $registry=if($case.Registry){$case.Registry}else{''}
        $responseText=if($responses.Count){[string]::Join(',',$responses)}else{'inspect'}
        $arguments=@('--disk-space-sequence-probe',$dll,$responseText,$layout,'1041',"$UnicodeMode",$item.Api,$progressLayout,$values)+$steps
        [IO.File]::WriteAllText((Join-Path $root 'invocation.json'),($arguments | ConvertTo-Json))
        $rows=@(& $RunnerPath --timeout-seconds 60 $TestProgram --registry $registry @arguments 2>&1 | ForEach-Object {"$_"})
        $code=$LASTEXITCODE
        [IO.File]::WriteAllLines((Join-Path $root 'command.log'),[string[]]$rows)
        if($code -ne 0){throw "容量確認 $label/$side が停止しました: $code"}
        $result=if($case.ContainsKey('Result')){$case.Result}else{0}
        $queries=if($case.ContainsKey('Queries')){$case.Queries}else{2}
        $count=$queries+2+$(if($side -eq 'oracle'){2}else{0})
        if([string]::Join('|',@($rows -match '^result=')) -cne "result=$result|result=0" -or
            "command-dialog.count=$($responses.Count)" -cnotin $rows -or
            "disk-space.queries=$count,cwd-preserved=1" -cnotin $rows -or
            @($rows -ceq 'archive-released=1,error=0').Count -ne 2){throw "容量確認 $label/$side の結果・確認数・解放状態が不正です"}
        if($case.Safety -and (@($rows -ceq 'compat-error=0').Count -ne 2 -or
            @($rows -ceq 'compat-system-error=38').Count -ne 2)){throw '安全性例外の終了状態が不正です'}
        $actualQueries=@($rows | Where-Object {$_ -match '^disk-space.query='} | ForEach-Object {
            if($_ -notmatch '^disk-space.query=(".*"),available=([0-9]+)$' -or $Matches[2] -cne $values){throw '容量照会記録が不正です'}
            ($Matches[1] | ConvertFrom-Json).TrimEnd('\')
        })
        $expectedQueries=@(
            if($side -eq 'oracle'){$root}
            for($index=0;$index -lt $queries;$index++){
                if($command -eq 'x' -and $index -eq 0){Join-Path $first 'folder'}else{$first}
            }
            if($side -eq 'oracle'){$root}
            $second;$second
        )
        if([string]::Join('|',$actualQueries) -cne [string]::Join('|',$expectedQueries)){throw '出力先の親以外の容量を照会しました'}
        $writes=if($case.Safety -and $side -eq 'oracle'){@('nested','other')}else{$case.Writes}
        foreach($key in $writes){$expected[$key]=$bodies[$key]}
        $state=@();$expectedFiles=@()
        foreach($key in @($expected.Keys | Sort-Object)){
            $path=$paths[$key]
            if([IO.File]::ReadAllText($path) -cne $expected[$key]){throw "容量確認の本文または保持結果が異なります: $label/$side/$key"}
            $relative=$path.Substring($first.Length+1).Replace('\','/');$expectedFiles+=$relative
            $file=Get-Item -LiteralPath $path -Force
            $state+="$relative`: $($file.Length),$([int]$file.Attributes),$($file.CreationTimeUtc.Ticks),$($file.LastWriteTimeUtc.Ticks)"
        }
        $actualFiles=@(Get-ChildItem -LiteralPath $first -File -Recurse -Force | ForEach-Object {$_.FullName.Substring($first.Length+1).Replace('\','/')})
        if([string]::Join('|',@($actualFiles | Sort-Object)) -cne [string]::Join('|',@($expectedFiles | Sort-Object))){throw '容量不足の拒否後に余分な出力があります'}
        $secondFiles=@()
        foreach($key in 'nested','other'){
            if([uint64]$values -ge $bodies[$key].Length){
                $path=Join-Path $second "$key.txt";$secondFiles+="$key.txt"
                if([IO.File]::ReadAllText($path) -cne $bodies[$key]){throw '次命令の本文が異なります'}
                $file=Get-Item -LiteralPath $path
                $state+="second/$key`: $($file.Length),$([int]$file.Attributes),$($file.CreationTimeUtc.Ticks),$($file.LastWriteTimeUtc.Ticks)"
            }
        }
        $actualSecond=@(Get-ChildItem -LiteralPath $second -Recurse -Force | ForEach-Object {$_.Name} | Sort-Object)
        if([string]::Join('|',$actualSecond) -cne [string]::Join('|',@($secondFiles | Sort-Object))){throw '次命令に余分または不足した出力があります'}
        $directories=@(Get-ChildItem -LiteralPath $first -Directory -Recurse -Force | ForEach-Object {$_.FullName.Substring($first.Length+1).Replace('\','/')} | Sort-Object)
        $expectedDirectories=if($case.Directory){'empty-dir'}elseif($command -eq 'x'){'folder'}else{''}
        if([string]::Join('|',$directories) -cne $expectedDirectories){throw '容量確認前の親作成結果が異なります'}
        $state+=@($directories | ForEach-Object {"dir=$_"})
        if((Get-FileHash -LiteralPath $archive).Hash -cne $hashes[$input] -or (Get-FileHash -LiteralPath $recovery).Hash -cne $hashes[$seed]){throw '容量確認が入力書庫を変更しました'}
        [IO.File]::WriteAllLines((Join-Path $root 'effects.log'),[string[]]$state);$effects[$side]=$state
        # 原版の書庫開始時の総容量分類とA/W照会方法は実装詳細。公開結果を除外せず照合する。
        $observed[$side]=@($rows | Where-Object {$_ -notmatch '^disk-space\.'} | ForEach-Object {$_.Replace($root.Replace('\','\\'),'<case>').Replace($root.Replace('\','/'),'<case>').Replace($root,'<case>')})
    }
    $difference=@(Compare-Object $observed.oracle $observed.reimpl -SyncWindow 0)
    if($case.Safety){
        if(!$difference.Count){throw '桁あふれの原版不具合と候補の容量保護を区別できません'}
        $safe++
    }elseif($difference.Count -or [string]::Join('|',$effects.oracle) -cne [string]::Join('|',$effects.reimpl)){
        [IO.File]::WriteAllText((Join-Path $Workspace "$label.diff.log"),($difference | Format-List | Out-String -Width 2000))
        throw "容量確認 $label の画面・通知・本文・メタデータ・エラーが一致しません"
    }
    $done++
    if($done % 5 -eq 0){"Disk space dialogs progress: $done/$($plan.Count) verified; safety exceptions=$safe"}
}
foreach($path in $hashes.Keys){if((Get-FileHash -LiteralPath $path).Hash -cne $hashes[$path]){throw '実行物または入力書庫が変更されました'}}
"Disk space dialogs: $($done-$safe) compatible sequences, $safe safety-exception sequences verified; choices, byte boundaries, options, files, callbacks and reuse verified"
