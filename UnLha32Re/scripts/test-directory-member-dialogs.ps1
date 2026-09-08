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
$definitions=@(
    @{Name='directory-yes';Response='1';Directory=$true},
    @{Name='directory-no';Response='22:1';Directory=$false},
    @{Name='directory-all';Response='23:1';Directory=$true},
    @{Name='directory-skip-all';Response='24:1';Directory=$false},
    @{Name='directory-cancel';Response='2,2';Directory=$false;Result=32800},
    @{Name='nested-yes';Response='1';Directory=$true;Nested=$true;Body=$true},
    @{Name='nested-no';Response='22:1,22:1';Directory=$false;Nested=$true},
    @{Name='nested-all';Response='23:1';Directory=$true;Nested=$true;Body=$true},
    @{Name='nested-skip-all';Response='24:1';Directory=$false;Nested=$true},
    @{Name='nested-cancel';Response='2,2';Directory=$false;Nested=$true;Result=32800},
    @{Name='nested-no-then-yes';Response='22:1,1';Directory=$true;Nested=$true;Body=$true;Implicit=$true}
)
foreach($name in $CaseNames){if($name -cnotin $definitions.Name){throw "未知の確認条件: $name"}}
foreach($name in 'TestProgram','RunnerPath','Oracle','Candidate'){Set-Variable -Name $name -Value (Resolve-Path -LiteralPath (Get-Variable -Name $name -ValueOnly)).Path}
$Workspace=[IO.Path]::GetFullPath($Workspace)
if(Test-Path -LiteralPath $Workspace){throw '既存の検証領域は上書きしません'}
$source=Join-Path $Workspace 'input'
$directory=Join-Path $source 'a-dir'
New-Item -ItemType Directory -Path $directory | Out-Null
$stamp=[datetime]'2020-01-02T03:04:06Z'
[IO.Directory]::SetCreationTimeUtc($directory,$stamp)
[IO.Directory]::SetLastAccessTimeUtc($directory,$stamp)
[IO.Directory]::SetLastWriteTimeUtc($directory,$stamp)
$hashes=@{}
foreach($path in $TestProgram,$RunnerPath,$Oracle,$Candidate,$PSCommandPath){$hashes[$path]=(Get-FileHash -LiteralPath $path).Hash}
[IO.File]::WriteAllText((Join-Path $Workspace 'environment.json'),($hashes | ConvertTo-Json))
$directorySeed=Join-Path $Workspace 'directory.lzh'
$fileSeed=Join-Path $Workspace 'file.lzh'
$nestedSeed=Join-Path $Workspace 'nested.lzh'
$body='directory child payload'
foreach($kind in 'directory','file'){
    if($kind -eq 'directory'){$archive=$directorySeed;$switches='-a1 -d1';$member='a-dir'}else{
        $path=Join-Path $directory 'child.txt'
        [IO.File]::WriteAllText($path,$body,[Text.UTF8Encoding]::new($false))
        $file=Get-Item -LiteralPath $path
        $file.CreationTimeUtc=$file.LastWriteTimeUtc=$file.LastAccessTimeUtc=$stamp
        $archive=$fileSeed;$switches='-x1 -jm0';$member='a-dir/child.txt'
    }
    $line='a -+ -h2 -n1 -gm1 -y1 '+$switches+' "'+$archive+'" "'+$source+'/" '+$member
    $rows=@(& $RunnerPath --timeout-seconds 30 $TestProgram --registry '' --command-probe $Oracle $line 2>&1 | ForEach-Object {"$_"})
    $code=$LASTEXITCODE
    [IO.File]::WriteAllLines((Join-Path $Workspace "$kind-seed.log"),[string[]]$rows)
    if($code -ne 0 -or 'result=0' -cnotin $rows){throw 'ディレクトリ確認の正常入力を作成できません'}
}
$prefix=[IO.File]::ReadAllBytes($directorySeed)
if($prefix[20] -ne 2 -or [Text.Encoding]::ASCII.GetString($prefix,2,5) -cne '-lhd-' -or [BitConverter]::ToUInt16($prefix,0)+1 -ne $prefix.Length){throw '単一ディレクトリの正常入力ではありません'}
[IO.File]::WriteAllBytes($nestedSeed,[byte[]]($prefix[0..($prefix.Length-2)]+[IO.File]::ReadAllBytes($fileSeed)))
foreach($path in $directorySeed,$fileSeed,$nestedSeed){$hashes[$path]=(Get-FileHash -LiteralPath $path).Hash}
$done=0
foreach($case in $definitions){if($CaseNames.Count -and $case.Name -cnotin $CaseNames){continue}
    foreach($api in $Apis){foreach($language in $Languages){
        $label="$($case.Name)-$api-$language"
        $observed=@{};$effects=@{}
        foreach($side in 'oracle','reimpl'){
            $root=Join-Path $Workspace "$label/$side"
            foreach($phase in 'first','second'){New-Item -ItemType Directory -Path (Join-Path $root $phase) | Out-Null}
            $archive=Join-Path $root 'source.lzh'
            Copy-Item -LiteralPath $(if($case.Nested){$nestedSeed}else{$directorySeed}) -Destination $archive
            $inputHash=(Get-FileHash -LiteralPath $archive).Hash
            $steps=@('@initial-language:'+$language)
            foreach($phase in 'first','second'){
                $steps+=('x -n1 -m0 "'+$archive+'" "'+(Join-Path $root $phase)+'/" *')
                $steps+=('@audit-archive-release:'+$archive)
            }
            $responses=$case.Response+',23:1'
            $dll=if($side -eq 'oracle'){$Oracle}else{$Candidate}
            $layout=if($api -eq 'W'){'w64'}else{'a32'}
            $arguments=@('--sequence-dialog-probe',$dll,$responses,$layout,'1041','0',$api,$layout)+$steps
            $rows=@(& $RunnerPath --timeout-seconds 60 $TestProgram --registry '' @arguments 2>&1 | ForEach-Object {"$_"})
            $code=$LASTEXITCODE
            [IO.File]::WriteAllLines((Join-Path $root 'command.log'),[string[]]$rows)
            if($code -ne 0){throw "ディレクトリ項目の確認が停止しました: $label/$side ($code)"}
            $result=if($case.ContainsKey('Result')){$case.Result}else{0}
            if([string]::Join('|',@($rows -match '^result=')) -cne "result=$result|result=0" -or
                "command-dialog.count=$($responses.Split(',').Count)" -cnotin $rows -or
                @($rows -ceq 'archive-released=1,error=0').Count -ne 2){throw "確認状態または入力解放が不正です: $label/$side"}
            $state=@()
            foreach($phase in 'first','second'){
                $output=Join-Path $root $phase
                $target=Join-Path $output 'a-dir'
                $child=Join-Path $target 'child.txt'
                $exists=$phase -eq 'second' -or $case.Directory
                $written=$case.Nested -and ($phase -eq 'second' -or $case.Body)
                if((Test-Path -LiteralPath $target) -ne $exists -or (Test-Path -LiteralPath $child) -ne [bool]$written){throw "作成・拒否の結果が不正です: $label/$side/$phase"}
                if($written -and [IO.File]::ReadAllText($child) -cne $body){throw '子ファイルの本文が異なります'}
                $state+="$phase/directory=$exists,body=$([bool]$written)"
                if($exists){
                    $dir=Get-Item -LiteralPath $target -Force
                    $explicit=$phase -eq 'second' -or !$case.Implicit
                    if(($dir.CreationTimeUtc.ToFileTimeUtc() -eq $stamp.ToFileTimeUtc()) -ne $explicit){throw 'ディレクトリ項目を拒否した場合の日時復元が不正です'}
                    $state+="$phase/attributes=$([int]$dir.Attributes),explicit-time=$explicit"
                    if(!$case.Nested){$state+="$phase/write=$($dir.LastWriteTimeUtc.Ticks)"}
                }
                if(@(Get-ChildItem -LiteralPath $output -File -Recurse -Force).Count -ne [int][bool]$written){throw '余分な出力ファイルが残りました'}
            }
            if((Get-FileHash -LiteralPath $archive).Hash -cne $inputHash){throw '入力書庫が変更されました'}
            [IO.File]::WriteAllLines((Join-Path $root 'effects.log'),[string[]]$state)
            $effects[$side]=$state
            $observed[$side]=@($rows | ForEach-Object {$_.Replace($root.Replace('\','/'),'<case>').Replace($root.Replace('\','\\'),'<case>').Replace($root,'<case>')})
        }
        $difference=@(Compare-Object $observed.oracle $observed.reimpl -SyncWindow 0)
        if($difference.Count -or [string]::Join('|',$effects.oracle) -cne [string]::Join('|',$effects.reimpl)){
            [IO.File]::WriteAllText((Join-Path $Workspace "$label.diff.log"),($difference | Format-List | Out-String -Width 2000))
            throw "ディレクトリ項目の確認が一致しません: $label"
        }
        $done++
        if($done % 5 -eq 0){"Directory member dialogs progress: $done sequences compatible"}
    }}
}
if(!$done){throw '比較対象がありません'}
foreach($path in $hashes.Keys){if((Get-FileHash -LiteralPath $path).Hash -cne $hashes[$path]){throw '実行物または入力書庫が変更されました'}}
"Directory member dialogs: $done sequences compatible; explicit/implicit creation, metadata, bodies, retries and ordered logs verified"
