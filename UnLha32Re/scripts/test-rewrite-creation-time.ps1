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
$TestProgram=(Resolve-Path -LiteralPath $TestProgram).Path
$RunnerPath=(Resolve-Path -LiteralPath $RunnerPath).Path
$Oracle=(Resolve-Path -LiteralPath $Oracle).Path
$Candidate=(Resolve-Path -LiteralPath $Candidate).Path
$root=[IO.Path]::GetFullPath($Workspace)
if(Test-Path -LiteralPath $root){throw '新しい検証領域を指定してください。'}

# 原版が使う現在の Windows のバイアスで、ローカル日時の境界を UTC へ変換する。
# 将来年の夏時間規則を使う DateTime の変換とは区別する。
if(-not ('RewriteCreationTimeNative' -as [type])){
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class RewriteCreationTimeNative {
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool LocalFileTimeToFileTime(ref long local, out long utc);
}
'@
}
function Convert-LocalBoundary([datetime]$Date){
    [long]$local=$Date.Ticks-504911232000000000L
    [long]$utc=0
    if(-not [RewriteCreationTimeNative]::LocalFileTimeToFileTime([ref]$local,[ref]$utc)){
        throw 'ローカル日時の境界を変換できません。'
    }
    return [datetime]::FromFileTimeUtc($utc)
}
$maximum=Convert-LocalBoundary ([datetime]::new(2107,12,31,23,59,58))
$ordinary=[datetime]::new(2024,1,2,3,4,6,[DateTimeKind]::Utc)
$future=[datetime]::new(2200,1,1,0,0,0,[DateTimeKind]::Utc)
$definitions=@(
    @{Name='comment-matched';Command='c';Pattern='a.txt'},
    @{Name='comment-unmatched';Command='c';Pattern='absent.txt'},
    @{Name='rename-matched';Command='n';Pattern='a.txt'},
    @{Name='rename-unmatched';Command='n';Pattern='absent.txt'},
    @{Name='header-matched';Command='y';Pattern='a.txt'},
    @{Name='header-unmatched';Command='y';Pattern='absent.txt'},
    @{Name='join-existing';Command='j'}
)
foreach($date in @(
    @{Name='year1979';Value=[datetime]::new(1979,12,31,0,0,0,[DateTimeKind]::Utc)},
    @{Name='year1980';Value=[datetime]::new(1980,1,1,0,0,0,[DateTimeKind]::Utc)},
    @{Name='upper-before';Value=$maximum.AddSeconds(-1)},
    @{Name='upper-at';Value=$maximum},
    @{Name='upper-after';Value=$maximum.AddSeconds(1)},
    @{Name='year2200';Value=$future}
)){
    foreach($mode in @(
        @{Name='default';Switches='';Clamp=$true},
        @{Name='off';Switches='-jsf0';Clamp=$false},
        @{Name='on';Switches='-jsf1';Clamp=$true}
    )){
        $definitions+=@{Name=($date.Name+'-'+$mode.Name);Command='c';Pattern='a.txt';
            Creation=$date.Value;Switches=$mode.Switches;Clamp=$mode.Clamp}
    }
}
foreach($mode in @(
    @{Name='bare';Switches='-jsf';Clamp=$false},
    @{Name='bare-twice';Switches='-jsf -jsf';Clamp=$true},
    @{Name='off-bare';Switches='-jsf0 -jsf';Clamp=$true},
    @{Name='on-bare';Switches='-jsf1 -jsf';Clamp=$false},
    @{Name='off-two';Switches='-jsf0 -jsf2';Clamp=$true},
    @{Name='on-two';Switches='-jsf1 -jsf2';Clamp=$false},
    @{Name='off-plus';Switches='-jsf0 -jsf+';Clamp=$true},
    @{Name='on-minus';Switches='-jsf1 -jsf-';Clamp=$false}
)){
    $definitions+=@{Name=$mode.Name;Command='c';Pattern='a.txt';Creation=$future;
        Switches=$mode.Switches;Clamp=$mode.Clamp}
}
if($CaseNames.Count){
    $selected=@($CaseNames | ForEach-Object {$_.Split(',')})
    if(@($selected | Select-Object -Unique).Count -ne $selected.Count){throw '条件の重複指定はできません。'}
    foreach($name in $selected){if($name -notin $definitions.Name){throw "未知の条件: $name"}}
    $definitions=@($definitions | Where-Object {$_.Name -in $selected})
}
$hashes=@{}
foreach($path in $TestProgram,$RunnerPath,$Oracle,$Candidate){
    $hashes[$path]=(Get-FileHash -LiteralPath $path).Hash
}
New-Item -ItemType Directory -Path $root | Out-Null
function Invoke-Probe([string[]]$Arguments,[string]$Log){
    $rows=@(& $RunnerPath --timeout-seconds 10 $TestProgram --registry '' @Arguments)
    $processExit=$LASTEXITCODE
    [IO.File]::WriteAllLines($Log,[string[]]$rows,[Text.UTF8Encoding]::new($false))
    if($processExit -ne 0){throw "診断プロセス失敗: $processExit / $Log"}
    return ,$rows
}
function Read-ArchiveState([string]$Path){
    # コマンド後に排他的に開けることも確認し、日時だけの一致でハンドル漏れを見逃さない。
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    $stream.Dispose()
    $item=Get-Item -LiteralPath $Path
    return [pscustomobject]@{Hash=(Get-FileHash -LiteralPath $Path).Hash;Length=$item.Length;
        Creation=$item.CreationTimeUtc.Ticks;Write=$item.LastWriteTimeUtc.Ticks;Attributes=[int]$item.Attributes}
}
function Initialize-Archive([string]$Path,[datetime]$Creation){
    Copy-Item -LiteralPath $seed -Destination $Path
    [IO.File]::SetCreationTimeUtc($Path,$Creation)
    [IO.File]::SetLastWriteTimeUtc($Path,$ordinary)
    $state=Read-ArchiveState $Path
    if($state.Creation -ne $Creation.Ticks){throw "入力の作成日時を設定できません: $Path"}
    return $state
}
$source=Join-Path $root 'a.txt'
[IO.File]::WriteAllText($source,'comment-selection-body',[Text.UTF8Encoding]::new($false))
$seed=Join-Path $root 'seed.lzh'
$seedRows=Invoke-Probe @('--command-probe-a',$Oracle,('a -n1 -gm1 -y1 -c1 -h2 "'+$seed+'" "'+$source+'"'),'A') (Join-Path $root 'seed.log')
if($seedRows -notcontains 'result=0'){throw '原版の基準書庫生成に失敗しました。'}
$seedHash=(Get-FileHash -LiteralPath $seed).Hash
$records=[Collections.Generic.List[object]]::new()
$count=0
foreach($api in $Apis){foreach($case in $definitions){
    $pair=@{}
    foreach($side in 'oracle','reimpl'){
        $folder=Join-Path $root ($api+'-'+$case.Name+'-'+$side)
        New-Item -ItemType Directory -Path $folder | Out-Null
        $archive=Join-Path $folder 'archive.lzh'
        $creation=if($case.ContainsKey('Creation')){$case.Creation}else{$ordinary}
        $before=Initialize-Archive $archive $creation
        $comment=Join-Path $folder 'comment.txt'
        # 原版の非終端入力の過剰読み取りを、通常の書庫バイト比較へ混入させない。
        [IO.File]::WriteAllText($comment,('headless-comment'+[char]0),[Text.UTF8Encoding]::new($false))
        $extra=switch($case.Command){
            'c' {'-jz"'+$comment+'"'}
            'n' {'-grb.txt'}
            'y' {'-h1'}
            'j' {''}
        }
        $command=$case.Command+' -n1 -gm1 -y1 '+$case.Switches+' '+$extra+' "'+$archive+'" '+$case.Pattern
        $joinBefore=$null
        if($case.Command -eq 'j'){
            $join=Join-Path $folder 'join.lzh'
            $joinBefore=Initialize-Archive $join $ordinary
            $command+=' "'+$join+'"'
        }
        $dll=if($side -eq 'oracle'){$Oracle}else{$Candidate}
        $expectedCalls=1
        if($api -eq 'W'){
            $following=Join-Path $folder 'following.lzh'
            $followingBefore=Initialize-Archive $following $future
            $next='c -n1 -gm1 -y1 -jz"'+$comment+'" "'+$following+'" a.txt'
            $arguments=@('--command-sequence-probe',$dll,$command,$next)
            $expectedCalls=2
        }else{
            $arguments=@('--command-probe-a',$dll,$command)
            if($api -eq 'A'){$arguments+='A'}
        }
        $started=[datetime]::UtcNow.Ticks
        $rows=Invoke-Probe $arguments (Join-Path $folder 'command.log')
        $ended=[datetime]::UtcNow.Ticks
        $after=Read-ArchiveState $archive
        foreach($field in @('result=0','win32-error=0','compat-error=0','compat-system-error=38')){
            if(@($rows | Where-Object {$_ -ceq $field}).Count -ne $expectedCalls){throw "終了状態不一致: $folder / $field"}
        }
        $expectedRows=if($api -eq 'W'){12}else{6}
        if($rows.Count -ne $expectedRows){throw "診断行数不一致: $folder"}
        $expectedCreation=if($case.ContainsKey('Clamp') -and $case.Clamp -and $creation -gt $maximum){$maximum.Ticks}else{$creation.Ticks}
        if($after.Creation -ne $expectedCreation -or $after.Attributes -ne $before.Attributes){throw "作成日時・属性不一致: $folder"}
        if($after.Write -lt $started -or $after.Write -gt $ended){throw "更新日時が実行区間外: $folder"}
        if($case.Pattern -eq 'absent.txt' -and $after.Hash -ne $before.Hash){throw "対象なしで書庫内容が変化: $folder"}
        if($joinBefore){
            $joinAfter=Read-ArchiveState $join
            foreach($key in 'Hash','Length','Creation','Write','Attributes'){
                if($joinBefore.$key -ne $joinAfter.$key){throw "連結元の変更: $folder / $key"}
            }
        }
        $followingAfter=$null
        if($api -eq 'W'){
            $followingAfter=Read-ArchiveState $following
            if($followingAfter.Creation -ne $maximum.Ticks -or
               $followingAfter.Attributes -ne $followingBefore.Attributes -or
               $followingAfter.Write -lt $started -or $followingAfter.Write -gt $ended){
                throw "同一 DLL の次命令へ設定が残りました: $folder"
            }
        }
        if(@(Get-ChildItem -LiteralPath $folder -Filter '*.tmp').Count){throw "一時書庫が残っています: $folder"}
        $record=[pscustomobject]@{Case=$case.Name;Api=$api;Side=$side;Command=$command;
            Rows=$rows;Before=$before;After=$after;Following=$followingAfter;Started=$started;Ended=$ended}
        $records.Add($record)
        [IO.File]::WriteAllText((Join-Path $folder 'result.json'),($record | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
        $pair[$side]=@($rows | ForEach-Object {$_.Replace($folder.Replace('\','/'),'<ROOT>').Replace($folder,'<ROOT>')})
        foreach($key in 'Hash','Length','Creation','Attributes'){$pair[$side]+="$key=$($after.$key)"}
        if($followingAfter){$pair[$side]+='following.hash='+$followingAfter.Hash}
    }
    if(@(Compare-Object $pair.oracle $pair.reimpl -SyncWindow 0).Count){throw "原版との比較不一致: $api / $($case.Name)"}
    $count++
}}
if((Get-FileHash -LiteralPath $seed).Hash -ne $seedHash){throw '基準書庫が変化しました。'}
foreach($path in $hashes.Keys){if((Get-FileHash -LiteralPath $path).Hash -ne $hashes[$path]){throw "検証中のバイナリ変更: $path"}}
[IO.File]::WriteAllText((Join-Path $root 'results.json'),($records | ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))
Write-Host "Rewrite creation time: $count comparisons passed."
