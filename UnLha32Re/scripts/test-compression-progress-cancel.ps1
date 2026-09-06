[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$RunnerPath,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$SeedArchive,
    [Parameter(Mandatory)][string]$Workspace,
    [ValidateSet('a','u','f','m')][string[]]$Commands=@('a','u','f','m'),
    [ValidateSet('open','begin1','begin2','begin3','process1','finish','search')]
    [string[]]$Cases=@('open','begin1','begin2','begin3','process1','finish'),
    [ValidateSet('a32','w32','a64','w64')][string[]]$Profiles=@('a32','w32','a64','w64'),
    [ValidateSet(0,2)][int[]]$Methods=@(0,2),
    [ValidateSet(1033,1041)][int[]]$Languages=@(1041),
    [ValidateSet(0,1)][int]$SuppressDialogs=1,
    [ValidateRange(1,16)][int]$Repeat=1,
    [ValidateSet('source','ソース','日本語')][string]$SourceDirectoryName='source',
    [ValidateSet(-1,0,1)][int]$UseMappedFile=-1,
    [ValidateRange(1,16777216)][int]$InputSize=19,
    [switch]$NewArchive
)
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath($Workspace)
if(Test-Path -LiteralPath $workspace){throw '新しい試験領域を指定してください'}
if($NewArchive -and ('f' -in $Commands -or @($Cases | Where-Object {$_ -in 'begin2','begin3'}).Count)){
    throw '新規書庫では存在しない旧項目や f の中断条件を指定できません'
}
if('f' -in $Commands -and 'search' -in $Cases){throw 'f は検索通知を送りません'}
$TestProgram=(Resolve-Path -LiteralPath $TestProgram).Path
$runner=(Resolve-Path -LiteralPath $RunnerPath).Path
$oracle=(Resolve-Path -LiteralPath $Oracle).Path
$candidate=(Resolve-Path -LiteralPath $Candidate).Path
$seed=(Resolve-Path -LiteralPath $SeedArchive).Path
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'test-enum-state.ps1'),[ref]$null,[ref]$null)
$helper=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-EnumProbe'},$true)
if(!$helper){throw '隔離プローブがありません'}
$registrySeed=if($UseMappedFile -lt 0){''}else{"L:UseMFile=$UseMappedFile"}
. ([scriptblock]::Create($helper.Extent.Text.Replace("'--registry',''", "'--registry',`$registrySeed")))
New-Item -ItemType Directory -Path $workspace | Out-Null
$hashes=@{}
foreach($path in $TestProgram,$runner,$oracle,$candidate,$seed){$hashes[$path]=(Get-FileHash -LiteralPath $path).Hash}
$caseMap=@{open=@(3,1);begin1=@(0,1);begin2=@(0,2);begin3=@(0,3);process1=@(1,1);finish=@(6,1);search=@(5,1)}
$stamp=[datetime]'2024-01-02T03:04:06Z'
$fixedTime=$stamp.ToFileTimeUtc()
$results=[Collections.Generic.List[object]]::new()
$releases=0
Write-Host "Compression cancellation: candidate=$($hashes[$candidate]), probe=$($hashes[$TestProgram]), oracle=$($hashes[$oracle])"
Write-Host "Compression cancellation registry sandbox: $registrySeed"
foreach($command in $Commands){foreach($caseName in $Cases){foreach($profile in $Profiles){foreach($method in $Methods){foreach($language in $Languages){
    $label="$command-$caseName-$profile-jm$method-lang$language"
    $snapshots=@()
    foreach($side in 'oracle','reimpl'){
        $root=Join-Path $workspace ('case-{0:D4}-{1}' -f $results.Count,$side)
        $source=Join-Path $root $SourceDirectoryName
        New-Item -ItemType Directory -Path $source | Out-Null
        $inputPath=Join-Path $source 'a.txt'
        [IO.File]::WriteAllText($inputPath,'replacement payload',[Text.UTF8Encoding]::new($false))
        if($InputSize -ne 19){
            $payload=[byte[]]::new($InputSize)
            for($payloadIndex=0;$payloadIndex -lt $payload.Length;$payloadIndex++){$payload[$payloadIndex]=[byte]($payloadIndex % 251)}
            [IO.File]::WriteAllBytes($inputPath,$payload)
        }
        $sourceHash=(Get-FileHash -LiteralPath $inputPath).Hash
        [IO.File]::SetCreationTimeUtc($inputPath,$stamp)
        [IO.File]::SetLastWriteTimeUtc($inputPath,$stamp)
        [IO.File]::SetLastAccessTimeUtc($inputPath,$stamp)
        $archive=Join-Path $root 'archive.lzh'
        if(!$NewArchive){Copy-Item -LiteralPath $seed -Destination $archive}
        $dll=if($side -eq 'oracle'){$oracle}else{$candidate}
        $api=if($profile.StartsWith('w')){'W'}else{'A'}
        $line="$command -+ -h2 -jm$method -gm$SuppressDialogs -y1 -n1 `"$archive`" `"$($source.Replace('\','/'))/`" a.txt"
        $case=$caseMap[$caseName]
        $steps=@("@language:$language","@audit-access:$inputPath",'@audit-find-access','@full-progress-paths')
        for($iteration=0;$iteration -lt $Repeat;$iteration++){
            $steps+=@("@count:$seed","@abort-state:$($case[0])","@abort-occurrence:$($case[1])",$line,
                "@audit-archive-release:$archive","@audit-archive-release:$inputPath",'@handle-count')
        }
        # 読み取りだけの次命令も同じ DLL で実行し、書庫と入力の解放を再確認する。
        $steps+=@('@abort-state:-1',"l -+ -gm1 -n1 `"$seed`" *","@audit-archive-release:$seed","@audit-archive-release:$inputPath")
        $started=[datetime]::UtcNow.ToFileTimeUtc()
        $rows=@(Invoke-EnumProbe (Join-Path $root 'sequence') (@('--sequence-dialog-probe',$dll,((@('2')*$Repeat)-join ','),$profile,'1041','1',$api,$profile)+$steps) $root)
        $ended=[datetime]::UtcNow.ToFileTimeUtc()
        $returns=@($rows -match '^result=')
        if($returns.Count -ne $Repeat+1 -or $returns[-1] -cne 'result=0' -or @($returns[0..($Repeat-1)] -cne 'result=32800').Count){throw "中断と再利用の戻り値が不正: $label/$side"}
        if(@($rows -ceq 'compat-error=32800').Count -ne $Repeat -or @($rows -ceq 'compat-system-error=1223').Count -ne $Repeat){throw "中断エラー情報が不正: $label/$side"}
        $released=@($rows -ceq 'archive-released=1,error=0').Count
        $expectedRelease=if($NewArchive){$Repeat+2}else{2*$Repeat+2}
        if($released -ne $expectedRelease -or @($rows -ceq 'archive-released=0,error=2').Count -ne $(if($NewArchive){$Repeat}else{0})){throw "ハンドルが残っています: $label/$side"}
        $releases+=$released
        $handles=@($rows -match '^handle-count=' | ForEach-Object {[int]($_ -split '=')[1]})
        if($handles.Count -ne $Repeat -or @($handles | Select-Object -Unique).Count -ne 1){throw "中断を繰り返すとハンドル数が変わります: $label/$side"}
        if($NewArchive){if(Test-Path -LiteralPath $archive){throw "中断時に新規書庫が残っています: $label/$side"}}
        elseif((Get-FileHash -LiteralPath $archive).Hash -cne $hashes[$seed]){throw "中断で旧書庫が変わりました: $label/$side"}
        if((Get-FileHash -LiteralPath $inputPath).Hash -cne $sourceHash){throw "中断で元ファイルが変わりました: $label/$side"}
        if(@(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.tmp').Count){throw "一時書庫が残っています: $label/$side"}
        $currentAccess=$null
        $normalized=@(foreach($row in $rows){
            if($row -match '^progress\.entry=.*?,state=5,'){
                # 原版の検索通知は名前だけが有効。候補のゼロ初期化は独立に検査する。
                if($side -eq 'reimpl' -and $row -notmatch ',file=0,compressed=0,write=0,attributes=0,crc=0,os=0,ratio=0,create=0,access=0,write-time=0,mode="",source='){
                    throw "検索通知の未使用欄が未初期化です: $label/$side"
                }
                $row=$row -replace ',file=.*?,mode="(?:\\.|[^"\\])*",source=',',metadata=undefined,source='
            }
            if($row -match ',source-access-audit=(\d+)'){
                $audit=[long]$Matches[1]
                if($audit -ne $fixedTime -and ($audit -lt $started -or $audit -gt $ended)){throw "実ファイルの参照日時が範囲外: $label/$side"}
                $row=$row -replace ',source-access-audit=\d+',(",source-access-audit="+$(if($audit -eq $fixedTime){'fixed'}else{'refreshed'}))
            }
            if($row -match ',source-find-access-audit=(\d+)'){
                $findAudit=[long]$Matches[1]
                # 初回の入力 BEGIN より前だけ未参照を保証する。後続命令は前回の本文読込で更新され得る。
                if($UseMappedFile -eq 0 -and $null -eq $currentAccess -and $row -match ",create=$fixedTime," -and $findAudit -ne $fixedTime){throw "マッピング無効時に初回検索参照日時が変化: $label/$side"}
                if($findAudit -ne $fixedTime -and ($findAudit -lt $started -or $findAudit -gt $ended)){throw "検索参照日時が範囲外: $label/$side"}
                if($row -match ",create=$fixedTime,"){$currentAccess=$findAudit}
                $row=$row -replace ',source-find-access-audit=\d+',(",source-find-access-audit="+$(if($findAudit -eq $fixedTime){'fixed'}else{'refreshed'}))
            }
            if($row -match "^progress\.entry=.*?,create=$fixedTime,access=(\d+),write-time=(\d+),"){
                if($null -eq $currentAccess -or [long]$Matches[1] -ne $currentAccess -or [long]$Matches[2] -ne $fixedTime){throw "通知日時が実ファイルと不一致: $label/$side"}
                $row=$row -replace ',access=\d+,',',access=<source-at-BEGIN>,'
            }
            if($row -notmatch '^handle-count='){
                $row.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>')
            }
        })
        $snapshots+=,$normalized
    }
    $difference=@(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
    if($difference.Count){$difference | Export-Csv -LiteralPath (Join-Path $workspace "$($results.Count)-diff.tsv") -Delimiter "`t" -NoTypeInformation;throw "中断後の通知・ログ・状態が不一致: $label"}
    $results.Add([pscustomobject]@{Case=$label;Rows=$snapshots[0].Count})
    if($results.Count % 32 -eq 0){Write-Host "Compression cancellation: $($results.Count) comparisons passed"}
}}}}}
foreach($path in $hashes.Keys){if((Get-FileHash -LiteralPath $path).Hash -cne $hashes[$path]){throw "検証資産が変更されました: $path"}}
$results | Export-Csv -LiteralPath (Join-Path $workspace 'observations.tsv') -Delimiter "`t" -NoTypeInformation
Write-Host "Compression cancellation: $($results.Count) comparisons, $releases exclusive opens; archive/source/temp/handle/continuation checks passed"
