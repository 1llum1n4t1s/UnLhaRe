[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-float-release-codegen-20261004'
$reportPath=Join-Path $work 'report.json'
$report=Get-Content -Raw -LiteralPath $reportPath|ConvertFrom-Json -Depth 32 -DateKind String
if($report.status -cne 'diagnostic-passed' -or $report.compile_calls -ne 1 -or $report.native_calls -ne 3 -or $report.source_numerical_changes -ne 0 -or $report.Rust_source_copies -ne 0){throw 'Saved run status/calls/source boundary'}
$identityPairs=0
foreach($category in @('sources','identities')){
 $before=@($report.($category+'_before'));$after=@($report.($category+'_after'))
 if($before.Count -ne $after.Count){throw 'Identity count'}
 for($i=0;$i -lt $before.Count;$i++){
  $a=$before[$i];$b=$after[$i];$file=Get-Item -LiteralPath $a.path -Force
  if($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Identity shape/link'}
  if($a.path -cne $b.path -or $a.sha256 -cne $b.sha256 -or $a.bytes -ne $b.bytes -or $a.mtime_utc -cne $b.mtime_utc -or (Get-FileHash -LiteralPath $a.path).Hash -cne $a.sha256 -or $file.Length -ne $a.bytes -or $file.LastWriteTimeUtc.ToString('o') -cne $a.mtime_utc){throw "Identity changed: $($a.path)"};$identityPairs++
 }
}
$oldReportPath=Join-Path $project 'build/khc-float-fresh-transaction-20261004/report.json'
$oldReport=Get-Content -Raw -LiteralPath $oldReportPath|ConvertFrom-Json -Depth 32 -DateKind String
if($report.source_count -ne 19 -or $report.source_bytes -ne 160965 -or $report.imports.Count -ne 18 -or $oldReport.sources_before.Count -ne 19){throw 'Frozen closure'}
foreach($entry in $report.sources_before){
 $old=@($oldReport.sources_before|Where-Object path -ceq $entry.path)
 if($old.Count -ne 1 -or ($entry|ConvertTo-Json -Compress) -cne ($old[0]|ConvertTo-Json -Compress)){throw 'Different FT1 source closure'}
}
$expected=@('--edition=2024','--cfg','frame_audit','--cfg','primitive_audit','-C','opt-level=3','-C','lto=thin','-C','codegen-units=1','-C','panic=unwind','-C','overflow-checks=yes','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE')
if(($report.compile_settings|ConvertTo-Json -Compress) -cne ($expected|ConvertTo-Json -Compress)){throw 'Compiler settings'}
foreach($child in $report.children){if($child.exit_code -ne 0 -or $child.failure -or [Text.Encoding]::UTF8.GetByteCount($child.stdout) -gt 65536 -or [Text.Encoding]::UTF8.GetByteCount($child.stderr) -gt 16384){throw 'Bounded child failure'}}
$fresh=$report.selfcheck.fresh_rejections;$standalone=$report.selfcheck.standalone
if($fresh.fresh_named_rejections -ne 20 -or $fresh.all_state_comparisons -ne 20 -or $fresh.rejected_callback_calls -ne 14 -or $fresh.CAP_exact_successes -ne 1 -or $standalone.normal_cases -ne 14 -or $standalone.malformed_cases -ne 33 -or $standalone.model_rejection_assertions -ne 26){throw 'E2E counts'}
$names=@('runs','primary','alphabet','payload','plain_crc','payload_crc','rank','length','escape','grammar','base_pool','branches','classes','cdf_bits')
function Test-CodegenProof($A,$B){
 if(@($A.PSObject.Properties).Count -ne 14 -or @($B.PSObject.Properties).Count -ne 14){throw 'Proof field count'}
 foreach($name in $names){
  if(!$A.PSObject.Properties[$name] -or !$B.PSObject.Properties[$name]){throw 'Proof field names'}
  $aValues=@($A.$name);$bValues=@($B.$name)
  if($aValues.Count -ne $bValues.Count){throw 'Proof array count'}
  for($j=0;$j -lt $aValues.Count;$j++){if($aValues[$j] -ne $bValues[$j]){throw "Proof value differs: $name"}}
 }
}
if($report.screen.cases -ne 5 -or $report.screen.fixed_frame_bytes -ne 478750 -or !$report.screen.size_gate_passed -or $report.old_opt2_saved_Proof14_comparisons -ne 5){throw 'Size/equivalence gate'}
for($i=0;$i -lt 5;$i++){
 $record=$report.screen.records[$i]
 if(!$record.complete_frame_compared -or !$record.cdf_bits_compared -or $record.direct_plain_comparisons -ne 3 -or $record.typed_Proof14_comparisons -ne 3 -or $record.full_stats_comparisons -ne 3){throw 'Direct same-EXE comparison counts'}
 Test-CodegenProof $record.proof $oldReport.screen.records[$i].proof
 if(($record.stats|ConvertTo-Json -Compress) -cne ($oldReport.screen.records[$i].stats|ConvertTo-Json -Compress)){throw 'Saved opt2 stats differ'}
}
$encode=[long[]]@(0,0);$decode=[long[]]@(0,0)
for($i=0;$i -lt 4;$i++){
 $r=$report.ABBA.records[$i];$method=if($i -in @(1,2)){'fresh'}else{'reference'};$index=if($method -ceq 'fresh'){1}else{0}
 if($r.index -ne $i -or $r.method -cne $method -or $r.frame_bytes -ne 478750 -or $r.direct_plain_bytes -ne 2811006){throw 'ABBA record'}
 Test-CodegenProof $r.typed_proof $report.screen.records[-1].proof
 $encode[$index]+=$r.encode_ns;$decode[$index]+=$r.decode_ns
}
if($encode[0] -ne $report.ABBA.reference_encode_sum_ns -or $encode[1] -ne $report.ABBA.fresh_encode_sum_ns -or $decode[0] -ne $report.ABBA.reference_decode_sum_ns -or $decode[1] -ne $report.ABBA.fresh_decode_sum_ns -or $report.ABBA.ABBA_cycles -ne 1 -or $report.ABBA.warmup_runs -ne 0){throw 'ABBA sums/cycles'}
$shorter=$encode[1] -lt $encode[0] -and $decode[1] -lt $decode[0]
if($shorter -ne $report.same_binary_both_directions_shorter){throw 'Same-binary condition'}
$exe=$report.executable_before;$file=Get-Item -LiteralPath $exe.path
if($file.Length -ne $exe.bytes -or $file.Length -gt 1048576 -or (Get-FileHash -LiteralPath $exe.path).Hash -cne $exe.sha256){throw 'EXE pin/bound'}
$owned=@(Get-Process|Where-Object {$_.Path -eq $exe.path});if($owned.Count){throw 'Owned EXE active'}
$guard=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8
[pscustomobject]@{status='verified-readonly';identity_pairs=$identityPairs;Rust_source_changes=0;frozen_closure=19;fresh_rejections=20;saved_opt2_Proof14_stat_comparisons=5;crosscompile_direct_frame_compared=$false;same_EXE_both_directions_shorter=$shorter;same_EXE_encode_reduction_percent=100*(1-$encode[1]/$encode[0]);same_EXE_decode_reduction_percent=100*(1-$decode[1]/$decode[0]);crosscompile_formal_effect_rate_claimed=$false;owned_exe_processes=$owned.Count;report_sha256=(Get-FileHash -LiteralPath $reportPath).Hash;generated_files=@(Get-ChildItem -LiteralPath $work -File -Recurse|ForEach-Object{[pscustomobject]@{path=$_.FullName;bytes=$_.Length}});guard_after_final_report_save=$guard}|ConvertTo-Json -Depth 6
