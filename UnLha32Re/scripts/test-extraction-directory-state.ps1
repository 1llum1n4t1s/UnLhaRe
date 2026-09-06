[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$RunnerPath,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [Parameter(Mandatory)][string]$BodyDirectory,
    [string[]]$DirectoryNames=@('a-dir','資料'),
    [string[]]$Variants=@('good','body0-cut3','body1-cut3','header-cut21','crc-first','crc-all'),
    [ValidateSet('silent','keep-stop','delete-stop')][string[]]$Policies=@('silent','keep-stop','delete-stop'),
    [string[]]$Profiles=@('w64','a32'),
    [int[]]$DirectoryAttributes=@(16),
    [int[]]$RestoreAttributes=@(0,1),
    [bool[]]$ExistingDirectories=@($false,$true),
    [ValidateSet(0,1)][int]$UnicodeMode=1,
    [string]$DestinationName='output',
    [switch]$NestedFile,
    [switch]$DirectoryLast,
    [datetime]$ExistingCreation='2010-01-02T03:04:06Z'
)
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath($Workspace)
if(Test-Path -LiteralPath $workspace){throw '既存の検証領域は上書きしません'}
if($DirectoryLast -and (!$NestedFile -or @($Variants | Where-Object {$_ -ne 'good'}).Count)){throw '後置ディレクトリは正常な入れ子入力に限定します'}
foreach($name in @($DirectoryNames)+@($DestinationName)){if([IO.Path]::GetFileName($name) -cne $name -or $name -in '','.','..'){throw 'ディレクトリ名は単一の要素に限定します'}}
$TestProgram=(Resolve-Path -LiteralPath $TestProgram).Path
$runner=(Resolve-Path -LiteralPath $RunnerPath).Path
$oracle=(Resolve-Path -LiteralPath $Oracle).Path
$candidate=(Resolve-Path -LiteralPath $Candidate).Path
$BodyDirectory=(Resolve-Path -LiteralPath $BodyDirectory).Path
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'test-enum-state.ps1'),[ref]$null,[ref]$null)
$helper=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-EnumProbe'},$true)
if(!$helper){throw '隔離プローブが見つかりません'}
. ([scriptblock]::Create($helper.Extent.Text))
function Update-DirectoryFixtureHeader([byte[]]$Bytes,[switch]$FixedTimes){
    $size=[BitConverter]::ToUInt16($Bytes,0)
    $offset=24
    $crcAt=-1
    while($offset+2 -lt $size){
        $length=[BitConverter]::ToUInt16($Bytes,$offset)
        if(!$length){break}
        if($length -lt 3 -or $offset+$length -gt $size){throw '拡張ヘッダーが不正です'}
        if($Bytes[$offset+2] -eq 0){$crcAt=$offset+3}
        if($FixedTimes -and $Bytes[$offset+2] -eq 0x41 -and $length -eq 27){
            $timeBytes=[BitConverter]::GetBytes(([datetime]'2020-01-02T03:04:06Z').ToFileTimeUtc())
            foreach($at in 3,11,19){$timeBytes.CopyTo($Bytes,$offset+$at)}
        }
        $offset+=$length
    }
    if($crcAt -lt 0){throw 'ヘッダー CRC がありません'}
    $Bytes[$crcAt]=0;$Bytes[$crcAt+1]=0
    [int]$crc=0
    for($at=0;$at -lt $size;$at++){
        $crc=$crc -bxor [int]$Bytes[$at]
        for($bit=0;$bit -lt 8;$bit++){$crc=if($crc -band 1){($crc -shr 1) -bxor 0xa001}else{$crc -shr 1}}
    }
    [BitConverter]::GetBytes([uint16]$crc).CopyTo($Bytes,$crcAt)
}
New-Item -ItemType Directory -Path $workspace | Out-Null
$hashes=@{}
$stamps=@{}
foreach($path in $TestProgram,$runner,$oracle,$candidate){$hashes[$path]=(Get-FileHash -LiteralPath $path).Hash;$stamps[$path]=[IO.File]::GetLastWriteTimeUtc($path)}
Write-Host "Directory extraction state: candidate SHA256=$($hashes[$candidate]), oracle SHA256=$($hashes[$oracle])"
$good=(Resolve-Path -LiteralPath (Join-Path $BodyDirectory 'ascii-jm0/good.lzh')).Path
$observations=[Collections.Generic.List[object]]::new()
$expected=0
$fixtureIndex=0
foreach($name in $DirectoryNames){foreach($attributes in $DirectoryAttributes){
    $fixtureRoot=Join-Path $workspace "fixture-$fixtureIndex"
    $source=Join-Path $fixtureRoot 'source'
    $directory=Join-Path $source $name
    New-Item -ItemType Directory -Path $directory | Out-Null
    $stamp=[datetime]'2020-01-02T03:04:06Z'
    [IO.Directory]::SetCreationTimeUtc($directory,$stamp)
    [IO.Directory]::SetLastAccessTimeUtc($directory,$stamp)
    [IO.Directory]::SetLastWriteTimeUtc($directory,$stamp)
    [IO.File]::SetAttributes($directory,[IO.FileAttributes]$attributes)
    $seed=Join-Path $fixtureRoot 'directory.lzh'
    $seedRows=@(Invoke-EnumProbe (Join-Path $fixtureRoot 'seed') @('--command-probe',$oracle,"a -+ -a1 -d1 -h2 -n1 -gm1 -y1 `"$seed`" `"$($source.Replace('\','/'))/`" `"$name`"") $fixtureRoot)
    if('result=0' -notin $seedRows){throw '正常ディレクトリ書庫を作成できません'}
    $prefix=[IO.File]::ReadAllBytes($seed)
    if($prefix[20] -ne 2 -or [Text.Encoding]::ASCII.GetString($prefix,2,5) -cne '-lhd-' -or [BitConverter]::ToUInt16($prefix,0)+1 -ne $prefix.Length){throw '正常対照が単一ディレクトリではありません'}
    $nestedSeed=''
    if($NestedFile){
        # 入力の参照日時も古い固定値にして、子項目作成による実アクセスと区別する。
        Update-DirectoryFixtureHeader $prefix -FixedTimes
        $inputFile=Join-Path $directory 'a.txt'
        [IO.File]::WriteAllText($inputFile,'first payload',[Text.UTF8Encoding]::new($false))
        [IO.File]::SetCreationTimeUtc($inputFile,$stamp)
        [IO.File]::SetLastAccessTimeUtc($inputFile,$stamp)
        [IO.File]::SetLastWriteTimeUtc($inputFile,$stamp)
        $nestedSeed=Join-Path $fixtureRoot 'nested.lzh'
        $rows=@(Invoke-EnumProbe (Join-Path $fixtureRoot 'nested-seed') @('--command-probe',$oracle,"a -+ -x1 -h2 -jm0 -n1 -gm1 -y1 `"$nestedSeed`" `"$($source.Replace('\','/'))/`" `"$name/a.txt`"") $fixtureRoot)
        if('result=0' -notin $rows){throw '入れ子の正常書庫を作成できません'}
    }
    $headerAccess=$null
    for($at=24;$at+2 -lt [BitConverter]::ToUInt16($prefix,0);){
        $length=[BitConverter]::ToUInt16($prefix,$at)
        if(!$length){break}
        if($prefix[$at+2] -eq 0x41 -and $length -eq 27){$headerAccess=[BitConverter]::ToInt64($prefix,$at+19)}
        $at+=$length
    }
    if($null -eq $headerAccess){throw 'ディレクトリの参照日時がありません'}
    foreach($variant in $Variants){
        $body=(Resolve-Path -LiteralPath (Join-Path $BodyDirectory "ascii-jm0/$variant.lzh")).Path
        $bodyBytes=[IO.File]::ReadAllBytes($body)
        if($NestedFile){
            $body=$nestedSeed
            $bodyBytes=[IO.File]::ReadAllBytes($body)
            $headerSize=[BitConverter]::ToUInt16($bodyBytes,0)
            if($bodyBytes[20] -ne 2 -or $headerSize+14 -ne $bodyBytes.Length){throw '入れ子入力が 13 バイトの単一ファイルではありません'}
            switch($variant){
                'good'{}
                'body0-cut3'{$bodyBytes=$bodyBytes[0..($headerSize+2)]}
                'header-cut21'{$bodyBytes=$bodyBytes[0..20]}
                {$_ -in 'crc-first','crc-all'}{$bodyBytes[21]=$bodyBytes[21] -bxor 1; Update-DirectoryFixtureHeader $bodyBytes}
                default{throw "未対応の入れ子条件: $variant"}
            }
        }
        $archive=Join-Path $fixtureRoot "$variant.lzh"
        if($DirectoryLast){
            [IO.File]::WriteAllBytes($archive,[byte[]]($bodyBytes[0..($bodyBytes.Length-2)]+$prefix))
        }else{
            [IO.File]::WriteAllBytes($archive,[byte[]]($prefix[0..($prefix.Length-2)]+$bodyBytes))
        }
        foreach($path in $good,$body,$seed,$archive){$hashes[$path]=(Get-FileHash -LiteralPath $path).Hash;$stamps[$path]=[IO.File]::GetLastWriteTimeUtc($path)}
        foreach($policy in $Policies){
            # gm0 の確認分岐は CRC 不良だけで行う。正常・読み取り失敗は同一条件を重複実行しない。
            if($policy -ne 'silent' -and $variant -notmatch '^crc-'){continue}
            foreach($restore in $RestoreAttributes){foreach($existing in $ExistingDirectories){foreach($profile in $Profiles){
                $expected++
                $api=if($profile -in 'w64','w32','W-A32'){'W'}elseif($profile -eq 'legacy'){'legacy'}else{'A'}
                $layout=if($profile -in 'legacy','W-A32'){'a32'}else{$profile}
                if($layout -notin 'w64','w32','a32','a64'){throw "未知のプローブ構成: $profile"}
                $responses=if($policy -eq 'keep-stop'){'7,7,2'}elseif($policy -eq 'delete-stop'){'6,7,2'}else{'6'}
                $gm=if($policy -eq 'silent'){1}else{0}
                $label="$fixtureIndex-$variant-$policy-a$restore-existing$existing-$profile"
                $snapshots=@()
                foreach($side in 'oracle','reimpl'){
                    $caseStarted=[datetime]::UtcNow
                    $root=Join-Path $workspace ('case-{0:D4}-{1}' -f $observations.Count,$side)
                    $output=Join-Path $root $DestinationName
                    $next=Join-Path $root 'next'
                    New-Item -ItemType Directory -Path $output,$next | Out-Null
                    $target=Join-Path $output $name
                    if($existing){
                        New-Item -ItemType Directory -Path $target | Out-Null
                        [IO.Directory]::SetCreationTimeUtc($target,$ExistingCreation)
                        [IO.Directory]::SetLastAccessTimeUtc($target,[datetime]'2010-01-02T03:04:06Z')
                        [IO.Directory]::SetLastWriteTimeUtc($target,[datetime]'2010-01-02T03:04:06Z')
                    }
                    $dll=if($side -eq 'oracle'){$oracle}else{$candidate}
                    $line="x -+ -a$restore -gm$gm -y1 -n1 `"$archive`" `"$($output.Replace('\','/'))/`" *"
                    $following="x -+ -gm1 -y1 -n1 `"$good`" `"$($next.Replace('\','/'))/`" *"
                    $steps=@('@audit-directory-set-time',"@audit-directory:$target",$line,"@directory-state:$target","@audit-archive-release:$archive",$following,"@directory-state:$target","@audit-archive-release:$archive")
                    $rows=@(Invoke-EnumProbe (Join-Path $root 'sequence') (@('--sequence-dialog-probe',$dll,$responses,$layout,'1041',[string]$UnicodeMode,$api,'w64')+$steps) $root)
                    $caseFinished=[datetime]::UtcNow
                    $results=@($rows -match '^result=')
                    if($results.Count -ne 2 -or $results[1] -cne 'result=0'){throw "後続の正常展開が失敗しました: $label/$side"}
                    if($variant -eq 'good' -and $results[0] -cne 'result=0'){throw "正常対照が失敗しました: $label/$side"}
                    if($policy -ne 'silent' -and $results[0] -cne 'result=32780'){throw "CRC 中止に到達していません: $label/$side"}
                    $dialogCount=if($policy -eq 'silent'){0}else{3}
                    if("command-dialog.count=$dialogCount" -notin $rows -or @($rows -ceq 'archive-released=1,error=0').Count -ne 2){throw "解放または完了記録が不正です: $label/$side"}
                    $states=@($rows -match '^directory-state=')
                    if($states.Count -ne 2){throw '処理直後と次命令後の状態がありません'}
                    $oldExisting=$existing -and $ExistingCreation -lt $caseStarted
                    $expectedCreate=($(if($oldExisting){$ExistingCreation}else{$stamp})).ToFileTimeUtc()
                    foreach($state in $states){
                        if($state -notmatch ',create=(\d+),' -or [long]$Matches[1] -ne $expectedCreate){throw "ディレクトリの作成日時の選択が不正です: $label/$side"}
                    }
                    # NTFS の実アクセスによる後続更新とは別に、設定 API の値と即時結果を厳密に検査する。
                    $setRows=@($rows -match '^directory-set-time=')
                    $expectedSets=if($oldExisting){0}else{1}
                    if($setRows.Count -ne $expectedSets){throw "ディレクトリ日時の設定回数が不正です: $label/$side"}
                    if($expectedSets){
                        $time=$stamp.ToFileTimeUtc()
                        $expectedSet="directory-set-time=result=1,queried=1,create=$time,access=$headerAccess,write=$time,actual-create=$time,actual-access=$headerAccess,actual-write=$time"
                        if($setRows[0] -cne $expectedSet){throw "設定したディレクトリ日時が入力ヘッダーと一致しません: $label/$side"}
                    }
                    # 次の無関係な展開が以前のディレクトリの日時・属性を復元してはいけない。
                    if(($states[0] -replace ',access=\d+','') -cne ($states[1] -replace ',access=\d+','')){throw "次命令が前のディレクトリを変更しました: $label/$side"}
                    # NTFS の参照日時更新が有効な環境では、原版でも設定直後の値と実アクセス時刻の
                    # 両方を取り得る。API の設定値は上で固定し、観測値は保持または実行区間内に限定する。
                    $initialAccess=if($oldExisting){([datetime]'2010-01-02T03:04:06Z').ToFileTimeUtc()}else{$headerAccess}
                    foreach($state in $states){
                        if($state -notmatch ',access=(\d+),'){throw '参照日時がありません'}
                        $access=[long]$Matches[1]
                        if($access -ne $initialAccess -and ($access -lt $caseStarted.ToFileTimeUtc() -or $access -gt $caseFinished.ToFileTimeUtc())){throw 'ディレクトリの参照日時が保持値・実行区間外です'}
                    }
                    $normalizedRows=@($rows | ForEach-Object {
                        if($_ -match '^directory-state=.*?,access=(\d+),'){
                            $_ -replace ',access=\d+,',',access=<VALID-ACCESS>,'
                        }else{$_}
                    })
                    if($NestedFile){
                        $initialWrite=($(if($oldExisting){[datetime]'2010-01-02T03:04:06Z'}else{$stamp})).ToFileTimeUtc()
                        foreach($state in $states){
                            if($state -notmatch ',write=(\d+)$'){throw 'ディレクトリ更新日時がありません'}
                            $write=[long]$Matches[1]
                            if($DirectoryLast -and !$oldExisting){
                                if($write -ne $stamp.ToFileTimeUtc()){throw '後置ディレクトリの更新日時が復元されていません'}
                            }elseif($variant -ne 'header-cut21' -and $write -eq $initialWrite){throw '子ファイル処理後にディレクトリの更新日時が古い値へ戻っています'}
                            if($write -ne $initialWrite -and ($write -lt $caseStarted.ToFileTimeUtc() -or $write -gt $caseFinished.ToFileTimeUtc())){throw 'ディレクトリ更新日時が実行区間外です'}
                        }
                        $normalizedRows=@($normalizedRows | ForEach-Object {
                            if($_ -match '^directory-state='){
                                if($_ -match ',write=(\d+)$' -and [long]$Matches[1] -ne $initialWrite){$_ -replace ',write=\d+$',',write=<TOUCHED>'}else{$_}
                            }elseif($_ -match ',directory-write=(\d+)'){
                                $write=[long]$Matches[1]
                                if($write -eq $initialWrite -or ($DirectoryLast -and $existing -and $write -eq ([datetime]'2010-01-02T03:04:06Z').ToFileTimeUtc())){$_}else{
                                    if($write -lt $caseStarted.ToFileTimeUtc() -or $write -gt $caseFinished.ToFileTimeUtc()){throw '進捗中のディレクトリ更新日時が実行区間外です'}
                                    $_ -replace ',directory-write=\d+',',directory-write=<TOUCHED>'
                                }
                            }else{$_}
                        })
                    }
                    if($DirectoryLast -and !$existing){
                        $normalizedRows=@($normalizedRows | ForEach-Object {
                            if($_ -match ',directory-create=(\d+)' -and [long]$Matches[1] -ne $stamp.ToFileTimeUtc()){
                                $create=[long]$Matches[1]
                                if($create -lt $caseStarted.ToFileTimeUtc() -or $create -gt $caseFinished.ToFileTimeUtc()){throw '先行作成された親の作成日時が実行区間外です'}
                                $_ -replace ',directory-create=\d+',',directory-create=<CREATED>'
                            }else{$_}
                        })
                    }
                    $effects=@(Get-ChildItem -LiteralPath $root -Recurse -File -Force | Where-Object DirectoryName -ne $root | Sort-Object FullName | ForEach-Object {
                        "file=$([IO.Path]::GetRelativePath($root,$_.FullName).Replace('\','/')),size=$($_.Length),sha256=$((Get-FileHash -LiteralPath $_.FullName).Hash),attributes=$([int]$_.Attributes),write=$($_.LastWriteTimeUtc.Ticks)"
                    })
                    if(@(Get-ChildItem -LiteralPath $next -File).Count -ne 3){throw '後続の正常展開が 3 ファイルではありません'}
                    [IO.File]::WriteAllLines((Join-Path $root 'effects.txt'),[string[]]$effects)
                    $snapshots+=,@((@($normalizedRows)+$effects) | ForEach-Object {$_.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>')})
                }
                $difference=@(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
                if($difference.Count){$difference | Export-Csv -LiteralPath (Join-Path $workspace "$label-diff.tsv") -Delimiter "`t" -NoTypeInformation}
                $observations.Add([pscustomobject]@{Case=$observations.Count;Label=$label;Differences=$difference.Count})
            }}}
        }
        $observations | Export-Csv -LiteralPath (Join-Path $workspace 'observations.tsv') -Delimiter "`t" -NoTypeInformation
        Write-Host "directory=$name, attributes=$attributes, $variant comparisons=$($observations.Count)"
    }
    $fixtureIndex++
}}
foreach($path in $hashes.Keys){if((Get-FileHash -LiteralPath $path).Hash -cne $hashes[$path] -or [IO.File]::GetLastWriteTimeUtc($path) -ne $stamps[$path]){throw "入力・バイナリーが変更されました: $path"}}
if(!$expected -or $observations.Count -ne $expected){throw '比較数が不足しています'}
$failures=@($observations | Where-Object Differences -ne 0)
if($failures.Count){$failures | Format-Table -AutoSize | Out-String -Width 200 | Write-Host; throw 'ディレクトリ処理・中断後の状態が一致しません'}
Write-Host "Directory extraction state: $($observations.Count) comparisons, exact metadata API values, bounded access times and release/continuation guards passed"
