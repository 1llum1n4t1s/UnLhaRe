[CmdletBinding()]
param([switch]$PreflightOnly)
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-temporal-short-leaf-20261004'
$exe=Join-Path $work 'temporal-short-leaf-o3.exe'
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
function Validate-Screen($n,$old){
 Need $n.status 'passed' 'Native status';Need $n.kind 'temporal_short_leaf_information_only' 'Kind'
 foreach($v in @(@('input_reads',1),@('BWT_calls',1),@('fixed_Front_walks',1),@('tile_width_runs',65536),@('tile_count',14),@('full_tiles',13),@('tail_runs',37259),@('width_sweeps',0),@('coded_branches',3825218),@('implicit_prefix1_branches',122),@('rows_checked_per_flush',872448),@('rows_checked',12214272),@('flushes',14),@('dense_instances_simultaneous',1),@('dense_row_capacity',872448),@('dense_capacity_bytes',13959192),@('side_bytes',3079),@('frame_encodes',0),@('frame_decodes',0),@('raw_event_Vecs',0))){Need $n.($v[0]) $v[1] 'Screen census'}
 foreach($field in @('Tree_node_counts','tokens','runs','primary','escape_bytes','grammar','history_checks_per_walk','branches','classes','class_prefixes','final_last10bit_history')){if(!(Same $n.$field $old.screen.$field)){throw ('Original full Meta '+$field)}}
 foreach($v in @(@('synthetic_boundary_runs',65537),@('synthetic_boundary_events',131079),@('boundary_all_row_child_comparisons',6979584),@('exact_end_runs',65536),@('exact_end_all_row_child_comparisons',3489792),@('rejected_cases',24),@('real_Front_cases',3),@('real_Front_all_row_arithmetic_checks',2617344),@('real_Front_BWT_calls',3),@('real_Front_walks',3))){Need $n.E2E.frozen_temporal.($v[0]) $v[1] 'E2E census'}
 Need $n.E2E.frozen_temporal.same_process_recovery $true 'Recovery';Need $n.E2E.frozen_temporal.full_event_trace_saved $false 'Trace'
 foreach($field in @('second_walk_event_Q_replay_claimed','adoption','real_size_claimed','speed_claimed','portable_wire_verified','holdout_claimed','mathematical_frame_lower_bound_claimed','Q_partition_monotonicity_claimed')){Need $n.$field $false 'Claim boundary'}
 Need $n.trained_in_sample_only $true 'In-sample';Need $n.original_raw_Meta_check_owner 'parent_runner' 'Meta owner'
 Need ($n.node_column_schema|ConvertTo-Json -Compress) '["component","node","count","active_rows","pure_rows","nonzero_cells","empirical_bits","Q_bits"]' 'Node schema'
 Need @($n.tiles).Count 14 'Tile count';Need @($n.node_totals).Count 284 'Node count';Need @($n.component_totals).Count 2 'Component count'
 $tileSums=@([double[]]::new(6),[double[]]::new(6));$nodeSums=@([double[]]::new(6),[double[]]::new(6));$implicit=[long[]]::new(2)
 $fields=@('count','active_rows','pure_rows','nonzero_cells','empirical_bits','Q_bits')
 for($t=0;$t -lt 14;$t++){
  $tile=$n.tiles[$t];Need $tile.tile $t 'Tile index';Need $tile.first_run ($t*65536) 'Tile start';Need $tile.run_count $(if($t -eq 13){37259}else{65536}) 'Tile runs'
  for($j=0;$j -lt 6;$j++){
   $a=$tile.components[0].($fields[$j]);$b=$tile.components[1].($fields[$j]);$w=$tile.whole.($fields[$j])
   if($j -lt 4){Need ($a+$b) $w 'Tile integer sum'}else{Near ($a+$b) $w}
   for($c=0;$c -lt 2;$c++){$tileSums[$c][$j]+=$tile.components[$c].($fields[$j])}
  }
  for($c=0;$c -lt 2;$c++){$implicit[$c]+=$tile.implicit_component_counts[$c]}
 }
 for($i=0;$i -lt 284;$i++){
  $row=$n.node_totals[$i];Need @($row).Count 8 'Node row width';Need $row[0] ([Math]::Floor($i/142)) 'Node component';Need $row[1] ($i%142) 'Node index'
  for($j=0;$j -lt 6;$j++){if(![double]::IsFinite($row[$j+2]) -or $row[$j+2] -lt 0){throw 'Node finite'};$nodeSums[[int]$row[0]][$j]+=$row[$j+2]}
 }
 for($j=0;$j -lt 6;$j++){
  for($c=0;$c -lt 2;$c++){
   $actual=$n.component_totals[$c].($fields[$j])
   if($j -lt 4){Need $tileSums[$c][$j] $actual 'Tile/component integer';Need $nodeSums[$c][$j] $actual 'Node/component integer'}else{Near $tileSums[$c][$j] $actual;Near $nodeSums[$c][$j] $actual}
  }
  $sum=$n.component_totals[0].($fields[$j])+$n.component_totals[1].($fields[$j])
  if($j -lt 4){Need $sum $n.whole.($fields[$j]) 'Whole integer'}else{Near $sum $n.whole.($fields[$j])}
 }
 for($c=0;$c -lt 2;$c++){Need ($n.component_totals[$c].count+$implicit[$c]) $n.branches[$c] 'Component branch counts'}
 Need ($implicit[0]+$implicit[1]) 122 'Implicit';Need $n.whole.count 3825218 'Coded whole'
 foreach($p in @('empirical','Q')){
  $total=$n.($p+'_total_loss_bits');Near $total $n.whole.($(if($p -eq 'Q'){'Q_bits'}else{'empirical_bits'}))
  Need $n.($p+'_token_bytes_ceil') ([Math]::Ceiling($total/8)) 'Loss ceil'
  Need $n.('optimistic_'+$p+'_screen_bytes') ($n.($p+'_token_bytes_ceil')+3079) 'Screen bytes'
  Need $n.($p+'_size_condition_passed') ($n.('optimistic_'+$p+'_screen_bytes') -le 483599) 'Information condition'
 }
 if($n.model_working_RAM_estimate_bytes -gt 25165824 -or $n.fixed_phase_RAM_estimate_bytes -gt 50331648){throw 'Source RAM'}
 Need $n.BWT_phase_RAM_estimate_bytes 141598926 'BWT phase'
 $m=$n.memory;Need $m.API_calls 1 'API calls';Need $m.ABI_size 80 'ABI';Need $m.ABI_cb 80 'cb';Need $m.ABI_checked $true 'Layout';Need $m.measured $true 'Measured'
 if($null -ne $m.last_OS_error -or $m.peak_working_set_bytes -le 0 -or $m.peak_private_commit_bytes -le 0 -or $m.peak_working_set_bytes -gt 167772160 -or $m.peak_private_commit_bytes -gt 167772160){throw 'OS memory bounds'}
}

function Validate-Paid($n,$previous){
 foreach($f in @('tiles','node_totals','component_totals','whole','empirical_total_loss_bits','Q_total_loss_bits','Q_token_bytes_ceil','optimistic_Q_screen_bytes')){Need (Same $n.$f $previous.screen.$f) $true "Free predecessor $f"}
 foreach($v in @(@('packet_normal_cases',4),@('packet_all_CDF_comparisons',3489792),@('root_rejections',3),@('packet_rejections',8),@('weighted_rejections',4))){Need $n.E2E.($v[0]) $v[1] 'New E2E census'}
 foreach($f in @('same_process_recovery','independent_default_Hamilton','independent_weighted_loss','depth5_split')){Need $n.E2E.$f $true 'New E2E oracle'}
 foreach($v in @(@('paid_models',3976),@('paid_roots',11928),@('Fit_root_all_CDF_comparisons',12214272),@('packet_capacity_limit_bytes',5053003),@('packet_instances_simultaneous',1),@('packet_files_saved',0),@('node_oracle_array_bytes',4544))){Need $n.($v[0]) $v[1] 'Paid census'}
 Need $n.completed_packet_parse_verified $true 'Packet parsed';Need $n.paid_model_verified $true 'Paid model verified'
 Need @($n.paid_tiles).Count 14 'Paid tiles'
 $headers=0L;$bits=0L;$padding=0L;$defaults=0L;$explicit=0L;$checks=0L;$loss=0.0;$dp=0.0
 for($t=0;$t -lt 14;$t++){
  $s=$n.paid_tiles[$t];Need $s.tile $t 'Paid tile index';Need $s.models 284 'Models';Need $s.roots 852 'Roots';Need ($s.default_roots+$s.explicit_roots) 852 'Root tags'
  Need $s.header_bytes (4+[Math]::Ceiling($s.header_bits/8)) 'Packet bytes';Need $s.padding_bits (($s.header_bytes-4)*8-$s.header_bits) 'Packet padding'
  if($s.padding_bits -lt 0 -or $s.padding_bits -gt 7 -or $s.header_bytes -gt 5053003){throw 'Packet bounds'}
  Need $s.Fit_root_all_CDF_comparisons 872448 'CDF checks';Need $s.completed_packet_row_checks 872448 'Parsed rows'
  Near $s.DP_loss_bits $s.parsed_row_loss_bits
  for($c=0;$c -lt 2;$c++){Need $s.component_counts[$c] $n.tiles[$t].components[$c].count 'Paid count';Near $s.component_DP_bits[$c] $s.component_parsed_bits[$c]}
  Near ($s.component_parsed_bits[0]+$s.component_parsed_bits[1]) $s.parsed_row_loss_bits
  $headers+=$s.header_bytes;$bits+=$s.header_bits;$padding+=$s.padding_bits;$defaults+=$s.default_roots;$explicit+=$s.explicit_roots
  $checks+=$s.concatenated_root_bits_directly_compared;$loss+=$s.parsed_row_loss_bits;$dp+=$s.DP_loss_bits
 }
 foreach($v in @(@($headers,$n.paid_header_bytes),@($bits,$n.paid_header_bits),@($padding,$n.paid_padding_bits),@($defaults,$n.paid_default_roots),@($explicit,$n.paid_explicit_roots),@($checks,$n.concatenated_root_bits_directly_compared))){Need $v[0] $v[1] 'Paid aggregate'}
 Near $loss $n.paid_parsed_loss_bits;Near $dp $n.paid_DP_loss_bits
 Need $n.paid_token_bytes_ceil ([Math]::Ceiling($loss/8)) 'Paid ceil'
 Need $n.paid_token_delta_from_free_Q_bytes ($n.paid_token_bytes_ceil-449308) 'Signed delta'
 Need $n.paid_delta_plus_header_bytes ($n.paid_token_delta_from_free_Q_bytes+$headers) 'Paid sum'
 Need $n.paid_screen_bytes ($n.paid_token_bytes_ceil+$headers+3079) 'Paid screen'
 Need $n.paid_size_condition_passed ($n.paid_screen_bytes -le 483599 -and $n.paid_delta_plus_header_bytes -le 31212) 'Paid information condition'
 Need $n.model_saved_bytes $headers 'Model bytes'
 Need $n.paid_DP_bits_plus_flags_verified $true 'DP packet bits'
 Need $n.paid_outer_flag_bits 11928 'Flags'
 Need ($n.paid_DP_internal_bits+11928) $n.paid_header_bits 'DP/actual wire bits'
 $dpBits=0L;foreach($t in $n.paid_tiles){$dpBits+=$t.DP_internal_bits;Need ($t.DP_internal_bits+852) $t.header_bits 'Tile DP bits'}
 Need $dpBits $n.paid_DP_internal_bits 'Whole DP bits'
 foreach($v in @(@('pure_cases',9),@('internal_uniform_cases',1),@('raw_cases',3),@('default_root_cases',3),@('DP_boundary_cases',2),@('wire_rejections',4))){Need $n.E2E.short_leaf.($v[0]) $v[1] 'Short E2E census'}
}
try{
 $null=Safe-Path $work;if(Test-Path -LiteralPath $work){throw 'Unused output required'}
 $null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Runner AST'}
 Source (Join-Path $PSScriptRoot 'probe.rs');Need $sources.Count 15 'Source closure';Need $graph.Count 14 'Source edges'
 $report.sources_before=@($sources);$report.imports=@($graph);$report.source_count=$sources.Count;$report.source_bytes=[long](($sources|Measure-Object bytes -Sum).Sum)
 foreach($s in $sources){if([IO.File]::ReadAllText($s.path) -match '#\[global_allocator\]'){throw 'Custom allocator'}}
 $priorPath=Join-Path $project 'build/khc-temporal-node-information-heap-20261004/report.json'
 Need (Identity $priorPath).sha256 'E8A89FEE46CC6BB39697C416FD8150CB83B2406D9297A1C4397E6D9956C052A8' 'Prior report'
 $prior=Get-Content -Raw -LiteralPath $priorPath|ConvertFrom-Json -Depth 64 -DateKind String;Need $prior.status 'diagnostic-passed' 'Prior status'
 foreach($kind in @('sources','identities')){
  $a=@($prior.($kind+'_before'));$b=@($prior.($kind+'_after'));Need $a.Count $b.Count 'Prior pairs'
  for($i=0;$i -lt $a.Count;$i++){if(!(Same $a[$i] $b[$i]) -or !(Same $a[$i] (Identity $a[$i].path))){throw 'Prior before/after/live'};Pin $a[$i].path}
 }
 if(!(Same $prior.executable_before $prior.executable_after) -or !(Same $prior.executable_before (Identity $prior.executable_before.path))){throw 'Prior EXE'};Pin $prior.executable_before.path
 $oldPath=Join-Path $project 'build/khc-node-history-information-20261004/report.json'
 $old=Get-Content -Raw -LiteralPath $oldPath|ConvertFrom-Json -Depth 64 -DateKind String
 $plan=Join-Path $PSScriptRoot '../TEMPORAL_SHORT_LEAF_PLAN_20261004.md';Need (Identity $plan).sha256 'ADECAFF3E410B9797C406F592B838B7B591FC64424C2AC82E9B5AAD8B14F8DDA' 'PLAN'
 foreach($v in @(
 @('FAILURE_PLAN.md','14F2D5D076F3C0678774D4130C66A66D1CE6490FC485EF73865BA01E860BBF8F'),
 @('paid_model.rs','B1A38FBDFAE53E9F2D6D0F34C4223E23F75C033E7B0AB1A6A79E6A9CBEB74302'),
 @('packet.rs','AF79C0244FD6E88A4BCE9F2D8CD1C26A10D1E9B03A1D62D0E64D092DC098BF1B'),
 @('tile_accumulator.rs','A37C45D43FAF21E98BB54495A192F09344408F36AB65EEB041B8F808ADEB2A24'),
 @('e2e.rs','24968DA69E6FC455B979657E8A6AD9537612312F2D15256C0B48509455CA13B5'),
 @('probe.rs','CAE36A627BBB364F2726B47170245D308DF89384F576F9344AD972047F35884B')
 )){Need (Identity (Join-Path $PSScriptRoot $v[0])).sha256 $v[1] 'Candidate SHA';Pin (Join-Path $PSScriptRoot $v[0])}
 $raw=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../class-selective-static-mdl/model.rs')).Replace("\r\n","\n")
 $paid=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'paid_model.rs')).Replace("\r\n","\n")
 $originalPrefix=$raw.Substring(0,$raw.IndexOf('#[derive(Clone,Copy,Default)]')).TrimEnd()
 $newPrefix=$paid.Substring(0,$paid.IndexOf('// 短いleafの厳密CDF mode')).TrimEnd()
 Need $newPrefix $originalPrefix 'Original Hist/quantize prefix'
 $report.original_Hist_quantize_prefix_equal=$true
 $paidPrior=Join-Path $project 'build/khc-temporal-paid-root-20261004/report.json'
 Need (Identity $paidPrior).sha256 '1D87164EF4869B24BB5267914DE80ACC44E358D4C3D5D39E3CE42D278269C4B1' 'Paid prior report'
 Pin $paidPrior;Pin (Join-Path $PSScriptRoot '../temporal-paid-root/verify-artifacts.ps1')
 foreach($p in @($PSCommandPath,$helper,$guard,$compiler,(Get-Process -Id $PID).Path,$fixedInputPath,$priorPath,$plan,(Join-Path $PSScriptRoot '../TEMPORAL_SHORT_LEAF_AUDIT_20261004.md'),(Join-Path $PSScriptRoot '../temporal-node-information/verify-artifacts.ps1'))){Pin $p}
 $report.identities_before=@($pins)
 Need (Identity $fixedInputPath).sha256 '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76' 'Input';Need (Identity $compiler).sha256 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC' 'Compiler';Need (Identity (Get-Process -Id $PID).Path).sha256 '362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139' 'PowerShell'
 if($report.source_bytes+(Identity $plan).bytes+(Identity (Join-Path $PSScriptRoot 'FAILURE_PLAN.md')).bytes -gt 307200){throw 'Sources capacity'}
 if(![OperatingSystem]::IsWindows() -or [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() -cne 'X64'){throw 'Windows x64'}
 $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8
 if(!$PreflightOnly){
  $null=New-Item -ItemType Directory -Path $work;$created=$true;$report.status='running';Save-Report
  $v=Child $compiler @('--version') 60;Need $v.stdout 'rustc 1.98.1 (48a229cea 2026-09-01)' 'Compiler version'
  $report.compile_settings=@('--edition=2024','-C','opt-level=3','-C','lto=thin','-C','codegen-units=1','-C','panic=unwind','-C','overflow-checks=yes','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE');$report.compile_calls=1
  $null=Child $compiler (@((Join-Path $PSScriptRoot 'probe.rs'))+$report.compile_settings+@('-o',$exe)) 60
  $report.executable_before=Identity $exe;if($report.executable_before.bytes -gt 1048576){throw 'EXE capacity'};$locks.Add([IO.File]::Open($exe,'Open','Read','Read'))
  $report.total_native_calls=1;$native=Child $exe @('screen',$fixedInputPath) 120;if($native.stderr){throw 'Native stderr'}
  Need @($native.stdout -split "\n"|Where-Object {$_}).Count 1 'Raw JSON records'
  $n=$native.stdout|ConvertFrom-Json -Depth 64 -DateKind String;$report.screen=$n;Save-Report;Validate-Screen $n $old;Validate-Paid $n $prior
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
[pscustomobject]@{status=$report.status;source_count=$report.source_count;source_bytes=$report.source_bytes;identity_count=$pins.Count;compile_calls=$report.compile_calls;native_calls=$report.total_native_calls;paid_screen_bytes=$report.screen.paid_screen_bytes;disk=$finalGuard}|ConvertTo-Json -Depth 5



