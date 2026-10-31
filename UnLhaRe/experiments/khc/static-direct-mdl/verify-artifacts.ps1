[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$ownedRoot=Join-Path $project 'build/khc-static-direct-mdl-20261004'
$work=Join-Path $ownedRoot 'corrected-native'
$savedReport=Join-Path $work 'report.json'
function Identity([string]$Path){$resolved=[IO.Path]::GetFullPath($Path);$ancestor=$resolved;while($ancestor){if(Test-Path -LiteralPath $ancestor){if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse path'}};$ancestor=[IO.Path]::GetDirectoryName($ancestor)};$item=Get-Item -LiteralPath $resolved -Force;if($item.PSIsContainer){throw 'Expected file'};[pscustomobject]@{path=$resolved;sha256=(Get-FileHash -LiteralPath $resolved).Hash;bytes=$item.Length;mtime_utc=$item.LastWriteTimeUtc.ToString('o')}}
function Same($A,$B){foreach($field in @('path','sha256','bytes','mtime_utc')){if($A.$field -cne $B.$field){return $false}};return $true}
if((Identity $savedReport).sha256 -cne 'DCFBB1001CBC1BD43956B2F92255210BCFAE79B831C4D08FB140D1B871628C5F'){throw 'Successful report SHA'}
$report=Get-Content -Raw -LiteralPath $savedReport|ConvertFrom-Json -Depth 32 -DateKind String
if($report.status -cne 'diagnostic-passed' -or $report.compile_calls -ne 1 -or $report.native_calls -ne 1 -or $report.repair.compile_calls_total -ne 2 -or $report.repair.native_calls_total -ne 1 -or $report.budget_candidate_qualified){throw 'Run scope/status'}
$pairs=0
foreach($set in @(@($report.sources_before,$report.sources_after),@($report.identities_before,$report.identities_after))){
 $before=@($set[0]);$after=@($set[1]);if($before.Count -ne $after.Count){throw 'Pin extent'}
 foreach($entry in $before){$matching=@($after|Where-Object path -ceq $entry.path);if($matching.Count -ne 1 -or !(Same $entry $matching[0]) -or !(Same $entry (Identity $entry.path))){throw "Pin/live mismatch: $($entry.path)"};$pairs++}
}
if($report.source_count -ne 19 -or $report.source_bytes -ne 140383 -or [long](($report.sources_before|Measure-Object bytes -Sum).Sum) -ne 140383){throw 'Source closure count/bytes'}
foreach($set in @(@($report.executable_before,$report.executable_after),@($report.header_before,$report.header_after))){if(!(Same $set[0] $set[1]) -or !(Same $set[0] (Identity $set[0].path))){throw 'Artifact before/after/live mismatch'}}
$ledger=Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'observer-ledger.json')|ConvertFrom-Json -Depth 8 -DateKind String
$expected=[IO.File]::ReadAllText((Join-Path $PSScriptRoot $ledger.source)).Replace("`r`n","`n").TrimEnd("`n")+"`n"
if(@($ledger.operations).Count -ne 5 -or $ledger.numerical_changes -ne 0){throw 'Ledger scope'}
foreach($operation in $ledger.operations){if(([regex]::Matches($expected,[regex]::Escape($operation.from))).Count -ne 1 -or $operation.count -ne 1){throw 'Ledger count'};$expected=$expected.Replace($operation.from,$operation.to)}
$actual=[IO.File]::ReadAllText((Join-Path $PSScriptRoot $ledger.destination)).Replace("`r`n","`n").TrimEnd("`n")+"`n";if($actual -cne $expected){throw 'Whole source ledger equality'}
$failed=Get-Content -Raw -LiteralPath $report.repair.predecessor|ConvertFrom-Json -Depth 32 -DateKind String
if($failed.status -cne 'failed' -or $failed.native_calls -ne 0 -or $failed.compile_calls -ne 1){throw 'Failed predecessor scope'}
$changed=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach($old in @($failed.sources_before)+@($failed.identities_before)){$current=Identity $old.path;if(!(Same $old $current)){$null=$changed.Add($old.path)}}
$repairPaths=@($report.repair.changed_prior_pin_paths);if($changed.Count -ne 2 -or @($repairPaths|Where-Object {!$changed.Contains($_)}).Count){throw 'Repair change set'}
$screen=$report.screen;if($screen.status -cne 'passed' -or $screen.cases -ne 6 -or $screen.header_rejections -ne 16 -or $screen.header_normal_checks -ne 3){throw 'E2E counters'}
foreach($record in $screen.records){if(!$record.whole_frame_equal -or !$record.fullplain_equal -or !$record.typed_Proof14_equal -or !$record.stats_equal -or $record.hist_cells_per_comparison -ne 342278 -or $record.hist_comparisons -ne 2){throw 'Whole equivalence/cells'};if(@($record.proof.PSObject.Properties).Count -ne 14 -or @($record.proof.branches).Count -ne 2 -or @($record.proof.classes).Count -ne 6){throw 'Saved typed Proof14 shape'}}
$fixed=$screen.records[5]
if($fixed.name -cne 'fixed' -or $fixed.reference_frame_bytes -ne 478750 -or $fixed.direct_tokens -ne 1778454 -or $fixed.old_branches -ne 3825340 -or $fixed.selected_CDFs -ne 62 -or $fixed.model_bits -ne 112616 -or $fixed.model_bytes -ne 14077 -or $fixed.token_bytes_ceil -ne 625014 -or $fixed.escape_bytes -ne 742 -or $fixed.budget_bytes -ne 642170 -or $fixed.budget_gate_passed){throw 'Fixed screen values'}
if([Math]::Ceiling([double]$fixed.truncated_loss_bits/8) -ne $fixed.token_bytes_ceil -or $fixed.model_bytes+$fixed.token_bytes_ceil+$fixed.escape_bytes+$fixed.framing_bytes+$fixed.model_bit_length_bytes+$fixed.coder_reserve_bytes -ne $fixed.budget_bytes -or $fixed.lookup_bytes_estimate -ne $fixed.selected_CDFs*32768*2){throw 'Budget/lookup arithmetic'}
if($fixed.proof.runs -ne 889227 -or $fixed.proof.primary -ne 1762795 -or $fixed.proof.grammar -ne [Numerics.BigInteger]::Parse('6373537040327497557') -or $fixed.proof.base_pool -ne [Numerics.BigInteger]::Parse('16543436934116980951') -or $fixed.proof.cdf_bits -ne [Numerics.BigInteger]::Parse('4705459439931356009')){throw 'Exact wide integer Proof bits'}
# 保存metadataを読み取り専用で再parseし、field費用/選択数/tagを独立に数える。
$script:headerBytes=[IO.File]::ReadAllBytes($report.header_after.path);$script:bitPos=0;$script:bitLimit=[int]$fixed.model_bits;$script:cdfCount=0;$script:cdfBits=0
if($script:headerBytes.Length -ne [Math]::Ceiling($script:bitLimit/8)){throw 'Header byte extent'}
function Read-Bits([int]$Width){if($script:bitPos+$Width -gt $script:bitLimit){throw 'Truncated metadata'};$value=0;for($j=0;$j -lt $Width;$j++){$value=$value -bor ((($script:headerBytes[[int][Math]::Floor($script:bitPos/8)] -shr ($script:bitPos%8)) -band 1) -shl $j);$script:bitPos++};return $value}
function Read-Cdf([int]$Alphabet){$start=$script:bitPos;$used=Read-Bits 9;if($used -lt 1 -or $used -gt $Alphabet){throw 'Header used'};$previous=-1;for($j=0;$j -lt $used;$j++){$symbol=Read-Bits 9;if($symbol -le $previous -or $symbol -ge $Alphabet){throw 'Header symbol order/range'};$previous=$symbol};$sum=0;for($j=0;$j -lt $used-1;$j++){$frequency=Read-Bits 15;if($frequency -le 0){throw 'Header zero freq'};$sum+=$frequency;if($sum -ge 32768){throw 'Header total'}};if($script:bitPos-$start -ne 24*$used-6){throw 'CDF bit cost'};$script:cdfCount++;$script:cdfBits+=$script:bitPos-$start}
Read-Cdf 257;Read-Cdf 256
$tagCounts=@(0,0,0,0);$childFlagBits=0
foreach($shape in @(@(257,257),@(9,256))){for($g=0;$g -lt $shape[0];$g++){$tag=Read-Bits 2;$tagCounts[$tag]++;if($tag -band 1){Read-Cdf $shape[1]};if($tag -ge 2){$owned=0;for($b=0;$b -lt 4;$b++){$flag=Read-Bits 1;$childFlagBits++;if($flag){$owned++;Read-Cdf $shape[1]}};if(!$owned){throw 'Redundant split'}}}}
if($script:bitPos -ne $script:bitLimit -or $script:cdfCount -ne 62 -or $script:cdfBits+266*2+$childFlagBits -ne $fixed.model_bits -or ($tagCounts -join ',') -cne ($fixed.tags -join ',')){throw 'Header reconstruction totals'}
if($script:bitLimit%8 -and $script:headerBytes[-1] -shr ($script:bitLimit%8)){throw 'Padding'}
$entries=@(Get-ChildItem -LiteralPath $ownedRoot -Recurse -Force);$files=@($entries|Where-Object {!$_.PSIsContainer});if($files.Count -ne 4 -or @($entries|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Output shape'}
$allowed=@($savedReport,$report.header_after.path,$report.executable_after.path,$report.repair.predecessor);if(@($files|Where-Object FullName -notin $allowed).Count){throw 'Unexpected output file'}
if((Get-Item -LiteralPath $savedReport).Length -gt 262144 -or $report.executable_after.bytes -gt 1048576 -or $report.header_after.bytes -gt 1048576){throw 'Artifact individual bound'}
$ownedProcesses=@(Get-Process|Where-Object {$_.Path -eq $report.executable_after.path}).Count;if($ownedProcesses){throw 'Owned EXE remains'}
$finalGuard=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $ownedRoot -MaxRunMiB 8
[pscustomobject]@{status='readonly-verified';before_after_live_pin_pairs=$pairs;artifact_pairs=2;repair_historical_changed_paths=@($changed);whole_ledger_equal=$true;cases=6;cells_per_comparison=342278;hist_comparisons=12;header_roundtrip_checks=1;quantization_boundary_checks=3;empty_quantization_rejections=2;header_rejections=16;selected_CDFs=$script:cdfCount;parsed_model_bits=$script:bitPos;CDF_field_bits=$script:cdfBits;group_tag_bits=532;child_flag_bits=$childFlagBits;budget_bytes=$fixed.budget_bytes;candidate_qualified=$false;output_file_count=$files.Count;actual_outputs=@($files|ForEach-Object {Identity $_.FullName});owned_exe_processes=$ownedProcesses;final_guard_after_report_save=$finalGuard}|ConvertTo-Json -Depth 8
