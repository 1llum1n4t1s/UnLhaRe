[CmdletBinding()]
param([switch]$PreflightOnly)
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-temporal-node-information-heap-20261004'
$exe=Join-Path $work 'temporal-node-information-o3.exe'
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
 Need $n.status 'passed' 'Native status';Need $n.kind 'temporal_node_information_optimistic_only' 'Kind'
 foreach($v in @(@('input_reads',1),@('BWT_calls',1),@('fixed_Front_walks',1),@('tile_width_runs',65536),@('tile_count',14),@('full_tiles',13),@('tail_runs',37259),@('width_sweeps',0),@('coded_branches',3825218),@('implicit_prefix1_branches',122),@('rows_checked_per_flush',872448),@('rows_checked',12214272),@('flushes',14),@('dense_instances_simultaneous',1),@('dense_row_capacity',872448),@('dense_capacity_bytes',13959192),@('side_bytes',3079),@('model_saved_bytes',0),@('frame_encodes',0),@('frame_decodes',0),@('raw_event_Vecs',0))){Need $n.($v[0]) $v[1] 'Screen census'}
 foreach($field in @('Tree_node_counts','tokens','runs','primary','escape_bytes','grammar','history_checks_per_walk','branches','classes','class_prefixes','final_last10bit_history')){if(!(Same $n.$field $old.screen.$field)){throw ('Original full Meta '+$field)}}
 foreach($v in @(@('synthetic_boundary_runs',65537),@('synthetic_boundary_events',131079),@('boundary_all_row_child_comparisons',6979584),@('exact_end_runs',65536),@('exact_end_all_row_child_comparisons',3489792),@('rejected_cases',24),@('real_Front_cases',3),@('real_Front_all_row_arithmetic_checks',2617344),@('real_Front_BWT_calls',3),@('real_Front_walks',3))){Need $n.E2E.($v[0]) $v[1] 'E2E census'}
 Need $n.E2E.same_process_recovery $true 'Recovery';Need $n.E2E.full_event_trace_saved $false 'Trace'
 foreach($field in @('second_walk_event_Q_replay_claimed','adoption','real_size_claimed','speed_claimed','portable_wire_verified','holdout_claimed','paid_model_verified','mathematical_frame_lower_bound_claimed','Q_partition_monotonicity_claimed')){Need $n.$field $false 'Claim boundary'}
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
try{
 $null=Safe-Path $work;if(Test-Path -LiteralPath $work){throw 'Unused output required'}
 $null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Runner AST'}
 Source (Join-Path $PSScriptRoot 'probe.rs');Need $sources.Count 12 'Source closure';Need $graph.Count 11 'Source edges'
 $report.sources_before=@($sources);$report.imports=@($graph);$report.source_count=$sources.Count;$report.source_bytes=[long](($sources|Measure-Object bytes -Sum).Sum)
 foreach($s in $sources){if([IO.File]::ReadAllText($s.path) -match '#\[global_allocator\]'){throw 'Custom allocator'}}
 $oldPath=Join-Path $project 'build/khc-node-history-information-20261004/report.json';Need (Identity $oldPath).sha256 '95A36B260AD51AC7702B55C0E43AD8A638FD7DE87BDC96CE2AA8ED66648719FC' 'Old report'
 $old=Get-Content -Raw -LiteralPath $oldPath|ConvertFrom-Json -Depth 64 -DateKind String;Need $old.status 'diagnostic-passed' 'Old status'
 foreach($kind in @('sources','identities')){
  $a=@($old.($kind+'_before'));$b=@($old.($kind+'_after'));Need $a.Count $b.Count 'Prior count'
  for($i=0;$i -lt $a.Count;$i++){if(!(Same $a[$i] $b[$i]) -or !(Same $a[$i] (Identity $a[$i].path))){throw 'Old before/after/live'};Pin $a[$i].path}
 }
 if(!(Same $old.executable_before $old.executable_after) -or !(Same $old.executable_before (Identity $old.executable_before.path))){throw 'Old EXE'};Pin $old.executable_before.path
 $originalPath=Join-Path $PSScriptRoot '../node-history-information/grammar.rs';$original=[IO.File]::ReadAllText($originalPath);$restored=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'grammar.rs'))
 foreach($v in @(@('FnMut(usize,usize,usize,usize,u16,usize,usize)','FnMut(usize,usize,usize,usize,u16,usize)'),@('branch(c,node,class,k,histories[class],child,meta.runs)?;','branch(c,node,class,k,histories[class],child)?;'))){Need ([regex]::Matches($restored,[regex]::Escape($v[0]))).Count 1 'Grammar count';$restored=$restored.Replace($v[0],$v[1])}
 Need $restored $original 'Grammar exact two restoration';$report.grammar_ledger=@{allowed_replacements=2;extra_residual=0;raw_bytes_restored=$true}
 $plan=Join-Path $PSScriptRoot '../TEMPORAL_TILE_PLAN_20261004.md';$note=Join-Path $PSScriptRoot '../TEMPORAL_TILE_EXECUTION_20261004.md';$failure=Join-Path $PSScriptRoot 'FAILURE_PLAN.md'
 Need (Identity $plan).sha256 '6357F7A38CC2480DFDA761620CEC0EFC36D2B54B6D445B83EA62FC9C6F73659C' 'PLAN';Need (Identity $note).sha256 '9C8B74C8B688A496F47F72FB0756C4E0D920707ED5E4AB92527A59D6B9E56408' 'Execution note'
 foreach($v in @(@('FAILURE_PLAN.md','D7B45C2001ED7B651F03BEFD6E468A7D51AB7BC5341E7B01027A6B21453323F7'),@('grammar.rs','BC5ECBF318516E84DCC4726BD4195073C1CEC87644862BC891A8C40B55D765E0'),@('tiles.rs','59C3D8675A99FE47F0B0F0AB6CF728A3E644E6B0489E4ABE9EC7A8991C42DB7C'),@('e2e.rs','D8F2253E3AD3CF6599502A2DD3AE7978E55D339D3258CC6D5261CDD955669EE6'),@('probe.rs','F022A131B31B168CE6BAB8CEA11954366181599A24348F10BB6179F46ED1A8CB'))){Need (Identity (Join-Path $PSScriptRoot $v[0])).sha256 $v[1] 'Candidate SHA'}
 $stackNote=Join-Path $PSScriptRoot '../TEMPORAL_TILE_STACK_FIX_20261004.md';Need (Identity $stackNote).sha256 '4DC5EC56B9BBDC3220D4D0978B383511068494B76E5962960CBFE60105E220B8' 'Stack fix plan';Pin $stackNote
 $failedRoot=Join-Path $project 'build/khc-temporal-node-information-20261004'
 $failedReport=Join-Path $failedRoot 'report.json';$failedExe=Join-Path $failedRoot 'temporal-node-information-o3.exe'
 Need (Identity $failedReport).sha256 'D2D7CF244C55738A1F466C5CAC60C5EC40DF4C3E2539D7AC322AC4D8695A6064' 'Failed report';Need (Identity $failedExe).sha256 'FD0E3CD0C76CE7878B44ACF30CA7175B90C2C355FF4302F731682AB3211C820E' 'Failed EXE';Pin $failedReport;Pin $failedExe
 $report.previous_terminal_failure=@{compile_calls=1;native_calls=1;exit_code=-1073741571;report=Identity $failedReport;executable=Identity $failedExe;source_changed_intentionally=$true}
 foreach($p in @($PSCommandPath,$helper,$guard,$compiler,(Get-Process -Id $PID).Path,$fixedInputPath,$oldPath,$plan,$note,$failure,(Join-Path $PSScriptRoot '../TEMPORAL_PAYLOAD_FEASIBILITY_20261004.md'),(Join-Path $PSScriptRoot '../node-history-information/verify-artifacts.ps1'))){Pin $p};$report.identities_before=@($pins)
 Need (Identity $fixedInputPath).sha256 '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76' 'Input';Need (Identity $compiler).sha256 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC' 'Compiler';Need (Identity (Get-Process -Id $PID).Path).sha256 '362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139' 'PowerShell'
 if($report.source_bytes+(Identity $plan).bytes+(Identity $note).bytes+(Identity $failure).bytes -gt 307200){throw 'Sources capacity'}
 if(![OperatingSystem]::IsWindows() -or [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() -cne 'X64'){throw 'Windows x64'}
 $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8
 if(!$PreflightOnly){
  $null=New-Item -ItemType Directory -Path $work;$created=$true;$report.status='running';Save-Report
  $v=Child $compiler @('--version') 60;Need $v.stdout 'rustc 1.98.1 (48a229cea 2026-09-01)' 'Compiler version'
  $report.compile_settings=@('--edition=2024','-C','opt-level=3','-C','lto=thin','-C','codegen-units=1','-C','panic=unwind','-C','overflow-checks=yes','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE');$report.compile_calls=1
  $null=Child $compiler (@((Join-Path $PSScriptRoot 'probe.rs'))+$report.compile_settings+@('-o',$exe)) 60
  $report.executable_before=Identity $exe;if($report.executable_before.bytes -gt 1048576){throw 'EXE capacity'};$locks.Add([IO.File]::Open($exe,'Open','Read','Read'))
  $report.total_native_calls=1;$native=Child $exe @('screen',$fixedInputPath) 120;if($native.stderr){throw 'Native stderr'}
  Need @($native.stdout -split "`n"|Where-Object {$_}).Count 1 'Raw JSON records'
  $n=$native.stdout|ConvertFrom-Json -Depth 64 -DateKind String;$report.screen=$n;Save-Report;Validate-Screen $n $old
  $report.original_full_Meta_equal=$true;$report.optimistic_Q_difference_bytes=$n.optimistic_Q_screen_bytes-504637
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
[pscustomobject]@{status=$report.status;source_count=$report.source_count;source_bytes=$report.source_bytes;identity_count=$pins.Count;compile_calls=$report.compile_calls;native_calls=$report.total_native_calls;optimistic_Q_screen_bytes=$report.screen.optimistic_Q_screen_bytes;disk=$finalGuard}|ConvertTo-Json -Depth 5
