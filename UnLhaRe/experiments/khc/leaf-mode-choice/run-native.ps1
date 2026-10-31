[CmdletBinding()]
param([switch]$PreflightOnly)
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-leaf-mode-choice-20261005'
$exe=Join-Path $work 'leaf-mode-choice-o3.exe'
$fixedInputPath=Join-Path $project 'build/khc-current-source-native-solid-20260923-group/all.group'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$guard=Join-Path $PSScriptRoot '../disk-budget.ps1'
$helper=Join-Path $PSScriptRoot '../float-fresh-transaction/run-native.ps1'
$frozenSourceRoot=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($helper))
$created=$false
$locks=[Collections.Generic.List[IO.FileStream]]::new();$sources=[Collections.Generic.List[object]]::new();$graph=[Collections.Generic.List[object]]::new();$pins=[Collections.Generic.List[object]]::new()
$report=[ordered]@{status='preflight';children=@();started_utc=[DateTime]::UtcNow.ToString('o');compile_calls=0;total_native_calls=0;frozen_entrypoints_executed=$false;raw_traces=0;disk_frame_plain_input_copies=0;diagnostic_only=$true}
function Need($a,$b,[string]$why){if($a -cne $b){throw $why}}
function Same($a,$b){($a|ConvertTo-Json -Compress -Depth 32) -ceq ($b|ConvertTo-Json -Compress -Depth 32)}
function Near([double]$a,[double]$b){if(![double]::IsFinite($a) -or ![double]::IsFinite($b) -or $a -lt 0 -or $b -lt 0 -or [Math]::Abs($a-$b) -gt 0.000001){throw 'Loss arithmetic'}}
Need (Get-FileHash -LiteralPath $helper).Hash 'A3DCE4B3A5A48897173E1BB34F0025F0A6BB933F6A59F798AAAF24A9559E0D85' 'Helper SHA'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Helper AST'}
foreach($name in @('Identity','Safe-Path','Source','Save-Report','Child')){
 $defs=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Need $defs.Count 1 'Helper definition'
 $text=$defs[0].Extent.Text
 if($name -eq 'Source'){$text=$text.Replace('$PSScriptRoot','$frozenSourceRoot');Need $text.Replace('$frozenSourceRoot','$PSScriptRoot') $defs[0].Extent.Text 'Source helper exact root binding'}
 . ([scriptblock]::Create($text))
}
function Pin([string]$p){$p=Safe-Path $p;if(@($pins|Where-Object path -eq $p).Count){return};$pins.Add((Identity $p));$locks.Add([IO.File]::Open($p,'Open','Read','Read'))}

function NearSigned([double]$a,[double]$b){if(![double]::IsFinite($a) -or ![double]::IsFinite($b) -or [Math]::Abs($a-$b) -gt 0.000001){throw 'Signed loss arithmetic'}}
function Validate-Global($n,$prior){
 Need $n.status 'passed' 'Native status';Need $n.kind 'leaf_mode_choice_cost_screen_only' 'Kind'
 foreach($v in @(@('training_Fit_builds',556),@('high_weighted_rows',854016),@('verification_high_weighted_rows',854016),@('leaf_root_order_bits',0),@('default_root_order_bits',0))){Need $n.($v[0]) $v[1] 'Order census'}
 Need ($n.selected_low_roots+$n.selected_high_roots) 834 'Root choices'
 Need $n.selected_high_roots $n.selected_high_split_roots 'High choices are split roots'
 Need ($n.selected_low_split_roots+$n.selected_high_split_roots) $n.selected_split_roots 'Split choice total'
 Need $n.root_order_bits $n.selected_split_roots 'Paid order bits'
 if($n.selected_split_roots -gt $n.global_explicit_roots -or $n.selected_split_roots -lt 0){throw 'Split order bound'}
 Need @($n.node_root_high_flags).Count 2 'Order components';$highCount=0
 for($c=0;$c -lt 2;$c++){Need @($n.node_root_high_flags[$c]).Count 142 'Order nodes';for($i=0;$i -lt 142;$i++){Need @($n.node_root_high_flags[$c][$i]).Count 3 'Order prefixes';foreach($flag in $n.node_root_high_flags[$c][$i]){if($flag -isnot [bool]){throw 'Order flag type'};if($flag){$highCount++}}}}
 Need $highCount $n.selected_high_roots 'High flags count'
 foreach($v in @(@('distinct_models',278),@('verification_Fit_builds',556),@('total_Fit_builds',1668),@('verification_weighted_rows',854016),@('completed_Forest_Fit_CDF_comparisons',854016),@('LUT_bytes',512),@('length_field_bytes',4),@('global_root_count',834))){Need $n.($v[0]) $v[1] 'Verification census'}
 foreach($v in @(@('LUT_values',256),@('LUT_bytes',512),@('floor_values_checked',16382),@('exact_LUT_roundtrips',256),@('dominant_tie_cases',3),@('pure_cases',9),@('compact_cases',9),@('default_cases',3),@('internal_split_cases',1),@('DP_boundary_cases',2),@('wire_rejections',8),@('exact_root_rejections',4),@('weighted_rejections',7),@('global_rejections',6),@('global_normal_cases',2),@('global_Forest_CDF_comparisons',1708032),@('global_default_bytes',109),@('packet_files_saved',0))){Need $n.E2E.($v[0]) $v[1] 'E2E census'}
 Need $n.E2E.rejection_reasons_verified $true 'Rejection reasons';Need $n.E2E.same_process_recovery $true 'Recovery'
 foreach($v in @(@('history_permutation_values',1024),@('history_unique_values',1024),@('history_inverse_checks',1024),@('symmetric_cases',2),@('symmetric_CDF_comparisons',4096),@('shallow_paid_root_bits',18),@('deep_paid_root_bits',4438),@('prefix_mixed_cases',1),@('prefix_mixed_CDF_comparisons',3072),@('prefix_mixed_global_Forest_CDF_comparisons',854016),@('leaf_default_no_order_prefixes',3),@('extra_order_bit_DP_boundary_cases',1),@('old_split_objective_bits',15),@('new_split_objective_bits',16),@('extra_order_bit_boundary_leaf_loss',16),@('wire_rejections',2))){Need $n.E2E.root_order.($v[0]) $v[1] 'Order E2E census'}
 Need $n.E2E.root_order.rejection_reasons_verified $true 'Order rejection reasons';Need $n.E2E.root_order.same_process_recovery $true 'Order recovery'
 Need (Same $n.E2E.Density_happy $prior.screen.E2E.Density_happy) $true 'Density happy'
 Need (Same $n.E2E.Density_adversarial $prior.screen.E2E.Density_adversarial) $true 'Density adversarial'
 foreach($v in @(@('input_reads',1),@('BWT_calls',1),@('fixed_Front_walks',2),@('runs',889227),@('primary',1762795),@('escape_bytes',742),@('history_checks_per_walk',1778454),@('coded_branches',3825218),@('implicit_prefix1_branches',122),@('weighted_rows',854016),@('weighted_root_comparisons',1668),@('Fit_individual_parse_CDF_comparisons',854016),@('model_count',278),@('teacher_models_executed',0),@('frame_encodes',0),@('frame_decodes',0),@('raw_event_Vecs',0),@('parameter_sweeps',0),@('side_bytes',3079))){Need $n.($v[0]) $v[1] 'Census'}
 foreach($field in @('tokens','grammar','branches','classes','class_prefixes','final_last10bit_history','selected_mask','selected_node_counts','selected_coded_counts')){Need (Same $n.$field $prior.screen.$field) $true "Original Meta/mask $field"}
 Need $n.whole_two_walk_Meta_equal $true 'Meta direct equality'
 foreach($f in @('teacher_state_preservation_verified','speed_claimed','portable_wire_verified','adoption')){Need $n.$f $false 'Claim boundary'}
 Need $n.trained_in_sample_only $true 'In-sample'
 Near $n.teacher_nonselected_loss_bits $prior.screen.teacher_nonselected_loss_bits
 for($c=0;$c -lt 2;$c++){Near $n.free_component_loss_bits[$c] $prior.screen.free_component_loss_bits[$c]}
 Need @($n.nodes).Count 2 'Node components'
 $objective=0L;$oracle=0L;$models=0;$dp=0.0;$parsed=0.0;$original=0.0;$delta=0.0
 for($c=0;$c -lt 2;$c++){
  Need @($n.nodes[$c]).Count 142 'Node extent';$count=0L;$compDP=0.0;$compParsed=0.0;$compFree=0.0
  foreach($row in $n.nodes[$c]){
   Need @($row).Count 8 'Node width';for($i=0;$i -lt 7;$i++){if(![double]::IsFinite($row[$i]) -or $row[$i] -lt 0){throw 'Node nonnegative finite'}}
   if(![double]::IsFinite($row[7])){throw 'Signed delta finite'}
   Near $row[3] $row[4];NearSigned ($row[3]-$row[6]) $row[7]
   $count+=$row[0];$objective+=$row[1];$oracle+=$row[2];if($row[2]){$models++}
   $compDP+=$row[3];$compParsed+=$row[4];$compFree+=$row[5];$original+=$row[6];$delta+=$row[7]
  }
  Need $count $n.selected_coded_counts[$c] 'Component count'
  Near $compDP $n.DP_component_loss_bits[$c];Near $compParsed $n.parsed_component_loss_bits[$c];Near $compFree $n.free_component_loss_bits[$c]
  Near $compParsed $n.parsed_class_loss_bits[$c*3+2];$dp+=$compDP;$parsed+=$compParsed
 }
 Need $models 278 'Selected models'
 Near $dp $n.DP_selected_loss_bits;Near $parsed $n.parsed_selected_loss_bits
 Need $objective $n.global_DP_internal_bits 'DP internal bits'
 Need $n.root_outer_flag_bits 834 'Outer flags';Need ($objective+834) $n.header_effective_bits 'DP/actual bits'
 Need $oracle ($objective+3*$n.global_default_roots) 'Oracle/default bit distinction'
 Need $n.concatenated_root_bits_directly_compared $objective 'Explicit root all bits compared'
 Need ($n.global_default_roots+$n.global_explicit_roots) 834 'Tags'
 Near $original $n.same_selected_tree_original_Q_loss_bits;NearSigned $delta $n.approx_selected_loss_delta_bits
 NearSigned ($parsed-$original) $delta
 Near $n.combined_loss_bits ($parsed+$n.teacher_nonselected_loss_bits)
 Need $n.Q_token_bytes_ceil ([Math]::Ceiling($n.combined_loss_bits/8)) 'Token ceil'
 Need $n.bundle_bytes (134+[Math]::Ceiling($n.header_effective_bits/8)) 'Actual header'
 Need $n.global_padding_bits (($n.bundle_bytes-134)*8-$n.header_effective_bits) 'Padding'
 if($n.global_padding_bits -lt 0 -or $n.global_padding_bits -gt 7){throw 'Padding bounds'}
 Need $n.screen_bytes ($n.Q_token_bytes_ceil+$n.bundle_bytes+3079) 'Total screen'
 $leafRoots=$n.global_explicit_roots-$n.selected_split_roots
 if($n.nondefault_leaf_root_internal_bits -lt 3*$leafRoots -or $n.nondefault_leaf_root_internal_bits -gt 61*$leafRoots){throw 'Unordered explicit leaf fees'}
 if($n.node_report_utf8_bytes -gt 32000 -or $n.node_report_utf8_bytes -le 0){throw 'Node JSON bound'}
 Need $n.necessary_size_condition_passed ($n.screen_bytes -le 483599) 'Information condition'
 if($n.model_working_RAM_estimate_bytes -gt 33554432 -or $n.fixed_phase_RAM_estimate_bytes -gt 67108864 -or $n.scratch_capacity_bytes -gt 65536 -or $n.fit_node_size -gt 32){throw 'RAM bounds'}
 Need $n.max_Hist_capacity_bytes ($n.max_high_Hist_capacity_bytes*2) 'Both Hist capacities'
 if($n.max_Fit_capacity_bytes -lt $n.max_high_Fit_capacity_bytes*2 -or $n.max_Fit_capacity_bytes -gt $n.max_high_Fit_capacity_bytes*4){throw 'Paid/baseline Fit capacity bound'}
 Near $n.model_working_RAM_estimate_bytes ($n.dense_capacity_bytes+$n.Forest_capacity_bytes+$n.max_Hist_capacity_bytes+$n.max_Fit_capacity_bytes+$n.max_Dispatch_capacity_bytes+$n.max_packet_capacity_bytes+$n.bundle_capacity_bytes+$n.scratch_capacity_bytes+4194304+512)
 Near $n.fixed_phase_RAM_estimate_bytes ($n.model_working_RAM_estimate_bytes+$n.run_capacity*12+$n.input_capacity+1369112+4194304)
 Need $n.BWT_phase_RAM_estimate_bytes 141598926 'BWT phase'
 $m=$n.memory;Need $m.API_calls 1 'API calls';Need $m.ABI_size 80 'ABI';Need $m.ABI_cb 80 'cb';Need $m.ABI_checked $true 'Layout';Need $m.measured $true 'Measured'
 if($null -ne $m.last_OS_error -or $m.peak_working_set_bytes -le 0 -or $m.peak_private_commit_bytes -le 0 -or $m.peak_working_set_bytes -gt 167772160 -or $m.peak_private_commit_bytes -gt 167772160){throw 'OS memory'}
}

function Validate-Paid($n,$prior){
 . (Join-Path $PSScriptRoot '../paid-code-tree/verify-book.ps1')
 $minorPath=Join-Path $project 'build/khc-header-minor-census-20261005/report.json'
 Need (Identity $minorPath).sha256 'BC00DC11E643D3F71664E2306FD588DCFDEAB340B74CE4D372F6A38E2C914A55' 'Independent histogram source'
 $minor=Get-Content -Raw -LiteralPath $minorPath|ConvertFrom-Json -Depth 64 -DateKind String
 $book=Expected-Book $minor
 Need (Same $n.book_lengths $book.lengths) $true 'Independent fixed 257 lengths'
 Need $book.canonical.table_sha256 '32DAED5A6DAC9EF7440A72CF6259980F9B15A8A659EF4316EA57C86730C30077' 'Packed table identity'
 foreach($v in @(@('codec_flag_bytes',1),@('length_table_bytes',129),@('metadata_prefix_bytes',134),@('baseline_repriced_payload_bits',21256),@('baseline_repriced_header_bytes',2791),@('baseline_Q_token_bytes',478416),@('baseline_screen_bytes',484286),@('baseline_minor_count',2312),@('baseline_ESC_count',0),@('baseline_repricing_passes',556),@('baseline_repricing_root_scans',1668),@('baseline_repricing_CDF_comparisons',1708032),@('baseline_training_Fit_builds',556),@('paid_training_Fit_builds',556),@('paid_verification_Fit_builds',556))){Need $n.($v[0]) $v[1] 'Paid census'}
 Near $n.baseline_selected_loss_bits $prior.screen.DP_selected_loss_bits
 Need $n.baseline_repriced_payload_bits $prior.screen.header_effective_bits 'Frozen paid baseline bits'
 Need $n.baseline_repriced_header_bytes $prior.screen.bundle_bytes 'Frozen paid baseline bytes'
 Need $n.estimated_cost_only $false 'Actual codec required'
 foreach($f in @('header_entropy_encoder_implemented','header_entropy_decoder_verified','codec_dropped_before_report')){Need $n.$f $true 'Codec implementation boundary'}
 foreach($v in @(@('canonical_symbol_comparisons',257),@('minor_roundtrips',256),@('known_symbols',183),@('unknown_symbols',73),@('ESC_length',11),@('unknown_fee_bits',19),@('all_mode_dominant_root_cases',21),@('finite_root_CDF_comparisons',23552),@('root_rejections',12),@('table_header_rejections',13),@('finite_Forest_CDF_comparisons',1708032),@('paid_Fit_builds',11),@('baseline_Fit_builds',1),@('baseline_repricing_passes',1),@('baseline_root_scans',1),@('baseline_CDF_comparisons',1024),@('book_redundant_ESC_rejections',1),@('book_truncation_rejections',4),@('book_table_rejections',4),@('paid_boundary_old_split_bits',50),@('paid_boundary_repriced_split_bits',48),@('paid_boundary_new_leaf_bits',9))){Need $n.paid_E2E.($v[0]) $v[1] 'Paid finite E2E census'}
 foreach($f in @('rejection_reasons_verified','same_process_recovery','wire_table_used','entropy_encoder_implemented','entropy_decoder_verified','RAM_only')){Need $n.paid_E2E.$f $true 'Paid finite proof'}
 if($n.baseline_node_objective_comparisons -lt 1668 -or $n.baseline_node_objective_comparisons -gt 1668*1365){throw 'Baseline direct node comparisons'}
 if($n.selected_minor_known_count -lt 0 -or $n.selected_ESC_count -lt 0 -or ($n.selected_minor_known_count+$n.selected_ESC_count) -gt 3*$n.selected_compact_leaves){throw 'Minor count bound'}
 Need $n.token_byte_delta_from_repriced_baseline ($n.Q_token_bytes_ceil-478416) 'Actual token byte delta'
 Need $n.header_byte_delta_from_repriced_baseline ($n.bundle_bytes-2791) 'Actual header byte delta'
 Need $n.ESC_count_delta_from_repriced_baseline $n.selected_ESC_count 'ESC delta'
 Need $n.header_payload_delta_bits_from_repriced_baseline ($n.header_effective_bits-21256) 'Payload delta'
 NearSigned $n.token_loss_delta_bits_from_repriced_baseline ($n.DP_selected_loss_bits-$n.baseline_selected_loss_bits)
 NearSigned $n.objective_delta_bits_from_repriced_baseline ($n.DP_selected_loss_bits+$n.header_effective_bits-$n.baseline_selected_loss_bits-21256)
 if($n.objective_delta_bits_from_repriced_baseline -gt 0.000001){throw 'Paid global objective worsened'}
 Need $n.encoder_capacity_bytes 772 'Encoder fixed arrays'
 Need $n.table_decoder_capacity_bytes 3366 'Decoder trie reservation'
 Need $n.table_decoder_trie_nodes 367 'Decoder complete 184-leaf tree'
 Need $n.codec_peak_capacity_bytes ($n.encoder_capacity_bytes+2*$n.table_decoder_capacity_bytes+257*8+256) 'Concurrent codec buffers'
 Need $n.max_baseline_Fit_capacity_bytes ($n.max_high_Fit_capacity_bytes*2) 'Two baseline Fit capacities'
 if($n.codec_phase_scratch_capacity_bytes -le 0 -or $n.codec_phase_scratch_capacity_bytes -gt 65536){throw 'Codec scratch bound'}
 Near $n.codec_peak_model_RAM_estimate_bytes ($n.dense_capacity_bytes+$n.Forest_capacity_bytes+$n.max_Hist_capacity_bytes+$n.max_Fit_capacity_bytes+$n.max_baseline_Fit_capacity_bytes+$n.max_Dispatch_capacity_bytes+$n.max_packet_capacity_bytes+$n.bundle_capacity_bytes+$n.codec_phase_scratch_capacity_bytes+$n.codec_peak_capacity_bytes+4194304+512)
 Near $n.codec_peak_phase_RAM_estimate_bytes ($n.codec_peak_model_RAM_estimate_bytes+$n.run_capacity*12+$n.input_capacity+1369112+4194304)
 if($n.codec_peak_model_RAM_estimate_bytes -gt 33554432 -or $n.codec_peak_phase_RAM_estimate_bytes -gt 67108864){throw 'Actual concurrent codec RAM bounds'}
 Need ($n.selected_uniform_leaves+$n.selected_pure_leaves+$n.selected_compact_leaves) $n.selected_leaves 'Mode partition'
 Need $n.selected_leaves (3*$n.selected_splits+834) 'Quaternary tree partition'
 Need $n.peak_resource_gate_passed $true 'Measured OS memory gate'
}
function Validate-LeafChoice($n,$prior){
 throw 'Leaf choice validator pending READY contract'
}
try{
 $null=Safe-Path $work;if(Test-Path -LiteralPath $work){throw 'Unused output required'}
 $null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Runner AST'}
 Source (Join-Path $PSScriptRoot 'probe.rs');Need $sources.Count 21 'Source closure';Need $graph.Count 20 'Source edges'
 $report.sources_before=@($sources);$report.imports=@($graph);$report.source_count=$sources.Count;$report.source_bytes=[long](($sources|Measure-Object bytes -Sum).Sum)
 foreach($s in $sources){if([IO.File]::ReadAllText($s.path) -match '#\[global_allocator\]'){throw 'Custom allocator'}}
 $priorPath=Join-Path $project 'build/khc-paid-code-tree-20261005/report.json'
 Need (Identity $priorPath).sha256 '1A244D67F80617B92812E715C2CA45394144CA51D59A45E6D1D8703F5711C116' 'Prior report'
 $prior=Get-Content -Raw -LiteralPath $priorPath|ConvertFrom-Json -Depth 64 -DateKind String;Need $prior.status 'diagnostic-passed' 'Prior status'
 foreach($kind in @('sources','identities')){
  $a=@($prior.($kind+'_before'));$b=@($prior.($kind+'_after'));Need $a.Count $b.Count 'Prior pairs'
  for($i=0;$i -lt $a.Count;$i++){if(!(Same $a[$i] $b[$i]) -or !(Same $a[$i] (Identity $a[$i].path))){throw 'Prior before/after/live'};Pin $a[$i].path}
 }
 $a=$prior.executable_before;Need (Same $a $prior.executable_after) $true 'Prior artifact';Need (Same $a (Identity $a.path)) $true 'Prior artifact live';Pin $a.path
 $plan=Join-Path $PSScriptRoot '../LEAF_MODE_CHOICE_PLAN_20261005.md';Need (Identity $plan).sha256 '04B0E1E8910C2093AC290CB9A60414F8A4A7F397FBFA6B1610162562C1E5985E' 'PLAN'
 foreach($v in @(
 @('FAILURE_PLAN.md','PENDING_FAILURE_SHA'),
 @('model.rs','PENDING_MODEL_SHA'),
 @('e2e.rs','PENDING_E2E_SHA'),
 @('probe.rs','PENDING_PROBE_SHA')
 )){Need (Identity (Join-Path $PSScriptRoot $v[0])).sha256 $v[1] 'Candidate SHA';Pin (Join-Path $PSScriptRoot $v[0])}
 foreach($f in @('model.rs','bundle.rs','e2e.rs')){
  $p=Safe-Path (Join-Path $PSScriptRoot ("../root-history-order/"+$f))
  Need @($sources|Where-Object path -eq $p).Count 1 'Frozen source directly referenced'
 }
 foreach($f in @('model.rs','codebook.rs','bundle.rs','e2e.rs')){
  $p=Safe-Path (Join-Path $PSScriptRoot ("../paid-code-tree/"+$f))
  Need @($sources|Where-Object path -eq $p).Count 1 'Paid frozen source directly referenced'
 }
 $report.frozen_model_source_directly_referenced=$true
 foreach($p in @($PSCommandPath,$helper,$guard,$compiler,(Get-Process -Id $PID).Path,$fixedInputPath,$priorPath,$plan,(Join-Path $PSScriptRoot '../LEAF_MODE_CHOICE_AUDIT_20261005.md'),(Join-Path $PSScriptRoot '../paid-code-tree/verify-result.ps1'),(Join-Path $PSScriptRoot '../paid-code-tree/verify-book.ps1'))){Pin $p}
 $report.identities_before=@($pins)
 Need (Identity $fixedInputPath).sha256 '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76' 'Input';Need (Identity $compiler).sha256 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC' 'Compiler';Need (Identity (Get-Process -Id $PID).Path).sha256 '362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139' 'PowerShell'
 if($report.source_bytes+(Identity $plan).bytes+(Identity (Join-Path $PSScriptRoot 'FAILURE_PLAN.md')).bytes -gt 358400){throw 'Sources capacity'}
 if(![OperatingSystem]::IsWindows() -or [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() -cne 'X64'){throw 'Windows x64'}
 $teacher=$prior.screen.teacher_nonselected_loss_bits;$free=$prior.screen.free_component_loss_bits
 $lossArguments=@($teacher.ToString('R',[Globalization.CultureInfo]::InvariantCulture),$free[0].ToString('R',[Globalization.CultureInfo]::InvariantCulture),$free[1].ToString('R',[Globalization.CultureInfo]::InvariantCulture))
 $report.roundtrip_loss_arguments=$lossArguments
 $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8
 if(!$PreflightOnly){
  $null=New-Item -ItemType Directory -Path $work;$created=$true;$report.status='running';Save-Report
  $v=Child $compiler @('--version') 60;Need $v.stdout 'rustc 1.98.1 (48a229cea 2026-09-01)' 'Compiler version'
  $report.compile_settings=@('--edition=2024','--cfg','frame_audit','--cfg','primitive_audit','-C','opt-level=3','-C','lto=thin','-C','codegen-units=1','-C','panic=unwind','-C','overflow-checks=yes','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE');$report.compile_calls=1
  $null=Child $compiler (@((Join-Path $PSScriptRoot 'probe.rs'))+$report.compile_settings+@('-o',$exe)) 60
  $report.executable_before=Identity $exe;if($report.executable_before.bytes -gt 1048576){throw 'EXE capacity'};$locks.Add([IO.File]::Open($exe,'Open','Read','Read'))
  $report.total_native_calls=1;$native=Child $exe (@('screen',$fixedInputPath)+$lossArguments) 120;if($native.stderr){throw 'Native stderr'}
  Need @($native.stdout -split "\n"|Where-Object {$_}).Count 1 'Raw JSON records'
  $n=$native.stdout|ConvertFrom-Json -Depth 64 -DateKind String;$report.screen=$n;Save-Report;Validate-Global $n $prior;Validate-Paid $n $prior;Validate-LeafChoice $n $prior
  $report.original_full_Meta_equal=$true;$report.free_Q_predecessor_equal=$true
  $report.executable_after=Identity $exe;if(!(Same $report.executable_before $report.executable_after)){throw 'EXE changed'}
  $report.owned_exe_processes=@(Get-Process|Where-Object Path -eq $exe).Count;Need $report.owned_exe_processes 0 'Owned processes'
  $files=@(Get-ChildItem -LiteralPath $work -Force);Need $files.Count 2 'Output count';if(@($files|Where-Object {$_.PSIsContainer -or $_.FullName -notin @($exe,(Join-Path $work 'report.json')) -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'Output shape'}
  $report.status='diagnostic-passed'
 }else{$report.status='preflight-passed'}
}catch{$report.status='failed';$report.error=$_.Exception.Message;throw}finally{
 try{
  $report.sources_after=@($sources|ForEach-Object {$now=Identity $_.path;if(!(Same $_ $now)){throw 'Source changed'};$now})
  $report.identities_after=@($pins|ForEach-Object {$now=Identity $_.path;if(!(Same $_ $now)){throw 'Pin changed'};$now})
  $report.ended_utc=[DateTime]::UtcNow.ToString('o');$report.disk_after=& $guard -WorkDirectory $work -MaxRunMiB 8;Save-Report;$finalGuard=& $guard -WorkDirectory $work -MaxRunMiB 8
 }finally{foreach($stream in $locks){$stream.Dispose()}}
}
[pscustomobject]@{status=$report.status;source_count=$report.source_count;source_bytes=$report.source_bytes;identity_count=$pins.Count;compile_calls=$report.compile_calls;native_calls=$report.total_native_calls;screen_bytes=$report.screen.screen_bytes;disk=$finalGuard}|ConvertTo-Json -Depth 5







