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
    @{Name='newer';Future=$true;Switches='-m1 -jse2 -gm1';Result=32782;Error=87},
    @{Name='newer-dialog';Future=$true;Switches='-m1 -jse2';Result=32782;Error=87;Responses='2'},
    @{Name='newer-stop1';Future=$true;Switches='-m1 -jse1'},
    @{Name='newer-stop0';Future=$true;Switches='-m1 -jse0'},
    @{Name='newer-empty';Future=$true;Empty=$true;Switches='-m1 -jse2 -gm1';Result=32782;Error=0},
    @{Name='newer-no-map';Future=$true;Registry='L:UseMFile=0';Switches='-m1 -jse2 -gm1';Result=32782;Error=0},
    @{Name='existing';Switches='-m1 -jn1 -jse2 -gm1';Result=32784;Error=87},
    @{Name='older';Switches='-m1 -u2 -jse2 -gm1';Result=32782;Error=87},
    @{Name='missing';Missing=$true;Switches='-m1 -gf1 -jse2 -gm1';Result=32783;Error=2},
    @{Name='missing-parent';Missing=$true;NoParent=$true;Command='x';Switches='-m1 -gf1 -jse2 -gm1';Result=32783;Error=3},
    @{Name='protected';Attributes=33;Switches='-m1 -ga2 -jse2';Result=32774;Error=87;Responses='2'},
    @{Name='protected-stop1';Attributes=33;Switches='-m1 -ga2 -jse1 -gm1'},
    @{Name='overwrite-no';Switches='-m0 -jse2';Result=32782;Error=87;Responses='22:1,2'},
    @{Name='hidden';Seed='hidden';Missing=$true;Switches='-m1 -jse2';Result=32776;Error=2;Responses='2'},
    @{Name='hidden-stop1';Seed='hidden';Missing=$true;Switches='-m1 -jse1 -gm1'},
    @{Name='parent-no';Missing=$true;NoParent=$true;Command='x';Switches='-m1 -jyc0 -jse2';Result=32775;Error=1223;Responses='22:1,2'},
    @{Name='parent-no-stop1';Missing=$true;NoParent=$true;Command='x';Switches='-m1 -jyc0 -jse1';Responses='22:1';Writes=@('other')},
    @{Name='parent-file';Missing=$true;ParentFile=$true;Command='x';Switches='-m1 -gm1';Result=32786;Error=183},
    @{Name='parent-file-stop1';Missing=$true;ParentFile=$true;Command='x';Switches='-m1 -jse1 -gm1';Result=32786;Error=183},
    @{Name='parent-file-stop2';Missing=$true;ParentFile=$true;Command='x';Switches='-m1 -jse2 -gm1';Result=32786;Error=183},
    @{Name='parent-file-no-capacity';Missing=$true;ParentFile=$true;Command='x';Switches='-m1 -f -gm1';Result=32786;Error=183},
    @{Name='parent-file-dialog';Missing=$true;ParentFile=$true;Command='x';Switches='-m1 -jyc1';Result=32786;Error=183;Responses='2'},
    @{Name='directory-no';Seed='directory';Missing=$true;NoParent=$true;Command='x';Switches='-m1 -jyc0 -jse2';Responses='22:1'},
    @{Name='directory-file';Seed='directory';Missing=$true;ParentFile=$true;Command='x';Switches='-m1 -gm1';Result=32786;Error=183},
    @{Name='directory-file-dialog';Seed='directory';Missing=$true;ParentFile=$true;Command='x';Switches='-m1 -jyc1 -jse2';Result=32786;Error=183;Responses='2'},
    @{Name='newer-last';FutureLast=$true;Switches='-m1 -jse2 -gm1';Result=32782;Error=87;Writes=@('nested')},
    @{Name='metadata-open';Locked='nested';Switches='-m1 -gm1';Result=32781;Error=32},
    @{Name='metadata-open-dialog';Locked='nested';Switches='-m1';Result=32781;Error=32;Responses='2'},
    @{Name='metadata-before-selection';Locked='nested';Future=$true;Switches='-m1 -jn1 -jse2 -gm1';Result=32781;Error=32},
    @{Name='metadata-open-last';Locked='other';Switches='-m1 -jse0 -gm1';Result=32781;Error=32;Writes=@('nested')}
)
foreach($axis in 'Apis','Languages'){
    $values=Get-Variable -Name $axis -ValueOnly
    if(!@($values).Count -or @($values | Select-Object -Unique).Count -ne @($values).Count){throw "空または重複した検証軸: $axis"}
}
foreach($name in $CaseNames){if($name -cnotin $definitions.Name){throw "未知の展開準備失敗条件: $name"}}
$plan=@(foreach($case in $definitions){if(!$CaseNames.Count -or $case.Name -cin $CaseNames){foreach($api in $Apis){foreach($language in $Languages){
    [pscustomobject]@{Name=$case.Name;Api=$api;Language=$language;Case=$case}
}}}})
if(!$plan.Count){throw '比較対象がありません'}
if($PlanOnly){"Preparation failure plan only: $($plan.Count) sequences; NOT RUN";$plan | Select-Object Name,Api,Language;return}
foreach($name in 'TestProgram','RunnerPath','Oracle','Candidate'){Set-Variable -Name $name -Value (Resolve-Path -LiteralPath (Get-Variable -Name $name -ValueOnly)).Path}
$Workspace=[IO.Path]::GetFullPath($Workspace)
if(Test-Path -LiteralPath $Workspace){throw '既存の検証領域は上書きしません'}
$source=Join-Path $Workspace 'input'
New-Item -ItemType Directory -Path (Join-Path $source 'folder') | Out-Null
$bodies=@{nested=('A'*100);other=('B'*77)}
foreach($key in 'nested','other'){
    $path=Join-Path $source $(if($key -eq 'nested'){'folder/nested.txt'}else{'other.txt'})
    [IO.File]::WriteAllText($path,$bodies[$key],[Text.UTF8Encoding]::new($false))
    $file=Get-Item -LiteralPath $path
    $file.CreationTimeUtc=$file.LastWriteTimeUtc=$file.LastAccessTimeUtc=[datetime]'2024-01-02T03:04:06Z'
}
$hashes=@{}
foreach($path in $TestProgram,$RunnerPath,$Oracle,$Candidate,$PSCommandPath){$hashes[$path]=(Get-FileHash -LiteralPath $path).Hash}
[IO.File]::WriteAllText((Join-Path $Workspace 'environment.json'),($hashes | ConvertTo-Json))
[IO.File]::WriteAllText((Join-Path $Workspace 'plan.json'),($plan | Select-Object Name,Api,Language | ConvertTo-Json))
$seeds=@{}
foreach($kind in 'normal','hidden','directory'){
    $seed=Join-Path $Workspace "$kind.lzh";$seeds[$kind]=$seed
    $seedSource=$source
    if($kind -eq 'directory'){
        $seedSource=Join-Path $Workspace 'directory-input'
        New-Item -ItemType Directory -Path (Join-Path $seedSource 'folder') | Out-Null
    }
    $members=if($kind -eq 'directory'){'folder'}elseif($kind -eq 'hidden'){'folder/nested.txt'}else{'folder/nested.txt other.txt'}
    if($kind -eq 'hidden'){(Get-Item -LiteralPath (Join-Path $source 'folder/nested.txt')).Attributes=34}
    $line='a -+ -n1 -gm1 -y1 -h2 -a1 -d1 -x1 -jm0 "'+$seed+'" "'+$seedSource+'/" '+$members
    $rows=@(& $RunnerPath --timeout-seconds 30 $TestProgram --registry '' --command-probe $Oracle $line 2>&1 | ForEach-Object {"$_"})
    $code=$LASTEXITCODE
    [IO.File]::WriteAllLines((Join-Path $Workspace "$kind-seed.log"),[string[]]$rows)
    if($code -ne 0 -or 'result=0' -cnotin $rows){throw '展開準備失敗試験の正常入力を作成できません'}
    $hashes[$seed]=(Get-FileHash -LiteralPath $seed).Hash
    (Get-Item -LiteralPath (Join-Path $source 'folder/nested.txt') -Force).Attributes=32
}
$done=0
foreach($item in $plan){
    $case=$item.Case;$label="$($item.Name)-$($item.Api)-$($item.Language)"
    $observed=@{};$effects=@{}
    foreach($side in 'oracle','reimpl'){
        $root=Join-Path $Workspace "$label/$side"
        $first=Join-Path $root "first$DestinationSuffix";$second=Join-Path $root "second$DestinationSuffix"
        New-Item -ItemType Directory -Path $first,$second | Out-Null
        $seed=$seeds[$(if($case.Seed){$case.Seed}else{'normal'})]
        $archive=Join-Path $root 'source.lzh';Copy-Item -LiteralPath $seed -Destination $archive
        $recovery=Join-Path $root 'recovery.lzh';Copy-Item -LiteralPath $seeds.normal -Destination $recovery
        $command=if($case.Command){$case.Command}else{'e'}
        if($command -eq 'x' -and !$case.NoParent -and !$case.ParentFile){New-Item -ItemType Directory -Path (Join-Path $first 'folder') | Out-Null}
        $paths=@{nested=(Join-Path $first $(if($command -eq 'x'){'folder/nested.txt'}else{'nested.txt'}));other=(Join-Path $first 'other.txt')}
        $expected=@{};$before=@{}
        if(!$case.Missing){foreach($key in 'nested','other'){
            $expected[$key]=if($case.Empty){''}else{'SAFE'}
            [IO.File]::WriteAllText($paths[$key],$expected[$key],[Text.UTF8Encoding]::new($false))
            $file=Get-Item -LiteralPath $paths[$key]
            $file.CreationTimeUtc=$file.LastWriteTimeUtc=$file.LastAccessTimeUtc=if($case.Future -or ($case.FutureLast -and $key -eq 'other')){[datetime]'2030-01-02T03:04:06Z'}else{[datetime]'2020-01-02T03:04:06Z'}
            $file.Attributes=if($case.Attributes){$case.Attributes}else{32}
            $before[$key]="$($file.CreationTimeUtc.Ticks),$($file.LastWriteTimeUtc.Ticks),$([int]$file.Attributes)"
        }}
        if($case.ParentFile){[IO.File]::WriteAllText((Join-Path $first 'folder'),'PARENT')}
        $line=$command+' -n1 '+$case.Switches+' "'+$archive+'" "'+$first+'/" *'
        $following='e -n1 -m1 "'+$recovery+'" "'+$second+'/" *'
        $steps=@(('@initial-language:'+$item.Language),$line,('@audit-archive-release:'+$archive),$following,('@audit-archive-release:'+$recovery),'@cp-state')
        $layout=if($EnumLayout -ne 'auto'){$EnumLayout}elseif($item.Api -eq 'W'){'w64'}else{'a32'}
        $progressLayout=if($layout -eq 'none'){'w64'}else{$layout}
        $dll=if($side -eq 'oracle'){$Oracle}else{$Candidate}
        $responseText=if($case.Responses){$case.Responses}else{'inspect'}
        $registry=if($case.Registry){$case.Registry}else{''}
        $arguments=@('--sequence-dialog-probe',$dll,$responseText,$layout,'1041',"$UnicodeMode",$item.Api,$progressLayout)+$steps
        [IO.File]::WriteAllText((Join-Path $root 'invocation.json'),($arguments | ConvertTo-Json))
        $held=$null
        try{
            if($case.Locked){$held=[IO.File]::Open($paths[$case.Locked],[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)}
            $rows=@(& $RunnerPath --timeout-seconds 60 $TestProgram --registry $registry @arguments 2>&1 | ForEach-Object {"$_"})
            $code=$LASTEXITCODE
        }finally{if($held){$held.Dispose()}}
        [IO.File]::WriteAllLines((Join-Path $root 'command.log'),[string[]]$rows)
        if($code -ne 0){throw "展開準備失敗 $label/$side が停止しました: $code"}
        $result=if($case.Result){$case.Result}else{0}
        $expectedSystemError=if($case.ContainsKey('Error')){$case.Error}else{38}
        $dialogs=if($case.Responses){@($case.Responses -split ',').Count}else{0}
        if([string]::Join('|',@($rows -match '^result=')) -cne "result=$result|result=0" -or
            [string]::Join('|',@($rows -match '^compat-error=')) -cne "compat-error=$result|compat-error=0" -or
            [string]::Join('|',@($rows -match '^compat-system-error=')) -cne "compat-system-error=$expectedSystemError|compat-system-error=38" -or
            @($rows -ceq 'win32-error=0').Count -ne 2 -or "command-dialog.count=$dialogs" -cnotin $rows -or
            @($rows -ceq 'archive-released=1,error=0').Count -ne 2){throw "展開準備失敗 $label/$side の結果・確認数・解放状態が不正です"}
        foreach($key in $case.Writes){$expected[$key]=$bodies[$key]}
        $state=@();$expectedFiles=@()
        foreach($key in @($expected.Keys | Sort-Object)){
            $path=$paths[$key]
            if([IO.File]::ReadAllText($path) -cne $expected[$key]){throw "展開準備失敗後の本文が異なります: $label/$side/$key"}
            $relative=$path.Substring($first.Length+1).Replace('\','/');$expectedFiles+=$relative
            $file=Get-Item -LiteralPath $path -Force
            $metadata="$($file.CreationTimeUtc.Ticks),$($file.LastWriteTimeUtc.Ticks),$([int]$file.Attributes)"
            if($key -notin $case.Writes -and $metadata -cne $before[$key]){throw '停止・スキップした既存ファイルの日時・属性が変更されました'}
            $state+="$relative`: $($file.Length),$metadata"
        }
        if($case.ParentFile){
            if([IO.File]::ReadAllText((Join-Path $first 'folder')) -cne 'PARENT'){throw '親と競合するファイルが変更されました'}
            $expectedFiles+='folder';$state+='folder=PARENT'
        }
        $actualFiles=@(Get-ChildItem -LiteralPath $first -Recurse -Force | ForEach-Object {$_.FullName.Substring($first.Length+1).Replace('\','/')})
        if([string]::Join('|',@($actualFiles | Sort-Object)) -cne [string]::Join('|',@($expectedFiles | Sort-Object))){throw '展開準備失敗後の出力集合が異なります'}
        foreach($key in 'nested','other'){
            $path=Join-Path $second "$key.txt"
            if([IO.File]::ReadAllText($path) -cne $bodies[$key]){throw '次命令の本文が異なります'}
            $file=Get-Item -LiteralPath $path
            $state+="second/$key`: $($file.Length),$([int]$file.Attributes),$($file.CreationTimeUtc.Ticks),$($file.LastWriteTimeUtc.Ticks)"
        }
        if([string]::Join('|',@(Get-ChildItem -LiteralPath $second -Recurse -Force | ForEach-Object {$_.Name} | Sort-Object)) -cne 'nested.txt|other.txt'){throw '次命令の出力集合が異なります'}
        if((Get-FileHash -LiteralPath $archive).Hash -cne $hashes[$seed] -or (Get-FileHash -LiteralPath $recovery).Hash -cne $hashes[$seeds.normal]){throw '展開準備失敗が入力書庫を変更しました'}
        [IO.File]::WriteAllLines((Join-Path $root 'effects.log'),[string[]]$state);$effects[$side]=$state
        $observed[$side]=@($rows | ForEach-Object {$_.Replace($root.Replace('\','\\'),'<case>').Replace($root.Replace('\','/'),'<case>').Replace($root,'<case>')})
    }
    $difference=@(Compare-Object $observed.oracle $observed.reimpl -SyncWindow 0)
    if($difference.Count -or [string]::Join('|',$effects.oracle) -cne [string]::Join('|',$effects.reimpl)){
        [IO.File]::WriteAllText((Join-Path $Workspace "$label.diff.log"),($difference | Format-List | Out-String -Width 2000))
        throw "展開準備失敗 $label の画面・通知・本文・メタデータ・エラーが一致しません"
    }
    $done++
    if($done % 5 -eq 0){"Preparation failure progress: $done/$($plan.Count) verified"}
}
foreach($path in $hashes.Keys){if((Get-FileHash -LiteralPath $path).Hash -cne $hashes[$path]){throw '実行物または入力書庫が変更されました'}}
"Preparation failure: $done compatible sequences verified; selection, parent creation, preservation, dialogs, callbacks and reuse verified"
