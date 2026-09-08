[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [ValidateSet('legacy','A','W')][string[]]$Apis=@('legacy','A','W'),
    [ValidateSet('none','a32','w32','a64','w64')][string[]]$Layouts=@('none','a32','w32','a64','w64'),
    [ValidateSet(3,932,65001,1252)][int[]]$CodePages=@(3,932,65001,1252),
    [ValidateSet(0,1,2)][int[]]$HeaderLevels=@(0,1,2),
    [ValidateSet(0,1)][int[]]$UnicodeModes=@(0,1),
    [ValidateSet(0,64)][int]$InputBytes=64,
    [ValidateSet('日本語.txt','Ā.txt','日本語/source.txt','Ā/source.txt','日本語/Ā.txt','Ā/日本語.txt')]
    [string]$MemberName='日本語.txt',
    [ValidateSet(1033,1041)][int]$Locale=1041,
    [string]$ArchiveFileName='日本語書庫.lzh',
    [switch]$UseSourceWildcard
)
$ErrorActionPreference='Stop'
$TestProgram=(Resolve-Path -LiteralPath $TestProgram).Path
$Oracle=(Resolve-Path -LiteralPath $Oracle).Path
$Candidate=(Resolve-Path -LiteralPath $Candidate).Path
$root=[IO.Path]::GetFullPath($Workspace)
if(Test-Path -LiteralPath $root){throw 'Fresh workspace required'}
if([string]::IsNullOrWhiteSpace($ArchiveFileName) -or
   [IO.Path]::GetFileName($ArchiveFileName) -cne $ArchiveFileName){throw 'ArchiveFileName must be a file name'}
if($UseSourceWildcard -and $MemberName.Contains('/')){throw 'UseSourceWildcard requires a leaf member name'}
New-Item -ItemType Directory -Path $root | Out-Null
$runner=Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe'
$binaryHashes=@{}
foreach($path in $TestProgram,$runner,$Oracle,$Candidate){$binaryHashes[$path]=(Get-FileHash -LiteralPath $path).Hash}
$expectedTime=[datetime]'2030-01-02T03:04:06Z'
$expectedFileTime=$expectedTime.ToFileTimeUtc()
function New-CompressionSource([string]$Path){
    [IO.File]::WriteAllText($Path,('A'*$InputBytes),[Text.UTF8Encoding]::new($false))
    [IO.File]::SetCreationTimeUtc($Path,$expectedTime)
    [IO.File]::SetLastWriteTimeUtc($Path,$expectedTime)
    [IO.File]::SetLastAccessTimeUtc($Path,$expectedTime)
}
function Get-HeaderCrc([byte[]]$Bytes,[int]$Length){
    $crc=0
    for($index=0;$index -lt $Length;$index++){
        $crc=$crc -bxor $Bytes[$index]
        for($bit=0;$bit -lt 8;$bit++){$crc=if($crc -band 1){($crc -shr 1) -bxor 0xa001}else{$crc -shr 1}}
    }
    return $crc
}
function Get-ComparableArchive([string]$Path,[int]$Level,[int]$CodePage,[long]$AccessTime){
    $bytes=[IO.File]::ReadAllBytes($Path)
    if($bytes.Length -lt 26+$InputBytes -or $bytes[20] -ne $Level -or
       [Text.Encoding]::ASCII.GetString($bytes,2,5) -cne '-lh0-' -or
       [BitConverter]::ToUInt32($bytes,11) -ne $InputBytes){throw "Invalid compression header $Path"}
    $headerLength=if($Level -eq 2){[BitConverter]::ToUInt16($bytes,0)}else{[int]$bytes[0]+2}
    $end=$headerLength+[BitConverter]::ToUInt32($bytes,7)
    if($end -ne $bytes.Length-1 -or $bytes[$end] -ne 0){throw "Unexpected member count or extent $Path"}
    for($index=$end-$InputBytes;$index -lt $end;$index++){if($bytes[$index] -ne 65){throw "Payload changed $Path"}}
    $crcOffset=if($Level -eq 2){21}else{22+[int]$bytes[21]}
    $expectedCrc=if($InputBytes){52106}else{0}
    if([BitConverter]::ToUInt16($bytes,$crcOffset) -ne $expectedCrc){throw "Payload CRC changed $Path"}
    if($Level -lt 2){
        $sum=0;for($index=2;$index -lt $headerLength;$index++){$sum=($sum+$bytes[$index]) -band 255}
        if($sum -ne $bytes[1]){throw "Header checksum mismatch $Path"}
    }else{
        $position=24;$timeOffset=-1;$headerCrcOffset=-1;$storedCodePage=-1
        while($position -lt $headerLength-2){
            $length=[BitConverter]::ToUInt16($bytes,$position)
            if($length -lt 3 -or $position+$length -gt $headerLength-2){throw "Invalid extension $Path"}
            switch($bytes[$position+2]){
                0 {if($headerCrcOffset -ge 0 -or $length -ne 6){throw 'Invalid common header'};$headerCrcOffset=$position+3}
                0x41 {if($timeOffset -ge 0 -or $length -ne 27){throw 'Invalid timestamp extension'};$timeOffset=$position+3}
                0x46 {if($storedCodePage -ge 0 -or $length -ne 7){throw 'Invalid code-page extension'};$storedCodePage=[BitConverter]::ToUInt32($bytes,$position+3)}
            }
            $position+=$length
        }
        $expectedCodePage=if($CodePage -eq 3){932}else{$CodePage}
        if($position -ne $headerLength-2 -or [BitConverter]::ToUInt16($bytes,$position) -ne 0 -or
           $timeOffset -lt 0 -or $headerCrcOffset -lt 0 -or $storedCodePage -ne $expectedCodePage){throw "Missing or incorrect metadata $Path"}
        if([BitConverter]::ToInt64($bytes,$timeOffset) -ne $expectedFileTime -or
           [BitConverter]::ToInt64($bytes,$timeOffset+8) -ne $expectedFileTime -or
           [BitConverter]::ToInt64($bytes,$timeOffset+16) -ne $AccessTime){throw "Stored file times differ from source $Path"}
        $storedCrc=[BitConverter]::ToUInt16($bytes,$headerCrcOffset)
        $bytes[$headerCrcOffset]=$bytes[$headerCrcOffset+1]=0
        if((Get-HeaderCrc $bytes $headerLength) -ne $storedCrc){throw "Header CRC mismatch $Path"}
        # 各実行の実ファイル日時との一致と実 CRC を先に検証し、実行ごとに異なる時刻だけを正規化する。
        [BitConverter]::GetBytes($expectedFileTime).CopyTo($bytes,$timeOffset+16)
    }
    return [Convert]::ToBase64String($bytes)
}
$warmupSource=Join-Path $root 'warmup.txt'
New-CompressionSource $warmupSource
$warmup=Join-Path $root 'warmup.lzh'
$seedRows=@(& $runner --timeout-seconds 30 $TestProgram --registry '' --command-probe $Oracle ('a -gm1 -y1 -jm0 -h2 "'+$warmup+'" "'+$warmupSource+'"'))
if($LASTEXITCODE -ne 0 -or $seedRows -notcontains 'result=0'){throw 'Cannot create warmup archive'}
$warmupHash=(Get-FileHash -LiteralPath $warmup).Hash
$count=0
Write-Host "Compression code-page workspace: $root"
foreach($utf8 in $UnicodeModes){foreach($api in $Apis){foreach($cp in $CodePages){foreach($level in $HeaderLevels){foreach($layout in $Layouts){
    $logs=@{};$archives=@{}
    foreach($side in 'oracle','reimpl'){
        $folder=Join-Path $root "$utf8-$api-$cp-h$level-$layout-$side"
        New-Item -ItemType Directory -Path $folder | Out-Null
        $sourceRoot=if($UseSourceWildcard){Join-Path $folder 'source'}else{$folder}
        $source=Join-Path $sourceRoot $MemberName
        if($UseSourceWildcard -or $MemberName.Contains('/')){New-Item -ItemType Directory -Path (Split-Path -Parent $source) | Out-Null}
        New-CompressionSource $source
        if([IO.File]::GetLastAccessTimeUtc($source).ToFileTimeUtc() -ne $expectedFileTime){throw 'Source timestamp not initialized'}
        $archive=Join-Path $folder $ArchiveFileName
        $command='a -gm1 -y1 -n1 -jm0 -h'+$level+' "'+$archive+'" "'+$source+'"'
        if($UseSourceWildcard){
            # 英語ロケールの ANSI 命令では、日本語のフルパスを引数にせず、
            # システム ACP の列挙結果を圧縮コアへ渡す。
            $command='a -gm1 -y1 -n1 -jm0 -h'+$level+' "'+$archive+'" "'+$sourceRoot+'\" *'
        }elseif($MemberName.Contains('/')){
            $command='a -gm1 -y1 -n1 -jm0 -x1 -h'+$level+' "'+$archive+'" "'+$folder+'\" "'+$MemberName+'"'
        }
        $dll=if($side -eq 'oracle'){$Oracle}else{$Candidate}
        # 原版の未初期化列挙メタデータを比較せず、実際の読み取りで既知の状態から始める。
        $steps=@(('@set-cp:'+$cp),('@count:'+$warmup),('@audit-access:'+$source),$command)
        $commandStart=[datetime]::UtcNow.ToFileTimeUtc()
        $rows=@(& $runner --timeout-seconds 30 $TestProgram --registry '' --progress-sequence-probe $dll $layout $Locale $utf8 $api w32 @steps 2>&1 | ForEach-Object {"$_"} | Tee-Object -FilePath (Join-Path $folder 'command.log'))
        $commandEnd=[datetime]::UtcNow.ToFileTimeUtc()
        if($LASTEXITCODE -ne 0 -or @($rows | Where-Object {$_ -eq 'result=0'}).Count -ne 1 -or $rows -notcontains 'count=1'){throw "Compression probe failed $folder"}
        $audits=@(foreach($row in $rows){if($row -match ',source-access-audit=(\d+)(?:,|$)'){[long]$Matches[1]}})
        if($audits.Count -ne 1){throw "Missing independent BEGIN timestamp $folder"}
        $access=$audits[0]
        $refreshed=$access -ne $expectedFileTime
        if($refreshed -and ($access -lt $commandStart -or $access -gt $commandEnd)){throw "Refreshed timestamp outside execution interval $folder"}
        if([IO.File]::GetCreationTimeUtc($source).ToFileTimeUtc() -ne $expectedFileTime -or
           [IO.File]::GetLastWriteTimeUtc($source).ToFileTimeUtc() -ne $expectedFileTime -or
           [IO.File]::ReadAllText($source,[Text.Encoding]::UTF8) -cne ('A'*$InputBytes)){throw "Source changed $folder"}
        $progressTimes=0;$opened=$false;$directoryNotices=0
        $normalized=@(foreach($row in $rows){
            if($row -match '^progress\.entry=.*?,state=3,'){$opened=$true}
            if($row -match '^progress\.entry=.*?,state=5,'){
                if($opened){throw "Unexpected DIRECTORY after OPEN $folder"}
                $directoryNotices++
                # WINMES.TXT の検索通知と原版 RVA 0x213BD: OPEN 前の数値領域は未初期化。
                # 生ログを残し、候補のゼロ初期化を検査してから名前・通知順の比較へ分離する。
                if($side -eq 'reimpl' -and $row -notmatch ',file=0,compressed=0,write=0,attributes=0,crc=0,os=0,ratio=0,create=0,access=0,write-time=0,mode="",source='){
                    throw "DIRECTORY metadata not zero-initialized $folder"
                }
                $row=$row -replace ',file=.*?,mode="(?:\\.|[^"\\])*",source=',',metadata=undefined-before-open,source='
            }
            if($row -match '^progress\.entry=.*?,create=(\d+),access=(\d+),write-time=(\d+),'){
                if([long]$Matches[1] -eq $expectedFileTime){
                    if([long]$Matches[2] -ne $access -or [long]$Matches[3] -ne $expectedFileTime){throw "Progress file times differ from source $folder"}
                    $progressTimes++
                    $row=$row -replace ',access=\d+,',',access=<source-after-share-check>,'
                }
            }
            $row=$row -replace ',source-access-audit=\d+',',source-access-audit=<source-after-share-check>'
            $row.Replace($folder.Replace('\','/'),'<ROOT>').Replace($folder,'<ROOT>') -creplace 'LHT[0-9A-F]+\.tmp','LHT<ID>.tmp'
        })
        # DIRECTORY は入力検索の通知。単一の通常ファイルも OPEN 前に 1 件通知する。
        $expectedDirectory=1
        if($directoryNotices -ne $expectedDirectory){throw "Unexpected DIRECTORY count $folder"}
        if($progressTimes -ne 5){throw "Incomplete timestamp notifications $folder"}
        $expectedEnum=if($layout -eq 'none'){0}else{1}
        if(@($rows | Where-Object {$_ -match '^enum\.entry='}).Count -ne $expectedEnum){throw "Unexpected enum count $folder"}
        if(@(Get-ChildItem -LiteralPath $folder -Filter '*.tmp').Count){throw "Temporary archive remains $folder"}
        # 日時の絶対値だけでなく、BEGIN 前に参照日時が更新されたかも比較する。
        $logs[$side]=@("source.access-refreshed=$refreshed")+$normalized
        $archives[$side]=Get-ComparableArchive $archive $level $cp $access
    }
    $diff=@(Compare-Object $logs.oracle $logs.reimpl -SyncWindow 0)
    if($diff.Count -or $archives.oracle -cne $archives.reimpl){$diff | Format-List;throw "Compression code-page mismatch $utf8/$api/$cp/h$level/$layout"}
    $count++
}};Write-Host "Compression code pages: unicode=$utf8 api=$api cp=$cp passed, $count pairs"}}}
foreach($path in $binaryHashes.Keys){if((Get-FileHash -LiteralPath $path).Hash -cne $binaryHashes[$path]){throw 'Binary changed during test'}}
if((Get-FileHash -LiteralPath $warmup).Hash -cne $warmupHash){throw 'Warmup archive changed'}
$expectedCount=$UnicodeModes.Count*$Apis.Count*$CodePages.Count*$HeaderLevels.Count*$Layouts.Count
if($count -ne $expectedCount){throw 'Incomplete compression code-page comparisons'}
Write-Host "Compression code pages: $count output/defined-notification/archive comparisons with independent source times, header checksums/CRC, payload, code-page and zero-initialized DIRECTORY checks passed"
