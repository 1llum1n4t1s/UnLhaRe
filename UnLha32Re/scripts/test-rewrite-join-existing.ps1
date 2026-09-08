param(
 [Parameter(Mandatory)][string]$TestProgram,
 [Parameter(Mandatory)][string]$Oracle,
 [Parameter(Mandatory)][string]$Candidate,
 [Parameter(Mandatory)][string]$FixturesRoot,
 [Parameter(Mandatory)][string]$Workspace,
 [ValidateSet('seed-l0.lzh','seed-l1.lzh','seed-l2.lzh','unix-l1.lzh','unix-l2.lzh')]
 [string[]]$SeedNames=@('seed-l0.lzh','seed-l1.lzh','seed-l2.lzh','unix-l1.lzh','unix-l2.lzh'),
 [ValidateSet(0,1,2)][int[]]$Modes=@(0,1,2),
 [ValidateSet('legacy','A','W')][string[]]$Apis=@('W'),
 [ValidateSet('none','a32','a64','w32','w64')][string[]]$Layouts=@('none','a32','a64','w32','w64')
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
foreach($axis in @(@{name='SeedNames';values=$SeedNames},@{name='Modes';values=$Modes},
 @{name='Apis';values=$Apis},@{name='Layouts';values=$Layouts})){
 if(!$axis.values.Count -or @($axis.values | Sort-Object -Unique).Count -ne $axis.values.Count){throw "Empty or duplicate axis: $($axis.name)"}
}
$incoming=Join-Path $FixturesRoot 'seed-l2.lzh'
foreach($path in @($TestProgram,$runner,$Oracle,$Candidate,$incoming)+@($seeds | ForEach-Object {Join-Path $FixturesRoot $_})){
 $hashes[$path]=(Get-FileHash -LiteralPath $path).Hash
}
$count=0
foreach($name in $seeds){
 $seed=Join-Path $FixturesRoot $name
 $oldBytes=[IO.File]::ReadAllBytes($seed)
 if($oldBytes[-1] -ne 0){throw 'Old fixture has no terminator'}
 foreach($mode in $Modes){foreach($api in $Apis){foreach($layout in $Layouts){
  $selections=if($layout -eq 'none'){@(1)}else{@(0,1)}
  foreach($selected in $selections){
   $logs=@{}; $archives=@{}
   foreach($side in 'oracle','reimpl'){
    $folder=Join-Path $root "$name-n$mode-$api-$layout-$selected-$side"
    New-Item -ItemType Directory -Path $folder | Out-Null
    $archive=Join-Path $folder 'joined.lzh'
    $source=Join-Path $folder 'source.lzh'
    Copy-Item -LiteralPath $seed -Destination $archive
    Copy-Item -LiteralPath $incoming -Destination $source
    $line='j -gm1 -y1 -n'+$mode+' "'+$archive+'" "'+$source+'"'
    $dll=if($side -eq 'oracle'){$Oracle}else{$Candidate}
    $rows=@(& $runner --timeout-seconds 30 $TestProgram --registry '' --command-enum-probe $dll $line $layout $selected '@file:変更後.txt' 1041 0 $api 1 2>&1 | ForEach-Object {"$_"} | Tee-Object -FilePath (Join-Path $folder 'command.log'))
    $expectedEnum=if($layout -eq 'none'){0}else{1}
    if($LASTEXITCODE -ne 0 -or $rows -notcontains 'result=0' -or $rows -notcontains "enum.count=$expectedEnum"){throw "Join probe failed $folder"}
    $expectedStates=if($mode -eq 0){''}else{'5,3,0,0,1,1,4,1,2'}
    $states=@($rows | Where-Object {$_ -match '^progress\.entry=.*?,state=(\d+),'} | ForEach-Object {[regex]::Match($_,',state=(\d+),').Groups[1].Value})
    if(($states -join ',') -cne $expectedStates -or $rows -notcontains "progress.count=$($states.Count)"){throw "Existing join progress order/count mismatch: $folder"}
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
    foreach($path in $archive,$source){
     $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
     $stream.Dispose()
    }
    $archives[$side]=(Get-FileHash -LiteralPath $archive).Hash
    $logs[$side]=@($rows | ForEach-Object {
     $row=$_.Replace($folder.Replace('\','/'),'<ROOT>').Replace($folder,'<ROOT>')
     if($row -match '^progress\.entry=.*?,state=5,'){
      if($side -eq 'reimpl' -and !$row.Contains(',file=0,compressed=0,write=0,attributes=0,crc=0,os=0,ratio=0,create=0,access=0,write-time=0,mode="",source=')){throw 'Candidate SEARCH metadata is not initialized'}
      # 原版の SEARCH の未使用数値欄だけを除外し、名前・宛先・順序は比較する。
      $row=$row -replace ',file=.*?,mode="(?:\\.|[^"\\])*",source=',',metadata=undefined,source='
     }
     # 一時ファイルのランダム名だけを正規化する。場所・公開タイミングは本試験の比較対象外。
     $row -replace 'source=path="LHT[0-9A-Fa-f]+\.tmp"','source=path="LHT<TEMP>.tmp"'
    })
   }
   $difference=@(Compare-Object $logs.oracle $logs.reimpl -SyncWindow 0)
   if($archives.oracle -cne $archives.reimpl -or $difference.Count){throw "Join mismatch $name/n$mode/$api/$layout/$selected`n$($difference | Out-String -Width 3000)"}
   $count++
  }
 }}}
 Write-Host "Existing join: $name passed, $count pairs"
}
foreach($path in $hashes.Keys){if((Get-FileHash -LiteralPath $path).Hash -cne $hashes[$path]){throw 'Join fixture or binary changed'}}
if($count -ne $seeds.Count*$Modes.Count*$Apis.Count*(2*$Layouts.Count-[int]($Layouts -contains 'none'))){throw 'Incomplete existing join test'}
Write-Host "Existing join: $count callback/progress/output/archive comparisons and raw preservation/release checks passed; fixtures=$($seeds -join ','); modes=$($Modes -join ','); APIs=$($Apis -join ',')"
