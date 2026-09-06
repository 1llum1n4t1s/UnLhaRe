param(
 [Parameter(Mandatory)][string]$TestProgram,
 [Parameter(Mandatory)][string]$Oracle,
 [Parameter(Mandatory)][string]$Candidate,
 [Parameter(Mandatory)][string]$Workspace,
 [ValidateSet(3,932,65001)][int[]]$CodePages=@(3,932,65001),
 [ValidateSet(0,1)][int[]]$UnicodeModes=@(0,1),
 [ValidateSet('a32','a64','w32','w64')][string[]]$Layouts=@('a32','a64','w32','w64')
)
$ErrorActionPreference='Stop'
$TestProgram=(Resolve-Path -LiteralPath $TestProgram).Path
$Oracle=(Resolve-Path -LiteralPath $Oracle).Path
$Candidate=(Resolve-Path -LiteralPath $Candidate).Path
$root=[IO.Path]::GetFullPath($Workspace)
if(Test-Path -LiteralPath $root){throw 'Fresh workspace required'}
$inputRoot=Join-Path $root 'input'
New-Item -ItemType Directory -Path $inputRoot | Out-Null
$probe=$TestProgram
$runner=Join-Path (Split-Path -Parent $probe) 'DesktopRunner.exe'
$binaryHashes=@{}
foreach($path in $probe,$runner,$Oracle,$Candidate){$binaryHashes[$path]=(Get-FileHash -LiteralPath $path).Hash}
$inputFile=Join-Path $inputRoot '日本語.txt'
[IO.File]::WriteAllText($inputFile,('A'*64),[Text.UTF8Encoding]::new($false))
$file=Get-Item -LiteralPath $inputFile
$file.CreationTimeUtc=$file.LastWriteTimeUtc=$file.LastAccessTimeUtc=[datetime]'2024-01-02T03:04:06Z'
$seed=Join-Path $root 'seed.lzh'
$line='a -gm1 -y1 -jm0 -h2 "'+$seed+'" "'+$inputFile+'"'
$rows=@(& $runner --timeout-seconds 30 $probe --registry '' --command-probe $Oracle $line)
if($LASTEXITCODE -ne 0 -or $rows -notcontains 'result=0'){throw 'Settings seed creation failed'}
$seedHash=(Get-FileHash -LiteralPath $seed).Hash
$bytes=[IO.File]::ReadAllBytes($seed)
if($bytes[20] -ne 2 -or [BitConverter]::ToUInt32($bytes,7) -ne 64 -or [BitConverter]::ToUInt32($bytes,11) -ne 64 -or [BitConverter]::ToUInt16($bytes,0)+65 -ne $bytes.Length -or $bytes[-1] -ne 0){throw 'Settings seed layout is invalid'}
$States=@(-1,0,1,2,3)
$count=0
foreach($UnicodeMode in $UnicodeModes){foreach($Layout in $Layouts){
 foreach($cp in $CodePages){foreach($command in 'n','y'){foreach($state in $States){
 $pair=@{}
 foreach($side in 'oracle','reimpl'){
  $folder=Join-Path $root "$UnicodeMode-$Layout-$cp-$command-$state-$side"
  New-Item -ItemType Directory -Path $folder | Out-Null
  $source=Join-Path $folder ('source-'+[char]0x100+'.lzh')
  $plain=Join-Path $folder '日本語.lzh'
  Copy-Item -LiteralPath $seed -Destination $source
  Copy-Item -LiteralPath $seed -Destination $plain
  $plainHash=(Get-FileHash -LiteralPath $plain).Hash
  $line="$command -gm1 -y1 -n1 `"$source`" *"
  if($command -eq 'n'){$line+=' -grrenamed.txt'}
  $read="t -gm1 -n1 `"$plain`""
  $steps=@("@set-cp:$cp",'@cp-state',"@abort-state:$state",$line,'@cp-state','@abort-state:-1','@api:A',$read,'@cp-state','@api:legacy',$read,'@cp-state')
  $dll=if($side -eq 'oracle'){$Oracle}else{$Candidate}
  $rows=@(& $runner --timeout-seconds 30 $probe --registry '' --progress-sequence-probe $dll $Layout 1041 $UnicodeMode W $Layout @steps 2>&1 | ForEach-Object {"$_"} | Tee-Object -FilePath (Join-Path $folder 'command.log'))
  if($LASTEXITCODE -ne 0){throw "Probe failed $folder"}
  $results=@($rows | Where-Object {$_ -match '^result='})
  $expected=if($state -in -1,2){'result=0'}else{'result=32800'}
  if($results.Count -ne 3 -or $results[0] -cne $expected -or $results[1] -cne 'result=0' -or $results[2] -cne 'result=0'){throw "Unexpected command state $folder"}
  $pages=@($rows | Where-Object {$_ -match '^code-page='})
  if($rows -notcontains 'code-page.set=1' -or $pages.Count -ne 4 -or @($pages | Where-Object {$_ -cne "code-page=$cp"}).Count){throw "Code page changed $folder"}
  if((Get-FileHash -LiteralPath $plain).Hash -cne $plainHash){throw "Read-only archive changed $folder"}
  if($expected -eq 'result=32800' -and (Get-FileHash -LiteralPath $source).Hash -cne $plainHash){throw "Cancelled archive changed $folder"}
  if(@(Get-ChildItem -LiteralPath $folder -Filter '*.tmp').Count){throw "Temporary archive remains $folder"}
  $pair[$side]=@($rows | ForEach-Object {$_.Replace($folder.Replace('\','/'),'<ROOT>').Replace($folder,'<ROOT>') -creplace 'LHT[0-9A-F]+\.tmp','LHT<ID>.tmp'})
  $pair[$side]+='archive.hash='+(Get-FileHash -LiteralPath $source).Hash
 }
 $diff=@(Compare-Object $pair.oracle $pair.reimpl -SyncWindow 0)
 if($diff.Count){$diff | Format-List;throw "Mismatch $cp/$command/$state"}
 $count++
 }}}
 Write-Host "Rewrite settings: unicode-mode=$UnicodeMode layout=$Layout passed, $count sequences"
}}
foreach($path in $binaryHashes.Keys){if((Get-FileHash -LiteralPath $path).Hash -cne $binaryHashes[$path]){throw 'Binary changed during settings test'}}
if((Get-FileHash -LiteralPath $seed).Hash -cne $seedHash -or $count -ne $UnicodeModes.Count*$Layouts.Count*$CodePages.Count*2*$States.Count){throw 'Settings seed changed or coverage count is invalid'}
Write-Host "Rewrite settings: $count W/A/legacy notification/output/archive sequences passed; code-pages=$($CodePages -join ',')"
