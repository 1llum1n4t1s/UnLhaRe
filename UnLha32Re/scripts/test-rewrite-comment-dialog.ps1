[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$RunnerPath,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [ValidateSet('legacy','A','W')][string[]]$Apis=@('legacy','A','W'),
    [ValidateSet(1041,1033)][int[]]$Languages=@(1041,1033),
    [string[]]$CaseNames=@()
)

$ErrorActionPreference='Stop'
if(@($Apis | Select-Object -Unique).Count -ne $Apis.Count){throw 'API の重複指定はできません。'}
if(@($Languages | Select-Object -Unique).Count -ne $Languages.Count){throw '言語の重複指定はできません。'}
foreach($name in 'TestProgram','RunnerPath','Oracle','Candidate'){
    Set-Variable -Name $name -Value (Resolve-Path -LiteralPath (Get-Variable -Name $name -ValueOnly)).Path
}
$root=[IO.Path]::GetFullPath($Workspace)
if(Test-Path -LiteralPath $root){throw '新しい検証領域を指定してください。'}

# c の対話的な注釈入力は、既存・空・取消・複数メンバーを同じ画面応答経路で検証する。
# 文字列は command-dialog-probe の text:<UTF-16 code unit>:button 形式で渡す。
$definitions=@(
    @{Name='h2-existing';Seed='h2-comment';Pattern='a.txt';Responses='1';ExpectedDialogs=1;Changed=$false},
    @{Name='h2-text';Seed='h2-comment';Pattern='a.txt';Responses='text:004100420043:1';ExpectedDialogs=1;Changed=$true},
    @{Name='h2-empty';Seed='h2-comment';Pattern='a.txt';Responses='text::1';ExpectedDialogs=1;Changed=$true},
    @{Name='h2-close';Seed='h2-comment';Pattern='a.txt';Responses='close';ExpectedDialogs=1;Changed=$false},
    @{Name='h2-bare';Seed='h2-empty';Pattern='a.txt';Responses='1';ExpectedDialogs=1;Changed=$false},
    # level 0 has no extension area; the original ignores an explicit comment and
    # accepting an empty interactive value leaves the bytes unchanged.
    @{Name='h0-empty';Seed='h0-comment';Pattern='a.txt';Responses='text::1';ExpectedDialogs=1;Changed=$false},
    @{Name='h1-empty';Seed='h1-comment';Pattern='a.txt';Responses='text::1';ExpectedDialogs=1;Changed=$true},
    @{Name='multi-first-close';Seed='multi-comment';Pattern='*';Responses='1,close';ExpectedDialogs=2;Changed=$false},
    @{Name='multi-close-first';Seed='multi-comment';Pattern='*';Responses='close,1';ExpectedDialogs=2;Changed=$false}
)
if($CaseNames.Count){
    $selected=@($CaseNames | ForEach-Object {$_.Split(',')})
    if(@($selected | Select-Object -Unique).Count -ne $selected.Count){throw '条件の重複指定はできません。'}
    foreach($name in $selected){if($name -notin $definitions.Name -and $name -ne 'layout'){throw "未知の条件: $name"}}
    $definitions=@($definitions | Where-Object {$_.Name -in $selected})
}
if(!$definitions.Count){throw '実行対象の比較がありません。'}

function Invoke-Isolated([string[]]$Arguments,[string]$Log,[int]$ExpectedExit=0){
    $rows=@(& $RunnerPath --timeout-seconds 30 $TestProgram --registry '' @Arguments 2>&1 |
        ForEach-Object {"$_"})
    $code=$LASTEXITCODE
    [IO.File]::WriteAllLines($Log,[string[]]$rows,[Text.UTF8Encoding]::new($false))
    if($code -ne $ExpectedExit){throw "注釈ダイアログプローブが停止しました: exit=$code expected=$ExpectedExit / $Log"}
    return ,$rows
}

function Get-State([string]$Path){
    if(!(Test-Path -LiteralPath $Path)){return $null}
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    $stream.Dispose()
    $item=Get-Item -LiteralPath $Path -Force
    return [pscustomobject]@{
        Hash=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        Length=$item.Length; Creation=$item.CreationTimeUtc.Ticks; Write=$item.LastWriteTimeUtc.Ticks
        Attributes=[int]$item.Attributes
    }
}

function Normalize-Rows([string[]]$Rows,[string]$Folder){
    $slash=$Folder.Replace('\','/')
    $escaped=$Folder.Replace('\','\\')
    @($Rows | ForEach-Object {
        $line=$_.Replace($escaped,'<ROOT>').Replace($slash,'<ROOT>').Replace($Folder,'<ROOT>')
        $line -replace '(?i)\b(?:LHT|ulr)[0-9a-f]+\.tmp\b','<TEMP>'
    })
}

function Assert-Rows([string[]]$Rows,[int]$ExpectedDialogs,[string]$Label){
    foreach($field in 'result=0','win32-error=0','compat-error=0','compat-system-error=38'){
        if(@($Rows | Where-Object {$_ -ceq $field}).Count -ne 1){throw "終了状態が不正です: $Label / $field"}
    }
    $dialogCount=@($Rows | Where-Object {$_ -like 'command-dialog.count=*'})
    if($dialogCount.Count -ne 1 -or $dialogCount[0] -cne "command-dialog.count=$ExpectedDialogs"){
        throw "ダイアログ件数が不正です: $Label"
    }
    foreach($kind in 'enum','progress'){
        $count=@($Rows | Where-Object {$_ -like "$kind.count=*"})
        if($count.Count -ne 1){throw "${Label}: $kind の完了記録がありません"}
        $expected=[int]$count[0].Split('=')[1]
        if(@($Rows | Where-Object {$_ -like "$kind.entry=*"}).Count -ne $expected){
            throw "${Label}: $kind の通知件数が不正です"
        }
    }
}

New-Item -ItemType Directory -Path $root | Out-Null
$hashes=@{}
foreach($path in $TestProgram,$RunnerPath,$Oracle,$Candidate,$PSCommandPath){
    $hashes[$path]=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}

$source=Join-Path $root 'source'
New-Item -ItemType Directory -Path $source | Out-Null
[IO.File]::WriteAllText((Join-Path $source 'a.txt'),'comment-dialog-body',[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $source 'b.txt'),'second-comment-dialog-body',[Text.UTF8Encoding]::new($false))
$comment=Join-Path $root 'comment.txt'
[IO.File]::WriteAllText($comment,('headless-comment'+[char]0),[Text.UTF8Encoding]::new($false))

function New-Archive([string]$Path,[string]$Options,[string]$Pattern='a.txt'){
    $sourceArgument='"'+(Join-Path $source $Pattern)+'"'
    if($Pattern -eq '*'){$sourceArgument='"'+$source.Replace('\','/')+'/'+'"'}
    $line='a -n1 -gm1 -y1 '+$Options+' "'+$Path+'" '+$sourceArgument
    if($Pattern -eq '*'){$line+=' *'}
    $rows=Invoke-Isolated @('--command-probe-a',$Oracle,$line,'A') (Join-Path $root ([IO.Path]::GetFileNameWithoutExtension($Path)+'.add.log'))
    if('result=0' -notin $rows -or !(Test-Path -LiteralPath $Path)){throw "基準書庫を作成できません: $Path"}
}

$base=@{}
foreach($level in 0,1,2){
    $path=Join-Path $root "base-h$level.lzh"
    New-Archive $path ('-h'+$level)
    $base["h$level"]=$path
}
$multiBase=Join-Path $root 'base-multi.lzh'
New-Archive $multiBase '' '*'
$base.multi=$multiBase

function Add-SeedComment([string]$BasePath,[string]$Name,[string]$Pattern='a.txt'){
    $target=Join-Path $root "$Name.lzh"
    Copy-Item -LiteralPath $BasePath -Destination $target
    $line='c -n1 -gm1 -y1 -jz"'+$comment+'" "'+$target+'" '+$Pattern
    $rows=Invoke-Isolated @('--command-probe-a',$Oracle,$line,'A') (Join-Path $root "$Name.comment.log")
    if('result=0' -notin $rows -or !(Test-Path -LiteralPath $target)){throw "基準注釈書庫を作成できません: $Name"}
    return $target
}
$seed=@{
    'h2-comment'=(Add-SeedComment $base.h2 'seed-h2-comment')
    'h0-comment'=(Add-SeedComment $base.h0 'seed-h0-comment')
    'h1-comment'=(Add-SeedComment $base.h1 'seed-h1-comment')
    'h2-empty'=$base.h2
}
$multiSeed=Join-Path $root 'seed-multi-comment.lzh'
Copy-Item -LiteralPath $multiBase -Destination $multiSeed
foreach($member in 'a.txt','b.txt'){
    $line='c -n1 -gm1 -y1 -jz"'+$comment+'" "'+$multiSeed+'" '+$member
    $rows=Invoke-Isolated @('--command-probe-a',$Oracle,$line,'A') (Join-Path $root "multi-$member.comment.log")
    if('result=0' -notin $rows){throw "複数メンバー基準注釈を作成できません: $member"}
}
$seed['multi-comment']=$multiSeed
$seedHashes=@{}
foreach($path in $seed.Values | Select-Object -Unique){$seedHashes[$path]=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}

$plan=[Collections.Generic.List[object]]::new()
foreach($api in $Apis){foreach($language in $Languages){foreach($case in $definitions){
    $plan.Add([pscustomobject]@{Label="$api-$language-$($case.Name)";Api=$api;Language=$language;Case=$case.Name})
}}}
# 位置・資源は API に依存しないが、英日両方を原版と比較して保持する。
if(!$CaseNames.Count -or 'layout' -in $CaseNames){
    foreach($api in $Apis){foreach($language in $Languages){
        $plan.Add([pscustomobject]@{Label="$api-$language-layout";Api=$api;Language=$language;Case='layout'})
    }}
}
[IO.File]::WriteAllText((Join-Path $root 'plan.json'),($plan | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))

$observations=[Collections.Generic.List[object]]::new()
foreach($item in $plan){
    $pair=@{}
    foreach($side in 'oracle','reimpl'){
        $folder=Join-Path $root (Join-Path $item.Label $side)
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $archive=Join-Path $folder 'archive.lzh'
        $case=if($item.Case -eq 'layout'){$null}else{$definitions | Where-Object Name -eq $item.Case}
        $sourceSeed=if($item.Case -eq 'layout'){$seed['h2-comment']}else{$seed[$case.Seed]}
        Copy-Item -LiteralPath $sourceSeed -Destination $archive
        $before=Get-State $archive
        $dll=if($side -eq 'oracle'){$Oracle}else{$Candidate}
        $layout=if($item.Api -eq 'W'){'w32'}else{'a32'}
        if($item.Case -eq 'layout'){
            $line='c -n1 -gm1 -y1 "'+$archive+'" a.txt'
            $args=@('--command-dialog-probe',$dll,$line,'inspect-layout',$layout,'0',$item.Api,'1041',[string]$item.Language)
            $rows=Invoke-Isolated $args (Join-Path $folder 'command.log') 125
            if('command dialog observation completed' -notin $rows){throw "画面観測が完了しません: $($item.Label)/$side"}
            $snapshot=@($rows | Where-Object {$_ -match '^(dialog\.|control\.|command-dialog\.)'})
            if($snapshot.Count -ne 12 -or @($snapshot | Where-Object {$_ -like 'control.geometry=*'}).Count -ne 3){
                throw "注釈画面の観測項目が不足しています: $($item.Label)/$side"
            }
            # inspect は診断プロセスを画面表示直後に終了させるため、原版同様に
            # 一時書庫だけが残って入力名がまだ戻らない場合がある。戻った場合は
            # バイトが不変であることを確認し、基準シード自体は後段で再確認する。
            $after=Get-State $archive
            if($after -and $after.Hash -cne $before.Hash){throw "未応答の注釈画面で書庫が変化しました: $($item.Label)/$side"}
            $pair[$side]=Normalize-Rows $snapshot $folder
            $observations.Add([pscustomobject]@{Label=$item.Label;Side=$side;Rows=$rows;Before=$before;After=$after})
            continue
        }
        $line='c -n1 -gm1 -y1 "'+$archive+'" '+$case.Pattern
        $args=@('--command-dialog-probe',$dll,$line,$case.Responses,$layout,'0',$item.Api,'1041',[string]$item.Language)
        $rows=Invoke-Isolated $args (Join-Path $folder 'command.log')
        Assert-Rows $rows $case.ExpectedDialogs "$($item.Label)/$side"
        $after=Get-State $archive
        if(!$after){throw "注釈処理で書庫が失われました: $($item.Label)/$side"}
        if(([bool]($after.Hash -cne $before.Hash)) -ne [bool]$case.Changed){
            throw "注釈の変更有無が不正です: $($item.Label)/$side"
        }
        if(@(Get-ChildItem -LiteralPath $folder -Filter '*.tmp' -Force -ErrorAction SilentlyContinue).Count){
            throw "一時書庫が残っています: $($item.Label)/$side"
        }
        $pair[$side]=Normalize-Rows $rows $folder
        $observations.Add([pscustomobject]@{Label=$item.Label;Side=$side;Rows=$rows;Before=$before;After=$after})
    }
    $difference=@(Compare-Object $pair.oracle $pair.reimpl -SyncWindow 0)
    if($difference.Count){
        [IO.File]::WriteAllText((Join-Path $root "$($item.Label).diff.log"),($difference | Format-List | Out-String -Width 2000),[Text.UTF8Encoding]::new($false))
        throw "注釈ダイアログの原版比較に失敗しました: $($item.Label)"
    }
    if($observations.Count % 6 -eq 0){Write-Host "Rewrite comment dialog progress: $($observations.Count)/$($plan.Count*2) sides"}
}

foreach($path in $seedHashes.Keys){if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $seedHashes[$path]){throw "基準書庫が変化しました: $path"}}
foreach($path in $hashes.Keys){if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $hashes[$path]){throw "検証中のファイルが変化しました: $path"}}
[IO.File]::WriteAllText((Join-Path $root 'results.json'),($observations | ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))
Write-Host "Rewrite comment dialog: $($plan.Count) exact oracle/reimplementation comparisons passed."
