[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-anchored-sa-generation-20261004'
$reportPath=Join-Path $work 'report.json'
if((Get-FileHash -LiteralPath $reportPath).Hash -cne 'A4C1128B0092FC89D20D419AF87059ADCF607F76E989262396E41B5F0AD8DAAE'){throw 'Report SHA'}
$r=Get-Content -Raw -LiteralPath $reportPath|ConvertFrom-Json -Depth 32 -DateKind String
function Check-Identity($a,$b){
 foreach($key in @('path','sha256','bytes','mtime_utc')){if($a.$key -cne $b.$key){throw "Before/after $key"}}
 $file=Get-Item -LiteralPath $a.path
 if(($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Length -ne $a.bytes -or $file.LastWriteTimeUtc.ToString('o') -cne $a.mtime_utc -or (Get-FileHash -LiteralPath $a.path).Hash -cne $a.sha256){throw "Live drift $($a.path)"}
}
$pairs=0
foreach($kind in @('sources','identities')){
 $before=@($r.($kind+'_before'));$after=@($r.($kind+'_after'))
 if($before.Count -ne $after.Count){throw 'Identity extent'}
 for($i=0;$i -lt $before.Count;$i++){Check-Identity $before[$i] $after[$i];$pairs++}
}
Check-Identity $r.executable_before $r.executable_after;$pairs++
if($pairs -ne 59 -or $r.source_count -ne 9 -or $r.imports.Count -ne 8 -or $r.source_bytes -ne 44128 -or $r.compile_calls -ne 1 -or $r.native_calls -ne 1 -or $r.status -cne 'diagnostic-passed' -or $r.children.Count -ne 3 -or $r.setting_sweeps -ne 0){throw 'Execution census'}
foreach($c in $r.children){if($c.exit_code -ne 0 -or $c.failure){throw 'Child failed'}}
$raw=$r.children[-1].stdout|ConvertFrom-Json -Depth 32 -DateKind String
if(($raw|ConvertTo-Json -Depth 32 -Compress) -cne ($r.diagnostic|ConvertTo-Json -Depth 32 -Compress)){throw 'Raw stdout mismatch'}
$d=$raw;$f=$d.fixed;$s=$d.small;$e=$d.selector
function Census($value,$expected){foreach($key in $expected.Keys){if($value.$key -ne $expected[$key]){throw "Census $key"}}}
Census $s @{plain_cases=92;independent_suffix_sort_cases=92;SA_anchor_comparisons=512;fallback_cases=28;anchored_cases=64;remainder_categories=8}
Census $e @{q0_safe_select_calls=28;target_select_calls=152;synthetic_anchor_comparisons=152;target_roundtrip_cases=19;wrong_suffix_nonselection_cases=1;selector_rejections=8;unchanged_stack_rejections=5;oversized_BWT_rejections=2;recovery_cases=1;maximum_selector_n=8388609;large_forward_BWT_calls=0}
Census $f @{input_reads=1;alphabet_prep_calls=1;alphabet_validation_calls=1;restore_alphabet_scan_calls=1;input_length=2811006;input_capacity=2811006;last_capacity_each=2811007;metadata_capacity_each=32;metadata_bytes=32;n=2811007;primary=1762795;warmups_each=1;rounds=9;timed_calls=18;timed_old_BWT_calls=9;timed_old_LF_generation_calls=9;timed_new_BWT_calls=9;new_LF_generation_calls=0;new_separate_SA_scans=0;all_plain_bytes_compared=2811006;candidate_scratch_capacity_words=2811007;candidate_result_capacity=2811006;AB_rounds=5;BA_rounds=4}
foreach($flag in @('all_BWT_primary_metadata_bytes_equal','all_three_way_plain_equal')){if(!$s.$flag){throw 'Tiny direct comparison'}}
foreach($flag in @('alphabet_prep_outside_pipeline_timers','prepared_alphabet_all_values_equal','all18_pipeline_last_primary_metadata_comparisons','old_plain_dropped_before_candidate_restore','both_BWT_phases_bound','function_SA_text_scratch_drop_timed')){if(!$f.$flag){throw 'Pipeline contract'}}
function Median($values){$v=@($values|Sort-Object);$m=[int][math]::Floor($v.Count/2);if($v.Count%2){return [double]$v[$m]};([double]$v[$m-1]+[double]$v[$m])/2}
if($f.samples.Count -ne 9){throw 'Sample extent'}
$times=@(@(),@(),@(),@());$orders=@(@(@(),@()),@(@(),@()))
for($i=0;$i -lt 9;$i++){
 $v=$f.samples[$i];$o=$i%2
 if($v.round -ne $i -or $v.order -cne @('AB','BA')[$o] -or $v.old_BWT_ns -le 0 -or $v.old_LF_generation_ns -le 0 -or $v.old_total_ns -le 0 -or $v.new_total_ns -le 0 -or $v.old_total_minus_BWT_LF_ns -lt 0 -or $v.old_total_minus_BWT_LF_ns -ne $v.old_total_ns-$v.old_BWT_ns-$v.old_LF_generation_ns){throw 'Raw timing'}
 foreach($j in 0..3){$key=@('old_BWT_ns','old_LF_generation_ns','old_total_ns','new_total_ns')[$j];$times[$j]+=$v.$key}
 $orders[$o][0]+=$v.old_total_ns;$orders[$o][1]+=$v.new_total_ns
}
foreach($j in 0..3){$key=@('old_BWT_median_ns','old_LF_generation_median_ns','old_total_median_ns','new_total_median_ns')[$j];if($f.$key -ne (Median $times[$j])){throw 'Overall median'}}
if($f.AB_old_total_median_ns -ne (Median $orders[0][0]) -or $f.AB_new_total_median_ns -ne (Median $orders[0][1]) -or $f.BA_old_total_median_ns -ne (Median $orders[1][0]) -or $f.BA_new_total_median_ns -ne (Median $orders[1][1])){throw 'Order medians'}
if($f.new_BWT_source_phase_bytes -ne 141598926+2*2811007+64+4096 -or $f.old_LF_source_phase_bytes -ne 2811006+8*2811007+64+4096+4MB -or $f.restore_source_phase_bytes -ne 2811006+7*2811007-1+32+4MB){throw 'RAM phase equations'}
if(!$d.memory.measured -or !$d.memory.ABI_checked -or $d.memory.API_calls -ne 1 -or $d.memory.ABI_size -ne 80 -or $d.memory.ABI_cb -ne 80 -or $null -ne $d.memory.last_OS_error -or $d.memory.peak_working_set_bytes -le 0 -or $d.memory.peak_private_commit_bytes -le 0 -or $d.memory.peak_working_set_bytes -gt 160MB -or $d.memory.peak_private_commit_bytes -gt 160MB){throw 'OS memory'}
foreach($flag in @('metadata_CRC_protected','completed_archive_wire','formal_performance_claim','four_native_verified','adoption')){if($d.$flag){throw 'False claim'}}
if($e.OS_OOM_injected -or $f.CPU_quiet_verified -or $f.comparison_and_caller_drop_timed -or $f.alphabet_prep_ns -le 0 -or $d.frame_encodes -ne 0 -or $d.frame_decodes -ne 0 -or $d.disk_plain_input_frame_copies -ne 0 -or $d.raw_trace_copies -ne 0){throw 'Scope nonclaims'}
if(!$r.BWT_ledger.SA_IS_prefix_unchanged -or $r.BWT_ledger.metadata_replacements -ne 4 -or $r.BWT_ledger.extra_residual -ne 0 -or $r.BWT_ledger.new_LF_scratch_or_walk -or $r.BWT_ledger.new_separate_SA_scan){throw 'Source ledger'}
$oldText=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../causal-bayes-sais/bwt.rs')).Replace("`r`n","`n").TrimEnd()+"`n"
$newText=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'bwt.rs')).Replace("`r`n","`n")
$oldAt=$oldText.IndexOf('pub fn bwt(input:');$newAt=$newText.IndexOf('pub fn bwt(input:')
if($oldText.Substring(0,$oldAt) -cne $newText.Substring(0,$newAt)){throw 'Independent SA-IS prefix check'}
$suffixAt=$newText.IndexOf("`npub(crate) fn select");$suffix=$newText.Substring($suffixAt)
if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($suffix))) -cne $r.BWT_ledger.selector_suffix_sha256){throw 'Selector suffix SHA'}
$restored=$newText.Substring(0,$suffixAt).TrimEnd()+"`n"
foreach($p in @(
 @('pub fn bwt(input: &[u8]) -> Result<(Vec<u16>, usize, Vec<u8>)> {','pub fn bwt(input: &[u8]) -> Result<(Vec<u16>, usize)> {'),
 @("    let mut anchors=[None;8];`n",''),
 @("        select(&mut anchors,n,row,p)?;`n",''),
 @("    let metadata=finish(anchors,n,primary)?;`n    Ok((last, primary, metadata))",'    Ok((last, primary))')
)){if([regex]::Matches($restored,[regex]::Escape($p[0])).Count -ne 1){throw 'Restoration single occurrence'};$restored=$restored.Replace($p[0],$p[1])}
if($restored -cne $oldText){throw 'Independent full BWT restoration'}
$entries=@(Get-ChildItem -LiteralPath $work -Force)
if($entries.Count -ne 2 -or @($entries|Where-Object {$_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $_.Name -notin @('report.json','anchored-sa-generation-o3-thin.exe')}).Count){throw 'Output shape'}
if(@(Get-Process|Where-Object {$_.Path -eq $r.executable_after.path}).Count){throw 'Owned native remains'}
$guard=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8
[pscustomobject]@{status='readonly-passed';identity_pairs=$pairs;raw_native_records=1;additional_compile_calls=0;additional_native_calls=0;old_total_median_ms=$f.old_total_median_ns/1e6;new_total_median_ms=$f.new_total_median_ns/1e6;alphabet_prep_ms=$f.alphabet_prep_ns/1e6;disk=$guard}|ConvertTo-Json -Depth 6
