[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-anchored-inverse-20261004'
$reportPath=Join-Path $work 'report.json'
if((Get-FileHash -LiteralPath $reportPath).Hash -cne '3DDDA5809D5615E50017F012FCD22BD3AFEF424FF4A06B099F7ACEB34B40EEA9'){throw 'Report SHA'}
$r=Get-Content -Raw -LiteralPath $reportPath|ConvertFrom-Json -Depth 32 -DateKind String
$pairs=0
function Check-Identity($a,$b){
 foreach($key in @('path','sha256','bytes','mtime_utc')){if($a.$key -cne $b.$key){throw "Before/after $key"}}
 $file=Get-Item -LiteralPath $a.path
 if(($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Length -ne $a.bytes -or $file.LastWriteTimeUtc.ToString('o') -cne $a.mtime_utc -or (Get-FileHash -LiteralPath $a.path).Hash -cne $a.sha256){throw "Live drift $($a.path)"}
}
foreach($kind in @('sources','identities')){
 $before=@($r.($kind+'_before'));$after=@($r.($kind+'_after'))
 if($before.Count -ne $after.Count){throw 'Identity extent'}
 for($i=0;$i -lt $before.Count;$i++){Check-Identity $before[$i] $after[$i];$pairs++}
}
Check-Identity $r.executable_before $r.executable_after;$pairs++
if($pairs -ne 47 -or $r.source_count -ne 9 -or $r.imports.Count -ne 8 -or $r.source_bytes -ne 38529 -or $r.compile_calls -ne 1 -or $r.native_calls -ne 1 -or $r.status -cne 'diagnostic-passed' -or $r.children.Count -ne 3){throw 'Execution census'}
foreach($c in $r.children){if($c.exit_code -ne 0 -or $c.failure){throw 'Child failed'}}
$raw=$r.children[-1].stdout|ConvertFrom-Json -Depth 32 -DateKind String
if(($raw|ConvertTo-Json -Depth 32 -Compress) -cne ($r.diagnostic|ConvertTo-Json -Depth 32 -Compress)){throw 'Raw stdout mismatch'}
$d=$raw;$f=$d.fixed
function Median($values){$v=@($values|Sort-Object);$m=[int][math]::Floor($v.Count/2);if($v.Count%2){return [double]$v[$m]};([double]$v[$m-1]+[double]$v[$m])/2}
$old=@();$new=@();$orderOld=@(@(),@());$orderNew=@(@(),@())
if($f.samples.Count -ne 9 -or $f.timed_calls -ne 18 -or $f.warmups_each -ne 1){throw 'Sample extent'}
for($i=0;$i -lt 9;$i++){
 $s=$f.samples[$i];$order=$i%2
 if($s.round -ne $i -or $s.order -cne @('AB','BA')[$order] -or $s.old24_ns -le 0 -or $s.candidate_ns -le 0){throw 'Raw timing order'}
 $old+=$s.old24_ns;$new+=$s.candidate_ns;$orderOld[$order]+=$s.old24_ns;$orderNew[$order]+=$s.candidate_ns
}
if($f.old24_median_ns -ne (Median $old) -or $f.candidate_median_ns -ne (Median $new) -or $f.AB_old24_median_ns -ne (Median $orderOld[0]) -or $f.AB_candidate_median_ns -ne (Median $orderNew[0]) -or $f.BA_old24_median_ns -ne (Median $orderOld[1]) -or $f.BA_candidate_median_ns -ne (Median $orderNew[1])){throw 'Median mismatch'}
if($f.metadata_bytes -ne 32 -or $f.metadata_capacity -ne 32 -or $f.metadata_hex -cnotmatch '^[0-9a-f]{64}$' -or $f.anchors.Count -ne 8 -or $f.anchors[0] -ne 1762795 -or $f.metadata_generation_ns -le 0){throw 'Metadata'}
for($i=0;$i -lt 8;$i++){
 $h=$f.metadata_hex;$word=[Convert]::ToUInt32(($h.Substring(8*$i+6,2)+$h.Substring(8*$i+4,2)+$h.Substring(8*$i+2,2)+$h.Substring(8*$i,2)),16)
 if($word -ne $f.anchors[$i] -or $word -ge 2811007){throw 'LE anchor'}
}
if(!$d.small.all_three_way_plain_equal -or $d.small.plain_cases -ne 92 -or $d.small.SA_anchor_comparisons -ne 512 -or !$d.rejections.all_plain_directly_compared -or $d.rejections.enumeration_cases -ne 1793 -or $d.rejections.enumeration_accepted -ne 255 -or $d.rejections.enumeration_decoder_rejections -ne 1538 -or $d.rejections.generator_input_rejections -ne 17 -or $d.rejections.decoder_input_rejections -ne 17 -or $d.rejections.metadata_rejections -ne 9 -or $d.rejections.recovery_cases -ne 10 -or $d.rejections.counterexample72_primary_first_return -ne 8){throw 'Finite contracts'}
if($d.boundaries.Count -ne 3){throw 'Boundary extent'}
for($i=0;$i -lt 3;$i++){
 $b=$d.boundaries[$i];$n=8388607+$i
 if($b.n -ne $n -or !$b.three_way_all_plain_equal -or !$b.all_expected_zero -or $b.candidate_phase_RAM_estimate_bytes -ne 8*$n-2+32+4MB -or $b.reference_phase_RAM_estimate_bytes -ne 15*$n-2+4MB -or $b.candidate_scratch_capacity_words -ne $n -or $b.candidate_result_capacity -ne $n-1){throw 'Boundary contracts'}
}
if(!$f.all_plain_direct_comparisons -or $f.same_phase_RAM_estimate_bytes -ne 26682390 -or $f.generation_phase_RAM_estimate_bytes -ne 23871384 -or !$d.memory.measured -or $null -ne $d.memory.last_OS_error -or $d.memory.peak_working_set_bytes -le 0 -or $d.memory.peak_private_commit_bytes -le 0 -or $d.memory.peak_working_set_bytes -gt 160MB -or $d.memory.peak_private_commit_bytes -gt 160MB){throw 'Plain/RAM'}
foreach($flag in @('metadata_CRC_protected','completed_archive_wire','formal_performance_claim','four_native_verified','adoption')){if($d.$flag){throw 'False claim'}}
if($f.CPU_quiet_verified -or $f.encoder_metadata_cost_free -or !$f.metadata_generation_scratch_dropped_before_restore){throw 'Cost/quiet claim'}
$entries=@(Get-ChildItem -LiteralPath $work -Force)
if($entries.Count -ne 2 -or @($entries|Where-Object {$_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $_.Name -notin @('report.json','anchored-inverse-o3-thin.exe')}).Count){throw 'Output shape'}
if(@(Get-Process|Where-Object {$_.Path -eq $r.executable_after.path}).Count){throw 'Owned native remains'}
$guard=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8
[pscustomobject]@{status='readonly-passed';identity_pairs=$pairs;raw_native_records=1;additional_compile_calls=0;additional_native_calls=0;old_median_ms=$f.old24_median_ns/1e6;candidate_median_ms=$f.candidate_median_ns/1e6;metadata_generation_ms=$f.metadata_generation_ns/1e6;disk=$guard}|ConvertTo-Json -Depth 6
