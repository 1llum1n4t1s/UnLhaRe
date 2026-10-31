[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[A-F0-9]{64}$')][string]$ReportSha256)
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-hard-cut-stage-profile-20261004'
$reportPath=Join-Path $work 'report.json'
function Require([bool]$ok,[string]$why){if(!$ok){throw $why}}
function Json($v){ConvertTo-Json -InputObject $v -Compress -Depth 64}
function Near([double]$a,[double]$b){Require ([double]::IsFinite($a) -and [double]::IsFinite($b) -and [math]::Abs($a-$b) -le 1e-12*[math]::Max(1.0,[math]::Max([math]::Abs($a),[math]::Abs($b)))) 'Estimated arithmetic'}
function Identity($v){
 $p=[IO.Path]::GetFullPath($v.path);$a=$p
 while($a){if(Test-Path -LiteralPath $a){Require (!((Get-Item -LiteralPath $a -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Reparse ancestor'};$a=[IO.Path]::GetDirectoryName($a)}
 $i=Get-Item -LiteralPath $p -Force
 Require (!$i.PSIsContainer -and $i.Length -eq $v.bytes -and (Get-FileHash -LiteralPath $p).Hash -ceq $v.sha256 -and $i.LastWriteTimeUtc.ToString('o') -ceq $v.mtime_utc) 'Live identity'
}
Require ((Get-FileHash -LiteralPath $reportPath).Hash -ceq $ReportSha256) 'Report SHA'
$r=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json -Depth 64 -DateKind String
# 元runnerと失敗reportは実行証拠として凍結。数値実行は再起動せず照合段だけ修復する。
$recovered=$r.status -ceq 'failed'
if($recovered){Require ($ReportSha256 -ceq 'EBAFECF71276F59F19C4041CF806C9993A8ED4BEB22B6D1421C83F89FE70566C' -and $r.error -like 'Cannot convert argument *2482488208.226507*System.Int32*') 'Exact known validator failure'}
Require (($recovered -or $r.status -ceq 'diagnostic-passed') -and $r.compile_calls -eq 1 -and $r.total_native_calls -eq 2 -and $r.children.Count -eq 4) 'Execution census'
function Need($a,$b,[string]$why){Require ($a -ceq $b) $why}
function Same($a,$b){(Json $a) -ceq (Json $b)}
$runner=Join-Path $PSScriptRoot 'run-native.ps1'
Require ((Get-FileHash $runner).Hash -ceq '323A12CF6991EBAE47BAC58759CF709EDEA5D16E36F3EC9D95364242CE94570A') 'Frozen runner SHA'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors);Require ($errors.Count -eq 0) 'Runner AST'
foreach($name in @('Estimate-Near','Profile-Gate')){
 $defs=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true));Require ($defs.Count -eq 1) 'Replay definition count';$text=$defs[0].Extent.Text
 if($name -ceq 'Estimate-Near'){$needle='[math]::Max(1,[math]';Require ([regex]::Matches($text,[regex]::Escape($needle)).Count -eq 1) 'Exact overload repair count';$text=$text.Replace($needle,'[math]::Max(1.0,[math]')}
 . ([scriptblock]::Create($text))
}
Profile-Gate $r.fixed.encode_profile 'Encode' $r.fixed.encode_stats.branches $r.fixed.diagnostic_encode_ns @(1,0,1)
Profile-Gate $r.fixed.decode_profile 'Decode' $r.fixed.encode_stats.branches $r.fixed.diagnostic_decode_ns @(0,1,1)
$pairs=0
foreach($kind in @('sources','identities')){
 $before=@($r.($kind+'_before'));$after=@($r.($kind+'_after'));Require ($before.Count -eq $after.Count -and $before.Count -gt 0) 'Identity extent'
 for($i=0;$i -lt $before.Count;$i++){Require ((Json $before[$i]) -ceq (Json $after[$i])) 'Before-after';Identity $before[$i];$pairs++}
}
Require ($r.sources_before.Count -eq 20 -and $r.imports.Count -eq 19 -and ($r.sources_before|Measure-Object bytes -Sum).Sum -eq $r.source_bytes -and $r.source_bytes -le 307200) 'Closed source extent'
foreach($edge in $r.imports){Require (@($r.sources_before|Where-Object path -ceq $edge.source).Count -eq 1 -and @($r.sources_before|Where-Object path -ceq $edge.resolved).Count -eq 1) 'Closed edge'}
Require ($r.compile_settings -contains 'wire_audit') 'Wire cfg'
foreach($cfg in @('test','--test','frame_audit','primary_audit','primitive_audit')){Require ($r.compile_settings -notcontains $cfg) 'Disabled cfg'}
Require ($r.profile_model_ledger.stage_wrappers -eq 4 -and $r.profile_model_ledger.extra_residual -eq 0 -and $r.profile_model_ledger.numerical_functions_types_order_Result_unchanged -and $r.profile_codec_ledger.allowed_replacements -eq 6 -and $r.profile_codec_ledger.extra_residual -eq 0 -and $r.profile_codec_ledger.numerical_processing_unchanged) 'Observational ledgers'
Identity $r.executable_before
if(!$recovered){Identity $r.executable_after;Require ((Json $r.executable_before) -ceq (Json $r.executable_after)) 'Executable unchanged'}
foreach($child in $r.children){Require ($child.exit_code -eq 0 -and !$child.failure -and !$child.stderr) 'Child completion'}
$lines=@($r.children[2].stdout -split '\r?\n'|Where-Object {$_})
Require ($lines.Count -eq 2) 'Self NDJSON exact2'
Require ((Json ($lines[0]|ConvertFrom-Json -Depth 64 -DateKind String)) -ceq (Json $r.profile_fixtures) -and (Json ($lines[1]|ConvertFrom-Json -Depth 64 -DateKind String)) -ceq (Json $r.selfcheck) -and (Json ($r.children[3].stdout|ConvertFrom-Json -Depth 64 -DateKind String)) -ceq (Json $r.fixed)) 'Three raw projections'
$f=$r.profile_fixtures;$h=$r.selfcheck.E2E;$n=$r.fixed
Require ($f.status -ceq 'passed' -and $f.synthetic.synthetic_fixtures -eq 15 -and $f.synthetic.core_branches -eq 3080 -and $f.synthetic.core_samples -eq 16 -and $f.synthetic.core_child_attempts_each -eq 3080 -and $f.synthetic.core_child_pairs_each -eq 16 -and $f.synthetic.core_parent_ns -eq 160 -and $f.synthetic.core_child_ns_each -eq 16 -and $f.synthetic.core_residual_ns -eq 96 -and !$f.synthetic.runtime_clock_claim) 'Synthetic census'
Require ($f.actual.cases -eq 3 -and $f.actual.LCG_seed -eq 1831565813 -and $f.actual.truncated_payload_bytes -eq 5 -and $f.actual.numeric_error -ceq 'truncated range stream' -and $f.actual.aborts -ge 1 -and $f.actual.pending_none -and $f.actual.sameprocess_recovery -and $f.actual.direction_reset -and $f.actual.allframe_Proof14_stats_plain_compared -and $f.actual.rejection_sample_clock_observed -eq ($f.actual.rejection_samples -gt 0)) 'Actual codec lifecycle'
Require ($h.normal_cases -eq 14 -and $h.byte_roundtrips -eq 14 -and $h.canonical_cases -eq 14 -and $h.malformed_cases -eq 34 -and $h.malformed.Count -eq 34 -and $h.short_depth_header_checks -eq 4 -and $h.CRC32_known_fixture) 'Original finite census'
$oldPath=Join-Path $project 'build/khc-hard-cut-model-lazy-20261004/report.json'
Require ((Get-FileHash -LiteralPath $oldPath).Hash -ceq '62B93E3FF942CEB13ECD6572DAD6CDBBE4DD45F88B72512E9348BBA4812BBEF3') 'Normal predecessor SHA'
$old=Get-Content -LiteralPath $oldPath -Raw|ConvertFrom-Json -Depth 64 -DateKind String
Require ((Json $h) -ceq (Json $old.selfcheck.E2E) -and (Json $n.encode_stats) -ceq (Json $old.fixed.encode_stats) -and (Json $n.decode_stats) -ceq (Json $old.fixed.encode_stats) -and $n.Proof14_debug -ceq $old.fixed.Proof14_debug) 'Full frozen finite stats Proof'
Require ($n.input_reads -eq 1 -and $n.disabled_encode_calls -eq 1 -and $n.encode_calls -eq 1 -and $n.decode_calls -eq 1 -and $n.fixed_reencode_calls -eq 0 -and $n.matched_plain_bytes -eq 2811006 -and $n.all_frame_bytes_directly_compared -and $n.all_plain_bytes_compared -and $n.typed_Proof14_Eq -and $n.all_stats_equal -and $n.header_layout_and_CRC_checked) 'Fixed direct checks'
Require ($n.frame_bytes -eq 478856 -and $n.header_bytes -eq 285 -and $n.payload_bytes -eq 478571 -and $n.size_gate_limit_bytes -eq 483599 -and $n.size_gate_passed -and $n.frame_bytes -eq $n.header_bytes+$n.payload_bytes) 'Actual size'
Require ((Json $n.encode_profile.Model_prefixes) -ceq (Json $n.decode_profile.Model_prefixes)) 'Direction prefix equality'
foreach($entry in @(@($n.encode_profile,'Encode',$n.diagnostic_encode_ns,@(1,0,1)),@($n.decode_profile,'Decode',$n.diagnostic_decode_ns,@(0,1,1)))){
 $p=$entry[0];Require ($p.direction -ceq $entry[1] -and $p.whole_codec_ns -eq $entry[2] -and $p.strata.Count -eq 8 -and $p.whole.Count -eq 3 -and $p.Model_prefixes.Count -eq 2 -and !$p.pending_branch -and !$p.pending_stage -and !$p.pending_whole -and !$p.synthetic -and $null -eq $p.first_fault -and $p.fault_count -eq 0) 'Profile lifecycle'
 $totals=@(0L,0L);$sum=@(0.0,0.0,0.0,0.0)
 for($idx=0;$idx -lt 8;$idx++){
  $row=$p.strata[$idx];$c=[int][math]::Floor($idx/4);$k=$idx%4;$count=[long]$row.branch.attempts
  Require ($row.component -eq $c -and $row.prefix -eq $k+1 -and $p.Model_prefixes[$c].Count -eq 4 -and $p.Model_prefixes[$c][$k] -eq $count -and $row.children.Count -eq 4) 'Independent strata mirror'
  $samples=if($count -lt 128){0L}else{[long][math]::Floor(($count-128)/256)+1};Require ($row.samples -eq $samples) 'Systematic sample';$totals[$c]+=$count
  foreach($b in @($row.branch)+@($row.children)){Require ($b.attempts -eq $count -and $b.success -eq $count -and $b.error -eq 0 -and $b.timer_starts -eq $samples -and $b.timer_ends -eq $samples -and $b.timer_pairs -eq $samples -and $b.ns -ge 0 -and (($samples -eq 0 -and $b.ns -eq 0) -or ($samples -gt 0 -and $b.ns -gt 0))) 'Bucket census'}
  $cts=[decimal]$row.children[0].ns+[decimal]$row.children[3].ns;$pool=[decimal]$row.children[1].ns+[decimal]$row.children[2].ns;$res=[decimal]$row.branch.ns-$cts-$pool
  Require ($res -ge 0 -and $row.sampled_CTS_ns -eq $cts -and $row.sampled_pool_ns -eq $pool -and $row.sampled_residual_ns -eq $res) 'Raw residual arithmetic'
  $w=if($samples -eq 0){0.0}else{[double]$count/$samples};$values=@(([double]$row.branch.ns*$w),([double]$cts*$w),([double]$pool*$w),([double]$res*$w))
  $names=@('estimated_parent_ns','estimated_CTS_ns','estimated_pool_ns','estimated_residual_ns');for($j=0;$j -lt 4;$j++){Near $row.($names[$j]) $values[$j];$sum[$j]+=$values[$j]}
 }
 Require ((Json $totals) -ceq '[2725772,1099568]') 'Component total'
 $names=@('estimated_parent_ns','estimated_CTS_ns','estimated_pool_ns','estimated_residual_ns');for($j=0;$j -lt 4;$j++){Near $p.($names[$j]) $sum[$j]};Near $sum[0] ($sum[1]+$sum[2]+$sum[3]);Near $p.estimated_whole_residual_ns ([double]$entry[2]-$sum[0])
 Require (!$p.negative_estimate_clamped -and !$p.formal_CPU_fraction_claimed -and $p.estimate_within_whole -eq ($p.estimated_whole_residual_ns -ge 0)) 'Signed estimate not formal fraction'
 for($j=0;$j -lt 3;$j++){$b=$p.whole[$j];$want=$entry[3][$j];Require ($b.attempts -eq $want -and $b.success -eq $want -and $b.error -eq 0 -and $b.timer_starts -eq $want -and $b.timer_ends -eq $want -and $b.timer_pairs -eq $want -and (($want -eq 0 -and $b.ns -eq 0) -or ($want -gt 0 -and $b.ns -gt 0))) 'Whole bucket'}
}
Require ($n.profiler_combined_actual_bytes -eq $n.encode_profile.state_bytes+$n.profiler_snapshot_Report_bytes+$n.profiler_mirror_Cell_and_copies_bytes -and $n.profiler_combined_actual_bytes -le 65536 -and $n.profiler_source_reservation_bytes -eq 65536 -and $n.reference_frame_dropped_before_restore) 'Profiler capacity'
Require ($n.model_working_RAM_estimate_bytes -eq 16777216+$n.primary_source_bound_bytes+4*65536+4194304 -and $n.encoder_phase_RAM_estimate_bytes -eq $n.input_capacity+2*2811007+1048576*12+1048576+2*1048861+$n.model_working_RAM_estimate_bytes -and $n.inverse_phase_RAM_estimate_bytes -eq $n.input_capacity+$n.frame_capacity+14*2811007+2*65536+4194304 -and $n.model_working_RAM_estimate_bytes -le 33554432 -and $n.fixed_phase_RAM_estimate_bytes -le 67108864) 'Source RAM bounds'
foreach($m in @($r.selfcheck.memory,$n.memory)){Require ($m.measured -and $m.ABI_checked -and $m.API_calls -eq 1 -and $m.ABI_size -eq 80 -and $m.ABI_cb -eq 80 -and $null -eq $m.last_OS_error -and $m.peak_working_set_bytes -gt 0 -and $m.peak_working_set_bytes -le 167772160 -and $m.peak_private_commit_bytes -gt 0 -and $m.peak_private_commit_bytes -le 167772160) 'Both native measured peaks'}
Require ($n.clock_pair_count -eq 10000 -and $n.clock_pair_total_ns -ge 0 -and !$n.clock_correction_subtracted -and !$n.disabled_reference_is_independent_oracle -and !$n.speed_claimed -and !$n.portable_wire_verified -and !$n.adoption -and !$r.custom_allocator_linked -and !$r.normal_binary_old_frame_directly_compared) 'Nonclaims'
Require ($n.disk_frames -eq 0 -and $n.disk_restores -eq 0 -and $n.raw_event_Vecs -eq 0 -and @(Get-Process|Where-Object {$_.Path -eq $r.executable_before.path}).Count -eq 0) 'No disk copies or remaining processes'
$files=@(Get-ChildItem -LiteralPath $work -Force);$bytes=($files|Measure-Object Length -Sum).Sum
Require ($files.Count -eq 2 -and @($files|Where-Object {$_.PSIsContainer -or $_.Name -notin @('report.json','hard-cut-stage-profile-o3.exe') -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count -eq 0 -and $bytes -le 8MB) 'Output shape'
[pscustomobject]@{status='readonly-verified';recovered_validator_overload=$recovered;original_report_status=$r.status;original_Profile_Gate_replayed=$true;report_sha256=$ReportSha256;identity_pairs=$pairs;raw_projections=3;source_count=20;finite_normal=14;finite_malformed=34;synthetic_fixtures=15;actual_codec_cases=3;frame_bytes=$n.frame_bytes;generated_bytes=$bytes;compile_calls=0;native_calls=0}|ConvertTo-Json
