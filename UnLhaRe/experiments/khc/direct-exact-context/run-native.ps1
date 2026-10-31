[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-direct-exact-context-20261004'
$exe=Join-Path $work 'direct-exact-context-o3-thin.exe'
$fixedInputPath=Join-Path $project 'build/khc-current-source-native-solid-20260923-group/all.group'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$guard=Join-Path $PSScriptRoot '../disk-budget.ps1'
$frozenSourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../float-fresh-transaction'))
$helper=Join-Path $frozenSourceRoot 'run-native.ps1'
$created=$false
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$sources=[Collections.Generic.List[object]]::new()
$graph=[Collections.Generic.List[object]]::new()
$pins=[Collections.Generic.List[object]]::new()
$report=[ordered]@{status='preflight';started_utc=[DateTime]::UtcNow.ToString('o');children=@();compile_calls=0;total_native_calls=0;diagnostic_only=$true;coder_implemented=$false;raw_traces=0;disk_frame_plain_input_copies=0;frozen_entrypoints_executed=$false;CPU_quiet_verified=$false}
# 凍結runnerの関数定義だけを固定SHAから取り込み、旧entryは実行しない。
if((Get-FileHash -LiteralPath $helper).Hash -cne 'A3DCE4B3A5A48897173E1BB34F0025F0A6BB933F6A59F798AAAF24A9559E0D85'){throw 'Frozen helper SHA'}
$locks.Add([IO.File]::Open($helper,'Open','Read','Read'))
$tokens=$null;$parseErrors=$null
$helperAst=[Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Frozen helper syntax'}
foreach($name in @('Identity','Safe-Path','Source','Save-Report','Child')){
 $functions=@($helperAst.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
 if($functions.Count -ne 1){throw 'Frozen helper function identity'}
 $definition=$functions[0].Extent.Text
 if($name -ceq 'Source'){$definition=$definition.Replace('$PSScriptRoot','$frozenSourceRoot')}
 . ([scriptblock]::Create($definition))
}
function Pin-ExactFile([string]$Path){$p=Safe-Path $Path;if(@($pins|Where-Object path -eq $p).Count){return};$pins.Add((Identity $p));$locks.Add([IO.File]::Open($p,'Open','Read','Read'))}
function Same-ExactIdentity($A,$B){($A|ConvertTo-Json -Compress) -ceq ($B|ConvertTo-Json -Compress)}
function Need-Exact($Value,$Expected,[string]$Name){if($Value -cne $Expected){throw "Native $Name expected $Expected got $Value"}}
try{
 $null=Safe-Path $work;if(Test-Path -LiteralPath $work){throw 'Unused output root required'}
 $tokens=$null;$parseErrors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$parseErrors);if($parseErrors.Count){throw 'Runner syntax'}
 Source (Join-Path $PSScriptRoot 'probe.rs')
 $report.imports=@($graph);$report.sources_before=@($sources);$report.source_count=$sources.Count;$report.source_bytes=[long](($sources|Measure-Object bytes -Sum).Sum)
 if($sources.Count -ne 14 -or $graph.Count -ne 13 -or $report.source_bytes -gt 307200){throw 'Fixed source closure 14/13/300KiB'}
 foreach($pair in @(@('happy.rs','18AC0D9E360B32BE3B82EF9D52DF94BFCC5D3F340CB399057D604089A33B52FC',7638),@('adversarial.rs','5A9B4A78DCEE9190EAF102345FF6C8212C5F4CF5DA0DE6D2C04F8B2E8A8AA9AF',5912))){$id=Identity (Join-Path $PSScriptRoot $pair[0]);if($id.sha256 -cne $pair[1] -or $id.bytes -ne $pair[2]){throw 'Parent test identity'}}
 $causalReport=Join-Path $project 'build/khc-causal-direct-mix-20261004/corrected-native/report.json'
 if((Identity $causalReport).sha256 -cne 'DB086C81EC77DD41EF3114C917081FC3FEC9495B879F1FE12BACEF9BC8B78AD3'){throw 'Frozen causal report identity'}
 $old=Get-Content -LiteralPath $causalReport -Raw|ConvertFrom-Json -Depth 32 -DateKind String
 if($old.status -cne 'diagnostic-passed'){throw 'Frozen causal evidence status'}
 foreach($id in $old.sources_before){$now=Identity $id.path;if(!(Same-ExactIdentity $id $now)){throw 'Frozen causal source live identity'};Pin-ExactFile $id.path}
 foreach($path in @($PSCommandPath,$guard,$helper,$compiler,(Get-Process -Id $PID).Path,$fixedInputPath,$causalReport,
  (Join-Path $PSScriptRoot 'FAILURE_PLAN.md'),
  (Join-Path $PSScriptRoot '../DIRECT_EXACT_CONTEXT_PLAN_20261004.md'),
  (Join-Path $PSScriptRoot '../DIRECT_CONTEXT_ALIAS_QUESTION_20261004.md'),
  (Join-Path $PSScriptRoot '../DIRECT_CONTEXT_ALIAS_BUDGET_20261004.md'),
  (Join-Path $PSScriptRoot '../causal-direct-mix/RESULT_20261004.md'),
  (Join-Path $PSScriptRoot '../causal-direct-mix/verify-artifacts.ps1'),
  (Join-Path $PSScriptRoot '../packed-inverse/RESULT_20261004.md'),
  (Join-Path $PSScriptRoot '../packed-inverse/verify-artifacts.ps1'),
  (Join-Path $PSScriptRoot '../PACKED_INVERSE_MEMORY_API_NOTE_20261004.md'))){Pin-ExactFile $path}
 $report.identities_before=@($pins)
 $expectedPlans=@('3D97697B14CB26E2C315AA644A0BB05F8857C2FD8FA65159D78CC48918DAF372','02C1BC5A16744ECA7C787C14C3C2BC9AD4909F531F52E094970C3CD4EC79F90C','C58C7F722B1218D6C6C9E1042EA54854B171310E0ADC8C5801A8645A28A7ABB1')
 $planNames=@('DIRECT_EXACT_CONTEXT_PLAN_20261004.md','DIRECT_CONTEXT_ALIAS_QUESTION_20261004.md','DIRECT_CONTEXT_ALIAS_BUDGET_20261004.md')
 for($i=0;$i -lt 3;$i++){if((Identity (Join-Path $PSScriptRoot ('../'+$planNames[$i]))).sha256 -cne $expectedPlans[$i]){throw 'Plan final pin'}}
 $fixed=Identity $fixedInputPath;if($fixed.bytes -ne 2811006 -or $fixed.sha256 -cne '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'){throw 'Fixed input pin'}
 if((Identity $compiler).sha256 -cne 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'){throw 'Compiler pin'}
 $report.environment=@{child_cwd=$project;OS=[Runtime.InteropServices.RuntimeInformation]::OSDescription;process_architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString();PowerShell=$PSVersionTable.PSVersion.ToString()}
 if($report.environment.process_architecture -cne 'X64' -or ![OperatingSystem]::IsWindows()){throw 'Windows x64 required'}
 $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8
 $null=New-Item -ItemType Directory -Path $work;$created=$true;$report.status='running';Save-Report
 $version=Child $compiler @('--version') 60;if($version.stdout -cne 'rustc 1.98.1 (48a229cea 2026-09-01)'){throw 'Compiler version'}
 $report.compile_settings=@('--edition=2024','--cfg','frame_audit','--cfg','primitive_audit','-C','opt-level=3','-C','lto=thin','-C','codegen-units=1','-C','panic=unwind','-C','overflow-checks=yes','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE')
 $report.compile_limit_seconds=60;$report.native_limit_seconds=120;$report.compile_calls=1
 $null=Child $compiler (@((Join-Path $PSScriptRoot 'probe.rs'))+$report.compile_settings+@('-o',$exe)) 60
 $report.executable_before=Identity $exe;if($report.executable_before.bytes -gt 1048576){throw 'EXE 1MiB'};$locks.Add([IO.File]::Open($exe,'Open','Read','Read'))
 $report.total_native_calls=1;$native=Child $exe @('screen',$fixedInputPath) 120
 if($native.stderr){throw 'Unexpected native stderr'}
 $n=$native.stdout|ConvertFrom-Json -Depth 32 -DateKind String;$report.screen=$n;Save-Report
 Need-Exact $n.status 'passed' 'status';Need-Exact $n.kind 'direct_exact_context_loss_only' 'kind'
 $hf=$n.E2E.happy.fenwick;foreach($pair in @(@('rows',3),@('updates',16256),@('rescales',1),@('maximum_total',32767),@('dense_and_old_prefix_checks',4194822),@('terminal_nodes',771))){Need-Exact $hf.($pair[0]) $pair[1] $pair[0]};Need-Exact $hf.all_leaf_total_equal $true 'old u32 leaf/total equality'
 $hd=$n.E2E.happy.dictionary;Need-Exact $hd.collision_keys 4 'dictionary collisions';Need-Exact $hd.deterministic_maps 2 'decoder deterministic maps';Need-Exact $hd.existing_key_reregistrations 4 'reregistration';Need-Exact $hd.whole_map_equal $true 'two full arrays'
 $hm=$n.E2E.happy.mixture;foreach($pair in @(@('full_CDF_interval_checks',524),@('posterior_weights',4),@('whole_observed_banks',4),@('observations',1))){Need-Exact $hm.($pair[0]) $pair[1] $pair[0]};Need-Exact $hm.dense_oracle_equal $true 'mixture dense oracle'
 $af=$n.E2E.adversarial.fenwick;Need-Exact $af.range_rejections 4 'Fenwick range';Need-Exact $af.constructor_rejections 1 'Fenwick constructor';Need-Exact $af.whole_frequency_state_unchanged $true 'Fenwick rejection state'
 $ad=$n.E2E.adversarial.dictionary;Need-Exact $ad.rejections 4 'map rejects';Need-Exact $ad.constructor_rejections 2 'map constructors';Need-Exact $ad.whole_map_rejection_state_unchanged $true 'map state'
 $am=$n.E2E.adversarial.mixture;foreach($pair in @(@('full_pool_rejections',1),@('token_limit_rejections',3),@('key_rejections',4),@('weight_rejections',6),@('nonstationary_stale_rejections',1))){Need-Exact $am.($pair[0]) $pair[1] $pair[0]};Need-Exact $am.whole_logical_rejection_state_unchanged $true 'partial registration';Need-Exact $am.stationary_stale_guarantee $false 'stale scope'
 foreach($pair in @(@('input_reads',1),@('BWT_calls',1),@('fixed_Front_walks',1),@('frame_encodes',0),@('frame_decodes',0),@('raw_event_Vecs',0),@('runs',889227),@('primary',1762795),@('escape_bytes',742),@('history_checks',1778454),@('model_heap_capacity_bytes',120652224),@('terminal_rows_checked',114720),@('terminal_leaf_and_Fenwick_node_checks',29483040),@('mix_phase_precomputed_worst_bytes',141613654),@('BWT_phase_RAM_estimate_bytes',141598926),@('RAM_estimate_limit_bytes',167772160))){Need-Exact $n.($pair[0]) $pair[1] $pair[0]}
 if([Numerics.BigInteger]$n.grammar -ne [Numerics.BigInteger]::Parse('6373537040327497557') -or @($n.tokens).Count -ne 2 -or $n.tokens[0] -ne 889227 -or $n.tokens[1] -ne 889227){throw 'Frozen grammar/token totals'}
 if([math]::Abs(($n.quantized_component_loss_bits[0]+$n.quantized_component_loss_bits[1])-$n.quantized_total_loss_bits) -gt 0.000001 -or $n.Q_token_bytes_ceil -ne [math]::Ceiling($n.quantized_total_loss_bits/8) -or $n.screen_bytes -ne $n.Q_token_bytes_ceil+3079 -or $n.necessary_size_condition_passed -ne ($n.screen_bytes -le 483599) -or $n.minimum_actual_Q_frequency -lt 1){throw 'Loss/necessary screen arithmetic'}
 if($n.model_inline_bytes -gt 4096 -or $n.mix_working_RAM_estimate_bytes -gt 141613654 -or $n.model_total_capacity_and_inline_bytes -ne $n.model_heap_capacity_bytes+$n.model_inline_bytes){throw 'RAM capacity estimate'}
 Need-Exact $n.terminal_all_exact_maps_checked $true 'terminal maps';Need-Exact $n.all_updates_dense_oracle $false 'oracle scope';Need-Exact $n.f64_floor_portable_wire_verified $false 'wire scope'
 if(@($n.banks).Count -ne 4){throw 'Four banks'}
 $rows=@(32,16384,65536,32768);$used=@(53860,21737)
 for($i=0;$i -lt 4;$i++){$b=$n.banks[$i];Need-Exact $b.rows $rows[$i] 'bank rows';Need-Exact $b.tree_element_bytes 2 'u16 tree';Need-Exact $b.model_row_aliases 0 'alias absent';Need-Exact $b.token_updates 1778454 'updates';Need-Exact $b.prefix_queries 3556908 'queries';if($i -ge 2){Need-Exact $b.exact_map.capacity_rows $rows[$i] 'map capacity';Need-Exact $b.exact_map.used_rows $used[$i-2] 'map keys'}}
 Need-Exact $n.memory.API_calls 1 'WinAPI once';Need-Exact $n.memory.ABI_size 80 'WinAPI extent';Need-Exact $n.memory.ABI_cb 80 'WinAPI cb';Need-Exact $n.memory.ABI_checked $true 'WinAPI ABI'
 $report.status=if($n.peak_resource_gate_passed -eq $false){'diagnostic-resource-unmet'}else{'diagnostic-passed'}
 $report.size_gate_passed=[bool]$n.necessary_size_condition_passed;$report.adoption_scope='private loss-only; no coder/wire/performance adoption; no sweep or retry'
 $report.executable_after=Identity $exe;if(!(Same-ExactIdentity $report.executable_before $report.executable_after)){throw 'EXE changed'}
 $report.owned_exe_processes=@(Get-Process|Where-Object {$_.Path -eq $exe}).Count;if($report.owned_exe_processes){throw 'Owned EXE remains'}
 $entries=@(Get-ChildItem -LiteralPath $work -Force);if($entries.Count -ne 2 -or @($entries|Where-Object {$_.PSIsContainer -or $_.FullName -notin @($exe,(Join-Path $work 'report.json')) -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'Output shape'}
}catch{$report.status='failed';$report.error=$_.Exception.Message;throw}finally{
 try{
  $report.sources_after=@($sources|ForEach-Object {$now=Identity $_.path;if(!(Same-ExactIdentity $_ $now)){throw "Source changed: $($_.path)"};$now})
  $report.identities_after=@($pins|ForEach-Object {$now=Identity $_.path;if(!(Same-ExactIdentity $_ $now)){throw "Frozen/tool/input changed: $($_.path)"};$now})
  $report.disk_after=& $guard -WorkDirectory $work -MaxRunMiB 8;$report.ended_utc=[DateTime]::UtcNow.ToString('o');Save-Report
  $finalGuard=& $guard -WorkDirectory $work -MaxRunMiB 8
 }finally{foreach($stream in $locks){$stream.Dispose()}}
}
[pscustomobject]@{status=$report.status;size_gate_passed=$report.size_gate_passed;report=Identity (Join-Path $work 'report.json');final_guard_after_report_save=$finalGuard;source_count=$report.source_count;source_bytes=$report.source_bytes;compile_calls=$report.compile_calls;native_calls=$report.total_native_calls}|ConvertTo-Json -Depth 6
