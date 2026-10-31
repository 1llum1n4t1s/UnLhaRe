[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
function Need($actual,$expected,[string]$why){if($actual -cne $expected){throw $why}}
function Same($a,$b){($a|ConvertTo-Json -Compress -Depth 64) -ceq ($b|ConvertTo-Json -Compress -Depth 64)}
function Read-Json([string]$p){Get-Content -LiteralPath $p -Raw|ConvertFrom-Json -Depth 64 -DateKind String}
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-anchored-wire-20261004'
$reportPath=Join-Path $work 'report.json'
Need (Get-FileHash -LiteralPath $reportPath).Hash 'D580A0C79163CB6E7847E6FDC8663CC0C613AE84906A032038BEC9377CD2074F' 'Report SHA'
$r=Read-Json $reportPath
Need $r.status 'diagnostic-passed' 'Status';Need $r.compile_calls 1 'Compile';Need $r.total_native_calls 3 'Native'
Need $r.source_count 24 'Sources';Need @($r.imports).Count 24 'Edges';Need $r.source_bytes 165961 'Source bytes'
$pairs=0
foreach($kind in @('sources','identities')){
 $before=@($r.($kind+'_before'));$after=@($r.($kind+'_after'));Need $after.Count $before.Count 'Identity count'
 for($i=0;$i -lt $before.Count;$i++){
  $a=$before[$i];$b=$after[$i];if(!(Same $a $b)){throw 'Before/after identity'}
  $f=Get-Item -LiteralPath $a.path
  if($f.PSIsContainer -or ($f.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Identity regular file'}
  Need $f.Length $a.bytes 'Identity size';Need (Get-FileHash -LiteralPath $a.path).Hash $a.sha256 'Identity SHA'
  Need $f.LastWriteTimeUtc.Ticks ([DateTimeOffset]::Parse($a.mtime_utc).UtcTicks) 'Identity timestamp';$pairs++
 }
}
Need @($r.identities_before).Count 188 'Pin count'
if(!(Same $r.executable_before $r.executable_after)){throw 'EXE before/after'}
$exe=$r.executable_before
Need (Get-FileHash -LiteralPath $exe.path).Hash 'B46EA3ED817AC39E9B4E42838D06CB594045B82293E7993DBC6E2DED3C8377B3' 'EXE SHA'
Need (Get-Item -LiteralPath $exe.path).Length 543232 'EXE bytes'
Need (Get-Item -LiteralPath $exe.path).LastWriteTimeUtc.Ticks ([DateTimeOffset]::Parse($exe.mtime_utc).UtcTicks) 'EXE timestamp';$pairs++
Need @($r.children).Count 5 'Children'
foreach($c in $r.children){Need $c.exit_code 0 'Child exit';Need $c.stderr '' 'Child stderr';if($c.failure){throw 'Child failure'}}
$native=@($r.children|Where-Object file -eq $exe.path);Need $native.Count 3 'Raw native count'
$names=@('selfcontrol','selfcandidate','pair')
for($i=0;$i -lt 3;$i++){
 Need $native[$i].arguments[0] $names[$i] 'Native order'
 $raw=$native[$i].stdout|ConvertFrom-Json -Depth 64 -DateKind String
 if(!(Same $raw $r.($names[$i]))){throw 'Whole raw native projection'}
 $m=$raw.memory
 Need $m.API_calls 1 'Memory API';Need $m.ABI_size 80 'Memory ABI';Need $m.ABI_cb 80 'Memory cb';Need $m.ABI_checked $true 'Memory layout';Need $m.measured $true 'Memory measured'
 if($null -ne $m.last_OS_error -or $m.peak_working_set_bytes -le 0 -or $m.peak_working_set_bytes -gt 167772160 -or $m.peak_private_commit_bytes -le 0 -or $m.peak_private_commit_bytes -gt 167772160){throw 'Memory bounds'}
}
$old=Read-Json (Join-Path $project 'build/khc-hard-cut-model-lazy-20261004/report.json')
if(!(Same $r.selfcontrol.E2E $old.selfcheck.E2E)){throw 'Original self whole JSON'}
$s=$r.selfcandidate.E2E
foreach($p in $old.selfcheck.E2E.PSObject.Properties){if($p.Name -ne 'malformed' -and !(Same $p.Value $s.($p.Name))){throw ('Preserved E2E '+$p.Name)}}
Need @($s.malformed).Count 34 'Malformed count'
for($i=0;$i -lt 34;$i++){
 $a=$old.selfcheck.E2E.malformed[$i];$b=$s.malformed[$i];Need $b.name $a.name 'Original names'
 $reason=$a.reason;if($a.name -eq 'lf_cycle'){$reason='LF early primary cycle'};Need $b.reason $reason 'Strict original reasons'
 $length=$a.frame_bytes;if($a.name -in @('range_truncated','escape_noncanonical','escape_fourbytes','escape_remaining')){$length+=32};Need $b.frame_bytes $length 'Fixture layout'
}
foreach($v in @(@('anchor_boundary_cases',2),@('anchor_named_rejections',10),@('anchor_recovery_cases',10),@('reverse_magic_rejections',1))){Need $s.($v[0]) $v[1] 'New census'}
$named=@('old_hardcut_magic','anchor_crc_bitflip','anchor_row_range','anchor0_mismatch','anchor_duplicate','anchor_endpoint','anchor_cycle72','anchor_metadata_missing','anchor_metadata_extra','fallback_metadata_extra')
$reasons=@('bad frame magic/header','header CRC mismatch','anchor row range','anchor0 primary','duplicate anchor','anchor segment endpoint','LF early primary cycle','packed header length outside bounds','packed header length outside bounds','packed alphabet rank byte width not canonical')
Need @($s.anchor_named).Count 10 'Named count'
for($i=0;$i -lt 10;$i++){Need $s.anchor_named[$i].name $named[$i] 'Named order';Need $s.anchor_named[$i].reason $reasons[$i] 'Named strict reason'}
$n=$r.pair
foreach($v in @(@('input_reads',1),@('control_encode_calls',1),@('candidate_encode_calls',1),@('control_decode_calls',1),@('candidate_decode_calls',1),@('fixed_reencode_calls',0),@('matched_plain_bytes',2811006),@('frame_bytes',478888),@('control_frame_bytes',478856),@('header_bytes',317),@('old_header_bytes',285),@('payload_bytes',478571),@('anchor_metadata_bytes',32),@('disk_frames',0),@('disk_restores',0),@('raw_event_Vecs',0))){Need $n.($v[0]) $v[1] 'Pair census'}
Need $n.Proof14_debug $old.fixed.Proof14_debug 'Proof14 debug'
foreach($field in @('control_encode_stats','control_decode_stats')){if(!(Same $n.$field $old.fixed.encode_stats)){throw 'Old stats all fields'}}
if(!(Same $n.candidate_encode_stats $n.candidate_decode_stats)){throw 'New stats all fields'}
$os=$n.control_encode_stats;$ns=$n.candidate_encode_stats
Need @($ns.PSObject.Properties).Count (@($os.PSObject.Properties).Count+2) 'Stats schema'
foreach($p in $os.PSObject.Properties){if($p.Name -notin @('magic','frame_bytes','header_bytes','header_crc') -and !(Same $p.Value $ns.($p.Name))){throw 'Common stats all fields'}}
Need $ns.magic 'KHQCHA01' 'Magic';Need $ns.anchor_bytes 32 'Anchor bytes';Need $ns.header_crc_covers_anchors $true 'CRC coverage'
foreach($field in @('all_common_header_alphabet_payload_bytes_directly_compared','all_plain_bytes_compared','typed_Proof14_each_direction_Eq','cross_Proof14_Debug_equal','all_common_stats_equal','each_side_encode_decode_fullstats_equal','header_layout_and_CRC_checked','old_plain_dropped_before_candidate_restore','anchor_header_CRC_protected')){Need $n.$field $true 'Executed direct comparison'}
foreach($field in @('all_frame_bytes_directly_compared','all_stats_equal','cross_typed_Proof_Eq_claimed','speed_claimed','formal_speed_verified','native4_verified','adoption','custom_allocator_linked','stage_profile_linked')){Need $n.$field $false 'Claim boundary'}
Need $n.encoder_phase_RAM_estimate_bytes 45723526 'Encoder estimate';Need $n.BWT_phase_RAM_estimate_bytes 142651883 'BWT estimate'
Need $r.codec_ledger.allowed_replacements 20 'Codec ledger';Need $r.e2e_ledger.allowed_replacements 5 'E2E ledger';Need $r.scope_ledger.extra_residual 0 'Scope ledger'
Need @(Get-Process|Where-Object Path -eq $exe.path).Count 0 'Owned processes'
$files=@(Get-ChildItem -LiteralPath $work -Force);Need $files.Count 2 'Output count'
if(@($files|Where-Object {$_.PSIsContainer -or $_.Name -notin @('anchored-wire-o3.exe','report.json') -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'Output shape'}
$disk=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8
[pscustomobject]@{status='readonly-passed';identity_pairs=$pairs;raw_native_records=3;frame_bytes=478888;additional_compile_calls=0;additional_native_calls=0;disk=$disk}|ConvertTo-Json -Depth 5
