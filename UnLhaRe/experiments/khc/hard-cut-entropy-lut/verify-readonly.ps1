[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[0-9A-F]{64}$')][string]$ReportSha256)
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-hard-cut-entropy-lut-20261004'
$path=Join-Path $work 'report.json'
function Need($ok,[string]$why){if(!$ok){throw $why}}
function Same($a,$b){($a|ConvertTo-Json -Compress -Depth 64) -ceq ($b|ConvertTo-Json -Compress -Depth 64)}
function Identity([string]$p){$f=Get-Item -LiteralPath $p;Need (!$f.PSIsContainer -and !($f.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'File type';[pscustomobject]@{path=$f.FullName;sha256=(Get-FileHash -LiteralPath $p).Hash;bytes=$f.Length;mtime_utc=$f.LastWriteTimeUtc.ToString('o')}}
Need ((Get-FileHash -LiteralPath $path).Hash -ceq $ReportSha256) 'Report SHA'
$r=Get-Content -Raw -LiteralPath $path|ConvertFrom-Json -Depth 64 -DateKind String
Need ($r.status -ceq 'diagnostic-passed' -and $r.compile_calls -eq 1 -and $r.total_native_calls -eq 4) 'Execution census'
$count=0
foreach($kind in @('sources','identities')){$a=@($r.($kind+'_before'));$b=@($r.($kind+'_after'));Need ($a.Count -eq $b.Count) 'Pair census';for($i=0;$i -lt $a.Count;$i++){Need ((Same $a[$i] $b[$i]) -and (Same $a[$i] (Identity $a[$i].path))) 'Before after live';$count++}}
Need ((Same $r.executable_before $r.executable_after) -and (Same $r.executable_after (Identity $r.executable_after.path))) 'EXE identity'
$old=Get-Content -Raw -LiteralPath (Join-Path $project 'build/khc-hard-cut-model-lazy-20261004/report.json')|ConvertFrom-Json -Depth 64 -DateKind String
$raw=@($r.children|Where-Object {$_.stdout -like '{*'}|ForEach-Object {$_.stdout|ConvertFrom-Json -Depth 64 -DateKind String})
Need ($raw.Count -eq 4 -and (Same $raw[0] $r.finite) -and (Same $raw[1] $r.selfcontrol) -and (Same $raw[2] $r.selfcandidate) -and (Same $raw[3] $r.pair)) 'Raw JSON replay'
$f=$raw[0].finite
foreach($entry in @(@('domain_cases',32769),@('fallback_cases',2),@('table_before_bit_comparisons',32769),@('table_after_bit_comparisons',32769),@('special_bit_comparisons',2),@('Kahan_updates',768),@('Kahan_bit_comparisons',1536),@('capacity_overflow_rejections',1),@('constructor_calls',1),@('mismatches',0),@('cases_Vec',0),@('table_payload_bytes',262152))){Need ($f.($entry[0]) -eq $entry[1]) 'Finite census'}
Need ($f.streamed_cases -eq $true -and $f.OS_OOM_injected -eq $false -and $f.table_capacity_entries -ge 32769 -and $f.table_capacity_bytes -eq 8*$f.table_capacity_entries) 'Finite capacity contract'
foreach($s in @($r.selfcontrol,$r.selfcandidate)){Need ((Same $s.E2E $old.selfcheck.E2E) -and $s.E2E.normal_cases -eq 14 -and $s.E2E.malformed_cases -eq 34 -and $s.E2E.short_depth_header_checks -eq 4) 'Whole finite E2E'}
$n=$r.pair
foreach($field in @('control_encode_stats','candidate_encode_stats','control_decode_stats','candidate_decode_stats')){Need (Same $n.$field $old.fixed.encode_stats) 'All four stats'}
Need ($n.Proof14_debug -ceq $old.fixed.Proof14_debug -and $n.frame_bytes -eq 478856 -and $n.matched_plain_bytes -eq 2811006 -and $n.header_bytes+$n.payload_bytes -eq $n.frame_bytes) 'Proof and lengths'
foreach($field in @('all_frame_bytes_directly_compared','all_plain_bytes_compared','typed_Proof14_each_direction_Eq','cross_Proof14_Debug_equal','all_stats_equal','header_layout_and_CRC_checked','old_plain_dropped_before_candidate_restore','instrumentation_capacity_readback_only')){Need ($n.$field -eq $true) 'Direct checks'}
foreach($field in @('custom_allocator_linked','stage_profile_linked','speed_claimed','formal_speed_verified','native4_verified','adoption','cross_typed_Proof_Eq_claimed')){Need ($n.$field -eq $false) 'Nonclaim'}
foreach($s in $raw){$m=$s.memory;Need ($m.measured -and $m.API_calls -eq 1 -and $m.ABI_size -eq 80 -and $m.ABI_cb -eq 80 -and $m.ABI_checked -and $null -eq $m.last_OS_error -and $m.peak_working_set_bytes -gt 0 -and $m.peak_working_set_bytes -le 167772160 -and $m.peak_private_commit_bytes -gt 0 -and $m.peak_private_commit_bytes -le 167772160) 'OS peak memory'}
$table=[math]::Max($n.candidate_encode_table_capacity_entries,$n.candidate_decode_table_capacity_entries)*8
Need ($n.candidate_encode_table_capacity_bytes -eq $n.candidate_encode_table_capacity_entries*8 -and $n.candidate_decode_table_capacity_bytes -eq $n.candidate_decode_table_capacity_entries*8 -and $n.table_RAM_added_bytes -eq $table -and $n.table_payload_bytes -eq 262152) 'Actual table RAM'
Need ($n.model_working_RAM_estimate_bytes -eq 21561264+$table -and $n.encoder_phase_RAM_estimate_bytes -eq 45723494+$table -and $n.inverse_phase_RAM_estimate_bytes -eq ($n.input_capacity+$n.control_frame_capacity+$n.candidate_frame_capacity+14*2811007+65536+4194304+$table)) 'RAM formulas'
$data=$n.input_capacity+$n.control_frame_capacity+$n.candidate_frame_capacity+[math]::Max($n.control_plain_capacity,$n.candidate_plain_capacity)
Need ($data -eq $n.actual_main_data_Vec_capacity_peak_bytes -and $n.fixed_phase_RAM_estimate_bytes -eq [math]::Max([math]::Max($n.encoder_phase_RAM_estimate_bytes,$n.inverse_phase_RAM_estimate_bytes),($data+4194304)) -and $n.fixed_phase_RAM_estimate_bytes -le 67108864 -and $n.model_working_RAM_estimate_bytes -le 33554432) 'Phase bound'
$files=@(Get-ChildItem -LiteralPath $work -Force);Need ($files.Count -eq 2 -and @($files|Where-Object {$_.PSIsContainer -or $_.Name -notin @('report.json','entropy-lut-wire-o3.exe')}).Count -eq 0) 'Output shape'
$guard=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8
[pscustomobject]@{status='readonly-passed';before_after_live_pairs=$count;raw_native_records=4;additional_compile_calls=0;additional_native_calls=0;disk=$guard}|ConvertTo-Json -Depth 5
