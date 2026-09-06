param(
 [Parameter(Mandatory)][string]$TestProgram,
 [Parameter(Mandatory)][string]$Oracle,
 [Parameter(Mandatory)][string]$Candidate,
 [Parameter(Mandatory)][string]$Workspace
)
$ErrorActionPreference='Stop'
$TestProgram=(Resolve-Path -LiteralPath $TestProgram).Path
$Oracle=(Resolve-Path -LiteralPath $Oracle).Path
$Candidate=(Resolve-Path -LiteralPath $Candidate).Path
$root=[IO.Path]::GetFullPath($Workspace)
if(Test-Path -LiteralPath $root){throw 'Fresh workspace required'}
New-Item -ItemType Directory -Path (Join-Path $root 'input') | Out-Null
$runner=Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe'
$hashes=@{}
foreach($path in $TestProgram,$runner,$Oracle,$Candidate){$hashes[$path]=(Get-FileHash -LiteralPath $path).Hash}
$inputFile=Join-Path $root 'input/日本語.txt'
[IO.File]::WriteAllText($inputFile,('A'*64),[Text.UTF8Encoding]::new($false))
$file=Get-Item -LiteralPath $inputFile
$file.CreationTimeUtc=$file.LastWriteTimeUtc=$file.LastAccessTimeUtc=[datetime]'2024-01-02T03:04:06Z'
$seed=Join-Path $root 'japanese.lzh'
$rows=@(& $runner --timeout-seconds 30 $TestProgram --registry '' --command-probe $Oracle ('a -gm1 -y1 -jm0 -h2 "'+$seed+'" "'+$inputFile+'"'))
if($LASTEXITCODE -ne 0 -or $rows -notcontains 'result=0'){throw 'Japanese seed creation failed'}
$unicodeSeed=Join-Path $root 'unicode.lzh'
Copy-Item -LiteralPath $seed -Destination $unicodeSeed
$rows=@(& $runner --timeout-seconds 30 $TestProgram --registry '' --command-probe $Oracle ('n -gm1 -y1 -n0 "'+$unicodeSeed+'" * -gr'+[char]0x100+'.txt'))
if($LASTEXITCODE -ne 0 -or $rows -notcontains 'result=0'){throw 'Unicode seed creation failed'}
foreach($path in $seed,$unicodeSeed){$hashes[$path]=(Get-FileHash -LiteralPath $path).Hash}
$count=0
foreach($api in 'legacy','A','W'){foreach($profile in 'japanese','unicode'){
 $sourceSeed=if($profile -eq 'unicode'){$unicodeSeed}else{$seed}
 $pages=if($profile -eq 'unicode'){@(932,65001,1252)}else{@(65001,1252)}
 foreach($cp in $pages){foreach($kind in 'j-new','j-old','n','y'){
  $logs=@{}; $archives=@{}
  foreach($side in 'oracle','reimpl'){
   $folder=Join-Path $root "$api-$profile-$cp-$kind-$side"
   New-Item -ItemType Directory -Path $folder | Out-Null
   $source=Join-Path $folder 'source.lzh'
   $destination=if($kind.StartsWith('j')){Join-Path $folder 'joined.lzh'}else{$source}
   Copy-Item -LiteralPath $sourceSeed -Destination $source
   if($kind -eq 'j-old'){Copy-Item -LiteralPath $sourceSeed -Destination $destination}
   $line=$kind.Substring(0,1)+' -gm1 -y1 -n0 "'+$destination+'" '
   if($kind.StartsWith('j')){$line+='"'+$source+'"'}else{$line+='*'}
   if($kind -eq 'n'){$line+=' -gr日本語.txt'}
   $dll=if($side -eq 'oracle'){$Oracle}else{$Candidate}
   $rows=@(& $runner --timeout-seconds 30 $TestProgram --registry '' --progress-sequence-probe $dll none 1041 0 $api w64 ('@set-cp:'+$cp) $line 2>&1 | ForEach-Object {"$_"} | Tee-Object -FilePath (Join-Path $folder 'command.log'))
   if($LASTEXITCODE -ne 0 -or $rows -notcontains 'code-page.set=1' -or $rows -notcontains 'result=0'){throw "Code page rewrite failed $folder"}
   if($kind.StartsWith('j') -and (Get-FileHash -LiteralPath $source).Hash -cne $hashes[$sourceSeed]){throw "Join source changed $folder"}
   if(@(Get-ChildItem -LiteralPath $folder -Filter '*.tmp').Count){throw "Temporary archive remains $folder"}
   $logs[$side]=@($rows | ForEach-Object {$_.Replace($folder.Replace('\','/'),'<ROOT>').Replace($folder,'<ROOT>')})
   $archives[$side]=(Get-FileHash -LiteralPath $destination).Hash
   # 原版同士の比較だけでなく、既存連結先と新規出力の CP を個別に検査する。
   $bytes=[IO.File]::ReadAllBytes($destination); $position=0; $member=0
   while($position -lt $bytes.Length-1){
    $headerLength=[BitConverter]::ToUInt16($bytes,$position)
    if($bytes[$position+20] -ne 2 -or $headerLength -lt 26 -or $position+$headerLength -ge $bytes.Length){throw 'Invalid rewritten header'}
    $extension=$position+24; $actualPage=$null
    while($extension+2 -le $position+$headerLength){
     $length=[BitConverter]::ToUInt16($bytes,$extension)
     if(!$length){break}
     if($length -lt 3 -or $extension+$length -gt $position+$headerLength){throw 'Invalid rewritten extension'}
     if($bytes[$extension+2] -eq 0x46){if($length -ne 7){throw 'Invalid code page field'}; $actualPage=[BitConverter]::ToUInt32($bytes,$extension+3)}
     $extension+=$length
    }
    $expectedPage=if($kind -eq 'j-old' -and $member -eq 0){932}else{$cp}
    if($actualPage -ne $expectedPage -or [BitConverter]::ToUInt32($bytes,$position+7) -ne 64 -or [BitConverter]::ToUInt32($bytes,$position+11) -ne 64){throw 'Unexpected member code page or body size'}
    $position+=$headerLength+64; $member++
   }
   if($position -ne $bytes.Length-1 -or $bytes[$position] -ne 0 -or $member -ne $(if($kind -eq 'j-old'){2}else{1})){throw 'Unexpected archive terminator or member count'}
  }
  if($archives.oracle -cne $archives.reimpl -or @(Compare-Object $logs.oracle $logs.reimpl -SyncWindow 0).Count){throw "Code page mismatch $api/$profile/$cp/$kind"}
  $count++
 }}
 Write-Host "Rewrite code pages: $api/$profile passed, $count pairs"
}}
foreach($path in $hashes.Keys){if((Get-FileHash -LiteralPath $path).Hash -cne $hashes[$path]){throw 'Binary or seed changed during code page test'}}
if($count -ne 60){throw 'Incomplete code page test'}
Write-Host 'Rewrite code pages: 60 output/archive comparisons and per-member CP checks passed'
