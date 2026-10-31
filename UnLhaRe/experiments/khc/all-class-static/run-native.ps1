[CmdletBinding()]
param([switch]$PreflightOnly)
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-all-class-static-20261005'
$exe=Join-Path $work 'all-class-static-o3.exe'
$fixedInputPath=Join-Path $project 'build/khc-current-source-native-solid-20260923-group/all.group'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$guard=Join-Path $PSScriptRoot '../disk-budget.ps1'
$helper=Join-Path $PSScriptRoot '../float-fresh-transaction/run-native.ps1'
$frozenSourceRoot=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($helper))
$created=$false
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$sources=[Collections.Generic.List[object]]::new()
$graph=[Collections.Generic.List[object]]::new()
$pins=[Collections.Generic.List[object]]::new()
$report=[ordered]@{status='preflight';children=@();started_utc=[DateTime]::UtcNow.ToString('o');compile_calls=0;total_native_calls=0;frozen_entrypoints_executed=$false;raw_traces=0;disk_frame_plain_input_copies=0;diagnostic_only=$true;complete_frame_verified=$false}
function Need($a,$b,[string]$why){if($a -cne $b){throw $why}}
function Same($a,$b){($a|ConvertTo-Json -Compress -Depth 64) -ceq ($b|ConvertTo-Json -Compress -Depth 64)}
function Near([double]$a,[double]$b){if(![double]::IsFinite($a) -or ![double]::IsFinite($b) -or $a -lt 0 -or $b -lt 0 -or [Math]::Abs($a-$b) -gt 0.000001){throw 'Loss arithmetic'}}
Need (Get-FileHash -LiteralPath $helper).Hash 'A3DCE4B3A5A48897173E1BB34F0025F0A6BB933F6A59F798AAAF24A9559E0D85' 'Frozen helper SHA'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Helper AST'}
foreach($name in @('Identity','Safe-Path','Source','Save-Report','Child')){
 $defs=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Need $defs.Count 1 'Helper definition'
 $definition=$defs[0].Extent.Text
 if($name -eq 'Source'){$definition=$definition.Replace('$PSScriptRoot','$frozenSourceRoot');Need $definition.Replace('$frozenSourceRoot','$PSScriptRoot') $defs[0].Extent.Text 'Exact source root binding'}
 . ([scriptblock]::Create($definition))
}
function Pin([string]$p){$p=Safe-Path $p;if(@($pins|Where-Object path -eq $p).Count){return};$pins.Add((Identity $p));$locks.Add([IO.File]::Open($p,'Open','Read','Read'))}
function Validate-Screen($n,$prior){
 Need $n.status 'passed' 'Native status';Need $n.kind 'all_class_static_cost_screen_only' 'Screen scope'
 foreach($v in @(@('fixed_input_reads',1),@('fixed_BWT_calls',1),@('fixed_grammar_walks',2),@('fixed_input_bytes',2811006),@('model_count',284),@('root_count',852),@('training_Fit_builds',568),@('verification_Fit_builds',568),@('total_Fit_builds',1136),@('weighted_rows',872448),@('high_weighted_rows',872448),@('verification_weighted_rows',872448),@('verification_high_weighted_rows',872448),@('weighted_root_count_comparisons',3408),@('individual_root_parse_calls',852),@('Forest_parse_calls',1),@('individual_root_CDF_comparisons',872448),@('completed_Forest_reFit_CDF_comparisons',872448),@('replay_branch_probability_lookups',3825218),@('implicit_k1_per_walk',122),@('root_flag_bits',852),@('metadata_prefix_bytes',134),@('table_bytes',129),@('borrowed_fixed_side_bytes',3079),@('escape_side_subfield_bytes',742),@('remaining_borrowed_side_bytes',2337),@('stored_payload_input_bytes',2811006),@('teacher_models_executed',0),@('complete_frame_encodes',0),@('complete_frame_decodes',0),@('raw_packet_files_saved',0))){Need $n.($v[0]) $v[1] "Census $($v[0])"}
 foreach($f in @('whole_Meta_equal','k1_history_verified','integer_wire_CDF_verified','side_is_borrowed_estimate','borrowed_component_sizes_unmeasured','codec_dropped_before_report','OS_resource_gate_passed')){Need $n.$f $true "Positive gate $f"}
 foreach($f in @('speed_claimed','adoption')){Need $n.$f $false "Claim boundary $f"}
 if($null -ne $n.actual_complete_frame_bytes){throw 'Complete frame claim'}
 Need (Same $n.class_model_counts @(1,2,139,1,2,139)) $true 'All class models'
 foreach($field in @('tokens','runs','primary','grammar','branches','classes','class_prefixes')){Need (Same $n.$field $prior.screen.$field) $true "Prior full Meta $field"}
 Need (Same $n.final_history $prior.screen.final_last10bit_history) $true 'Prior final history'
 Need $n.control_class2_5_internal_bits $prior.screen.global_DP_internal_bits 'Prior internal bits'
 Need $n.control_class2_5_flags $prior.screen.root_outer_flag_bits 'Prior flags'
 Need $n.control_class2_5_packet_bytes $prior.screen.bundle_bytes 'Prior packet'
 Near $n.control_class2_5_loss_bits $prior.screen.DP_selected_loss_bits
 $loss=0.0;$internal=0L
 foreach($f in @('DP_class_loss_bits','parsed_class_loss_bits','replay_class_loss_bits','free_Q_class_loss_bits','same_selected_tree_Hamilton_class_loss_bits','class_internal_bits','coded_class_counts')){Need @($n.$f).Count 6 "Class extent $f"}
 for($i=0;$i -lt 6;$i++){Near $n.DP_class_loss_bits[$i] $n.parsed_class_loss_bits[$i];Near $n.DP_class_loss_bits[$i] $n.replay_class_loss_bits[$i];$loss+=$n.replay_class_loss_bits[$i];$internal+=$n.class_internal_bits[$i]}
 Need $n.payload_bits ($internal+852) 'Actual paid bit cost'
 Need $n.concatenated_root_bits_checked $internal 'Concatenated bit direct comparison'
 Need $n.packet_bytes (134+[Math]::Ceiling($n.payload_bits/8)) 'Actual packet bytes'
 Need $n.zero_pad_bits (($n.packet_bytes-134)*8-$n.payload_bits) 'Padding expense'
 if($n.zero_pad_bits -lt 0 -or $n.zero_pad_bits -gt 7){throw 'Padding bounds'}
 Need $n.ideal_token_bytes_ceil ([Math]::Ceiling($loss/8)) 'Ideal token ceil'
 Need $n.screen_bytes ($n.ideal_token_bytes_ceil+$n.packet_bytes+3079) 'Screen total'
 Need $n.screen_smaller_than_raw_input ($n.screen_bytes -lt 2811006) 'Stored comparison'
 Need $n.necessary_size_condition_passed ($n.screen_bytes -le 483599) 'Fixed size target, not completion condition'
 Need ($n.leaf_mode_counts|Measure-Object -Sum).Sum $n.selected_leaves 'Mode partition'
 Need $n.selected_leaves (3*$n.selected_splits+852) 'Quaternary tree'
 if($n.selected_high_roots -gt $n.selected_split_roots -or $n.selected_split_roots -gt (852-$n.default_roots)){throw 'Paid order bounds'}
 foreach($v in @(@('model_RAM_estimate_bytes',33554432),@('phase_RAM_estimate_bytes',67108864),@('scratch_capacity_bytes',65536))){$x=$n.($v[0]);if($x -le 0 -or $x -gt $v[1]){throw "RAM bound $($v[0])"}}
 foreach($f in @('peak_working_set_bytes','peak_private_commit_bytes')){if($n.memory.$f -le 0 -or $n.memory.$f -gt 167772160){throw "OS memory $f"}}
 Need $n.Forest_parse_transient_capacity_bytes ($n.Forest_parse_Dispatch_capacity_bytes+$n.Forest_parse_reader_capacity_bytes) 'Parser transient capacity'
 Need $n.Forest_parse_transient_conservatively_added $true 'Parser transient not free'
 Need $n.model_RAM_estimate_bytes ($n.dense_capacity_bytes+$n.Forest_capacity_bytes+$n.packet_capacity_bytes+$n.max_Hist_pair_capacity_bytes+$n.max_Fit_pair_capacity_bytes+$n.max_Dispatch_capacity_bytes+$n.max_local_wire_capacity_bytes+$n.codec_peak_capacity_bytes+$n.Forest_parse_transient_capacity_bytes+$n.scratch_capacity_bytes+4194304+512) 'Concurrent model capacity arithmetic'
 Need $n.phase_RAM_estimate_bytes ($n.model_RAM_estimate_bytes+$n.run_capacity*12+$n.input_capacity+1369112+4194304) 'Concurrent phase capacity arithmetic'
 foreach($v in @(@('input_bytes_total',26049),@('maximum_input_bytes',16384),@('BWT_calls',8),@('grammar_walks',16),@('case_Fit_builds',9088),@('order_fixture_Fit_builds',4),@('order_fixture_root_CDF_comparisons',4096),@('order_fixture_Forest_CDF_comparisons',872448),@('order_fixture_high_packet_bytes',880),@('total_Forest_parse_calls',9),@('combined_individual_and_Forest_CDF_comparisons',13959168))){Need $n.finite_E2E.($v[0]) $v[1] "Finite census $($v[0])"}
 Need @($n.finite_E2E.cases).Count 8 'Finite case count'
 foreach($v in @(@('packet_rejections',19),@('same_process_recoveries',19),@('total_Forest_parse_calls',39),@('normal_witness_packet_bytes',241),@('normal_witness_CDF_comparisons',872448),@('Fit_builds',0),@('BWT_calls',0),@('grammar_walks',0),@('input_reads',0))){Need $n.adversarial_E2E.($v[0]) $v[1] "Adversarial census $($v[0])"}
 Need $n.adversarial_E2E.exact_reasons_verified $true 'Adversarial exact reasons'
 Need $n.adversarial_E2E.RAM_only $true 'Adversarial RAM only'
 Need $n.adversarial_E2E.OS_chaos_executed $false 'No OS chaos claim'
 Need $n.finite_E2E.RAM_only $true 'Finite RAM only'
 Need $n.finite_E2E.all_class_coverage $true 'Finite all classes'
 Need $n.finite_E2E.whole_Meta_equal $true 'Finite Meta equality'
 Need $n.finite_E2E.exact_reasons_verified $true 'Finite rejection reasons'
 Need $n.finite_E2E.packet_rejections $n.finite_E2E.same_process_recoveries 'Finite recovery after every rejection'
 if($n.finite_E2E.packet_rejections -le 0 -or $n.finite_E2E.input_bytes_total -gt 32768){throw 'Finite input/rejection gate'}
 Need $n.finite_E2E.input_reads 0 'Finite no file copies'
}
try{
 $null=Safe-Path $work;if(Test-Path -LiteralPath $work){throw 'Unused output required'}
 $null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Runner AST'}
 $pinFile=Join-Path $PSScriptRoot 'source-pins.json'
 $candidate=Get-Content -Raw -LiteralPath $pinFile|ConvertFrom-Json -DateKind String -Depth 8
 Need @($candidate).Count 5 'Candidate pins'
 $candidateBytes=0L
 foreach($x in $candidate){if($x.name -notin @('FAILURE_PLAN.md','probe.rs','packet.rs','finite.rs','adversarial.rs')){throw 'Candidate pin name'};$p=Join-Path $PSScriptRoot $x.name;$id=Identity $p;Need $id.sha256 $x.sha256 'Candidate source SHA';Need $id.bytes $x.bytes 'Candidate source bytes';$candidateBytes+=$id.bytes;Pin $p}
 if(@($candidate.name|Sort-Object -Unique).Count -ne 5 -or $candidateBytes -gt 65536){throw 'Candidate source capacity/uniqueness'}
 Source (Join-Path $PSScriptRoot 'probe.rs')
 $report.sources_before=@($sources);$report.imports=@($graph);$report.source_count=$sources.Count;$report.source_bytes=[long](($sources|Measure-Object bytes -Sum).Sum)
 if($report.source_bytes -gt 358400){throw 'Source closure capacity'}
 foreach($s in $sources){if([IO.File]::ReadAllText($s.path) -match '#\[global_allocator\]'){throw 'Custom allocator'}}
 $priorPath=Join-Path $project 'build/khc-paid-code-tree-20261005/report.json'
 Need (Identity $priorPath).sha256 '1A244D67F80617B92812E715C2CA45394144CA51D59A45E6D1D8703F5711C116' 'Frozen paid report'
 $prior=Get-Content -Raw -LiteralPath $priorPath|ConvertFrom-Json -DateKind String -Depth 64;Need $prior.status 'diagnostic-passed' 'Prior status'
 foreach($p in @($PSCommandPath,$pinFile,$helper,$guard,$compiler,(Get-Process -Id $PID).Path,$fixedInputPath,$priorPath,(Join-Path $PSScriptRoot '../ALL_CLASS_STATIC_PLAN_20261005.md'),(Join-Path $PSScriptRoot '../ALL_CLASS_STATIC_EXECUTION_20261005.md'))){Pin $p}
 $report.identities_before=@($pins)
 Need (Identity $fixedInputPath).sha256 '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76' 'Input SHA';Need (Identity $fixedInputPath).bytes 2811006 'Input bytes'
 Need (Identity $compiler).sha256 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC' 'Compiler SHA'
 Need (Identity (Get-Process -Id $PID).Path).sha256 '362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139' 'PowerShell SHA'
 if(![OperatingSystem]::IsWindows() -or [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() -cne 'X64'){throw 'Windows x64 required'}
 $report.environment=@{CPU=@(Get-CimInstance Win32_Processor|Select-Object Name,NumberOfCores,NumberOfLogicalProcessors);OS=[Runtime.InteropServices.RuntimeInformation]::OSDescription;PowerShell=$PSVersionTable.PSVersion.ToString();child_cwd=$project}
 $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8
 if($PreflightOnly){$report.status='preflight-passed'}else{
  $null=New-Item -ItemType Directory -Path $work;$created=$true;$report.status='running';Save-Report
  $v=Child $compiler @('--version') 60;Need $v.stdout 'rustc 1.98.1 (48a229cea 2026-09-01)' 'Compiler version'
  $report.compile_settings=@('--edition=2024','--cfg','frame_audit','--cfg','primitive_audit','-C','opt-level=3','-C','lto=thin','-C','codegen-units=1','-C','panic=unwind','-C','overflow-checks=yes','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE');$report.compile_limit_seconds=60;$report.native_limit_seconds=120;$report.compile_calls=1
  $compile=Child $compiler (@((Join-Path $PSScriptRoot 'probe.rs'))+$report.compile_settings+@('-o',$exe)) 60
  $report.compiler_stderr_present=[bool]$compile.stderr
  $report.executable_before=Identity $exe;if($report.executable_before.bytes -gt 1048576){throw 'EXE capacity'};$locks.Add([IO.File]::Open($exe,'Open','Read','Read'))
  $report.total_native_calls=1;$native=Child $exe @('screen',$fixedInputPath) 120
  if($native.stderr){throw 'Native stderr'};Need @($native.stdout -split "\n"|Where-Object {$_}).Count 1 'One raw JSON record'
  $n=$native.stdout|ConvertFrom-Json -Depth 64 -DateKind String;$report.screen=$n;Save-Report;Validate-Screen $n $prior
  $report.executable_after=Identity $exe;Need (Same $report.executable_before $report.executable_after) $true 'EXE unchanged'
  $report.owned_exe_processes=@(Get-Process|Where-Object Path -eq $exe).Count;Need $report.owned_exe_processes 0 'Owned process remains'
  $entries=@(Get-ChildItem -LiteralPath $work -Force);Need $entries.Count 2 'Output count'
  if(@($entries|Where-Object {$_.PSIsContainer -or $_.FullName -notin @($exe,(Join-Path $work 'report.json')) -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'Output shape'}
  $report.status='diagnostic-passed'
 }
}catch{$report.status='failed';$report.error=$_.Exception.Message;throw}finally{
 try{
  $report.sources_after=@($sources|ForEach-Object {$now=Identity $_.path;Need (Same $_ $now) $true 'Source changed';$now})
  $report.identities_after=@($pins|ForEach-Object {$now=Identity $_.path;Need (Same $_ $now) $true 'Pin changed';$now})
  $report.ended_utc=[DateTime]::UtcNow.ToString('o');$report.disk_after=& $guard -WorkDirectory $work -MaxRunMiB 8;Save-Report
  $finalGuard=& $guard -WorkDirectory $work -MaxRunMiB 8
 }finally{foreach($stream in $locks){$stream.Dispose()}}
}
[pscustomobject]@{status=$report.status;source_count=$report.source_count;source_bytes=$report.source_bytes;compile_calls=$report.compile_calls;native_calls=$report.total_native_calls;screen_bytes=$report.screen.screen_bytes;disk=$finalGuard}|ConvertTo-Json -Depth 5
