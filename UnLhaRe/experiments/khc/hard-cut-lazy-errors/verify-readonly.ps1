[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-hard-cut-lazy-errors-20261004'
$reportPath=Join-Path $work 'report.json'
function Require([bool]$ok,[string]$why){if(!$ok){throw $why}}
function Json($v){ConvertTo-Json -InputObject $v -Compress -Depth 64}
function Identity($v){
 $p=[IO.Path]::GetFullPath($v.path);$a=$p
 while($a){if(Test-Path -LiteralPath $a){Require (!((Get-Item -LiteralPath $a -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Reparse ancestor'};$a=[IO.Path]::GetDirectoryName($a)}
 $i=Get-Item -LiteralPath $p -Force
 Require (!$i.PSIsContainer -and $i.Length -eq $v.bytes -and (Get-FileHash -LiteralPath $p).Hash -ceq $v.sha256 -and $i.LastWriteTimeUtc.ToString('o') -ceq $v.mtime_utc) 'Live identity'
}
Require ((Get-FileHash -LiteralPath $reportPath).Hash -ceq '52B58473E868E882886E8A89E46CE910CD72FDACFBDFD5DBED0E96EA302DF953') 'Report SHA'
$r=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json -Depth 64 -DateKind String
Require ($r.status -ceq 'diagnostic-passed' -and $r.compile_calls -eq 1 -and $r.total_native_calls -eq 3 -and $r.children.Count -eq 5) 'Execution census'
$pairs=0
foreach($kind in @('sources','identities')){
 $before=@($r.($kind+'_before'));$after=@($r.($kind+'_after'));Require ($before.Count -eq $after.Count -and $before.Count -gt 0) 'Pair extent'
 for($i=0;$i -lt $before.Count;$i++){Require ((Json $before[$i]) -ceq (Json $after[$i])) 'Before-after';Identity $before[$i];$pairs++}
}
Require ($r.sources_before.Count -eq 21 -and $r.imports.Count -eq 22 -and ($r.sources_before|Measure-Object bytes -Sum).Sum -eq 143743) 'Source extent'
foreach($edge in $r.imports){Require (@($r.sources_before|Where-Object path -ceq $edge.source).Count -eq 1 -and @($r.sources_before|Where-Object path -ceq $edge.resolved).Count -eq 1) 'Closed edge'}
Require ($r.compile_settings -contains 'wire_audit') 'Wire cfg'
foreach($cfg in @('test','--test','frame_audit','primary_audit','primitive_audit')){Require ($r.compile_settings -notcontains $cfg) 'Disabled cfg'}
Require ($r.engine_ledger.extra_residual -eq 0 -and $r.engine_ledger.allowed_replacements -eq 2 -and $r.codec_ledger.extra_residual -eq 0 -and $r.codec_ledger.allowed_replacements_per_side -eq 1 -and $r.codec_ledger.copies_identical -and $r.runner_prefix_ledger.extra_residual -eq 0 -and $r.source_helper_ledger.extra_residual -eq 0 -and $r.source_parser_prices.excluded_suffix_UTF8_bytes -eq 1064) 'Allowlist ledgers'
Identity $r.executable_before;Identity $r.executable_after;Require ((Json $r.executable_before) -ceq (Json $r.executable_after)) 'Executable unchanged'
foreach($child in $r.children){Require ($child.exit_code -eq 0 -and !$child.failure -and !$child.stderr) 'Child completion'}
for($i=0;$i -lt 2;$i++){Require ((Json ($r.children[$i+2].stdout|ConvertFrom-Json -Depth 64 -DateKind String)) -ceq (Json $r.selfchecks[$i])) 'Raw self projection'}
$n=$r.paired_fixed
Require ((Json ($r.children[4].stdout|ConvertFrom-Json -Depth 64 -DateKind String)) -ceq (Json $n)) 'Raw pair projection'
$oldPath=Join-Path $project 'build/khc-causal-hard-cut-wire-20261004/report.json'
Require ((Get-FileHash -LiteralPath $oldPath).Hash -ceq 'B24F7E1953CD556BF14E3EB2191E6D043A832EB5002624BDD18C4202DF635871') 'Frozen wire SHA'
$old=Get-Content -LiteralPath $oldPath -Raw|ConvertFrom-Json -Depth 64 -DateKind String
foreach($s in $r.selfchecks){$h=$s.E2E;Require ($h.normal_cases -eq 14 -and $h.byte_roundtrips -eq 14 -and $h.canonical_cases -eq 14 -and $h.malformed_cases -eq 34 -and $h.malformed.Count -eq 34 -and $h.short_depth_header_checks -eq 4 -and (Json $h) -ceq (Json $old.selfcheck.E2E)) 'Both whole finite evidence'}
Require ($n.full_frames_equal -and $n.typed_Proof14_Eq_per_side -and !$n.cross_type_typed_Proof_Eq -and $n.cross_type_Debug_Proof14_exact_equal -and $n.full_stats_equal -and $n.Proof14_debug -ceq $old.fixed.Proof14_debug -and (Json $n.stats) -ceq (Json $old.fixed.encode_stats)) 'Direct frame/typed/debug/stats distinction'
Require ($n.input_reads -eq 1 -and $n.encode_calls_per_side -eq 1 -and $n.decode_calls_per_side -eq 1 -and $n.fixed_reencode_calls -eq 0 -and $n.matched_plain_bytes_per_side -eq 2811006 -and $n.matched_frame_bytes -eq 478856 -and $n.header_bytes+$n.payload_bytes -eq 478856) 'Fixed calls and size'
foreach($name in @('control_encode','control_decode','candidate_encode','candidate_decode')){
 $c=$n.$name
 foreach($value in @($c.alloc_calls,$c.alloc_requested_bytes,$c.alloc_zeroed_calls,$c.alloc_zeroed_requested_bytes,$c.realloc_calls,$c.realloc_requested_bytes,$c.total_calls,$c.total_requested_bytes)){Require ($null -ne $value -and [Numerics.BigInteger]$value -ge 0 -and [Numerics.BigInteger]$value -le [Numerics.BigInteger]::Parse('18446744073709551615')) 'u64 counters'}
 Require ($c.total_calls -eq $c.alloc_calls+$c.alloc_zeroed_calls+$c.realloc_calls -and $c.total_requested_bytes -eq $c.alloc_requested_bytes+$c.alloc_zeroed_requested_bytes+$c.realloc_requested_bytes) 'Counter sums'
}
$coded=[long]$n.stats.branches[0]+[long]$n.stats.branches[1]-122
Require ($coded -eq 3825218) 'Coded branches excluding implicit'
foreach($direction in @('encode','decode')){
 $a=$n.('control_'+$direction);$b=$n.('candidate_'+$direction)
 Require ($a.total_calls-$b.total_calls -eq $n.($direction+'_call_reduction') -and $a.total_requested_bytes-$b.total_requested_bytes -eq $n.($direction+'_requested_byte_reduction')) 'Measured deltas'
 Require ($n.($direction+'_call_reduction') -eq $coded*18 -and $n.($direction+'_requested_byte_reduction') -eq $coded*(12*16+6*18)) 'Source mechanism matches measured deltas'
}
Require ($n.both_call_counts_reduced -and !$n.all_allocation_counters_equal -and !$n.noninstrumented_allocation_verified -and !$n.instrumented_times_used_for_formal_speed -and !$n.speed_claimed -and !$n.adoption -and !$n.requested_bytes_are_resident_or_physical_malloc_bytes) 'Bounded interpretation'
Require ($n.model_source_RAM_bound_bytes -eq 21561264 -and $n.encoder_source_RAM_bound_bytes -eq 45723494 -and $n.inverse_source_RAM_bound_bytes -eq 48522666 -and $n.fixed_phase_source_RAM_bound_bytes -eq 48522666 -and $n.BWT_with_retained_frame_source_RAM_bound_bytes -eq 142647787) 'Source bounds'
foreach($m in @($r.selfchecks[0].memory,$r.selfchecks[1].memory,$n.memory)){Require ($m.measured -and $m.ABI_checked -and $m.API_calls -eq 1 -and $m.ABI_size -eq 80 -and $m.ABI_cb -eq 80 -and $null -eq $m.last_OS_error -and $m.peak_working_set_bytes -gt 0 -and $m.peak_working_set_bytes -le 167772160 -and $m.peak_private_commit_bytes -gt 0 -and $m.peak_private_commit_bytes -le 167772160) 'Three measured peak pairs'}
Require ($r.owned_exe_processes -eq 0 -and $n.disk_input_frame_plain_copies -eq 0) 'Process/copy census'
$files=@(Get-ChildItem -LiteralPath $work -Force)
Require ($files.Count -eq 2 -and @($files|Where-Object {$_.PSIsContainer -or $_.Name -notin @('report.json','hard-cut-lazy-errors-o3.exe')}).Count -eq 0 -and ($files|Measure-Object Length -Sum).Sum -eq 634077) 'Output shape'
[pscustomobject]@{status='readonly-verified';identity_pairs=$pairs;raw_projections=3;allocation_calls_reduced_per_direction=$n.encode_call_reduction;requested_bytes_reduced_per_direction=$n.encode_requested_byte_reduction;full_frame_bytes=478856;compile_calls=0;native_calls=0;generated_bytes=634077}|ConvertTo-Json
