[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-causal-hard-cut-20261004'
$reportPath=Join-Path $work 'report.json'
function Require([bool]$ok,[string]$why){if(!$ok){throw $why}}
function Json($v){ConvertTo-Json -InputObject $v -Compress -Depth 64}
function Check-Identity($v){
 $p=[IO.Path]::GetFullPath($v.path);$a=$p
 while($a){if(Test-Path -LiteralPath $a){Require (!( (Get-Item -LiteralPath $a -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Reparse ancestor'};$a=[IO.Path]::GetDirectoryName($a)}
 $i=Get-Item -LiteralPath $p -Force
 Require (!$i.PSIsContainer -and $i.Length -eq $v.bytes -and (Get-FileHash -LiteralPath $p).Hash -ceq $v.sha256 -and $i.LastWriteTimeUtc.ToString('o') -ceq $v.mtime_utc) 'Live identity'
}
Require ((Get-FileHash -LiteralPath $reportPath).Hash -ceq 'E4CC334310A4426EB9F83E68D9D95D6421747723BCEE2A3F01C29CD346E4B9A0') 'Report hash'
$r=Get-Content -Raw -LiteralPath $reportPath|ConvertFrom-Json -Depth 64 -DateKind String
Require ($r.status -ceq 'diagnostic-passed' -and $r.compile_calls -eq 1 -and $r.total_native_calls -eq 1 -and $r.children.Count -eq 3) 'Single execution'
$pairs=0
foreach($kind in @('sources','identities')){
 $before=@($r.($kind+'_before'));$after=@($r.($kind+'_after'));Require ($before.Count -eq $after.Count -and $before.Count -gt 0) 'Pair extents'
 for($i=0;$i -lt $before.Count;$i++){Require ((Json $before[$i]) -ceq (Json $after[$i])) 'Before-after identity';Check-Identity $before[$i];$pairs++}
}
Require ($r.sources_before.Count -eq 19 -and $r.imports.Count -eq 18 -and ($r.sources_before|Measure-Object bytes -Sum).Sum -eq 85361) 'Source closure extent'
foreach($edge in $r.imports){Require (@($r.sources_before|Where-Object path -ceq $edge.source).Count -eq 1 -and @($r.sources_before|Where-Object path -ceq $edge.resolved).Count -eq 1) 'Closed edge'}
Require ($r.compile_settings -notcontains '--test' -and $r.compile_settings -notcontains 'test' -and $r.compile_settings -notcontains 'frame_audit' -and $r.source_helper_ledger.extra_residual -eq 0 -and $r.source_parser_prices.excluded_suffix_UTF8_bytes -eq 1064) 'Source cfg ledger'
Check-Identity $r.executable_before;Check-Identity $r.executable_after
Require ((Json $r.executable_before) -ceq (Json $r.executable_after)) 'Executable unchanged'
foreach($child in $r.children){Require ($child.exit_code -eq 0 -and !$child.failure) 'Child completion'}
$n=$r.screen;$raw=$r.children[2].stdout|ConvertFrom-Json -Depth 64 -DateKind String
Require ((Json $raw) -ceq (Json $n)) 'Raw native saved projection'
$h=$n.E2E.happy;$a=$n.E2E.adversarial
Require ($h.initial_readonly_CDFs -eq 24 -and $h.price_table_comparisons -eq 16384 -and $h.finite_events -eq 160 -and $h.full_node_comparisons -eq 8190*161 -and $h.probability_comparisons -eq 640 -and $h.whole_state_same_checked -and $h.root_cut_predictions+$h.deeper_cut_predictions -eq 160) 'Finite oracle'
Require ($a.depth_rejections -eq 3 -and $a.state_rejections -eq 15 -and $a.whole_state_assertions -eq 15 -and $a.CAP_exact_successes -eq 1 -and !$a.reachable_corruption_claimed) 'Finite refusals'
$classes=@(889227,620240,1216305,889227,64372,145969)
$prefixes=@(@(1,1,7,889218),@(97,995,13274,605874),@(23,414566,180,801536),@(1,1,2,889223),@(0,0,7500,56872),@(0,71468,0,74501))
Require ((Json $n.classes) -ceq (Json $classes) -and (Json $n.class_prefixes) -ceq (Json $prefixes) -and (Json $n.tokens) -ceq '[889227,889227]' -and (Json $n.branches) -ceq '[2725772,1099568]' -and [Numerics.BigInteger]$n.grammar -eq [Numerics.BigInteger]::Parse('6373537040327497557')) 'Fixed whole grammar'
$intervals=0L;$branches=0L;$implicit=0L
for($c=0;$c -lt 6;$c++){
 $sum=0L;for($k=1;$k -le 4;$k++){$count=$prefixes[$c][$k-1];$sum+=$count;$intervals+=$k*$count;if($k -eq 1){$implicit+=$count}}
 Require ($sum -eq $classes[$c] -and ($n.primary_selected_depth_counts[$c]|Measure-Object -Sum).Sum -eq $sum -and ($n.primary_full16bit_history[$c] -band 1023) -eq $n.final_last10bit_history[$c] -and $n.primary_observations[$c] -eq $sum) 'Primary census';$branches+=$sum
}
Require ($branches -eq 3825340 -and $implicit -eq 122 -and $n.coded_branches -eq $branches-$implicit -and $n.legal_intervals_checked -eq $intervals -and $n.select_endpoint_checks -eq 2*$intervals -and $n.fixed_Front_walks -eq 1 -and $n.input_reads -eq 1 -and $n.BWT_calls -eq 1) 'Single fixed walk'
Require ([Numerics.BigInteger]$n.actual_pool_entropy_u64 -eq [Numerics.BigInteger]$n.Model_audit_entropy_u64 -and [Numerics.BigInteger]$n.actual_pool_entropy_u64 -eq [Numerics.BigInteger]::Parse('4705461279319865477')) 'Actual CDF loss bits'
foreach($v in @($n.alternate_pool_loss_bits,$n.Model_audit_entropy_bits,($n.component_pool_loss_bits|Measure-Object -Sum).Sum,($n.class_pool_loss_bits|Measure-Object -Sum).Sum)){Require ([double]::IsFinite($v) -and [math]::Abs($v-$n.actual_pool_loss_bits) -le 0.000001) 'Loss aggregation'}
Require ($n.Q_token_bytes_ceil -eq [math]::Ceiling($n.actual_pool_loss_bits/8) -and $n.screen_bytes -eq $n.Q_token_bytes_ceil+3079 -and $n.screen_bytes -eq 480782 -and $n.necessary_size_condition_passed -and $r.size_gate_passed) 'Necessary size screen'
Require ($n.primary_node_size -eq 40 -and $n.primary_capacity_bytes -eq 327664 -and $n.model_working_RAM_estimate_bytes -le 33554432 -and $n.fixed_phase_RAM_estimate_bytes -le 67108864 -and !$n.base_private_Vec_capacities_measured) 'Capacity distinction'
Require ($n.memory.measured -and $n.memory.peak_working_set_bytes -le 167772160 -and $n.memory.peak_private_commit_bytes -le 167772160 -and $r.WS_and_private_commit_gate_passed) 'Both measured peaks'
Require ($n.frame_encodes -eq 0 -and $n.frame_decodes -eq 0 -and !$n.speed_claimed -and !$n.adoption -and !$n.portable_wire_verified -and !$n.regret_claimed) 'Scope'
$entries=@(Get-ChildItem -LiteralPath $work -Force)
Require ($entries.Count -eq 2 -and @($entries|Where-Object {$_.PSIsContainer -or $_.Name -notin @('report.json','causal-hard-cut-o3.exe')}).Count -eq 0) 'Only evidence outputs'
$owned=@(Get-Process|Where-Object {$_.Path -eq $r.executable_after.path}).Count
Require ($owned -eq 0 -and $r.owned_exe_processes -eq 0) 'Owned processes'
$guard=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8
Require ((Get-FileHash -LiteralPath $reportPath).Hash -ceq 'E4CC334310A4426EB9F83E68D9D95D6421747723BCEE2A3F01C29CD346E4B9A0') 'Readonly report unchanged'
[pscustomobject]@{status='verified-readonly';live_before_after_pairs=$pairs;raw_saved_equal=$true;screen_bytes=$n.screen_bytes;size_screen_only=$true;compile_calls=0;native_calls=0;owned_processes=$owned;generated_bytes=$guard.used_bytes;free_bytes=$guard.free_bytes}|ConvertTo-Json
