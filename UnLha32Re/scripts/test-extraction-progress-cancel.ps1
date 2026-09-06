[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$RunnerPath,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$BodyDirectory,
    [Parameter(Mandatory)][string]$Workspace,
    [string]$ArchivePath='',
    [ValidateSet('ascii','japanese')][string[]]$Families=@('ascii','japanese'),
    [ValidateSet(0,2)][int[]]$Methods=@(0,2),
    [ValidateSet('e','x','p','t')][string[]]$Commands=@('e','x','p','t'),
    [string[]]$Variants=@('good'),
    [string[]]$Profiles=@('w64','w32','a64','a32'),
    [string[]]$Cases=@('normal','open','begin1','begin2','begin3','process1','process2','process3','process4','end'),
    [ValidateSet(0,1,2)][int[]]$NameModes=@(1),
    [ValidateSet(1033,1041)][int[]]$Languages=@(1041),
    [ValidateSet(0,1)][int]$SuppressDialogs=1,
    [ValidateSet(0,1)][int]$UnicodeMode=1,
    [ValidateRange(1,32)][int]$Repeat=1
)
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath($Workspace)
if(Test-Path -LiteralPath $workspace){throw '検証領域には新しいディレクトリを指定してください'}
$TestProgram=(Resolve-Path -LiteralPath $TestProgram).Path
$runner=(Resolve-Path -LiteralPath $RunnerPath).Path
$oracle=(Resolve-Path -LiteralPath $Oracle).Path
$candidate=(Resolve-Path -LiteralPath $Candidate).Path
$BodyDirectory=(Resolve-Path -LiteralPath $BodyDirectory).Path
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'test-enum-state.ps1'),[ref]$null,[ref]$null)
$helper=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-EnumProbe'},$true)
if(!$helper){throw '隔離・時間上限付きプローブがありません'}
. ([scriptblock]::Create($helper.Extent.Text))
$caseMap=@{
    normal=@(-1,1);open=@(3,1);begin1=@(0,1);begin2=@(0,2);begin3=@(0,3)
    process1=@(1,1);process2=@(1,2);process3=@(1,3);process4=@(1,4);end=@(2,1)
}
$profileMap=@{
    w64=@('W','w64','w64','*','');w32=@('W','w32','w32','*','')
    a64=@('A','a64','a64','*','');a32=@('A','a32','a32','*','')
    legacy=@('legacy','a32','a32','*','');none=@('W','none','w64','*','')
    missing=@('W','w64','w64','missing','');reject=@('W','w64','w64','*','@reject')
    rename=@('W','w64','w64','*','@add:renamed.txt')
}
foreach($name in $Cases){if(!$caseMap.ContainsKey($name)){throw "不明な中断条件: $name"}}
foreach($name in $Profiles){if(!$profileMap.ContainsKey($name)){throw "不明な API 構成: $name"}}
New-Item -ItemType Directory -Path $workspace | Out-Null
$hashes=@{}
$good=Join-Path $BodyDirectory 'ascii-jm0/good.lzh'
foreach($path in $TestProgram,$runner,$oracle,$candidate,$good){$hashes[$path]=(Get-FileHash -LiteralPath $path).Hash}
Write-Host "Extraction cancellation: candidate=$($hashes[$candidate]), probe=$($hashes[$TestProgram]), oracle=$($hashes[$oracle])"
$observations=[Collections.Generic.List[object]]::new()
$releases=0
foreach($family in $Families){foreach($method in $Methods){foreach($variant in $Variants){
    $archive=(Resolve-Path -LiteralPath $(if($ArchivePath){$ArchivePath}else{Join-Path $BodyDirectory "$family-jm$method/$variant.lzh"})).Path
    $hashes[$archive]=(Get-FileHash -LiteralPath $archive).Hash
    foreach($command in $Commands){foreach($profileName in $Profiles){foreach($caseName in $Cases){
        foreach($mode in $NameModes){foreach($language in $Languages){
            $profile=$profileMap[$profileName];$case=$caseMap[$caseName]
            $label="$family-jm$method-$variant-$command-$profileName-$caseName-n$mode-lang$language"
            $snapshots=@();$fileSnapshots=@();$followingSnapshots=@()
            foreach($side in 'oracle','reimpl'){
                $root=Join-Path $workspace ('case-{0:D4}-{1}' -f $observations.Count,$side)
                $output=Join-Path $root 'output';$next=Join-Path $root 'next'
                New-Item -ItemType Directory -Path $output,$next | Out-Null
                $dll=if($side -eq 'oracle'){$oracle}else{$candidate}
                $line="$command -+ -gm$SuppressDialogs -y1 -n$mode `"$archive`""
                if($command -in 'e','x'){$line+=" `"$($output.Replace('\','/'))/`""}
                $line+=" `"$($profile[3])`""
                $steps=@("@language:$language")
                if(!$SuppressDialogs){$steps+=,"@audit-dialog-archive:$archive"}
                if($profileName -eq 'rename'){$steps+=,"@add:$(Join-Path $output 'renamed.txt')"}
                elseif($profile[4]){$steps+=,$profile[4]}
                for($attempt=0;$attempt -lt $Repeat;$attempt++){
                    $steps+=@("@abort-state:$($case[0])","@abort-occurrence:$($case[1])",$line,"@audit-archive-release:$archive",'@handle-count')
                }
                $following="x -+ -gm1 -y1 -n1 `"$good`" `"$($next.Replace('\','/'))/`" *"
                $steps+=@('@abort-state:-1','@accept','@add:',$following,"@audit-archive-release:$good")
                $responses=(@('2')*$Repeat) -join ','
                $rows=@(Invoke-EnumProbe (Join-Path $root 'sequence') (@('--sequence-dialog-probe',$dll,$responses,$profile[1],'1041',[string]$UnicodeMode,$profile[0],$profile[2])+$steps) $root)
                $results=@($rows -match '^result=')
                if($results.Count -ne $Repeat+1 -or $results[-1] -cne 'result=0'){throw "中断後の再利用が失敗: $label/$side"}
                if(!$ArchivePath -and $variant -eq 'good' -and $mode -ne 0 -and $profileName -notin 'missing','reject'){
                    # 通知が必ず存在する位置と、拒否を無視する END を独立に確認する。
                    $expected=if($caseName -in 'normal','end'){'result=0'}elseif($profileName -eq 'rename' -and $command -in 'e','x' -and $caseName -in 'process3','process4'){'result=0'}elseif($caseName -ne 'process4'){'result=32800'}else{''}
                    if($expected -and @($results[0..($Repeat-1)] -cne $expected).Count){throw "戻り値が不正: $label/$side"}
                }
                $released=@($rows -ceq 'archive-released=1,error=0').Count
                if($released -ne $Repeat+1){throw "書庫ハンドルが残っています: $label/$side"}
                $releases+=$released
                $handles=@($rows -match '^handle-count=' | ForEach-Object {[int]($_ -split '=')[1]})
                if($handles.Count -ne $Repeat -or ($Repeat -gt 1 -and @($handles | Select-Object -Unique).Count -ne 1)){
                    throw "反復処理でハンドル数が変化: $label/$side ($($handles -join ','))"
                }
                $files=@(Get-ChildItem -LiteralPath $output -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
                    '{0}|{1}|{2}|{3}|{4}' -f [IO.Path]::GetRelativePath($output,$_.FullName),$_.Length,(Get-FileHash -LiteralPath $_.FullName).Hash,[int]$_.Attributes,$_.LastWriteTimeUtc.Ticks
                })
                [IO.File]::WriteAllLines((Join-Path $root 'files.txt'),[string[]]$files)
                $fileSnapshots+=,$files
                # DLL の実装内部の絶対ハンドル数ではなく、上で同一プロセス内の増加を検査する。
                $snapshots+=,@($rows | Where-Object {$_ -notmatch '^handle-count='} | ForEach-Object {
                    $_.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>')
                })
                $followingFiles=@(Get-ChildItem -LiteralPath $next -Recurse -File | Sort-Object FullName)
                if($followingFiles.Count -ne 3){throw "後続の展開内容が不足: $label/$side"}
                $followingSnapshots+=,@($followingFiles | ForEach-Object {
                    '{0}|{1}|{2}' -f [IO.Path]::GetRelativePath($next,$_.FullName),$_.Length,(Get-FileHash -LiteralPath $_.FullName).Hash
                })
            }
            if(@(Compare-Object $fileSnapshots[0] $fileSnapshots[1] -SyncWindow 0).Count){throw "中断時の残存ファイルが不一致: $label"}
            if(@(Compare-Object $followingSnapshots[0] $followingSnapshots[1] -SyncWindow 0).Count){throw "後続コマンドの展開内容が不一致: $label"}
            $diff=@(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
            if($diff.Count){
                $diff | Export-Csv -LiteralPath (Join-Path $workspace "$($observations.Count)-diff.tsv") -Delimiter "`t" -NoTypeInformation
                throw "中断ログ・通知・状態・ダイアログが不一致: $label"
            }
            $observations.Add([pscustomobject]@{Case=$label;Rows=$snapshots[0].Count})
            if($observations.Count % 64 -eq 0){Write-Host "Extraction cancellation: $($observations.Count) comparisons passed"}
        }}
    }}}
}}}
$observations | Export-Csv -LiteralPath (Join-Path $workspace 'observations.tsv') -Delimiter "`t" -NoTypeInformation
foreach($path in $hashes.Keys){if((Get-FileHash -LiteralPath $path).Hash -cne $hashes[$path]){throw "入力・バイナリーが変更されました: $path"}}
Write-Host "Extraction cancellation: $($observations.Count) exact comparisons, $releases exclusive-open checks passed"
