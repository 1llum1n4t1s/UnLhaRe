[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$RunnerPath,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [ValidateNotNullOrEmpty()][ValidateSet('legacy','A','W')][string[]]$Apis=@('legacy','A','W'),
    [string[]]$CaseNames=@()
)

$ErrorActionPreference='Stop'
if(@($Apis | Select-Object -Unique).Count -ne $Apis.Count){throw 'API の重複指定はできません。'}
foreach($name in 'TestProgram','RunnerPath','Oracle','Candidate'){
    Set-Variable -Name $name -Value (Resolve-Path -LiteralPath (Get-Variable -Name $name -ValueOnly)).Path
}
$root=[IO.Path]::GetFullPath($Workspace)
if(Test-Path -LiteralPath $root){throw '新しい検証領域を指定してください。'}

$definitions=@(
    @{Name='missing-unmatched';Seed='single';File='missing';Pattern='absent.txt';Expected=0;Compat=0;System=38;Win32=0;Preserve=$true},
    @{Name='missing-matched';Seed='single';File='missing';Pattern='a.txt';Expected=32781;Compat=32781;System=2;Win32=0;Preserve=$true},
    @{Name='present-unmatched';Seed='single';File='present';Pattern='absent.txt';Expected=0;Compat=0;System=38;Win32=0;Preserve=$true},
    @{Name='present-matched';Seed='single';File='present';Pattern='a.txt';Expected=0;Compat=0;System=38;Win32=0;Preserve=$false},
    @{Name='empty-unmatched';Seed='single';File='empty';Pattern='absent.txt';Expected=0;Compat=0;System=38;Win32=0;Preserve=$true},
    @{Name='empty-matched';Seed='single';File='empty';Pattern='a.txt';Expected=32781;Compat=32781;System=87;Win32=0;Preserve=$true},
    @{Name='missing-excluded';Seed='single';File='missing';Pattern='*';Exclude=$true;Expected=0;Compat=0;System=38;Win32=0;Preserve=$true},
    @{Name='missing-archive';Seed='single';File='missing';Pattern='a.txt';NoArchive=$true;Expected=32809;Compat=0;System=2;Win32=2;Preserve=$true},
    @{Name='multi-first-matched';Seed='multi';File='missing';Pattern='a.txt';Expected=32781;Compat=32781;System=2;Win32=0;Preserve=$true},
    @{Name='multi-last-matched';Seed='multi';File='missing';Pattern='b.txt';Expected=32781;Compat=32781;System=2;Win32=0;Preserve=$true},
    @{Name='multi-unmatched';Seed='multi';File='missing';Pattern='absent.txt';Expected=0;Compat=0;System=38;Win32=0;Preserve=$true},
    @{Name='sequence-recovery';Sequence=$true}
)
if($CaseNames.Count){
    $selected=@($CaseNames | ForEach-Object {$_.Split(',')})
    if(@($selected | Select-Object -Unique).Count -ne $selected.Count){throw '条件の重複指定はできません。'}
    foreach($name in $selected){if($name -notin $definitions.Name){throw "未知の条件: $name"}}
    $definitions=@($definitions | Where-Object {$_.Name -in $selected})
}

New-Item -ItemType Directory -Path $root | Out-Null
$binaryHashes=@{}
foreach($path in $TestProgram,$RunnerPath,$Oracle,$Candidate,$PSCommandPath){
    $binaryHashes[$path]=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}
function Invoke-Probe([string]$Dll,[string]$Api,[string[]]$Arguments,[string]$Log){
    $rows=@(& $RunnerPath --timeout-seconds 30 $TestProgram --registry '' @Arguments 2>&1 | ForEach-Object {"$_"})
    $code=$LASTEXITCODE
    [IO.File]::WriteAllLines($Log,[string[]]$rows,[Text.UTF8Encoding]::new($false))
    if($code -ne 0){throw "コメント選択プローブが停止しました: $code / $Log"}
    return ,$rows
}
function Get-State([string]$Path){
    if(!(Test-Path -LiteralPath $Path)){return $null}
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    $stream.Dispose()
    $item=Get-Item -LiteralPath $Path -Force
    return [pscustomobject]@{Hash=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash;Length=$item.Length;
        Creation=$item.CreationTimeUtc.Ticks;Write=$item.LastWriteTimeUtc.Ticks;Attributes=[int]$item.Attributes}
}
function Normalize-Rows([string[]]$Rows,[string]$Folder){
    $slash=$Folder.Replace('\','/')
    $escaped=$Folder.Replace('\','\\')
    return @($Rows | ForEach-Object {$_.Replace($escaped,'<ROOT>').Replace($slash,'<ROOT>').Replace($Folder,'<ROOT>')})
}
function Assert-Scalar([string[]]$Rows,[string]$Prefix,[int[]]$Values,[string]$Label){
    $actual=@($Rows | Where-Object {$_ -like "$Prefix=*"})
    if($actual.Count -ne $Values.Count){throw "${Label}: $Prefix の件数が不正です"}
    for($index=0;$index -lt $Values.Count;$index++){
        if($actual[$index] -cne "$Prefix=$($Values[$index])"){
            throw "${Label}: $Prefix が不一致です ($($actual[$index]))"
        }
    }
}

$singleSource=Join-Path $root 'single-source'
$multiSource=Join-Path $root 'multi-source'
New-Item -ItemType Directory -Path $singleSource,$multiSource | Out-Null
[IO.File]::WriteAllText((Join-Path $singleSource 'a.txt'),'comment-selection-body',[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $multiSource 'a.txt'),'first-body',[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $multiSource 'b.txt'),'second-body',[Text.UTF8Encoding]::new($false))
$seedSingle=Join-Path $root 'seed-single.lzh'
$seedMulti=Join-Path $root 'seed-multi.lzh'
$seedLine='a -n1 -gm1 -y1 -h2 "'+$seedSingle+'" "'+$singleSource.Replace('\','/')+'/" a.txt'
$seedRows=Invoke-Probe $Oracle 'A' @('--command-probe-a',$Oracle,$seedLine,'A') (Join-Path $root 'seed-single.log')
if('result=0' -cnotin $seedRows){throw '単一メンバー基準書庫を作成できません。'}
$multiLine='a -n1 -gm1 -y1 -h2 "'+$seedMulti+'" "'+$multiSource.Replace('\','/')+'/" *'
$multiRows=Invoke-Probe $Oracle 'A' @('--command-probe-a',$Oracle,$multiLine,'A') (Join-Path $root 'seed-multi.log')
if('result=0' -cnotin $multiRows){throw '複数メンバー基準書庫を作成できません。'}
$seedHashes=@{
    $seedSingle=(Get-FileHash -LiteralPath $seedSingle -Algorithm SHA256).Hash
    $seedMulti=(Get-FileHash -LiteralPath $seedMulti -Algorithm SHA256).Hash
}
[IO.File]::WriteAllText((Join-Path $root 'environment.json'),($binaryHashes | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $root 'plan.json'),($definitions | Select-Object Name,Seed,File,Pattern,Sequence | ConvertTo-Json),[Text.UTF8Encoding]::new($false))

$results=[Collections.Generic.List[object]]::new()
$done=0
foreach($api in $Apis){
    foreach($case in $definitions){
        $pair=@{}
        foreach($side in 'oracle','reimpl'){
            $folder=Join-Path $root (Join-Path $api (Join-Path $case.Name $side))
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            $dll=if($side -eq 'oracle'){$Oracle}else{$Candidate}
            $rows=@();$states=@{};$started=[datetime]::UtcNow.Ticks
            if($case.Sequence){
                $first=Join-Path $folder 'first.lzh';$second=Join-Path $folder 'second.lzh'
                Copy-Item -LiteralPath $seedSingle -Destination $first
                Copy-Item -LiteralPath $seedSingle -Destination $second
                $comment=Join-Path $folder 'comment.txt'
                [IO.File]::WriteAllText($comment,('headless-comment'+[char]0),[Text.UTF8Encoding]::new($false))
                $missing=Join-Path $folder 'missing.txt'
                $firstLine='c -n1 -gm1 -jz"'+$missing+'" "'+$first+'" a.txt'
                $secondLine='c -n1 -gm1 -jz"'+$comment+'" "'+$second+'" a.txt'
                $beforeFirst=Get-State $first;$beforeSecond=Get-State $second
                $rows=Invoke-Probe $dll 'W' @('--command-sequence-probe',$dll,$firstLine,$secondLine) (Join-Path $folder 'command.log')
                $ended=[datetime]::UtcNow.Ticks
                Assert-Scalar $rows 'result' @(32781,0) "$api/$($case.Name)/$side"
                Assert-Scalar $rows 'compat-error' @(32781,0) "$api/$($case.Name)/$side"
                Assert-Scalar $rows 'compat-system-error' @(2,38) "$api/$($case.Name)/$side"
                if(@($rows -ceq 'win32-error=0').Count -ne 2){throw "${api}/$($case.Name)/${side}: Win32 エラーが不正です"}
                $afterFirst=Get-State $first;$afterSecond=Get-State $second
                if(!$afterFirst -or !$afterSecond -or $afterFirst.Hash -cne $beforeFirst.Hash -or
                    $afterFirst.Creation -ne $beforeFirst.Creation -or $afterSecond.Hash -ceq $beforeSecond.Hash -or
                    $afterSecond.Creation -ne $beforeSecond.Creation){throw "${api}/$($case.Name)/${side}: 失敗後の同一 DLL 回復状態が不正です"}
                $states.first=$afterFirst;$states.second=$afterSecond
            }else{
                $archive=Join-Path $folder 'archive.lzh'
                if(!$case.NoArchive){Copy-Item -LiteralPath $(if($case.Seed -eq 'multi'){$seedMulti}else{$seedSingle}) -Destination $archive}
                $before=Get-State $archive
                $comment=Join-Path $folder 'comment.txt'
                if($case.File -eq 'present'){
                    [IO.File]::WriteAllText($comment,('headless-comment'+[char]0),[Text.UTF8Encoding]::new($false))
                }
                $switch=if($case.File -eq 'empty'){'-jz'}else{'-jz"'+$comment+'"'}
                $exclude=if($case.Exclude){' -jxa.txt'}else{''}
                $line='c -n1 -gm1 '+$switch+$exclude+' "'+$archive+'" '+$case.Pattern
                $arguments=if($api -eq 'W'){@('--command-probe',$dll,$line)}
                    elseif($api -eq 'A'){@('--command-probe-a',$dll,$line,'A')}
                    else{@('--command-probe-a',$dll,$line)}
                if($case.NoArchive){$line=$line.Replace('"'+$archive+'"','"'+$archive+'"')}
                $rows=Invoke-Probe $dll $api $arguments (Join-Path $folder 'command.log')
                $ended=[datetime]::UtcNow.Ticks
                Assert-Scalar $rows 'result' @([int]$case.Expected) "$api/$($case.Name)/$side"
                Assert-Scalar $rows 'compat-error' @([int]$case.Compat) "$api/$($case.Name)/$side"
                Assert-Scalar $rows 'compat-system-error' @([int]$case.System) "$api/$($case.Name)/$side"
                if(@($rows -ceq "win32-error=$($case.Win32)").Count -ne 1){throw "${api}/$($case.Name)/${side}: Win32 エラーが不正です"}
                $after=Get-State $archive
                if($case.NoArchive){
                    if($after){throw "${api}/$($case.Name)/${side}: 無い書庫が作成されました"}
                }elseif(!$after){throw "${api}/$($case.Name)/${side}: 書庫が失われました"}
                elseif($case.Preserve -and $after.Hash -cne $before.Hash){throw "${api}/$($case.Name)/${side}: 失敗・未選択の書庫が変化しました"}
                elseif(!$case.Preserve -and $after.Hash -ceq $before.Hash){throw "${api}/$($case.Name)/${side}: 選択メンバーの注釈が反映されません"}
                if($after -and $after.Creation -ne $before.Creation){throw "${api}/$($case.Name)/${side}: 書庫の作成日時が変化しました"}
                $states.archive=$after
            }
            if(@(Get-ChildItem -LiteralPath $folder -Filter '*.tmp' -Force -ErrorAction SilentlyContinue).Count){throw "${api}/$($case.Name)/${side}: 一時書庫が残っています"}
            $normalized=Normalize-Rows $rows $folder
            $pair[$side]=@($normalized)
            $record=[pscustomobject]@{Api=$api;Case=$case.Name;Side=$side;Rows=$rows;States=$states;Started=$started;Ended=$ended}
            $results.Add($record)
            [IO.File]::WriteAllText((Join-Path $folder 'result.json'),($record | ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))
        }
        $difference=@(Compare-Object $pair.oracle $pair.reimpl -SyncWindow 0)
        if($difference.Count){
            [IO.File]::WriteAllText((Join-Path $root "$api-$($case.Name).diff.log"),($difference | Format-List | Out-String -Width 2000),[Text.UTF8Encoding]::new($false))
            throw "コメント選択の原版比較に失敗しました: $api/$($case.Name)"
        }
        $done++
        if($done % 4 -eq 0){Write-Host "Comment selection progress: $done/$($Apis.Count*$definitions.Count) comparisons"}
    }
}
foreach($path in $seedHashes.Keys){if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $seedHashes[$path]){throw "基準書庫が変化しました: $path"}}
foreach($path in $binaryHashes.Keys){if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $binaryHashes[$path]){throw "検証中のファイルが変化しました: $path"}}
[IO.File]::WriteAllText((Join-Path $root 'results.json'),($results | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
Write-Host "Rewrite comment selection: $done comparisons passed."
