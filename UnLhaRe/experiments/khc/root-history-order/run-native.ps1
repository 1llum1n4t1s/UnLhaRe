[CmdletBinding()]
param([switch]$PreflightOnly)
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-root-history-order-20261005'
$exe=Join-Path $work 'root-history-order-o3.exe'
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
 Need $n.status 'passed' 'Native status';Need $n.kind 'root_history_order_cost_screen_only' 'Kind'
 foreach($v in @(@('training_Fit_builds',556),@('high_weighted_rows',854016),@('verification_high_weighted_rows',854016),@('leaf_root_order_bits',0),@('default_root_order_bits',0))){Need $n.($v[0]) $v[1] 'Order census'}
 Need ($n.selected_low_roots+$n.selected_high_roots) 834 'Root choices'
 Need $n.selected_high_roots $n.selected_high_split_roots 'High choices are split roots'
 Need ($n.selected_low_split_roots+$n.selected_high_split_roots) $n.selected_split_roots 'Split choice total'
 Need $n.root_order_bits $n.selected_split_roots 'Paid order bits'
 if($n.selected_split_roots -gt $n.global_explicit_roots -or $n.selected_split_roots -lt 0){throw 'Split order bound'}
 Need @($n.node_root_high_flags).Count 2 'Order components';$highCount=0
 for($c=0;$c -lt 2;$c++){Need @($n.node_root_high_flags[$c]).Count 142 'Order nodes';for($i=0;$i -lt 142;$i++){Need @($n.node_root_high_flags[$c][$i]).Count 3 'Order prefixes';foreach($flag in $n.node_root_high_flags[$c][$i]){if($flag -isnot [bool]){throw 'Order flag type'};if($flag){$highCount++}}}}
 Need $highCount $n.selected_high_roots 'High flags count'
 foreach($v in @(@('distinct_models',278),@('verification_Fit_builds',556),@('total_Fit_builds',1112),@('verification_weighted_rows',854016),@('completed_Forest_Fit_CDF_comparisons',854016),@('LUT_bytes',512),@('length_field_bytes',4),@('global_root_count',834))){Need $n.($v[0]) $v[1] 'Verification census'}
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
 Need $n.bundle_bytes (4+[Math]::Ceiling($n.header_effective_bits/8)) 'Actual header'
 Need $n.global_padding_bits (($n.bundle_bytes-4)*8-$n.header_effective_bits) 'Padding'
 if($n.global_padding_bits -lt 0 -or $n.global_padding_bits -gt 7){throw 'Padding bounds'}
 Need $n.screen_bytes ($n.Q_token_bytes_ceil+$n.bundle_bytes+3079) 'Total screen'
 $leafRoots=$n.global_explicit_roots-$n.selected_split_roots
 if($n.nondefault_leaf_root_internal_bits -lt 4*$leafRoots -or $n.nondefault_leaf_root_internal_bits -gt 29*$leafRoots){throw 'Unordered explicit leaf fees'}
 if($n.node_report_utf8_bytes -gt 35000 -or $n.node_report_utf8_bytes -le 0){throw 'Node JSON bound'}
 Need $n.necessary_size_condition_passed ($n.screen_bytes -le 483599) 'Information condition'
 if($n.model_working_RAM_estimate_bytes -gt 33554432 -or $n.fixed_phase_RAM_estimate_bytes -gt 67108864 -or $n.scratch_capacity_bytes -gt 65536 -or $n.fit_node_size -gt 32){throw 'RAM bounds'}
 Need $n.max_Hist_capacity_bytes ($n.max_high_Hist_capacity_bytes*2) 'Both Hist capacities'
 Need $n.max_Fit_capacity_bytes ($n.max_high_Fit_capacity_bytes*2) 'Both Fit capacities'
 Near $n.model_working_RAM_estimate_bytes ($n.dense_capacity_bytes+$n.Forest_capacity_bytes+$n.max_Hist_capacity_bytes+$n.max_Fit_capacity_bytes+$n.max_Dispatch_capacity_bytes+$n.max_packet_capacity_bytes+$n.bundle_capacity_bytes+$n.scratch_capacity_bytes+4194304+512)
 Near $n.fixed_phase_RAM_estimate_bytes ($n.model_working_RAM_estimate_bytes+$n.run_capacity*12+$n.input_capacity+1369112+4194304)
 Need $n.BWT_phase_RAM_estimate_bytes 141598926 'BWT phase'
 $m=$n.memory;Need $m.API_calls 1 'API calls';Need $m.ABI_size 80 'ABI';Need $m.ABI_cb 80 'cb';Need $m.ABI_checked $true 'Layout';Need $m.measured $true 'Measured'
 if($null -ne $m.last_OS_error -or $m.peak_working_set_bytes -le 0 -or $m.peak_private_commit_bytes -le 0 -or $m.peak_working_set_bytes -gt 167772160 -or $m.peak_private_commit_bytes -gt 167772160){throw 'OS memory'}
}

try{
 $null=Safe-Path $work;if(Test-Path -LiteralPath $work){throw 'Unused output required'}
 $null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Runner AST'}
 Source (Join-Path $PSScriptRoot 'probe.rs');Need $sources.Count 15 'Source closure';Need $graph.Count 14 'Source edges'
 $report.sources_before=@($sources);$report.imports=@($graph);$report.source_count=$sources.Count;$report.source_bytes=[long](($sources|Measure-Object bytes -Sum).Sum)
 foreach($s in $sources){if([IO.File]::ReadAllText($s.path) -match '#\[global_allocator\]'){throw 'Custom allocator'}}
 $priorPath=Join-Path $project 'build/khc-global-minor-codebook-20261005/report.json'
 Need (Identity $priorPath).sha256 'CD41B1C038191835B2B4A75552F6DA123A1B7B5F2FD895779140B05FAE3F7EE9' 'Prior report'
 $prior=Get-Content -Raw -LiteralPath $priorPath|ConvertFrom-Json -Depth 64 -DateKind String;Need $prior.status 'diagnostic-passed' 'Prior status'
 foreach($kind in @('sources','identities')){
  $a=@($prior.($kind+'_before'));$b=@($prior.($kind+'_after'));Need $a.Count $b.Count 'Prior pairs'
  for($i=0;$i -lt $a.Count;$i++){if(!(Same $a[$i] $b[$i]) -or !(Same $a[$i] (Identity $a[$i].path))){throw 'Prior before/after/live'};Pin $a[$i].path}
 }
 $a=$prior.executable_before;Need (Same $a $prior.executable_after) $true 'Prior artifact';Need (Same $a (Identity $a.path)) $true 'Prior artifact live';Pin $a.path
 $plan=Join-Path $PSScriptRoot '../ROOT_HISTORY_ORDER_PLAN_20261005.md';Need (Identity $plan).sha256 'CA36830092FA3FF33523BAA2D94BE607FEE73DC272639E4FACA6D355C1EC0ED2' 'PLAN'
 foreach($v in @(
 @('FAILURE_PLAN.md','20F2B68B2802FEAC1C61CDE92383615A0DDFE91091D331E694DCC2B354927A65'),
 @('model.rs','46AA9A34A9E5DD7AA69D0C16929EF5AF5B671495B225F587DFE7F59CE4F39683'),
 @('bundle.rs','F49C71CE4C49CD184AD3E9A18A3DE0F50B200F94605D6CC3C6309C7D14E95DDA'),
 @('e2e.rs','768D1FA86D1B16D16FA8CF2E2D26AC3BEEE51D8A3F7FE36FAFECB11EE716934E'),
 @('probe.rs','41C867BD080052D64278C2352FAEC0A90E9C5AA8639C2A514F55D3AAE78A732D')
 )){Need (Identity (Join-Path $PSScriptRoot $v[0])).sha256 $v[1] 'Candidate SHA';Pin (Join-Path $PSScriptRoot $v[0])}
 $raw=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../global-minor-codebook/model.rs')).Replace("`r`n","`n")
 $new=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'model.rs')).Replace("`r`n","`n")
 $prefix=$new.Substring(0,$new.IndexOf('// 固定整数LUT')).TrimEnd()
 $restored=$prefix.Replace('MAX_BITS:usize=142338','MAX_BITS:usize=142335').Replace('MAX_BYTES:usize=17793','MAX_BYTES:usize=17792')
 Need $restored $raw.Substring(0,$raw.IndexOf('// 固定整数LUT')).TrimEnd() 'Hist/quantize prefix with capacity-only restoration'
 $report.original_Hist_quantize_prefix_equal=$true
 foreach($p in @($PSCommandPath,$helper,$guard,$compiler,(Get-Process -Id $PID).Path,$fixedInputPath,$priorPath,$plan,(Join-Path $PSScriptRoot '../ROOT_HISTORY_ORDER_AUDIT_20261005.md'),(Join-Path $PSScriptRoot '../global-minor-codebook/verify-result.ps1'))){Pin $p}
 $report.identities_before=@($pins)
 Need (Identity $fixedInputPath).sha256 '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76' 'Input';Need (Identity $compiler).sha256 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC' 'Compiler';Need (Identity (Get-Process -Id $PID).Path).sha256 '362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139' 'PowerShell'
 if($report.source_bytes+(Identity $plan).bytes+(Identity (Join-Path $PSScriptRoot 'FAILURE_PLAN.md')).bytes -gt 307200){throw 'Sources capacity'}
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
  $n=$native.stdout|ConvertFrom-Json -Depth 64 -DateKind String;$report.screen=$n;Save-Report;Validate-Global $n $prior
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



