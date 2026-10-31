[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-hard-cut-model-lazy-20261004'
$reportPath=Join-Path $work 'report.json'
function Require([bool]$ok,[string]$why){if(!$ok){throw $why}}
function Json($v){ConvertTo-Json -InputObject $v -Compress -Depth 64}
function Check-Identity($v){
 $p=[IO.Path]::GetFullPath($v.path);$a=$p
 while($a){if(Test-Path -LiteralPath $a){Require (!((Get-Item -LiteralPath $a -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Reparse ancestor'};$a=[IO.Path]::GetDirectoryName($a)}
 $i=Get-Item -LiteralPath $p -Force
 Require (!$i.PSIsContainer -and $i.Length -eq $v.bytes -and (Get-FileHash -LiteralPath $p).Hash -ceq $v.sha256 -and $i.LastWriteTimeUtc.ToString('o') -ceq $v.mtime_utc) 'Live identity'
}
Require ((Get-FileHash -LiteralPath $reportPath).Hash -ceq '62B93E3FF942CEB13ECD6572DAD6CDBBE4DD45F88B72512E9348BBA4812BBEF3') 'Report SHA'
$r=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json -Depth 64 -DateKind String
Require ($r.status -ceq 'diagnostic-passed' -and $r.compile_calls -eq 1 -and $r.total_native_calls -eq 2 -and $r.children.Count -eq 4) 'Execution census'
$pairs=0
foreach($kind in @('sources','identities')){
 $before=@($r.($kind+'_before'));$after=@($r.($kind+'_after'));Require ($before.Count -eq $after.Count -and $before.Count -gt 0) 'Pair extent'
 for($i=0;$i -lt $before.Count;$i++){Require ((Json $before[$i]) -ceq (Json $after[$i])) 'Before-after';Check-Identity $before[$i];$pairs++}
}
Require ($r.sources_before.Count -eq 18 -and $r.imports.Count -eq 17 -and ($r.sources_before|Measure-Object bytes -Sum).Sum -eq 108822) 'Source extent'
foreach($edge in $r.imports){Require (@($r.sources_before|Where-Object path -ceq $edge.source).Count -eq 1 -and @($r.sources_before|Where-Object path -ceq $edge.resolved).Count -eq 1) 'Closed edge'}
Require ($r.compile_settings -contains 'wire_audit') 'Wire cfg'
foreach($cfg in @('test','--test','frame_audit','primary_audit','primitive_audit')){Require ($r.compile_settings -notcontains $cfg) 'Disabled cfg'}
Require ($r.codec_ledger.extra_residual -eq 0 -and $r.codec_ledger.allowed_replacements -eq 5 -and $r.codec_ledger.numerical_processing_unchanged -and $r.e2e_ledger.extra_residual -eq 0 -and $r.e2e_ledger.old_model_rejections_executed -eq 0 -and $r.source_helper_ledger.extra_residual -eq 0 -and $r.source_parser_prices.excluded_suffix_UTF8_bytes -eq 1064) 'Connection ledgers'
Check-Identity $r.executable_before;Check-Identity $r.executable_after
Require ((Json $r.executable_before) -ceq (Json $r.executable_after)) 'Executable unchanged'
foreach($child in $r.children){Require ($child.exit_code -eq 0 -and !$child.failure -and !$child.stderr) 'Child completion'}
Require ((Json ($r.children[2].stdout|ConvertFrom-Json -Depth 64 -DateKind String)) -ceq (Json $r.selfcheck)) 'Raw selfcheck projection'
Require ((Json ($r.children[3].stdout|ConvertFrom-Json -Depth 64 -DateKind String)) -ceq (Json $r.fixed)) 'Raw fixed projection'
$h=$r.selfcheck.E2E;$n=$r.fixed;$st=$n.encode_stats
Require ($h.normal_cases -eq 14 -and $h.byte_roundtrips -eq 14 -and $h.canonical_cases -eq 14 -and $h.malformed_cases -eq 34 -and $h.malformed.Count -eq 34 -and $h.short_depth_header_checks -eq 4 -and $h.CRC32_known_fixture -and $h.LCG_seed -eq 1831565813) 'Finite census'
Require (@($h.malformed|Select-Object -ExpandProperty name -Unique).Count -eq 34 -and @($h.malformed|Where-Object {$_.name -ceq 'old_float_magic' -and $_.reason -ceq 'bad frame magic/header'}).Count -eq 1) 'Malformed names'
Require ($n.status -ceq 'passed' -and $n.input_reads -eq 1 -and $n.encode_calls -eq 1 -and $n.decode_calls -eq 1 -and $n.fixed_reencode_calls -eq 0 -and $n.validate_fixed_calls -eq 2 -and $n.matched_plain_bytes -eq 2811006 -and $n.all_plain_bytes_compared -and $n.typed_Proof14_Eq -and $n.encode_decode_full_stats_equal -and $n.header_layout_and_CRC_checked) 'Fixed direct checks'
Require ((Json $n.encode_stats) -ceq (Json $n.decode_stats)) 'Full stats'
Require ($n.new_magic -ceq 'KHQCHC01' -and $st.magic -ceq 'KHQCHC01' -and $st.runs -eq 889227 -and $st.primary -eq 1762795 -and $st.alphabet_symbols -eq 257 -and $st.rank_intervals -eq 889227 -and $st.length_intervals -eq 889227 -and $st.escape_bytes -eq 742 -and $st.plain_crc -eq 433441561 -and $st.grammar_digest -ceq '58735a2b7383d755' -and $st.base_pool_digest -ceq 'da077ab1cae3229f') 'Fixed grammar'
Require ((Json $st.branches) -ceq '[2725772,1099568]' -and (Json $st.class_observations) -ceq '[889227,620240,1216305,889227,64372,145969]') 'Whole counts'
Require ($n.Proof14_debug.EndsWith('cdf_bits: 4705461279319865477 }')) 'Exact CDF bits'
Require ($n.frame_bytes -eq 478856 -and $n.header_bytes -eq 285 -and $n.payload_bytes -eq 478571 -and $n.frame_bytes -eq $n.header_bytes+$n.payload_bytes -and $n.frame_bytes -eq $st.frame_bytes -and $n.size_gate_passed -and $n.size_gate_limit_bytes -eq 483599 -and $n.frame_bytes -le 483599) 'Actual size'
Require ($n.actual_main_data_Vec_capacity_bytes -eq $n.input_capacity+$n.frame_capacity+$n.restored_plain_capacity -and $n.primary_source_bound_bytes -eq 8190*$n.primary_node_size+65536 -and $st.node_storage_bytes -eq 8190*$n.primary_node_size) 'Capacity arithmetic'
Require ($n.model_working_RAM_estimate_bytes -eq 16777216+$n.primary_source_bound_bytes+3*65536+4194304 -and $n.encoder_phase_RAM_estimate_bytes -eq $n.input_capacity+2*2811007+1048576*12+1048576+1048861+$n.model_working_RAM_estimate_bytes -and $n.inverse_phase_RAM_estimate_bytes -eq $n.input_capacity+$n.frame_capacity+14*2811007+65536+4194304) 'Source RAM arithmetic'
Require ($n.fixed_phase_RAM_estimate_bytes -eq [math]::Max($n.encoder_phase_RAM_estimate_bytes,[math]::Max($n.inverse_phase_RAM_estimate_bytes,$n.actual_main_data_Vec_capacity_bytes+4194304)) -and $n.model_working_RAM_estimate_bytes -le 33554432 -and $n.fixed_phase_RAM_estimate_bytes -le 67108864) 'Phase limits'
foreach($m in @($r.selfcheck.memory,$n.memory)){Require ($m.measured -and $m.ABI_checked -and $m.API_calls -eq 1 -and $m.ABI_size -eq 80 -and $m.ABI_cb -eq 80 -and $null -eq $m.last_OS_error -and $m.peak_working_set_bytes -gt 0 -and $m.peak_working_set_bytes -le 167772160 -and $m.peak_private_commit_bytes -gt 0 -and $m.peak_private_commit_bytes -le 167772160) 'Both measured peaks'}
foreach($field in @('speed_claimed','portable_wire_verified','adoption','primary_whole_state_comparison_claimed','old_teacher_numerical_equality_required')){Require (!$n.$field) 'Nonclaim'}
Require ($n.disk_frames -eq 0 -and $n.disk_restores -eq 0 -and $n.raw_event_Vecs -eq 0 -and $r.owned_exe_processes -eq 0) 'No large copies/process'
$files=@(Get-ChildItem -LiteralPath $work -Force)
Require ($files.Count -eq 2 -and @($files|Where-Object {$_.PSIsContainer -or $_.Name -notin @('report.json','hard-cut-model-lazy-o3.exe')}).Count -eq 0 -and ($files|Measure-Object Length -Sum).Sum -eq 524686) 'Output shape'

Require ($pairs -eq 149 -and $r.identities_before.Count -eq 131) 'Complete pair census'
Require (!$r.custom_allocator_linked -and !$r.normal_graph_custom_global_allocator -and !$r.normal_graph_compare -and !$r.primary_collector_cfg_enabled -and !$r.normal_binary_old_frame_directly_compared) 'Normal binary and nonclaim'
$oldPath=Join-Path $project 'build/khc-causal-hard-cut-wire-20261004/report.json'
Require ((Get-FileHash -LiteralPath $oldPath).Hash -ceq 'B24F7E1953CD556BF14E3EB2191E6D043A832EB5002624BDD18C4202DF635871') 'Frozen report'
$old=Get-Content -LiteralPath $oldPath -Raw|ConvertFrom-Json -Depth 64 -DateKind String
Require ((Json $h) -ceq (Json $old.selfcheck.E2E) -and (Json $st) -ceq (Json $old.fixed.encode_stats) -and $n.Proof14_debug -ceq $old.fixed.Proof14_debug) 'Frozen E2E stats Proof'
Require ($r.current_single_diagnostic_ms.encode -eq $n.diagnostic_encode_ns/1000000.0 -and $r.current_single_diagnostic_ms.decode -eq $n.diagnostic_decode_ns/1000000.0) 'Diagnostic projection'


Require ($r.model_ledger.allowed_replacements -eq 3 -and $r.model_ledger.extra_residual -eq 0 -and $r.model_ledger.math_state_order_clone_error_text_unchanged -and $r.connection_ledger.codec_model_path_replacements -eq 1 -and $r.connection_ledger.scope_codec_path_replacements -eq 1 -and $r.connection_ledger.adapter_replacements -eq 0 -and $r.connection_ledger.probe_replacements -eq 0 -and $r.connection_ledger.extra_residual -eq 0 -and $r.runner_prefix_ledger.output_binding_replacements -eq 2 -and $r.runner_prefix_ledger.extra_residual -eq 0) 'New ledgers'
$normalPath=Join-Path $project 'build/khc-hard-cut-lazy-wire-20261004/report.json'
Require ((Get-FileHash -LiteralPath $normalPath).Hash -ceq '3827A0AA200CF655B0F0DE816DAFB4817637ABA296318A5E677A923AB653F75B') 'Normal predecessor SHA'
$normal=Get-Content -LiteralPath $normalPath -Raw|ConvertFrom-Json -Depth 64 -DateKind String
Require ((Json $h) -ceq (Json $normal.selfcheck.E2E) -and (Json $st) -ceq (Json $normal.fixed.encode_stats) -and $n.Proof14_debug -ceq $normal.fixed.Proof14_debug) 'Normal predecessor full values'

[pscustomobject]@{status='readonly-verified';identity_pairs=$pairs;raw_projections=2;frame_bytes=$n.frame_bytes;size_margin_bytes=483599-$n.frame_bytes;compile_calls=0;native_calls=0;generated_bytes=524686}|ConvertTo-Json
