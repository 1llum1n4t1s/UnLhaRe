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
New-Item -ItemType Directory -Path $root | Out-Null
$probe=$TestProgram
$runner=Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe'
$binaryHashes=@{}
foreach($path in $probe,$runner,$Oracle,$Candidate){$binaryHashes[$path]=(Get-FileHash -LiteralPath $path).Hash}
$times=@('2024-01-02T03:04:06.000Z','2024-01-02T03:04:06.001Z','2024-01-02T03:04:06.999Z',
 '2024-01-02T03:04:07.000Z','2024-01-02T03:04:07.001Z','2024-01-02T03:04:07.999Z',
 '2023-12-31T14:59:59.999Z','2024-02-28T14:59:59.999Z')
$count=0
foreach($index in 0..($times.Count-1)){
 $timestamp=$times[$index]
 $inputRoot=Join-Path $root "input-$index"
 New-Item -ItemType Directory -Path $inputRoot | Out-Null
 $inputFile=Join-Path $inputRoot '日本語.txt'
 [IO.File]::WriteAllText($inputFile,('A'*64),[Text.UTF8Encoding]::new($false))
 $file=Get-Item -LiteralPath $inputFile
 $file.CreationTimeUtc=$file.LastWriteTimeUtc=$file.LastAccessTimeUtc=[DateTimeOffset]::Parse($timestamp).UtcDateTime
 $seed=Join-Path $inputRoot 'seed.lzh'
 $rows=@(& $runner --timeout-seconds 30 $probe --registry '' --command-probe $oracle ('a -gm1 -y1 -jm0 -h2 "'+$seed+'" "'+$inputFile+'"'))
 if($LASTEXITCODE -ne 0 -or $rows -notcontains 'result=0'){throw "Seed failed $timestamp"}
 $seedHash=(Get-FileHash -LiteralPath $seed).Hash
 foreach($api in 'legacy','A','W'){foreach($level in 0,1,2){
  $logs=@{}; $hashes=@{}; $stamps=@{}
  foreach($side in 'oracle','reimpl'){
   $folder=Join-Path $root "$index-$api-h$level-$side"
   New-Item -ItemType Directory -Path $folder | Out-Null
   $archive=Join-Path $folder 'source.lzh'
   Copy-Item -LiteralPath $seed -Destination $archive
   $dll=if($side -eq 'oracle'){$Oracle}else{$Candidate}
   $line='y -gm1 -y1 -n1 -h'+$level+' "'+$archive+'" *'
   $rows=@(& $runner --timeout-seconds 30 $probe --registry '' --command-enum-probe $dll $line none 1 '' 1041 0 $api 1 2>&1 | ForEach-Object {"$_"} | Tee-Object -FilePath (Join-Path $folder 'command.log'))
   if($LASTEXITCODE -ne 0 -or $rows -notcontains 'result=0'){throw "Rewrite failed $folder"}
   $logs[$side]=@($rows | ForEach-Object {$_.Replace($folder.Replace('\','/'),'<ROOT>').Replace($folder,'<ROOT>') -creplace 'LHT[0-9A-F]+\.tmp','LHT<ID>.tmp'})
   $bytes=[IO.File]::ReadAllBytes($archive)
   if($bytes[20] -ne $level){throw 'Wrong output header level'}
   $time=[DateTimeOffset]::Parse($timestamp)
   $expectedStamp=if($level -eq 2){[uint32]$time.ToUnixTimeSeconds()}else{
    # 小数秒を落とした整数秒を 2 秒単位へ切り上げる。年・日付の繰り上がりも含む。
    $utc=$time.UtcDateTime.AddTicks(-($time.UtcTicks % [TimeSpan]::TicksPerSecond))
    if($utc.Second -band 1){$utc=$utc.AddSeconds(1)}
    $local=$utc.ToLocalTime()
    [uint32]((($local.Year-1980) -shl 25) -bor ($local.Month -shl 21) -bor ($local.Day -shl 16) -bor ($local.Hour -shl 11) -bor ($local.Minute -shl 5) -bor ($local.Second -shr 1))
   }
   if([BitConverter]::ToUInt32($bytes,15) -ne $expectedStamp){throw "Incorrect stored timestamp $folder"}
   if(@(Get-ChildItem -LiteralPath $folder -Filter '*.tmp').Count){throw "Temporary archive remains $folder"}
   $hashes[$side]=(Get-FileHash -LiteralPath $archive).Hash
   $stamps[$side]=[BitConverter]::ToUInt32($bytes,15).ToString('X8')
  }
  $diff=@(Compare-Object $logs.oracle $logs.reimpl -SyncWindow 0)
  if($diff.Count -or $hashes.oracle -cne $hashes.reimpl){$diff | Format-List;throw "Timestamp mismatch $index/$api/h$level"}
  $count++
 }}
 if((Get-FileHash -LiteralPath $seed).Hash -cne $seedHash){throw 'Timestamp seed changed'}
 Write-Host "Rewrite times: $timestamp passed, $count pairs"
}
foreach($path in $binaryHashes.Keys){if((Get-FileHash -LiteralPath $path).Hash -cne $binaryHashes[$path]){throw 'Binary changed during timestamp test'}}
if($count -ne 72){throw 'Incomplete timestamp test'}
Write-Host 'Rewrite times: 72 notification/output/archive comparisons and independent timestamp checks passed'
