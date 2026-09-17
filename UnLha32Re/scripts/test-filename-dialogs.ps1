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
    [string]$SelectionSuffix='',
    [switch]$NativeFileDialog
)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
if($SelectionSuffix.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0){throw '選択名の接尾辞はファイル名の文字に限定します'}
$definitions=@(
    @{Name='overwrite-new';Responses='22:1,6,@0,1';Selections=@('selected');Writes=@('selected','other')},
    @{Name='overwrite-existing';Responses='22:1,6,@0,1,1';Selections=@('selected');Writes=@('selected','other');ExistingSelected=$true},
    @{Name='overwrite-selected-refuse';Responses='22:1,6,@0,22:1,7,1';Selections=@('selected');Writes=@('other');ExistingSelected=$true},
    @{Name='overwrite-again';Responses='22:1,6,@0,22:1,6,@1,1';Selections=@('selected','again');Writes=@('again','other');ExistingSelected=$true},
    @{Name='overwrite-same';Responses='22:1,6,@0,1,1';Selections=@('nested');Writes=@('nested','other')},
    @{Name='overwrite-new-parent';Responses='22:1,6,@0,1,1';Selections=@('selected');Writes=@('selected','other');MissingSelectedParent=$true},
    @{Name='overwrite-new-parent-decline';Responses='22:1,6,@0,22:1,7,1';Selections=@('selected');Writes=@('other');MissingSelectedParent=$true},
    @{Name='overwrite-new-parent-again';Responses='22:1,6,@0,22:1,6,@1,1';Selections=@('selected','again');Writes=@('again','other');MissingSelectedParent=$true},
    @{Name='overwrite-cancel-save';Responses='22:1,6,@0,1';Selections=@('cancel');Writes=@('other')},
    @{Name='overwrite-decline';Responses='22:1,7,1';Writes=@('other')},
    @{Name='overwrite-skip-all-new';Responses='24:1,6,@0';Selections=@('selected');Writes=@('selected')},
    @{Name='overwrite-skip-all-decline';Responses='24:1,7';Writes=@()},
    @{Name='overwrite-protected-no';Responses='22:1';Writes=@('other');Attributes=33;Switches='-m1 -jyn0'},
    @{Name='overwrite-future';Responses='1';Writes=@('other');Future=$true},
    @{Name='overwrite-selected-future';Responses='22:1,6,@0,1';Selections=@('selected');Writes=@('other');ExistingSelected=$true;SelectedFuture=$true},
    @{Name='overwrite-selected-protected-no';Responses='22:1,6,@0,1,22:1,1';Selections=@('selected');Writes=@('other');ExistingSelected=$true;SelectedAttributes=33},
    @{Name='overwrite-selected-protected-yes';Responses='22:1,6,@0,1,1,1';Selections=@('selected');Writes=@('selected','other');ExistingSelected=$true;SelectedAttributes=33},
    @{Name='overwrite-existing-only';Responses='22:1,6,@0,1';Selections=@('selected');Writes=@('other');Switches='-m0 -jyn0 -gf1'},
    @{Name='overwrite-new-only';Responses='';Writes=@();Switches='-m0 -jyn0 -jn1'},
    @{Name='overwrite-reject';Responses='';Writes=@();Reject=$true},
    @{Name='directory-new';Kind='directory';Responses='22:1,6,@0';Selections=@('selected');Writes=@('selected','other')},
    @{Name='directory-existing';Kind='directory';Responses='22:1,6,@0,1';Selections=@('selected');Writes=@('selected','other');ExistingSelected=$true},
    @{Name='directory-cancel-save';Kind='directory';Responses='22:1,6,@0';Selections=@('cancel');Writes=@('other')},
    @{Name='directory-decline';Kind='directory';Responses='22:1,7';Writes=@('other')},
    @{Name='directory-skip-all-new';Kind='directory';Responses='24:1,6,@0';Selections=@('selected');Writes=@('selected','other')},
    @{Name='directory-skip-all-decline';Kind='directory';Responses='24:1,7';Writes=@('other')},
    @{Name='directory-selected-cancel';Kind='directory';Responses='22:1,6,@0,2,2';Selections=@('selected');Writes=@();ExistingSelected=$true;Result=32800},
    @{Name='member-new';Kind='member';Responses='22:1,6,@0';Selections=@('selected');Writes=@()},
    @{Name='member-cancel-save';Kind='member';Responses='22:1,6,@0';Selections=@('cancel');Writes=@()},
    @{Name='member-decline';Kind='member';Responses='22:1,7';Writes=@()},
    @{Name='member-skip-all-new';Kind='member';Responses='24:1,6,@0';Selections=@('selected');Writes=@()},
    @{Name='jyn-toggle';Responses='22:1,6,@0,1';Selections=@('selected');Writes=@('selected','other');Switches='-m0 -jyn'},
    @{Name='jyn-toggle-off';Responses='22:1,1';Writes=@('other');Switches='-m0 -jyn0 -jyn'},
    @{Name='y0';Kind='directory';Responses='22:1,6,@0';Selections=@('selected');Writes=@('selected','other');Switches='-y0'},
    @{Name='y0-jyn1';Responses='22:1,1';Writes=@('other');Switches='-y0 -jyn1'},
    @{Name='jyn0-y1-m0';Responses='22:1,1';Writes=@('other');Switches='-jyn0 -y1 -m0'},
    @{Name='jy-combined';Responses='22:1,6,@0,1';Selections=@('selected');Writes=@('selected','other');Switches='-m1 -jyo0n0'},
    @{Name='jy-combined-suppressed';Responses='22:1,1';Writes=@('other');Switches='-y0 -jyn1o0c0'},
    @{Name='jyn2';Responses='22:1,6,@0,1';Selections=@('selected');Writes=@('selected','other');Switches='-m0 -jyn2'},
    @{Name='jyn2-twice';Responses='22:1,1';Writes=@('other');Switches='-m0 -jyn2n2'},
    @{Name='m3';Kind='directory';Responses='';Writes=@('nested','other');Switches='-m0 -m3'},
    @{Name='y2';Kind='directory';Responses='';Writes=@('nested','other');Switches='-m0 -y2'},
    @{Name='jyc2';Kind='directory';Responses='22:1,6,@0';Selections=@('selected');Writes=@('selected','other');Switches='-m1 -jyc2n0'}
)
foreach($axis in 'Apis','Languages'){
    $values=@(Get-Variable -Name $axis -ValueOnly)
    if(!$values.Count -or @($values | Select-Object -Unique).Count -ne $values.Count){throw "空または重複した検証軸: $axis"}
}
foreach($name in $CaseNames){if($name -cnotin $definitions.Name){throw "未知の別名確認条件: $name"}}
$plan=@(foreach($case in $definitions){if(!$CaseNames.Count -or $case.Name -cin $CaseNames){foreach($api in $Apis){foreach($language in $Languages){
    [pscustomobject]@{Name=$case.Name;Api=$api;Language=$language;Case=$case}
}}}})
if(!$plan.Count){throw '比較対象がありません'}
if($PlanOnly){"Filename dialog plan only: $($plan.Count) sequences; NOT RUN";$plan | Select-Object Name,Api,Language;return}
foreach($name in 'TestProgram','RunnerPath','Oracle','Candidate'){Set-Variable -Name $name -Value (Resolve-Path -LiteralPath (Get-Variable -Name $name -ValueOnly)).Path}
$Workspace=[IO.Path]::GetFullPath($Workspace)
if(Test-Path -LiteralPath $Workspace){throw '既存の検証領域は上書きしません'}
# GUI入力の不正指定は対象DLLをロードする前に拒否する。
$invalidResponses=@(
    @{Response='file::1';Error='invalid dialog filename encoding'},
    @{Response='file:004:1';Error='invalid dialog filename encoding'},
    @{Response='file:GGGG:1';Error='invalid dialog filename encoding'},
    @{Response='file:0000:1';Error='invalid dialog filename character'},
    @{Response='file:00720065006C00610074006900760065:1';Error='dialog filename requires an absolute path'},
    @{Response=('file:'+('0041'*512)+':1');Error='invalid dialog filename encoding'},
    @{Response='file:0043003A005C0061:22:1';Error='filename/text cannot select a radio'}
)
foreach($invalid in $invalidResponses){
    $rows=@(& $RunnerPath --timeout-seconds 10 $TestProgram --registry '' --command-dialog-probe `
        (Join-Path $Workspace 'must-not-load.dll') 't' $invalid.Response w64 0 W 1041 1041 2>&1 | ForEach-Object {"$_"})
    if($LASTEXITCODE -ne 2 -or $invalid.Error -cnotin $rows){throw '保存画面の不正入力をDLLロード前に拒否できません'}
}
$source=Join-Path $Workspace 'input'
foreach($directory in 'folder','empty-dir'){New-Item -ItemType Directory -Path (Join-Path $source $directory) | Out-Null}
$bodies=@{nested=('A'*100);other=('B'*77);selected=('A'*100);again=('A'*100)}
foreach($member in 'folder/nested.txt','other.txt'){
    $path=Join-Path $source $member
    $key=if($member -match 'nested'){'nested'}else{'other'}
    [IO.File]::WriteAllText($path,$bodies[$key],[Text.UTF8Encoding]::new($false))
    $file=Get-Item -LiteralPath $path
    $file.CreationTimeUtc=$file.LastWriteTimeUtc=$file.LastAccessTimeUtc=[datetime]'2024-01-02T03:04:06Z'
}
$hashes=@{}
foreach($path in $TestProgram,$RunnerPath,$Oracle,$Candidate,$PSCommandPath){$hashes[$path]=(Get-FileHash -LiteralPath $path).Hash}
[IO.File]::WriteAllText((Join-Path $Workspace 'environment.json'),($hashes | ConvertTo-Json))
[IO.File]::WriteAllText((Join-Path $Workspace 'plan.json'),($plan | Select-Object Name,Api,Language | ConvertTo-Json))
[IO.File]::WriteAllText((Join-Path $Workspace 'options.json'),(@{EnumLayout=$EnumLayout;UnicodeMode=$UnicodeMode;SelectionSuffix=$SelectionSuffix;NativeFileDialog=[bool]$NativeFileDialog} | ConvertTo-Json))
$seed=Join-Path $Workspace 'seed.lzh'
$directorySeed=Join-Path $Workspace 'directory.lzh'
foreach($kind in 'files','directory'){
    $archive=if($kind -eq 'files'){$seed}else{$directorySeed}
    $options=if($kind -eq 'files'){'-x1 -jm0'}else{'-a1 -d1'}
    $members=if($kind -eq 'files'){'folder/nested.txt other.txt'}else{'empty-dir'}
    $line='a -+ -n1 -gm1 -y1 -h2 '+$options+' "'+$archive+'" "'+$source+'/" '+$members
    $rows=@(& $RunnerPath --timeout-seconds 30 $TestProgram --registry '' --command-probe $Oracle $line 2>&1 | ForEach-Object {"$_"})
    $code=$LASTEXITCODE
    [IO.File]::WriteAllLines((Join-Path $Workspace "$kind-seed.log"),[string[]]$rows)
    if($code -ne 0 -or 'result=0' -cnotin $rows){throw '別名確認の正常入力を作成できません'}
    $hashes[$archive]=(Get-FileHash -LiteralPath $archive).Hash
}
$recent=[Environment]::GetFolderPath('Recent')
$recentBefore=@(if($NativeFileDialog){Get-ChildItem -LiteralPath $recent -File -Filter '*.lnk' | ForEach-Object {$_.FullName}})
$done=0
foreach($item in $plan){
    $case=$item.Case
    $kind=if($case.Kind){$case.Kind}else{'overwrite'}
    $label="$($item.Name)-$($item.Api)-$($item.Language)"
    $observed=@{};$effects=@{}
    # OS標準保存画面のツリーが見る兄弟フォルダーを、両DLLの起動前から同じ構成にする。
    foreach($side in 'oracle','reimpl'){
        foreach($phase in 'first','second'){New-Item -ItemType Directory -Path (Join-Path $Workspace "$label/$side/$phase") | Out-Null}
    }
    foreach($side in 'oracle','reimpl'){
        $root=Join-Path $Workspace "$label/$side"
        $archive=Join-Path $root 'source.lzh'
        $input=if($kind -eq 'member'){$directorySeed}else{$seed}
        Copy-Item -LiteralPath $input -Destination $archive
        $recovery=if($kind -eq 'member'){Join-Path $root 'recovery.lzh'}else{$archive}
        if($recovery -ne $archive){Copy-Item -LiteralPath $seed -Destination $recovery}
        $first=Join-Path $root 'first'
        $second=Join-Path $root 'second'
        $paths=@{nested=(Join-Path $first $(if($kind -eq 'overwrite'){'nested.txt'}else{'folder/nested.txt'}));other=(Join-Path $first 'other.txt');selected=(Join-Path $first "selected$SelectionSuffix.txt");again=(Join-Path $first "again$SelectionSuffix.txt")}
        if($case.MissingSelectedParent){$paths.selected=Join-Path $first "new-parent/selected$SelectionSuffix.txt"}
        $expected=@{}
        if($kind -eq 'overwrite'){$expected.nested='SAFE';$expected.other='KEEP'}
        if($case.ExistingSelected){$expected.selected='PRESERVE'}
        foreach($key in @($expected.Keys)){
            [IO.File]::WriteAllText($paths[$key],$expected[$key],[Text.UTF8Encoding]::new($false))
            $file=Get-Item -LiteralPath $paths[$key]
            $future=($key -eq 'nested' -and $case.Future) -or ($key -eq 'selected' -and $case.SelectedFuture)
            $stamp=if($future){[datetime]'2030-01-02T03:04:06Z'}else{[datetime]'2020-01-02T03:04:06Z'}
            $file.CreationTimeUtc=$file.LastWriteTimeUtc=$file.LastAccessTimeUtc=$stamp
            $file.Attributes=if($key -eq 'nested' -and $case.ContainsKey('Attributes')){$case.Attributes}elseif($key -eq 'selected' -and $case.ContainsKey('SelectedAttributes')){$case.SelectedAttributes}else{32}
        }
        foreach($key in 'nested','other'){
            $path=Join-Path $second "$key.txt"
            [IO.File]::WriteAllText($path,$(if($key -eq 'nested'){'SAFE'}else{'KEEP'}),[Text.UTF8Encoding]::new($false))
            $file=Get-Item -LiteralPath $path
            $file.CreationTimeUtc=$file.LastWriteTimeUtc=$file.LastAccessTimeUtc=[datetime]'2020-01-02T03:04:06Z'
        }
        $selections=@(foreach($choice in $case.Selections){if($choice -eq 'cancel'){'cancel'}else{$paths[$choice]}})
        $responses=@()
        foreach($response in @($case.Responses -split ',' | Where-Object {$_})){
            if($response -match '^@(\d+)$'){
                $index=[int]$Matches[1]
                if($index -ge $selections.Count){throw '保存画面の応答番号が不正です'}
                if($NativeFileDialog){
                    if($selections[$index] -eq 'cancel'){$responses+='2'}else{
                        $hex=[string]::Join('',@($selections[$index].ToCharArray() | ForEach-Object {([int]$_).ToString('X4')}))
                        $responses+='file:'+$hex+':1'
                    }
                }
            }else{$responses+=$response}
        }
        # 次の命令では jyn の既定値へ戻し、上書き拒否後に別名確認が持ち越されないことを検査する。
        $responses+=@('22:1','1')
        $chosen=if(!$selections.Count){'none'}else{[string]::Join('|',@($selections | ForEach-Object {if($NativeFileDialog){'native:'+$_}else{$_}}))}
        $switches=if($case.ContainsKey('Switches')){$case.Switches}else{'-m0 -jyn0'}
        $command=$(if($kind -eq 'overwrite'){'e'}else{'x'})+' -n1 '+$switches+' "'+$archive+'" "'+$first+'/" *'
        $following='e -n1 -m0 "'+$recovery+'" "'+$second+'/" *'
        $steps=@('@initial-language:'+$item.Language)
        if($case.Reject){$steps+='@reject'}
        $steps+=@($command,('@audit-archive-release:'+$archive),'@accept',$following,('@audit-archive-release:'+$recovery),'@cp-state')
        $layout=if($EnumLayout -ne 'auto'){$EnumLayout}elseif($item.Api -eq 'W'){'w64'}else{'a32'}
        $progressLayout=if($layout -eq 'none'){'w64'}else{$layout}
        $dll=if($side -eq 'oracle'){$Oracle}else{$Candidate}
        $arguments=@('--filename-sequence-probe',$dll,([string]::Join(',',$responses)),$layout,'1041',"$UnicodeMode",$item.Api,$progressLayout,$chosen)+$steps
        [IO.File]::WriteAllText((Join-Path $root 'invocation.json'),($arguments | ConvertTo-Json))
        $rows=@(& $RunnerPath --timeout-seconds 60 $TestProgram --registry '' @arguments 2>&1 | ForEach-Object {"$_"})
        $code=$LASTEXITCODE
        [IO.File]::WriteAllLines((Join-Path $root 'command.log'),[string[]]$rows)
        if($code -ne 0){throw "別名確認 $label/$side が停止しました: $code"}
        $result=if($case.ContainsKey('Result')){$case.Result}else{0}
        if([string]::Join('|',@($rows -match '^result=')) -cne "result=$result|result=0" -or
            "command-dialog.count=$($responses.Count)" -cnotin $rows -or
            "filename-dialog.requests=$($selections.Count),cwd-preserved=1" -cnotin $rows -or
            @($rows -ceq 'archive-released=1,error=0').Count -ne 2){throw "別名確認 $label/$side の状態・解放・呼び出し回数が不正です"}
        foreach($key in $case.Writes){$expected[$key]=$bodies[$key]}
        $state=@()
        $expectedFiles=@()
        foreach($key in @($expected.Keys | Sort-Object)){
            $path=$paths[$key]
            if([IO.File]::ReadAllText($path) -cne $expected[$key]){throw "別名確認の本文または保持結果が異なります: $label/$side/$key"}
            $relative=$path.Substring($first.Length+1).Replace('\','/')
            $expectedFiles+=$relative
            $file=Get-Item -LiteralPath $path -Force
            $state+="first/$relative`: $($file.Length),$([int]$file.Attributes),$($file.CreationTimeUtc.Ticks),$($file.LastWriteTimeUtc.Ticks)"
        }
        $actualFiles=@(Get-ChildItem -LiteralPath $first -File -Recurse -Force | ForEach-Object {$_.FullName.Substring($first.Length+1).Replace('\','/')})
        if([string]::Join('|',@($actualFiles | Sort-Object)) -cne [string]::Join('|',@($expectedFiles | Sort-Object))){throw "余分または不足した別名出力があります: $label/$side"}
        $directories=@(Get-ChildItem -LiteralPath $first -Directory -Recurse -Force | Sort-Object FullName)
        if($kind -eq 'member' -and $directories.Count){throw '改名を選択したディレクトリ項目が保存先を作成しました'}
        $state+=@($directories | ForEach-Object {"first/dir=$($_.FullName.Substring($first.Length+1).Replace('\','/')),attributes=$([int]$_.Attributes)"})
        foreach($key in 'nested','other'){
            $path=Join-Path $second "$key.txt"
            $body=if($key -eq 'nested'){'SAFE'}else{$bodies.other}
            if([IO.File]::ReadAllText($path) -cne $body){throw '別名確認後の次命令の本文が異なります'}
            $file=Get-Item -LiteralPath $path
            $state+="second/$key`: $($file.Length),$([int]$file.Attributes),$($file.CreationTimeUtc.Ticks),$($file.LastWriteTimeUtc.Ticks)"
        }
        if(@(Get-ChildItem -LiteralPath $second -File -Recurse -Force).Count -ne 2){throw '次命令に余分なファイルが残りました'}
        if((Get-FileHash -LiteralPath $archive).Hash -cne $hashes[$input] -or (Get-FileHash -LiteralPath $recovery).Hash -cne $hashes[$seed]){throw '別名確認が入力書庫を変更しました'}
        [IO.File]::WriteAllLines((Join-Path $root 'effects.log'),[string[]]$state)
        $effects[$side]=$state
        $observed[$side]=@($rows | ForEach-Object {$_.Replace($root.Replace('\','\\'),'<case>').Replace($root.Replace('\','/'),'<case>').Replace($root,'<case>')})
    }
    $difference=@(Compare-Object $observed.oracle $observed.reimpl -SyncWindow 0)
    if($difference.Count -or [string]::Join('|',$effects.oracle) -cne [string]::Join('|',$effects.reimpl)){
        [IO.File]::WriteAllText((Join-Path $Workspace "$label.diff.log"),($difference | Format-List | Out-String -Width 2000))
        throw "別名確認 $label の画面・API引数・通知・本文・状態が一致しません"
    }
    $done++
    if($done % 5 -eq 0){"Filename dialogs progress: $done/$($plan.Count) sequences compatible"}
}
if($NativeFileDialog){
    $ownedLinks=@();$shell=New-Object -ComObject WScript.Shell
    foreach($link in @(Get-ChildItem -LiteralPath $recent -File -Filter '*.lnk' | Where-Object {$_.FullName -cnotin $recentBefore})){
        $target=$shell.CreateShortcut($link.FullName).TargetPath
        if($target.StartsWith($Workspace+'\',[StringComparison]::OrdinalIgnoreCase)){$ownedLinks+=[pscustomobject]@{Path=$link.FullName;Target=$target}}
    }
    [IO.File]::WriteAllText((Join-Path $Workspace 'recent-links.json'),(ConvertTo-Json -InputObject @($ownedLinks)))
    if($ownedLinks.Count){throw '保存画面が検証用の最近使ったファイルを追加しました。recent-links.json の記録対象の清掃が必要です'}
}
foreach($path in $hashes.Keys){if((Get-FileHash -LiteralPath $path).Hash -cne $hashes[$path]){throw '実行物または入力書庫が変更されました'}}
"Filename dialogs: $done sequences compatible; native=$([bool]$NativeFileDialog); API options, selected/preserved bodies, retries, callbacks and errors verified"
