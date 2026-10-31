[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-direct-exact-context-20261004'
$reportPath=Join-Path $work 'report.json'
$exe=Join-Path $work 'direct-exact-context-o3-thin.exe'
$streams=[Collections.Generic.List[IO.FileStream]]::new()
function Identity-Exact([string]$Path){$p=[IO.Path]::GetFullPath($Path);$ancestor=$p;while($ancestor){if(Test-Path -LiteralPath $ancestor){if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse path'}};$ancestor=[IO.Path]::GetDirectoryName($ancestor)};$i=Get-Item -LiteralPath $p -Force;if($i.PSIsContainer){throw 'Expected file'};[pscustomobject]@{path=$p;sha256=(Get-FileHash -LiteralPath $p).Hash;bytes=$i.Length;mtime_utc=$i.LastWriteTimeUtc.ToString('o')}}
function Need($Value,$Expected,[string]$Name){if($Value -cne $Expected){throw "$Name expected $Expected got $Value"}}
function Same-Identity($A,$B){$A.path -ceq $B.path -and $A.sha256 -ceq $B.sha256 -and $A.bytes -eq $B.bytes -and [DateTime]::Parse($A.mtime_utc).ToUniversalTime().Ticks -eq [DateTime]::Parse($B.mtime_utc).ToUniversalTime().Ticks}
function Compare-Pins($Before,$After,[int]$Expected){Need @($Before).Count $Expected 'pin count';Need @($After).Count $Expected 'after count';if(@($Before.path|Select-Object -Unique).Count -ne $Expected){throw 'Duplicate pin path'};for($i=0;$i -lt $Expected;$i++){$a=$Before[$i];$b=$After[$i];if(!(Same-Identity $a $b)){throw 'Before/after identity mismatch'};$streams.Add([IO.File]::Open($a.path,'Open','Read','Read'));if(!(Same-Identity $a (Identity-Exact $a.path))){throw "Live identity mismatch $($a.path)"}}}
function Fields($Object,$Expected){foreach($p in $Expected.GetEnumerator()){Need $Object.($p.Key) $p.Value $p.Key}}
try{
 $streams.Add([IO.File]::Open($reportPath,'Open','Read','Read'));$rid=Identity-Exact $reportPath
 Need $rid.sha256 '395911C6D71079AF4E739E4C1CF8482F0089BDA02EDD88E51E274199A0C9A305' 'report SHA';Need $rid.bytes 40973 'report bytes'
 $r=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json -Depth 32 -DateKind String
 Fields $r @{status='diagnostic-passed';compile_calls=1;total_native_calls=1;source_count=14;source_bytes=67679;diagnostic_only=$true;coder_implemented=$false;raw_traces=0;disk_frame_plain_input_copies=0;frozen_entrypoints_executed=$false;CPU_quiet_verified=$false;owned_exe_processes=0;size_gate_passed=$false;compile_limit_seconds=60;native_limit_seconds=120}
 Compare-Pins $r.sources_before $r.sources_after 14;Compare-Pins $r.identities_before $r.identities_after 24
 Need @($r.imports).Count 13 'source graph edges';foreach($edge in $r.imports){if($edge.source -notin $r.sources_before.path -or $edge.resolved -notin $r.sources_before.path){throw 'Graph pin missing'}}
 $streams.Add([IO.File]::Open($exe,'Open','Read','Read'));$eid=Identity-Exact $exe
 if(!(Same-Identity $r.executable_before $r.executable_after) -or !(Same-Identity $r.executable_after $eid)){throw 'EXE identity'}
 Need $eid.sha256 '64B7E0FA98B737AB4A430425983509A4DD25F6542B71C91497E19ADEDED254E3' 'EXE SHA';Need $eid.bytes 285184 'EXE bytes'
 $settings=@('--edition=2024','--cfg','frame_audit','--cfg','primitive_audit','-C','opt-level=3','-C','lto=thin','-C','codegen-units=1','-C','panic=unwind','-C','overflow-checks=yes','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE')
 if(($settings|ConvertTo-Json -Compress) -cne ($r.compile_settings|ConvertTo-Json -Compress)){throw 'Fixed compile settings'}
 Need @($r.children).Count 3 'compiler version/compile/native children';foreach($c in $r.children){Need $c.exit_code 0 'child exit';if($c.failure -or [Text.Encoding]::UTF8.GetByteCount($c.stdout) -gt 65536 -or [Text.Encoding]::UTF8.GetByteCount($c.stderr) -gt 16384){throw 'Bounded child failure/stream'};if($c.elapsed_ms -gt 120000){throw 'Child timeout bound'}}
 if($r.children[1].elapsed_ms -gt 60000 -or $r.children[2].file -cne $exe -or @($r.children[2].arguments).Count -ne 2 -or $r.children[2].arguments[0] -cne 'screen'){throw 'Single bounded screen invocation'}
 $native=$r.children[2].stdout|ConvertFrom-Json -Depth 32 -DateKind String
 if(($native|ConvertTo-Json -Depth 32 -Compress) -cne ($r.screen|ConvertTo-Json -Depth 32 -Compress)){throw 'Native stdout/report projection'}
 $n=$r.screen
 Fields $n @{status='passed';kind='direct_exact_context_loss_only';input_reads=1;BWT_calls=1;fixed_Front_walks=1;frame_encodes=0;frame_decodes=0;raw_event_Vecs=0;runs=889227;primary=1762795;escape_bytes=742;history_checks=1778454;minimum_actual_Q_frequency=2;Q_token_bytes_ceil=563758;model_table_saved_bytes=0;policy_metadata_defined=$false;framing_bytes=285;model_bitlength_bytes=4;coder_reserve_bytes=2048;screen_bytes=566837;necessary_size_condition_passed=$false;model_heap_capacity_bytes=120652224;model_inline_bytes=1992;model_total_capacity_and_inline_bytes=120654216;inline_Metadata_worst_bytes=4096;mix_working_RAM_estimate_bytes=141611550;mix_phase_precomputed_worst_bytes=141613654;BWT_phase_RAM_estimate_bytes=141598926;RAM_estimate_limit_bytes=167772160;run_capacity=1048576;input_capacity=2811006;terminal_rows_checked=114720;terminal_leaf_and_Fenwick_node_checks=29483040;terminal_all_exact_maps_checked=$true;all_updates_dense_oracle=$false;f64_floor_portable_wire_verified=$false;peak_resource_gate_passed=$true}
 Need ([Numerics.BigInteger]$n.grammar) ([Numerics.BigInteger]::Parse('6373537040327497557')) 'grammar';Need @($n.tokens).Count 2 'tokens count';Need $n.tokens[0] 889227 'rank tokens';Need $n.tokens[1] 889227 'length tokens'
 foreach($kind in @('quantized','unquantized')){$a=$n.($kind+'_component_loss_bits');$total=$n.($kind+'_total_loss_bits');if(@($a).Count -ne 2 -or ![double]::IsFinite($total) -or $a[0] -lt 0 -or $a[1] -lt 0 -or [math]::Abs(($a[0]+$a[1])-$total) -gt 0.000001){throw 'Component loss sum'}}
 if([math]::Abs($n.quantized_total_loss_bits-4510058.854214707) -gt 0.000001 -or [math]::Abs($n.unquantized_total_loss_bits-4494715.340974132) -gt 0.000001 -or $n.Q_token_bytes_ceil -ne [math]::Ceiling($n.quantized_total_loss_bits/8) -or $n.screen_bytes -ne $n.Q_token_bytes_ceil+3079 -or $n.screen_bytes-483599 -ne 83238){throw 'Necessary loss/size gate'}
 Fields $n.E2E.happy.fenwick @{rows=3;updates=16256;rescales=1;maximum_total=32767;dense_and_old_prefix_checks=4194822;terminal_nodes=771;all_leaf_total_equal=$true}
 Fields $n.E2E.happy.dictionary @{collision_keys=4;deterministic_maps=2;existing_key_reregistrations=4;whole_map_equal=$true}
 Fields $n.E2E.happy.mixture @{full_CDF_interval_checks=524;posterior_weights=4;whole_observed_banks=4;observations=1;dense_oracle_equal=$true}
 Fields $n.E2E.adversarial.fenwick @{range_rejections=4;constructor_rejections=1;whole_frequency_state_unchanged=$true}
 Fields $n.E2E.adversarial.dictionary @{rejections=4;constructor_rejections=2;whole_map_rejection_state_unchanged=$true}
 Fields $n.E2E.adversarial.mixture @{full_pool_rejections=1;token_limit_rejections=3;key_rejections=4;weight_rejections=6;nonstationary_stale_rejections=1;whole_logical_rejection_state_unchanged=$true;stationary_stale_guarantee=$false}
 Need @($n.banks).Count 4 'bank count';$rows=@(32,16384,65536,32768);$used=@(10,2423,53860,21737);$heap=0L
 for($i=0;$i -lt 4;$i++){$b=$n.banks[$i];Fields $b @{rows=$rows[$i];registered_rows=$used[$i];model_row_aliases=0;leaf_len=($rows[$i]*257);leaf_capacity=($rows[$i]*257);tree_len=($rows[$i]*258);tree_capacity=($rows[$i]*258);tree_element_bytes=2;total_capacity=$rows[$i];first_key_capacity=$rows[$i];prefix_queries=3556908;token_updates=1778454}
  $bankBytes=2L*$b.leaf_capacity+2L*$b.tree_capacity+4L*$b.total_capacity+4L*$b.first_key_capacity
  if($i -lt 2){if($null -ne $b.exact_map){throw 'Unexpected direct map'}}else{$m=$b.exact_map;Fields $m @{capacity_rows=$rows[$i];used_rows=$used[$i];key_slot_len=($rows[$i]*2);key_slot_capacity=($rows[$i]*2);row_slot_len=($rows[$i]*2);row_slot_capacity=($rows[$i]*2);allocation_bytes=($rows[$i]*16)};$bankBytes+=$m.allocation_bytes}
  Need $bankBytes $b.allocation_heap_bytes 'bank capacity bytes';$heap+=$bankBytes;if($b.rebuild_leaves -ne $b.rescales*257){throw 'Rescale operation counts'}
 }
 Need $heap 120652224 'total heap capacity';Need ($heap+$n.model_inline_bytes) $n.model_total_capacity_and_inline_bytes 'inline accounting';Need ($heap+$n.model_inline_bytes+$n.run_capacity*12+$n.input_capacity+1369112+4194304) $n.mix_working_RAM_estimate_bytes 'phase accounting'
 Fields $n.memory @{API_calls=1;ABI_size=80;ABI_cb=80;ABI_checked=$true;measured=$true;peak_working_set_bytes=138993664;peak_private_commit_bytes=137695232;peak_gate_passed=$true}
 if($n.memory.last_OS_error -ne $null -or $n.memory.peak_working_set_bytes -gt 167772160 -or $n.memory.peak_private_commit_bytes -gt 167772160 -or $n.mix_phase_precomputed_worst_bytes -gt 167772160){throw 'Resource gate'}
 $oldReport=Join-Path $project 'build/khc-causal-direct-mix-20261004/corrected-native/report.json';$old=Get-Content -LiteralPath $oldReport -Raw|ConvertFrom-Json -Depth 32 -DateKind String
 Need $old.diagnostic.screen_bytes 568897 'old frozen screen';Need ($old.diagnostic.screen_bytes-$n.screen_bytes) 2060 'same-policy size difference'
 $processes=@(Get-Process|Where-Object {$_.Path -eq $exe}).Count;Need $processes 0 'owned processes'
 $entries=@(Get-ChildItem -LiteralPath $work -Force);Need $entries.Count 2 'artifact count';foreach($i in $entries){if($i.PSIsContainer -or $i.FullName -notin @($exe,$reportPath) -or ($i.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Output shape'}}
 $guard=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8
 Need $guard.used_bytes 326157 'final actual disk bytes';Need $guard.max_bytes 8388608 'output guard'
 [pscustomobject]@{status='verified-readonly';before_after_live_pin_pairs=38;executable_live_verified=$true;source_count=14;source_bytes=67679;compile_calls=1;native_calls=1;screen_bytes=566837;size_gate_passed=$false;old_screen_difference_bytes=2060;terminal_pairs=29483040;final_disk_guard=$guard;owned_exe_processes=$processes;report=$rid;executable=$eid;recompiled=$false;native_rerun=$false}|ConvertTo-Json -Depth 6
}finally{foreach($s in $streams){$s.Dispose()}}
