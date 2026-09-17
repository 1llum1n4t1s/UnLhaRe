[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [ValidateSet('a32','a64','w32','w64')][string[]]$Layouts=@('a32','a64','w32','w64'),
    [ValidateRange(0,16777216)][int]$InputBytes=64,
    [ValidateSet(0,1,5)][int]$Method=0,
    [ValidateSet('*','nested.txt','other.txt')][string]$Pattern='*',
    [ValidateRange(-1,16777216)][int]$SecondInputBytes=-1,
    [switch]$NormalOnly,
    [switch]$UnicodeArchive,
    [switch]$RenameMember
)
$ErrorActionPreference='Stop'
if($RenameMember -and $Pattern -eq '*'){throw '項目名変更の試験では対象メンバーを一つ選択してください。'}
[Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
$memberEncoding=[Text.Encoding]::GetEncoding(932)
$replacement=if($RenameMember){'@file:変更後.txt'}else{'callback/new.txt'}
$TestProgram=(Resolve-Path -LiteralPath $TestProgram).Path
$Oracle=(Resolve-Path -LiteralPath $Oracle).Path
$Candidate=(Resolve-Path -LiteralPath $Candidate).Path
$Workspace=[IO.Path]::GetFullPath($Workspace)
$runner=Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe'
if(Test-Path -LiteralPath $Workspace){throw '進捗試験には新しい作業先が必要です。'}
New-Item -ItemType Directory -Path (Join-Path $Workspace 'input/folder') | Out-Null
$hashes=@{}
foreach($path in $TestProgram,$Oracle,$Candidate,$runner){$hashes[$path]=(Get-FileHash -LiteralPath $path).Hash}
foreach($name in 'folder/nested.txt','other.txt'){
    $path=Join-Path $Workspace "input/$name"
    $body=if($name -eq 'other.txt' -and $SecondInputBytes -ge 0){'B'*$SecondInputBytes}else{'A'*$InputBytes}
    [IO.File]::WriteAllText($path,$body,[Text.UTF8Encoding]::new($false))
    $file=Get-Item -LiteralPath $path
    $file.CreationTimeUtc=$file.LastWriteTimeUtc=$file.LastAccessTimeUtc=[datetime]'2024-01-02T03:04:06Z'
}
$seed=Join-Path $Workspace 'seed.lzh'
$line='a -gm1 -y1 -jm'+$Method+' -h2 -x1 "'+$seed+'" "'+(Join-Path $Workspace 'input/')+'" folder/nested.txt other.txt'
$rows=@(& $runner --timeout-seconds 30 $TestProgram --registry '' --command-probe $Oracle $line)
if($LASTEXITCODE -ne 0 -or $rows -notcontains 'result=0'){throw '原版の試験書庫作成に失敗しました。'}
$seedHash=(Get-FileHash -LiteralPath $seed).Hash
$seedBytes=[IO.File]::ReadAllBytes($seed)
$selectedPacked=@()
$offset=0
foreach($leaf in 'nested.txt','other.txt'){
    $headerSize=[BitConverter]::ToUInt16($seedBytes,$offset)
    if($seedBytes[$offset+20] -ne 2 -or ![Text.Encoding]::ASCII.GetString($seedBytes,$offset,$headerSize).Contains($leaf)){
        throw '種書庫のメンバー順またはヘッダーが想定と異なります。'
    }
    $packed=[BitConverter]::ToUInt32($seedBytes,$offset+7)
    if($Pattern -eq '*' -or $Pattern -eq $leaf){$selectedPacked+=$packed}
    $offset+=$headerSize+$packed
}
if($offset -ne $seedBytes.Length-1 -or $seedBytes[$offset] -ne 0){throw '種書庫の終端が不正です。'}
$hasMemberProgress=@($selectedPacked | Where-Object {($_ -gt 0 -and $_ -lt 100) -or $_ -gt 262144}).Count -gt 0
$originalRetryCount=0
function Test-OriginalMoveAccessDenied([string]$Root) {
    $texts = @(Get-ChildItem -LiteralPath $Root -Recurse -Filter '*.log' -File -ErrorAction SilentlyContinue |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue })
    $text = $texts -join "`n"
    return $text -match 'result=32792' -and $text -match 'compat-system-error=5' -and
        $text -match 'on execute_cmd \(MoveFile\)'
}
$cases=@()
foreach($mode in 0,1,2){foreach($selected in 0,1){$cases+=@{Mode=$mode;Selected=$selected;Abort=-1}}}
if(!$NormalOnly){
    foreach($state in 0,1,3){$cases+=@{Mode=1;Selected=1;Abort=$state}}
}
$pairs=0
$cancellations=0
foreach($layout in $Layouts){
    $api=if(!$UnicodeArchive -and $layout.StartsWith('a')){'A'}else{'W'}
    foreach($command in 'n','y'){
        foreach($case in $cases){
            $logs=@{}; $archives=@{}
            foreach($side in 'oracle','reimpl'){
                $completed=$false
                for($attempt=0;$attempt -lt 6 -and !$completed;$attempt++){
                    # 再試行先も元の layout-command-* と同じパス長にし、通知のパスを比較可能に保つ。
                    $folder=if($attempt -eq 0){Join-Path $Workspace "$layout-$command-n$($case.Mode)-s$($case.Selected)-b$($case.Abort)-$side"}
                        else {Join-Path $Workspace "try$attempt-$layout-$command-n$($case.Mode)-s$($case.Selected)-b$($case.Abort)-$side"}
                    try {
                New-Item -ItemType Directory -Path $folder | Out-Null
                $archive=Join-Path $folder $(if($UnicodeArchive){'source-'+[char]0x100+'.lzh'}else{'source.lzh'})
                Copy-Item -LiteralPath $seed -Destination $archive
                $line="$command -gm1 -y1 -n$($case.Mode) `"$archive`" $Pattern"
                if($command -eq 'n'){$line+=' -grrenamed.txt'}
                $dll=if($side -eq 'oracle'){$Oracle}else{$Candidate}
                $rows=@(& $runner --timeout-seconds 30 $TestProgram --registry '' --command-enum-probe $dll $line $layout $case.Selected $replacement 1041 0 $api 1 $case.Abort 2>&1 | ForEach-Object {"$_"} | Tee-Object -FilePath (Join-Path $folder 'command.log'))
                $expected=if($case.Abort -ge 0){32800}else{0}
                # y の中間通知がないサイズでは、最初の INPROCESS は拒否を無視する COPY 段階。
                if($command -eq 'y' -and $case.Abort -eq 1 -and !$hasMemberProgress){$expected=0}
                if($LASTEXITCODE -ne 0 -or $rows -notcontains "result=$expected"){throw "進捗呼び出し失敗: $folder"}
                # 作業先と一時名の可変番号だけを置換する。通知値・順序・出力長は維持する。
                $logs[$side]=@($rows | ForEach-Object {$_.Replace($folder.Replace('\','/'),'<ROOT>').Replace($folder,'<ROOT>') -creplace 'LHT[0-9A-F]+\.tmp','LHT<ID>.tmp'})
                if(!(Test-Path -LiteralPath $archive)){throw "書庫が消失しました: $folder"}
                $archives[$side]=(Get-FileHash -LiteralPath $archive).Hash
                if($expected -eq 32800 -and $archives[$side] -cne $seedHash){throw "中断で元書庫が変わりました: $folder"}
                if($RenameMember -and $expected -eq 0 -and $case.Selected){
                    # DLL 同士の一致だけでなく、実際の名前拡張が変わったことを独立に確認する。
                    $bytes=[IO.File]::ReadAllBytes($archive)
                    $memberNames=@(); $position=0
                    while($position -lt $bytes.Length-1){
                        $headerLength=[BitConverter]::ToUInt16($bytes,$position)
                        if($bytes[$position+20] -ne 2 -or $headerLength -lt 26 -or $position+$headerLength -ge $bytes.Length){throw '変更後のヘッダーが不正です。'}
                        $extension=$position+24
                        while($extension+2 -le $position+$headerLength){
                            $length=[BitConverter]::ToUInt16($bytes,$extension)
                            if(!$length){break}
                            if($length -lt 3 -or $extension+$length -gt $position+$headerLength){throw '名前拡張の範囲が不正です。'}
                            if($bytes[$extension+2] -eq 1){$memberNames+=$memberEncoding.GetString($bytes,$extension+3,$length-3)}
                            $extension+=$length
                        }
                        $position+=$headerLength+[BitConverter]::ToUInt32($bytes,$position+7)
                    }
                    if($position -ne $bytes.Length-1 -or $bytes[$position] -ne 0 -or $memberNames.Count -ne 2 -or @($memberNames | Where-Object {$_ -ceq '変更後.txt'}).Count -ne 1){throw "項目名が実際に変更されていません: $folder"}
                }
                if(@(Get-ChildItem -LiteralPath $folder -Filter '*.tmp').Count){throw "一時書庫が残っています: $folder"}
                $completed=$true
                    } catch {
                        if($side -eq 'oracle' -and $attempt -lt 5 -and (Test-OriginalMoveAccessDenied $folder)){
                            [IO.File]::WriteAllText((Join-Path $folder 'original-command-failure.txt'),$_.Exception.Message)
                            $originalRetryCount++
                            Write-Host "Rewrite progress: original MoveFile access denied; retrying in a fresh directory ($layout/$command/$($case.Mode)/$($case.Selected)/$($case.Abort)/$attempt)"
                            Start-Sleep -Milliseconds 100
                            continue
                        }
                        throw
                    }
                }
                if(!$completed){throw "進捗試験の原版取得を再試行できませんでした: $layout/$command/$($case.Mode)/$($case.Selected)/$($case.Abort)"}
            }
            if($archives.oracle -cne $archives.reimpl){throw "書庫内容不一致: $layout/$command/$($case.Mode)/$($case.Selected)/$($case.Abort)"}
            if(@(Compare-Object $logs.oracle $logs.reimpl -SyncWindow 0).Count){throw "通知・ログ不一致: $layout/$command/$($case.Mode)/$($case.Selected)/$($case.Abort)"}
            $pairs++
            if($expected -eq 32800){$cancellations++}
        }
    }
    Write-Host "Rewrite progress: $layout passed, $pairs pairs"
}
foreach($path in $hashes.Keys){if((Get-FileHash -LiteralPath $path).Hash -cne $hashes[$path]){throw '検証中にバイナリが変わりました。'}}
if((Get-FileHash -LiteralPath $seed).Hash -cne $seedHash -or $pairs -ne 2*$cases.Count*$Layouts.Count){throw '入力保持または検証件数が不正です。'}
Write-Host "Rewrite progress: $pairs notification/output/archive comparisons passed, including $cancellations cancellation preservation cases, $originalRetryCount original MoveFile retries; layouts=$($Layouts -join ','); member-rename=$RenameMember"
