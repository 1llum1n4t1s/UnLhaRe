param(
 [Parameter(Mandatory)][string]$TestProgram,
 [Parameter(Mandatory)][string]$Oracle,
 [Parameter(Mandatory)][string]$Candidate,
 [Parameter(Mandatory)][string]$FixturesRoot,
 [Parameter(Mandatory)][string]$Workspace,
 [ValidateSet('seed-l0.lzh','seed-l1.lzh','seed-l2.lzh','unix-l1.lzh','unix-l2.lzh')]
 [string[]]$SeedNames=@('seed-l0.lzh','seed-l1.lzh','seed-l2.lzh','unix-l1.lzh','unix-l2.lzh')
)
$ErrorActionPreference='Stop'
$TestProgram=(Resolve-Path -LiteralPath $TestProgram).Path
$Oracle=(Resolve-Path -LiteralPath $Oracle).Path
$Candidate=(Resolve-Path -LiteralPath $Candidate).Path
$FixturesRoot=(Resolve-Path -LiteralPath $FixturesRoot).Path
$root=[IO.Path]::GetFullPath($Workspace)
if(Test-Path -LiteralPath $root){throw 'Fresh workspace required'}
New-Item -ItemType Directory -Path $root | Out-Null
$runner=Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe'
$hashes=@{}
$seeds=$SeedNames
$incoming=Join-Path $FixturesRoot 'seed-l2.lzh'
foreach($path in @($TestProgram,$runner,$Oracle,$Candidate,$incoming)+@($seeds | ForEach-Object {Join-Path $FixturesRoot $_})){
 $hashes[$path]=(Get-FileHash -LiteralPath $path).Hash
}
$count=0
foreach($name in $seeds){
 $seed=Join-Path $FixturesRoot $name
 $oldBytes=[IO.File]::ReadAllBytes($seed)
 if($oldBytes[-1] -ne 0){throw 'Old fixture has no terminator'}
 foreach($layout in 'none','a32','a64','w32','w64'){
  $selections=if($layout -eq 'none'){@(1)}else{@(0,1)}
  foreach($selected in $selections){
   $logs=@{}; $archives=@{}
   foreach($side in 'oracle','reimpl'){
    $folder=Join-Path $root "$name-$layout-$selected-$side"
    New-Item -ItemType Directory -Path $folder | Out-Null
    $archive=Join-Path $folder 'joined.lzh'
    $source=Join-Path $folder 'source.lzh'
    Copy-Item -LiteralPath $seed -Destination $archive
    Copy-Item -LiteralPath $incoming -Destination $source
    $line='j -gm1 -y1 -n0 "'+$archive+'" "'+$source+'"'
    $dll=if($side -eq 'oracle'){$Oracle}else{$Candidate}
    $rows=@(& $runner --timeout-seconds 30 $TestProgram --registry '' --command-enum-probe $dll $line $layout $selected '@file:変更後.txt' 1041 0 W 0 2>&1 | ForEach-Object {"$_"} | Tee-Object -FilePath (Join-Path $folder 'command.log'))
    $expectedEnum=if($layout -eq 'none'){0}else{1}
    if($LASTEXITCODE -ne 0 -or $rows -notcontains 'result=0' -or $rows -notcontains "enum.count=$expectedEnum"){throw "Join probe failed $folder"}
    $bytes=[IO.File]::ReadAllBytes($archive)
    if($selected){
     if($bytes.Length -le $oldBytes.Length){throw 'Joined archive is too short'}
     for($index=0;$index -lt $oldBytes.Length-1;$index++){if($bytes[$index] -ne $oldBytes[$index]){throw "Old header or body changed $folder at $index"}}
    }
    $position=0; $members=0
    while($position -lt $bytes.Length-1){
     if($position+24 -gt $bytes.Length -or $bytes[$position+20] -gt 2){throw 'Invalid member header'}
     $headerLength=if($bytes[$position+20] -eq 2){[BitConverter]::ToUInt16($bytes,$position)}else{[int]$bytes[$position]+2}
     $end=$position+$headerLength+[BitConverter]::ToUInt32($bytes,$position+7)
     if($end -ge $bytes.Length -or $end-64 -lt $position+$headerLength -or [BitConverter]::ToUInt32($bytes,$position+11) -ne 64){throw 'Invalid joined member range'}
     for($index=$end-64;$index -lt $end;$index++){if($bytes[$index] -ne 65){throw 'Joined payload changed'}}
     $position=$end; $members++
    }
    if($position -ne $bytes.Length-1 -or $bytes[$position] -ne 0 -or $members -ne 1+$selected){throw 'Unexpected joined member count or terminator'}
    if((Get-FileHash -LiteralPath $source).Hash -cne $hashes[$incoming]){throw 'Incoming archive changed'}
    if(@(Get-ChildItem -LiteralPath $folder -Filter '*.tmp').Count){throw 'Temporary archive remains'}
    $archives[$side]=(Get-FileHash -LiteralPath $archive).Hash
    $logs[$side]=@($rows | ForEach-Object {$_.Replace($folder.Replace('\','/'),'<ROOT>').Replace($folder,'<ROOT>')})
   }
   if($archives.oracle -cne $archives.reimpl -or @(Compare-Object $logs.oracle $logs.reimpl -SyncWindow 0).Count){throw "Join mismatch $name/$layout/$selected"}
   $count++
  }
 }
 Write-Host "Existing join: $name passed, $count pairs"
}
foreach($path in $hashes.Keys){if((Get-FileHash -LiteralPath $path).Hash -cne $hashes[$path]){throw 'Join fixture or binary changed'}}
if($count -ne $seeds.Count*9){throw 'Incomplete existing join test'}
Write-Host "Existing join: $count callback/output/archive comparisons and raw preservation checks passed; fixtures=$($seeds -join ',')"
