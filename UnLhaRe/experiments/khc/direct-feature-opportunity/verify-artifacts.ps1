[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-direct-feature-opportunity-20261004'
$savedReport=Join-Path $work 'report.json'
function Identity([string]$Path){$resolved=[IO.Path]::GetFullPath($Path);$ancestor=$resolved;while($ancestor){if(Test-Path -LiteralPath $ancestor){if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse ancestor'}};$ancestor=[IO.Path]::GetDirectoryName($ancestor)};$item=Get-Item -LiteralPath $resolved -Force;if($item.PSIsContainer){throw 'Expected file'};[pscustomobject]@{path=$resolved;sha256=(Get-FileHash -LiteralPath $resolved).Hash;bytes=$item.Length;mtime_utc=$item.LastWriteTimeUtc.ToString('o')}}
function Same($A,$B){foreach($field in @('path','sha256','bytes','mtime_utc')){if($A.$field -cne $B.$field){return $false}};return $true}
function Near([double]$A,[double]$B,[double]$Tolerance=0.000001){if(![double]::IsFinite($A) -or ![double]::IsFinite($B) -or [Math]::Abs($A-$B) -gt $Tolerance){throw "Finite arithmetic mismatch: $A vs $B"}}
if((Identity $savedReport).sha256 -cne '12EE0AA78E71A9845B62551C3848BCF4C148CE4AD8FA6B45CB2D8D07821C232A'){throw 'Report SHA pin'}
$report=Get-Content -Raw -LiteralPath $savedReport|ConvertFrom-Json -Depth 32 -DateKind String
if($report.status -cne 'diagnostic-passed' -or $report.compile_calls -ne 1 -or $report.native_calls -ne 1 -or $report.source_count -ne 7 -or $report.source_bytes -ne 49123 -or $report.frozen_static_source_checks -ne 19){throw 'Bounded scope'}
$pinPairs=0
foreach($set in @(@($report.sources_before,$report.sources_after),@($report.identities_before,$report.identities_after))){$before=@($set[0]);$after=@($set[1]);if($before.Count -ne $after.Count){throw 'Pin extent'};foreach($entry in $before){$matching=@($after|Where-Object path -ceq $entry.path);if($matching.Count -ne 1 -or !(Same $entry $matching[0]) -or !(Same $entry (Identity $entry.path))){throw "Before/after/live pin mismatch: $($entry.path)"};$pinPairs++}}
if(!(Same $report.executable_before $report.executable_after) -or !(Same $report.executable_after (Identity $report.executable_after.path))){throw 'EXE before/after/live pin'}
$staticPath=Join-Path $project 'build/khc-static-direct-mdl-20261004/corrected-native/report.json';$staticReport=Get-Content -Raw -LiteralPath $staticPath|ConvertFrom-Json -Depth 32 -DateKind String
foreach($entry in $staticReport.sources_before){if(!(Same $entry (Identity $entry.path))){throw 'Frozen static source mismatch'}}
$d=$report.diagnostic
if($d.status -cne 'passed' -or $d.kind -cne 'training_only_feature_opportunity' -or $d.input_reads -ne 1 -or $d.BWT_calls -ne 1 -or $d.frame_encodes -ne 0 -or $d.frame_decodes -ne 0 -or $d.raw_event_Vecs -ne 0 -or $d.family_count -ne 4 -or $d.history_hand_checks -ne 90 -or $d.aggregate_hand_checks -ne 8){throw 'Diagnostic E2E categories'}
if($d.runs -ne 889227 -or $d.primary -ne 1762795 -or $d.rank_tokens -ne 889227 -or $d.length_tokens -ne 889227 -or $d.direct_tokens -ne 1778454 -or $d.escape_bytes -ne 742 -or $d.grammar -ne [Numerics.BigInteger]::Parse('6373537040327497557')){throw 'Frozen frontend totals'}
Near $d.baseline_single_accumulator_loss_bits $staticReport.screen.records[5].truncated_loss_bits
Near ($d.baseline_component_loss_bits[0]+$d.baseline_component_loss_bits[1]) $d.baseline_attributed_total_loss_bits
Near $d.baseline_attributed_total_loss_bits $d.saved_static_loss_bits
if($d.baseline_absolute_difference_bits -gt 1e-6 -or $d.baseline_token_bytes_ceil -ne [Math]::Ceiling($d.baseline_attributed_total_loss_bits/8) -or $d.fixed_run_capacity -ne 1048576 -or $d.fixed_run_capacity_bytes -ne $d.fixed_run_capacity*12 -or $d.peak_RAM_measured -or $d.old_expert_reproduced){throw 'Attribution/RAM scope'}
$names=@('global','symbol','recent','joint');$widths=@(5,14,21,23);$expectedBudgets=@(671710,739817,1174834,934341)
if(@($d.family_records).Count -ne 4){throw 'Fixed family count'}
$aggregateCells=0L;$historyChecks=0L
for($i=0;$i -lt 4;$i++){
 $r=$d.family_records[$i];if($r.family -cne $names[$i] -or $r.key_bits -ne $widths[$i] -or !$r.training_only -or $r.actual_model_serialized -or !$r.all_aggregate_cell_replay_counts_equal -or $r.naive_budget_within_483599 -or $r.Q_training_naive_budget_bytes -ne $expectedBudgets[$i]){throw 'Family scope/values'}
 foreach($field in @('tokens','rows','cells','singleton_rows','singleton_tokens','empirical_truncated_loss_bits','Q32768_truncated_loss_bits','rowfield_bits')){if(@($r.$field).Count -ne 2){throw 'Component array shape'}}
 for($c=0;$c -lt 2;$c++){if($r.tokens[$c] -ne 889227 -or $r.rows[$c] -gt $r.cells[$c] -or $r.cells[$c] -gt $r.tokens[$c] -or $r.singleton_rows[$c] -gt $r.rows[$c] -or $r.singleton_tokens[$c] -gt $r.tokens[$c] -or $r.singleton_tokens[$c] -lt $r.singleton_rows[$c]){throw 'Row/cell/token/singleton bounds'};if($r.rowfield_bits[$c] -ne 24*$r.cells[$c]+($r.key_bits-6)*$r.rows[$c]){throw 'Component naive metadata cost'};if(![double]::IsFinite($r.empirical_truncated_loss_bits[$c]) -or ![double]::IsFinite($r.Q32768_truncated_loss_bits[$c]) -or $r.empirical_truncated_loss_bits[$c] -lt 0 -or $r.Q32768_truncated_loss_bits[$c] -lt 0){throw 'Component finite loss'}}
 Near ($r.empirical_truncated_loss_bits[0]+$r.empirical_truncated_loss_bits[1]) $r.empirical_total_loss_bits
 Near ($r.Q32768_truncated_loss_bits[0]+$r.Q32768_truncated_loss_bits[1]) $r.Q_total_loss_bits
 if($r.common_row_count_bits -ne 32 -or $r.naive_metadata_bits -ne $r.rowfield_bits[0]+$r.rowfield_bits[1]+32 -or $r.naive_metadata_bytes_ceil -ne [Math]::Ceiling($r.naive_metadata_bits/8) -or $r.Q_token_bytes_ceil -ne [Math]::Ceiling($r.Q_total_loss_bits/8) -or $r.Q_training_naive_budget_bytes -ne $r.naive_metadata_bytes_ceil+$r.Q_token_bytes_ceil+$r.uniform_escape_bytes+$r.framing_bytes+$r.model_bitlength_bytes+$r.coder_reserve_bytes){throw 'Family metadata/ceil/budget arithmetic'}
 if($r.uniform_escape_bytes -ne 742 -or $r.framing_bytes -ne 285 -or $r.model_bitlength_bytes -ne 4 -or $r.coder_reserve_bytes -ne 2048 -or $r.cell_len -ne $r.cells[0]+$r.cells[1] -or $r.row_len -ne $r.rows[0]+$r.rows[1] -or $r.cell_capacity -lt $r.cell_len -or $r.cell_capacity -gt 1778454 -or $r.row_capacity -lt $r.row_len -or $r.row_capacity -gt $r.cell_len){throw 'Totals/capacity bounds'}
 foreach($field in @('count_prefix_capacity','Q_frequency_capacity','Q_prefix_capacity')){if($r.$field -ne $r.cell_len){throw 'Prefix capacity'}}
 if($r.map_capacity -ne 1835008 -or $r.map_buckets_estimate -ne 2097152 -or $r.map_bytes_estimate -ne 9*$r.map_buckets_estimate+16){throw 'Rust map layout estimate'}
 $base=$d.fixed_run_capacity_bytes+2811006+14077+127624+8512+1369112+4MB
 $score=$base+$r.cell_capacity*8+$r.row_capacity*16+($r.count_prefix_capacity+$r.Q_frequency_capacity+$r.Q_prefix_capacity)*4
 $drain=$base+$r.map_bytes_estimate+$r.cell_capacity*8
 if($r.score_working_RAM_estimate_bytes -ne $score -or $r.drain_working_RAM_estimate_bytes -ne $drain -or $score -gt 160MB -or $drain -gt 160MB -or $r.history_checks_build_and_replay -ne 3556908){throw 'RAM estimate/history count'}
 $aggregateCells+=$r.cell_len;$historyChecks+=$r.history_checks_build_and_replay
}
if($d.score_phase_worst_estimate_with_margin_bytes -ne 85131891 -or $d.BWT_phase_worst_estimate_bytes -ne 50*2811007+1MB -or $d.BWT_phase_worst_estimate_bytes -gt 160MB -or $d.RAM_estimate_limit_bytes -ne 160MB){throw 'Worst RAM arithmetic'}
if($report.children.Count -ne 3 -or @($report.children|Where-Object {$_.exit_code -ne 0 -or $_.failure}).Count -or $report.children[1].elapsed_ms -gt 60000 -or $report.children[2].elapsed_ms -gt 120000){throw 'Bounded children'}
foreach($child in $report.children){if([Text.Encoding]::UTF8.GetByteCount($child.stdout) -gt 65536 -or [Text.Encoding]::UTF8.GetByteCount($child.stderr) -gt 16384){throw 'Saved stream bound'}}
$entries=@(Get-ChildItem -LiteralPath $work -Force);if($entries.Count -ne 2 -or @($entries|Where-Object {$_.PSIsContainer -or $_.FullName -notin @($savedReport,$report.executable_after.path) -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'Output shape'}
if((Get-Item -LiteralPath $savedReport).Length -gt 262144 -or $report.executable_after.bytes -gt 1048576){throw 'Artifact individual capacity'}
$processCount=@(Get-Process|Where-Object {$_.Path -eq $report.executable_after.path}).Count;if($processCount){throw 'Owned EXE process remains'}
$finalGuard=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8
[pscustomobject]@{status='readonly-verified';before_after_live_pin_pairs=$pinPairs;EXE_pair=1;static_source_checks=19;history_hand_checks=90;aggregate_hand_checks=8;family_count=4;all_aggregate_cell_replay_counts_equal=$true;aggregate_cells_summed_across_four_families=$aggregateCells;history_checks_build_replay_summed=$historyChecks;baseline_difference_bits=$d.baseline_absolute_difference_bits;common_row_count_bits_each_family=32;all_naive_budgets_exceed_483599=$true;actual_model_serialized=$false;actual_output_files=@($entries|ForEach-Object {Identity $_.FullName});owned_exe_processes=$processCount;final_guard_after_report_save=$finalGuard}|ConvertTo-Json -Depth 8
