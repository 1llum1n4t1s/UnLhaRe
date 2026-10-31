#requires -Version 7.2
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-suffix-class-entropy-20261001'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$ids=[Collections.Generic.List[object]]::new()
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$calls=[Collections.Generic.List[object]]::new()
$checks=[Collections.Generic.List[object]]::new()
$owned=[Collections.Generic.List[string]]::new()
function No-Reparse([string]$Path){
    $p=[IO.Path]::GetFullPath($Path)
    while($p){if((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw "Reparse rejected: $p"};$p=[IO.Path]::GetDirectoryName($p)}
}
function Identity([string]$Path){No-Reparse $Path;$item=Get-Item -LiteralPath $Path -Force;if($item -isnot [IO.FileInfo]){throw 'Regular file required'};[pscustomobject]@{path=$item.FullName;bytes=$item.Length;sha256=(Get-FileHash -LiteralPath $Path).Hash}}
function Hold([string]$Path,[string]$Role,[string]$Expected=''){
    No-Reparse $Path;$locks.Add([IO.File]::Open($Path,'Open','Read','Read'))
    $id=Identity $Path;if($Expected -and $id.sha256 -cne $Expected){throw "Pin mismatch: $Path"}
    $ids.Add([pscustomobject]@{role=$Role;path=$id.path;before_bytes=$id.bytes;before_sha256=$id.sha256;after_bytes=$null;after_sha256=$null});$id
}
function Write-New([string]$Path,[byte[]]$Bytes){No-Reparse $Path;$f=[IO.File]::Open($Path,'CreateNew','Write','None');try{$f.Write($Bytes);$f.Flush($true)}finally{$f.Dispose()};$owned.Add($Path)}
function Check([string]$Name){$checks.Add([pscustomobject]@{name=$Name;passed=$true})}
function Same-Bytes([string]$Left,[string]$Right){
    if([Convert]::ToBase64String([IO.File]::ReadAllBytes($Left)) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($Right))){throw "Full byte mismatch: $Left / $Right"}
}
function Invoke-Child([string]$Program,[string[]]$Argv,[int]$Expected=0){
    $row=[ordered]@{program=$Program;argv=$Argv;exit=$null;expected_exit=$Expected;timeout=$false;stdout='';stderr=''};$calls.Add($row)
    $info=[Diagnostics.ProcessStartInfo]::new($Program);$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.WorkingDirectory=$work
    foreach($arg in $Argv){$info.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info;$started=$false;$outTask=$null;$errTask=$null
    try{
        $started=$p.Start();if(-not $started){throw 'Child start failed'}
        $outTask=$p.StandardOutput.ReadToEndAsync();$errTask=$p.StandardError.ReadToEndAsync()
        if(-not $p.WaitForExit(120000)){$row.timeout=$true;throw '120s child timeout'}
        $row.stdout=$outTask.GetAwaiter().GetResult();$row.stderr=$errTask.GetAwaiter().GetResult();$row.exit=$p.ExitCode
        if($row.exit -ne $Expected -or ($Expected -eq 0 -and $row.stderr) -or ($Expected -ne 0 -and $row.stdout)){throw 'Unexpected child exit/output'}
        [pscustomobject]$row
    }finally{
        if($started -and -not $p.HasExited){$p.Kill($true);$p.WaitForExit()}
        if($null -ne $outTask){$row.stdout=$outTask.GetAwaiter().GetResult()};if($null -ne $errTask){$row.stderr=$errTask.GetAwaiter().GetResult()};if($started){$row.exit=$p.ExitCode};$p.Dispose()
    }
}
function Refuse([string]$Exe,[string]$InputPath,[string]$OutputPath,[string]$Reason){
    $row=Invoke-Child $Exe @($InputPath,$OutputPath) 1
    if($row.stderr -notmatch $Reason -or (Test-Path -LiteralPath $OutputPath)){throw "Refusal/publication mismatch: $Reason"}
    Check "refusal-$([IO.Path]::GetFileNameWithoutExtension($InputPath))-$([IO.Path]::GetFileName($Exe))"
}
function Read-Histogram([string]$Path){
 $data=[IO.File]::ReadAllBytes($Path)
 if($data.Length -ne 5505044 -or [Text.Encoding]::ASCII.GetString($data,0,8) -cne 'KQHIST01' -or [BitConverter]::ToUInt32($data,8) -ne 7 -or [BitConverter]::ToUInt32($data,12) -ne 3 -or [BitConverter]::ToUInt32($data,16) -ne 32768){throw 'Histogram format mismatch'}
 $expectedCounts=@(889227,888970,2472373,1835474,889227,426165,221182)
 $rows=@()
 for($class=0;$class -lt 7;$class++){
  $losses=@();$totals=@();$occupied=@()
  for($component=0;$component -lt 3;$component++){
   [uint64]$total=0;[double]$loss=0;$occupiedBins=0;$base=20+($class*3+$component)*32768*8
   if([BitConverter]::ToUInt64($data,$base) -ne 0){throw 'Histogram bin0 used'}
   for($q=1;$q -lt 32768;$q++){
    $count=[BitConverter]::ToUInt64($data,$base+$q*8)
    $total+=$count
    if($count -gt 0){$loss-=[double]$count*[Math]::Log2([double]$q/32768.0);$occupiedBins++}
   }
   if($total -ne $expectedCounts[$class] -or [double]::IsNaN($loss) -or [double]::IsInfinity($loss) -or $loss -lt 0){throw 'Histogram total/loss invalid'}
   $losses+=@($loss);$totals+=@($total);$occupied+=@($occupiedBins)
  }
  $rows+=@([pscustomobject]@{class=$class;bits=$totals[0];component_counts=$totals;loss_bits_approx=$losses;occupied_bins=$occupied})
 }
 [pscustomobject]@{path=$Path;data=$data;rows=$rows}
}
No-Reparse $work
if(Test-Path -LiteralPath $work){throw 'New owned root required; no automatic retry'}
$null=New-Item -ItemType Directory -Path $work
$failure=$null
$report=[ordered]@{status='failed';error=$null;started_utc=[DateTime]::UtcNow.ToString('o');timing_used=$false;compiler=$compiler;identities=$ids;invocations=$calls;checks=$checks;owned_paths=$owned;class_diagnostic=@();inventory=@();owned_tmp_count=$null;owned_reparse_count=$null;limitations=@('Integer histogram diagnostic only; floating loss rollup is approximate, not exact archive-byte attribution.','No model/threshold/depth/grammar changes, speed measurements, parameter sweep, holdout or product adoption.','Parent source inspection and previous evidence reuse, not a new independent-author audit or native macOS/ARM64 verification.','Frame and auxiliary histogram publications are separate; auxiliary failure may leave a retained failed-trial frame.')}
Write-New (Join-Path $work 'ownership.json') ([Text.Encoding]::UTF8.GetBytes('{"owner":"suffix-class-entropy","retain":"frozen integer histograms, CLI frames/restores, sources/compiler identities and terminal diagnostic report"}'))
try{
 $pins=[ordered]@{
 'experiments/khc/SUFFIX_CLASS_ENTROPY_CONTRACT_20261001.md'='D955303D30B847D11F8917A0E75069AC38753ED77770B164195C97C8E62E69F6'
 'experiments/khc/suffix-class-entropy/old.rs'='DE57D86B36B1C06A533AE8F243203D92AE65FD2C025B08903D7D786A39018B6B'
 'experiments/khc/suffix-class-entropy/new.rs'='979E8BD6EC8F5D350324F38FED33483355F5600D256C43C38D6342D8873A37CF'
 'experiments/khc/suffix-class-entropy/histogram.rs'='44D9CE735F308262E5EFA3B1D540226433C48B713CE5436C99B98AA92DFC0AE6'
 'experiments/khc/suffix-class-entropy/correspondence.json'='0B22AAB7EA583C937580C704C4E039915F083D2DCED2A08351FB477D0222422D'
 'experiments/khc/causal-bayes-q32-kt-reciprocal/codec.rs'='9D757709834F501B83929C2882BCE6053FCA5CFC5AAEEC2B4A16EED7AE58680B'
 'experiments/khc/causal-bayes-q32-kt-reciprocal/cts_model.rs'='ACEAA15363123470FA09481BF6408FF2BDFF95A15D65489D64A9998B8E26F6C7'
 'experiments/khc/adaptive-suffix-kt/codec.rs'='B45F257D723478DA4C2D3FF0A8467BB8FB6A20CF18047CFF9575FAD3A110E78C'
 'experiments/khc/adaptive-suffix-kt/cts_model.rs'='F6E6BABE00ECB2063117D554135E8ED6F13B3B458E4FBCFA7D4B0596C6CCBB32'
 'experiments/khc/causal-bayes-q32-kt-reciprocal/exact_kt.rs'='4DC85F126E3813531337036A6A3C4B048B1B256645A3E58A60469170383A0B61'
 'experiments/khc/native32-quotient/exact_div.rs'='338B2EB4F8A7C70994BD96CE28038C107F65F1106DD57A575CA6C524797310CD'
 'experiments/khc/causal-bayes-log-table/bayes_model.rs'='E50A6DDFEB93044A7A7DBFAC6881F863DE94E194F3E5EF50A9E8E211D4181422'
 'experiments/khc/causal-bayes-sais/bwt.rs'='810662D4168EE8AC00C81A446D1F3B17056DBBEAFAD1724C43AB0C74A546132F'
 'experiments/khc/rejected-binary-mix/packed_alphabet.rs'='4934593F891296B72F91F8FB2CC27D26262514B3B153319A8EC1CDCA64B2734D'
 'experiments/khc/range.rs'='1BD47734E6224C1D4819F57D94B4B546A2279793E1092F43B69F58CE3AD4667C'
 'build/khc-current-source-native-solid-20260923-group/all.group'='18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'
 'build/khc-bwt-causal-bayes-q32-balanced-kt-20261001-schema-fix/full-e2e/fixed.frame'='7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C'
 'build/khc-adaptive-suffix-kt-20261001/fixed-native.frame'='F9B76F4DED7C402BC3B06BBDC499A5A7B41CE758067F8EFA24F3ED1CCB9B4531'
 'build/khc-adaptive-suffix-kt-20261001/report.json'='152ECC51BEDA2DA7C38637075548D5744A84E9A778AB8B10D6CA45C02B02D28A'
 'build/khc-q32-operation-counts-20261001/report.json'='36F6B6D44D5E3AF2F50298531E9DB76FBFC85AB2AD66AA847D5732383768D2B7'
 }
 foreach($pin in $pins.GetEnumerator()){$null=Hold (Join-Path $root $pin.Key) 'source-dependency-or-parent-evidence' $pin.Value}
 $null=Hold $PSCommandPath 'verifier'
 $null=Hold $compiler 'compiler' 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
 $correspondence=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'correspondence.json') -Raw | ConvertFrom-Json
 foreach($row in $correspondence){
  $original=[IO.File]::ReadAllText((Join-Path $PSScriptRoot $row.source_from)).Replace("`r`n","`n")
  foreach($change in $row.changes){if($original.Split([string[]]@($change.from),[StringSplitOptions]::None).Length-1 -ne $change.count){throw 'Source hook count mismatch'};$original=$original.Replace($change.from,$change.to)}
  $actual=[IO.File]::ReadAllText((Join-Path $PSScriptRoot $row.source_to)).Replace("`r`n","`n")
  if($original.TrimEnd([char]10) -cne $actual.TrimEnd([char]10)){throw 'Full source correspondence mismatch'}
  Check "$($row.variant)-source-correspondence"
 }
 $tokens=$null;$parseErrors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$parseErrors);if($parseErrors.Count){throw 'Verifier syntax failure'}
 $null=Invoke-Child $compiler @('--version','--verbose')
 $group=Join-Path $root 'build/khc-current-source-native-solid-20260923-group/all.group'
 $histograms=@{}
 foreach($variant in @('old','new')){
  $exe=Join-Path $work "$variant.exe"
  $null=Invoke-Child $compiler @('--edition=2024','-C','panic=abort','-C','opt-level=3','--cfg','khc_class_entropy_audit',(Join-Path $PSScriptRoot "$variant.rs"),'-o',$exe)
  $owned.Add($exe);$null=Hold $exe 'compiled-diagnostic'
  $expectedFrame=if($variant -eq 'old'){Join-Path $root 'build/khc-bwt-causal-bayes-q32-balanced-kt-20261001-schema-fix/full-e2e/fixed.frame'}else{Join-Path $root 'build/khc-adaptive-suffix-kt-20261001/fixed-native.frame'}
  $firstFrame=$null;$firstHist=$null
  foreach($round in @(0,1)){
   $frame=Join-Path $work "$variant-$round.frame";$hist="$frame.q15hist"
   $null=Invoke-Child $exe @('encode',$group,$frame)
   foreach($artifact in @($frame,$hist)){$owned.Add($artifact);$null=Hold $artifact 'diagnostic-frame-or-histogram'}
   Same-Bytes $frame $expectedFrame;Check "$variant-$round-original-frame-byteexact"
   if($round -eq 0){$firstFrame=$frame;$firstHist=$hist}else{Same-Bytes $frame $firstFrame;Same-Bytes $hist $firstHist;Check "$variant-repeat-frame-and-histogram-byteexact"}
  }
  $restore=Join-Path $work "$variant.restore";$restoreHist="$restore.q15hist"
  $null=Invoke-Child $exe @('decode',$firstFrame,$restore)
  foreach($artifact in @($restore,$restoreHist)){$owned.Add($artifact);$null=Hold $artifact 'diagnostic-restoration'}
  Same-Bytes $restore $group;Same-Bytes $restoreHist $firstHist;Check "$variant-restore-and-decode-histogram-byteexact"
  $histograms[$variant]=Read-Histogram $firstHist;Check "$variant-histogram-format-class-component-counts"
  $sentinel=Join-Path $work "$variant.existing.frame";Write-New $sentinel ([byte[]]@(1,2,3))
  $row=Invoke-Child $exe @('encode',$group,$sentinel) 1
  if($row.stderr -notmatch 'already exists' -or (Test-Path -LiteralPath "$sentinel.q15hist") -or [Convert]::ToBase64String([IO.File]::ReadAllBytes($sentinel)) -cne 'AQID'){throw 'Frame no-clobber failed'}
  $null=Hold $sentinel 'frame-no-clobber-sentinel';Check "$variant-existing-frame-preserved"
  $emptyFrame=Join-Path $work "$variant.aux-existing.frame";$auxSentinel="$emptyFrame.q15hist";Write-New $auxSentinel ([byte[]]@(4,5,6))
  $row=Invoke-Child $exe @('encode',$group,$emptyFrame) 1
  if($row.stderr -notmatch 'already exists' -or (Test-Path -LiteralPath $emptyFrame) -or [Convert]::ToBase64String([IO.File]::ReadAllBytes($auxSentinel)) -cne 'BAUG'){throw 'Aux no-clobber failed'}
  $null=Hold $auxSentinel 'aux-no-clobber-sentinel';Check "$variant-existing-aux-preserved-before-frame"
 }
 for($class=0;$class -lt 7;$class++){
  $base=20+$class*3*32768*8
  for($q=0;$q -lt 32768;$q++){if([BitConverter]::ToUInt64($histograms.old.data,$base+$q*8) -ne [BitConverter]::ToUInt64($histograms.new.data,$base+$q*8)){throw 'Old/new primary histogram differs'}}
  $oldRow=$histograms.old.rows[$class];$newRow=$histograms.new.rows[$class]
  $report.class_diagnostic+=@([pscustomobject]@{class=$class;bits=$oldRow.bits;old=$oldRow;new=$newRow;mixed_loss_delta_bits_approx=$newRow.loss_bits_approx[2]-$oldRow.loss_bits_approx[2];mixed_loss_delta_bytes_approx=($newRow.loss_bits_approx[2]-$oldRow.loss_bits_approx[2])/8})
 }
 Check 'old-new-primary-histogram-exact-and-class-loss-rollup'
 $report.status='verified_class_histograms_not_timed'
}catch{$failure=$_;$report.error=$_.Exception.Message}
finally{
 foreach($id in $ids){try{$after=Identity $id.path;$id.after_bytes=$after.bytes;$id.after_sha256=$after.sha256;if($id.before_bytes -ne $after.bytes -or $id.before_sha256 -cne $after.sha256){throw 'Held file changed'}}catch{$report.status='failed';$report.error=(@($report.error,$_.Exception.Message)|Where-Object {$_}) -join ';';if($null -eq $failure){$failure=$_}}}
 foreach($held in $locks){$held.Dispose()}
 $items=@(Get-ChildItem -LiteralPath $work -Force -Recurse)
 $report.inventory=@($items | Select-Object FullName,Length,Attributes)
 $report.owned_tmp_count=@($items | Where-Object {$_.Name -like '*.tmp'}).Count
 $report.owned_reparse_count=@($items | Where-Object {($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0}).Count
 if($report.owned_tmp_count -ne 0 -or $report.owned_reparse_count -ne 0){$report.status='failed';$report.error=(@($report.error,'Owned tmp/reparse remains')|Where-Object {$_}) -join ';'}
 $report.completed_utc=[DateTime]::UtcNow.ToString('o')
 Write-New (Join-Path $work 'report.json') ([Text.UTF8Encoding]::new($false).GetBytes(($report | ConvertTo-Json -Depth 12)))
}
if($null -ne $failure){throw $failure}
if($report.status -eq 'failed'){throw $report.error}
[pscustomobject]@{status=$report.status;checks=$checks.Count;cli_calls=$calls.Count;identities=$ids.Count;class_diagnostic=$report.class_diagnostic;tmp=$report.owned_tmp_count;reparse=$report.owned_reparse_count}|ConvertTo-Json -Depth 6

