[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$outputRoot=Join-Path $project 'build/khc-float-fresh-transaction-20261004'
$reportPath=Join-Path $outputRoot 'report.json'
$report=Get-Content -Raw -LiteralPath $reportPath|ConvertFrom-Json -Depth 32 -DateKind String
if($report.status -cne 'diagnostic-passed' -or $report.compile_calls -ne 1 -or $report.total_native_calls -ne 3){throw 'Saved native contract'}
$identityPairs=0
foreach($category in @('sources','identities')){
 $before=@($report.($category+'_before'));$after=@($report.($category+'_after'))
 if($before.Count -ne $after.Count){throw 'Identity pair count'}
 for($i=0;$i -lt $before.Count;$i++){
  $a=$before[$i];$b=$after[$i];$file=Get-Item -LiteralPath $a.path -Force
  if($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Identity shape/link'}
  if($a.path -cne $b.path -or $a.bytes -ne $b.bytes -or $a.sha256 -cne $b.sha256 -or $a.mtime_utc -cne $b.mtime_utc -or $file.Length -ne $a.bytes -or (Get-FileHash -LiteralPath $a.path).Hash -cne $a.sha256 -or $file.LastWriteTimeUtc.ToString('o') -cne $a.mtime_utc){throw "Identity changed: $($a.path)"};$identityPairs++
 }
}
function Read-FreshRustBody([string]$Text,[string]$Signature){
 $start=$Text.IndexOf($Signature,[StringComparison]::Ordinal);if($start -lt 0 -or $Text.IndexOf($Signature,$start+1,[StringComparison]::Ordinal) -ge 0){throw "Function signature count: $Signature"}
 $start=$Text.IndexOf('{',$start);$depth=0;$quoted=$false;$escaped=$false;$comment=$false
 for($i=$start;$i -lt $Text.Length;$i++){
  $c=$Text[$i]
  if($comment){if($c -eq "`n"){$comment=$false};continue}
  if($quoted){if($escaped){$escaped=$false}elseif($c -eq '\'){$escaped=$true}elseif($c -eq '"'){$quoted=$false};continue}
  if($c -eq '"'){$quoted=$true;continue}
  if($c -eq '/' -and $i+1 -lt $Text.Length -and $Text[$i+1] -eq '/'){$comment=$true;continue}
  if($c -eq '{'){$depth++}elseif($c -eq '}'){$depth--;if($depth -eq 0){return $Text.Substring($start+1,$i-$start-1)}}
 }
 throw 'Function body not closed'
}
function Normalize-FreshBody([string]$Text){[regex]::Replace([regex]::Replace($Text,'//[^\r\n]*',''),'\s+','')}
function Same-FreshBody([string]$A,[string]$B,[string]$Label){if((Normalize-FreshBody $A) -cne (Normalize-FreshBody $B)){throw "Kernel text differs: $Label"};$Label}
$oldRoot=Join-Path $PSScriptRoot '../lookup-float-cts'
$oldModel=[IO.File]::ReadAllText((Join-Path $oldRoot 'model.rs'))
$newModel=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'model.rs'))
$oldCts=[IO.File]::ReadAllText((Join-Path $oldRoot 'float_cts.rs'))
$newCts=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'float_cts.rs'))
$oldPool=[IO.File]::ReadAllText((Join-Path $oldRoot 'float_pool.rs'))
$newPool=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'float_pool.rs'))
$oldCodec=[IO.File]::ReadAllText((Join-Path $oldRoot 'codec.rs'))
$newCodec=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'codec.rs'))
$kernelChecks=@()
$kernelChecks+=Same-FreshBody (Read-FreshRustBody $oldModel 'pub fn new(depth:usize)') (Read-FreshRustBody $newModel 'pub fn new(depth:usize)') 'Model constructor'
$kernelChecks+=Same-FreshBody (Read-FreshRustBody $oldModel 'pub fn predict(&self,component:usize') (Read-FreshRustBody $newModel 'fn predict_branch(&self,component:usize') 'Model prediction arithmetic and validation'
foreach($signature in @('pub fn kt(raw:','pub fn predict_kernel(raw:','pub fn predict(&self,class:')){
 $kernelChecks+=Same-FreshBody (Read-FreshRustBody $oldCts $signature) (Read-FreshRustBody $newCts $signature) $signature
}
$kernelChecks+=Same-FreshBody (Read-FreshRustBody $oldCts 'pub fn observe(&mut self,s:') (Read-FreshRustBody $newCts 'pub fn observe(&mut self,s:') 'CTS checked split all validations retained'
$kernelChecks+=Same-FreshBody (Read-FreshRustBody $oldPool 'pub fn predict(math:') (Read-FreshRustBody $newPool 'pub fn predict(math:') 'Pool prediction all arithmetic/CDF/vector retained'
$gradient=Read-FreshRustBody $oldPool 'pub fn observe(s:'
$gradient=$gradient.Replace('if child>=s.prefix||!(1..=4).contains(&s.prefix){return Err("pool observed child".into());}vector(s.p,s.prefix)?;','')
$kernelChecks+=Same-FreshBody $gradient (Read-FreshRustBody $newPool 'fn prepare_update(s:') 'Pool gradient arithmetic unchanged after validated child/p'
$counts=Read-FreshRustBody $oldModel 'fn prepare(self,child:'
$counts=$counts.Replace('if child>=4||self.values.contains(&0)||self.total!=self.values.iter().map(|&v|u32::from(v)).sum::<u32>()||self.total>32768{return Err("count state".into());}','')
$kernelChecks+=Same-FreshBody $counts (Read-FreshRustBody $newModel 'fn prepare_fresh(self,child:') 'Count increment/rescale arithmetic unchanged'
$ctsFresh=Read-FreshRustBody $oldCts 'pub fn observe(&mut self,s:'
foreach($remove in @(
 'if s.ids!=path(self.history[s.class])||s.history!=self.history[s.class]||s.observations!=self.observations[s.class]{return Err("stale snapshot".into());}',
 'let current=self.nodes.get(s.class*1365+s.ids[l]).ok_or("prediction node index")?;',
 'if current.raw!=s.raw[l]||current.weight.to_bits()!=s.weights[l].to_bits(){return Err("stale snapshot node".into());}',
 'weight(current.weight)?;',
 'else if current.weight.to_bits()!=0.5f64.to_bits(){return Err("invalid kernel leaf".into());}'
)){$ctsFresh=$ctsFresh.Replace($remove,'')}
$ctsFresh=$ctsFresh.Replace('current.raw','s.raw[l]').Replace('current.weight','s.weights[l]')
$kernelChecks+=Same-FreshBody $ctsFresh (Read-FreshRustBody $newCts 'pub(crate) fn observe_fresh(&mut self,s:') 'CTS fresh only documented rechecks omitted, arithmetic/CAP/commit same'
foreach($signature in @('fn encode(input:','fn decode(frame:','fn encode_payload(last:','fn decode_payload(payload:')){
 $kernelChecks+=Same-FreshBody (Read-FreshRustBody $oldCodec $signature) (Read-FreshRustBody $newCodec $signature) $signature
}
if($newModel -match '\bunsafe\b' -or $newCts -match '\bunsafe\b' -or $newPool -match '\bunsafe\b' -or $newCodec -match '\bunsafe\b'){throw 'Unexpected unsafe'}
if($newCodec -match '\.model\.(predict|observe)\s*\(' -or $newModel -notmatch 'where F:FnOnce\(&BranchPrediction,&Tree\)->Result<usize>'){throw 'Normal split/callback boundary'}
$exe=$report.executable_before;$exeFile=Get-Item -LiteralPath $exe.path
if($exeFile.Length -ne $exe.bytes -or (Get-FileHash -LiteralPath $exe.path).Hash -cne $exe.sha256){throw 'EXE changed'}
$owned=@(Get-Process|Where-Object {$_.Path -eq $exe.path});if($owned.Count){throw 'Owned EXE still active'}
$fresh=$report.selfcheck.fresh_rejections
if($fresh.fresh_named_rejections -ne 20 -or $fresh.all_state_comparisons -ne 20 -or $fresh.records.Count -ne 20 -or $fresh.CAP_exact_successes -ne 1 -or $fresh.rejected_callback_calls -ne 14 -or @($fresh.records|Where-Object {!$_.all_state_direct_bits_compared}).Count){throw 'Fresh state rejection counts'}
if($report.screen.cases -ne 5 -or !$report.screen.size_gate_passed -or $report.screen.fixed_frame_bytes -ne 478750){throw 'Screen gate'}
$baseline=$report.screen.records[-1].proof|ConvertTo-Json -Compress
foreach($record in $report.screen.records){if(!$record.complete_frame_compared -or !$record.cdf_bits_compared -or $record.direct_plain_comparisons -ne 3 -or $record.typed_Proof14_comparisons -ne 3){throw 'Direct comparison contract'}}
$sumEncode=[long[]]@(0,0);$sumDecode=[long[]]@(0,0)
for($i=0;$i -lt 4;$i++){
 $record=$report.ABBA.records[$i];$method=if($i -in @(1,2)){'fresh'}else{'reference'};$index=if($method -ceq 'fresh'){1}else{0}
 if($record.index -ne $i -or $record.method -cne $method -or $record.frame_bytes -ne 478750 -or $record.direct_plain_bytes -ne 2811006 -or ($record.typed_proof|ConvertTo-Json -Compress) -cne $baseline){throw 'ABBA direct record'}
 $sumEncode[$index]+=$record.encode_ns;$sumDecode[$index]+=$record.decode_ns
}
if($sumEncode[0] -ne $report.ABBA.reference_encode_sum_ns -or $sumEncode[1] -ne $report.ABBA.fresh_encode_sum_ns -or $sumDecode[0] -ne $report.ABBA.reference_decode_sum_ns -or $sumDecode[1] -ne $report.ABBA.fresh_decode_sum_ns){throw 'ABBA timer sums'}
$retained=$sumEncode[1] -lt $sumEncode[0] -and $sumDecode[1] -lt $sumDecode[0]
if($retained -ne $report.private_candidate_retained -or $report.ABBA.warmup_runs -ne 0 -or $report.ABBA.ABBA_cycles -ne 1){throw 'ABBA retention condition'}
$guard=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $outputRoot -MaxRunMiB 8
[pscustomobject]@{status='verified-readonly';identity_pairs=$identityPairs;kernel_checks=$kernelChecks;fresh_rejections=20;fresh_rejected_callback_calls=14;private_candidate_retained=$retained;encode_internal_reduction_percent=100*(1-$sumEncode[1]/$sumEncode[0]);decode_internal_reduction_percent=100*(1-$sumDecode[1]/$sumDecode[0]);owned_exe_processes=$owned.Count;generated_files=@(Get-ChildItem -LiteralPath $outputRoot -File -Recurse|ForEach-Object{[pscustomobject]@{path=$_.FullName;bytes=$_.Length}});report_sha256=(Get-FileHash -LiteralPath $reportPath).Hash;guard_after_final_report_save=$guard}|ConvertTo-Json -Depth 6
