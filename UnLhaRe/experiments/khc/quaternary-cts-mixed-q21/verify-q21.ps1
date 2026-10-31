[CmdletBinding()]
param([switch]$Execute)
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-quaternary-cts-mixed-q21-20261003'
$guard=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../disk-budget.ps1'))
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$formatter=Join-Path (Split-Path $compiler) 'rustfmt.exe'
$runtime='C:/Users/IMT/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe'
$contractSha='E2268BEDAA246D76FE8227DBA664627AA6AAC498A604F04C51FE5C8CF4FA3C54'
$planSha='B2B6BCD2F56BF46C412D13BE3A7C916438C2B48A3F2FF85552695D28B3130DDF'
$files=@('FAILURE_PLAN.md','integer_cts.rs','integer_pool.rs','model.rs','codec.rs','baseline_codec.rs','e2e.rs','oracle.rs','comparison.rs','probe.rs','verify-q21.ps1')
$records=[Collections.Generic.List[object]]::new()
$sources=[Collections.Generic.List[object]]::new()
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$created=$false;$exe=$null
$report=[ordered]@{status='preflight';began_utc=[DateTime]::UtcNow.ToString('o');source_count=163;sources=$sources;sources_after=@();sources_live=@();records=$records;compiled_graph=$null;capacity_plan=@{max_bytes=8MB;exe_reserve_bytes=1MB;report_reserve_bytes=512KB;retained_estimated_bytes=1536KB;failure_evidence_max_bytes=4096};compiler=$null;runtime=$null;basis=$null;parsed_compare=$null;parsed_selfcheck_old=$null;parsed_selfcheck_new=$null;parsed_abba=$null;candidate_cli_calls=0;compile_calls=0;formal_speed_CPU_verified=$false;full_benchmark_allowed=$false;disk_frame_restore_input_copy_created=$false;unverified=@('formal median574.5624ms/CPU15%','holdout/categories','four native environments','product/API integration');error=$null}
function Identity([string]$Path){$p=[IO.Path]::GetFullPath($Path);$item=Get-Item -LiteralPath $p;[pscustomobject]@{path=$p;sha256=(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash;bytes=$item.Length;mtime_utc=$item.LastWriteTimeUtc.ToString('o')}}
function Same-Time([string]$A,[string]$B){$style=[Globalization.DateTimeStyles]::RoundtripKind;[DateTime]::Parse($A,[Globalization.CultureInfo]::InvariantCulture,$style).ToUniversalTime().Ticks -eq [DateTime]::Parse($B,[Globalization.CultureInfo]::InvariantCulture,$style).ToUniversalTime().Ticks}
function Same-Identity($A,$B){if($A.path -ne $B.path -or $A.sha256 -ne $B.sha256 -or $A.bytes -ne $B.bytes -or !(Same-Time $A.mtime_utc $B.mtime_utc)){throw "Identity mismatch: $($A.path)"}}
function Safe-Path([string]$Path){$p=[IO.Path]::GetFullPath($Path);$a=$p;while($a){if(Test-Path -LiteralPath $a){if((Get-Item -LiteralPath $a -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Reparse path: $a"}};$a=[IO.Path]::GetDirectoryName($a)};return $p}
function Text-Sha([string]$Text){[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text)))}
function Preview([string]$Text,[int]$Limit){$n=[Math]::Min($Text.Length,$Limit);while($n -gt 0 -and [Text.Encoding]::UTF8.GetByteCount($Text.Substring(0,$n)) -gt $Limit){$n--};if($n -gt 0 -and [char]::IsHighSurrogate($Text[$n-1])){$n--};$Text.Substring(0,$n)}
function Save-Report{
    if(!$created){return};$json=$report|ConvertTo-Json -Depth 30
    $n=[Text.Encoding]::UTF8.GetByteCount($json);if($n -gt 512KB){throw 'Report exceeds512KiB'}
    $null=& $guard -WorkDirectory $work -MaxRunMiB 8
    $other=@(Get-ChildItem -LiteralPath $work -File|Where-Object {$_.Name -ne 'report.json'}|Measure-Object -Property Length -Sum).Sum
    if([long]$other+$n -gt 8MB){throw 'Report write exceeds8MiB'}
    [IO.File]::WriteAllText((Join-Path $work 'report.json'),$json,[Text.UTF8Encoding]::new($false))
}
function Child([string]$File,[string[]]$Argv,[switch]$Formatting){
    $si=[Diagnostics.ProcessStartInfo]::new();$si.FileName=$File;$si.WorkingDirectory=$project;$si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
    foreach($x in $Argv){$si.ArgumentList.Add($x)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$si;$watch=[Diagnostics.Stopwatch]::StartNew();$started=$false
    $out=[Text.StringBuilder]::new();$err=[Text.StringBuilder]::new();$failure=$null;$exit=$null;$status='start-failed'
    try{
        $null=$p.Start();$started=$true;$status='running';$ob=[char[]]::new(4096);$eb=[char[]]::new(4096);$ot=$p.StandardOutput.ReadAsync($ob,0,4096);$et=$p.StandardError.ReadAsync($eb,0,4096);$od=$false;$ed=$false
        while(!$od -or !$ed -or !$p.HasExited){
            if($watch.Elapsed.TotalSeconds -gt 120){throw 'Owned child timeout120s'}
            if(!$od -and $ot.IsCompleted){$n=$ot.GetAwaiter().GetResult();if($n -eq 0){$od=$true}else{$null=$out.Append($ob,0,$n);if([Text.Encoding]::UTF8.GetByteCount($out.ToString()) -gt $(if($Formatting){2MB}else{128KB})){throw 'Child stdout cap'};$ot=$p.StandardOutput.ReadAsync($ob,0,4096)}}
            if(!$ed -and $et.IsCompleted){$n=$et.GetAwaiter().GetResult();if($n -eq 0){$ed=$true}else{$null=$err.Append($eb,0,$n);if([Text.Encoding]::UTF8.GetByteCount($err.ToString()) -gt 32KB){throw 'Child stderr cap'};$et=$p.StandardError.ReadAsync($eb,0,4096)}}
            [Threading.Thread]::Sleep(5)
        }
        $exit=$p.ExitCode;$status='completed'
    }catch{$failure=$_.Exception.Message;$status='interrupted';if($started -and !$p.HasExited){$p.Kill($true);$p.WaitForExit()};if($started -and $p.HasExited){$exit=$p.ExitCode}}
    finally{if($started -and !$p.HasExited){$p.Kill($true);$p.WaitForExit()};$p.Dispose()}
    $rawout=$out.ToString();$rawerr=$err.ToString();$stdout=$rawout.Trim();$stderr=$rawerr.Trim()
    $record=[pscustomobject]@{file=$File;argv=$Argv;exit=$exit;status=$status;elapsed_ms=$watch.Elapsed.TotalMilliseconds;stdout_bytes=[Text.Encoding]::UTF8.GetByteCount($rawout);stdout_sha256=(Text-Sha $rawout);stdout=$(if($Formatting){Preview $rawout 1024}else{$stdout});stdout_truncated=($Formatting -and [Text.Encoding]::UTF8.GetByteCount($rawout) -gt 1024);stderr=(Preview $stderr 32KB);stderr_bytes=[Text.Encoding]::UTF8.GetByteCount($rawerr);stderr_truncated=([Text.Encoding]::UTF8.GetByteCount($rawerr) -gt 32KB);error=$failure}
    $records.Add($record);if($File -ne $exe){Save-Report};if($failure){throw $failure};return $record
}
function Success($Record){if($Record.status -ne 'completed' -or $Record.exit -ne 0){throw "Child failed: $($Record.file): $($Record.stderr)"}}
function Schema($Object,[string[]]$Names){if($null -eq $Object){throw 'Missing JSON object'};$a=@($Object.PSObject.Properties.Name|Sort-Object);$b=@($Names|Sort-Object);if(($a -join '|') -ne ($b -join '|')){throw "JSON schema differs: $($a -join ',')"}}
function Require($Object,[hashtable]$Expected){foreach($key in $Expected.Keys){if($null -eq $Object.$key -or $Object.$key -cne $Expected[$key]){throw "JSON field mismatch: $key"}}}
function Capture($Record){if($Record.stdout -match '[\r\n]'){throw 'CLI must emit exactly one JSON record'};if(!$Record.stdout){throw "CLI JSON missing; exit=$($Record.exit); stderr=$($Record.stderr)"};if($Record.stderr -and $Record.exit -eq 0){throw "Unexpected successful CLI stderr: $($Record.stderr)"};$Record.stdout|ConvertFrom-Json -DateKind String}
function Validate-Compare($c){
    Schema $c @('status','operation','loops','pure_predictions','stream_snapshot_comparisons','stream_state_comparisons','CTS_success_observes','CTS_rejections','refusal_cross_state_comparisons','candidate_mass_bits','oracle_mass_bits','all_snapshot_fields_direct','all_nodes_direct','refusal_before_after_direct','Math_only_shared','diagnostic_only')
    Require $c @{status='passed';operation='compare';pure_predictions=1080;stream_snapshot_comparisons=2160;stream_state_comparisons=2376;CTS_success_observes=1620;CTS_rejections=2979;refusal_cross_state_comparisons=5958;candidate_mass_bits=64;oracle_mass_bits=128;all_snapshot_fields_direct=$true;all_nodes_direct=$true;refusal_before_after_direct=$true;Math_only_shared=$true;diagnostic_only=$true}
    $expected=@('V-valid:4','V-invalid:16','KT-heavy:40','KT-tie:12','KT-inactive:12','KT-allraw:8','KT-prefix:3','MIX-valid:50','MIX-invalid:8','SWITCH-valid:135','SWITCH-invalid:9','SWITCH-priority:3','analytic-cts:7','K-normal:1350','K-entry:225','K-switch:240','K-priority:20','K-empty:50','CTS-constructor:11','CTS-stream:1080','CTS-token:2160','CTS-foreign:216','CTS-same-state:216','CTS-rebased:216','CTS-CAP:162','CTS-node-atomic:54','CTS-current:216','CTS-nonleaf:48','CTS-inactive-raw:108','CTS-level-priority:96','CTS-class-prefix:27','POOL-predict:350','POOL-learn:1000','POOL-count-bad:32','POOL-cts-bad:16','POOL-weight-bad:40','POOL-prefix-bad:3','POOL-normalize:12','POOL-normalize-bad:27','POOL-smooth-prefix:3','POOL-score:80','POOL-feature:200','POOL-feature-inactive:30','POOL-feature-huge:100','POOL-q0:20','POOL-observe-priority:20','MATH-connect:6','EXP-domain:8','SIGNED-golden:4','analytic-pool:1')
    if($c.loops.Count -ne $expected.Count){throw 'Loop IDs count differs'}
    for($i=0;$i -lt $expected.Count;$i++){Schema $c.loops[$i] @('id','cases');if("$($c.loops[$i].id):$($c.loops[$i].cases)" -cne $expected[$i]){throw "Loop count/order differs: $i"}}
}
function Validate-Selfcheck($s,[bool]$Old){
    Schema $s @('status','operation','depths','normal_cases','byte_roundtrips','canonical_cases','proof_encode_decode','proof_repeat','proof_fields','malformed_cases','short_depth_header_checks','model_rejection_named_cases','model_rejection_assertions','cap_exact_successes','records')
    $depths=if($Old){@(4,5,6,7,8)}else{@(0,1,2,4,5,8)};$op=if($Old){'selfcheck-old'}else{'selfcheck-new'};$n=$depths.Count;$mal=if($Old){33}else{34}
    Require $s @{status='passed';operation=$op;normal_cases=14*$n;byte_roundtrips=14*$n;canonical_cases=14*$n;proof_encode_decode=14*$n;proof_repeat=14*$n;proof_fields=14;malformed_cases=$mal*$n;short_depth_header_checks=4*$n;model_rejection_named_cases=14*$n;model_rejection_assertions=16*$n;cap_exact_successes=$n}
    if(($s.depths -join ',') -cne ($depths -join ',') -or $s.records.Count -ne $n){throw 'Selfcheck depth/count differs'}
    $names=@('short_header','old_magic','bad_magic','input_length','primary_field','alphabet_zero','alphabet_over','payload_short','payload_quota','payload_derived_bound','header_crc','payload_crc','plain_crc','metadata_padding','metadata_sentinel','metadata_width','metadata_rank','range_prefix','range_gap','range_truncated','range_trailing','range_termination','sentinel_count','primary_sentinel','lf_cycle','active_early','active_remaining','escape_noncanonical','escape_fourbytes','escape_remaining','unsupported_depth9','unsupported_depth_max','depth_crc');if(!$Old){$names+='old_q32_magic'}
    $reasons=@('bad frame magic/header','bad frame magic/header','bad frame magic/header','frame fields outside bounds','frame fields outside bounds','frame fields outside bounds','frame fields outside bounds','frame fields outside bounds','frame fields outside bounds','payload exceeds transformed bound','header CRC mismatch','payload CRC mismatch','plain length/CRC mismatch','packed alphabet high bitmap padding nonzero','packed alphabet sentinel 0 missing','packed alphabet rank byte width not canonical','packed alphabet rank outside factorial','invalid range prefix','range rounding gap','truncated range stream','trailing range bytes','noncanonical range termination','sentinel count','invalid primary sentinel','LF cycle inconsistent','active list exhausted before declared length','active list not empty at end','noncanonical length escape','length escape exceeds four bytes','run length outside remaining bound','unsupported CTS depth','unsupported CTS depth','header CRC mismatch');if(!$Old){$reasons+='bad frame magic/header'}
    for($i=0;$i -lt $n;$i++){$r=$s.records[$i];Schema $r @('depth','short_depth_header_checks','status','operation','normal_cases','byte_roundtrips','canonical_cases','malformed_cases','model_rejection_named_cases','model_rejection_assertions','cap_exact_successes','CRC32_known_fixture','LCG_seed','model_state_comparison','malformed','general_8MiB_input_supported','full_benchmark_allowed','heap_write_sync_fault_injection');Require $r @{depth=$depths[$i];status='passed';operation='selfcheck';normal_cases=14;byte_roundtrips=14;canonical_cases=14;malformed_cases=$mal;short_depth_header_checks=4;model_rejection_named_cases=14;model_rejection_assertions=16;cap_exact_successes=1;CRC32_known_fixture=$true;LCG_seed=1831565813;general_8MiB_input_supported=$false;full_benchmark_allowed=$false;heap_write_sync_fault_injection=$false};if($r.malformed.Count -ne $mal){throw 'Malformed count differs'};for($j=0;$j -lt $mal;$j++){Schema $r.malformed[$j] @('name','reason','frame_bytes');Require $r.malformed[$j] @{name=$names[$j];reason=$reasons[$j]};if($r.malformed[$j].frame_bytes -le 0){throw 'Missing malformed fixture size'}}}
}
function Validate-ABBA($a,$Record){
    Schema $a @('status','operation','implementation_order','depth_order','records','runs_completed','encode_calls','decode_calls','plain_comparisons','proof_comparisons','repeat_frame_comparisons','repeat_frame_matched_bytes','input_reads','warmup_runs','abba_cycles','peak_live_candidate_frames','peak_live_candidate_frame_bytes','references_remaining','frame_clones_created','disk_frames_created','disk_restores_created','old_encode_total_ns','new_encode_total_ns','old_decode_total_ns','new_decode_total_ns','candidate_adoption_gates_passed','diagnostic_only','formal_speed_CPU_verified','failure_evidence')
    Require $a @{operation='abba';input_reads=1;warmup_runs=0;references_remaining=0;frame_clones_created=$false;disk_frames_created=$false;disk_restores_created=$false;diagnostic_only=$true;formal_speed_CPU_verified=$false}
    if(($a.implementation_order -join ',') -cne 'old,new,new,old' -or ($a.depth_order -join ',') -cne '5,5,5,5'){throw 'ABBA order differs'}
    if($a.status -eq 'passed'){if($Record.exit -ne 0){throw 'Passed ABBA exit differs'};Require $a @{runs_completed=4;encode_calls=4;decode_calls=4;plain_comparisons=4;proof_comparisons=4;repeat_frame_comparisons=2;abba_cycles=1};if($a.peak_live_candidate_frames -gt 3 -or $a.peak_live_candidate_frame_bytes -gt 1445948 -or $a.repeat_frame_matched_bytes -ne 478750+$a.records[1].frame_bytes){throw 'ABBA frame/accounting bound'}}
    elseif($a.status -eq 'size-rejected'){if($Record.exit -ne 2){throw 'Size rejection exit differs'};Require $a @{runs_completed=2;encode_calls=2;decode_calls=2;plain_comparisons=2;proof_comparisons=2;repeat_frame_comparisons=0;repeat_frame_matched_bytes=0;abba_cycles=0;candidate_adoption_gates_passed=$false};if($a.records[1].frame_bytes -le 483599){throw 'False size refusal'}}
    else{throw 'ABBA failed'}
    if($a.records.Count -ne $a.runs_completed -or $null -ne $a.failure_evidence){throw 'ABBA record count/error'}
    for($i=0;$i -lt $a.records.Count;$i++){$r=$a.records[$i];Schema $r @('index','depth','implementation','status','frame_bytes','encode_elapsed_ns','decode_elapsed_ns','matched_plain_bytes','all_plain_equal','all_proof_equal','proof_fields','CDF_as_bits','repeat_frame_compared','candidate_frames_before_comparison','candidate_frame_bytes_before_comparison','reference_frames_after','reference_frame_bytes_after','size_gate_limit_bytes','size_gate_passed','encode_stats','decode_stats');Require $r @{index=$i;depth=5;implementation=@('old','new','new','old')[$i];matched_plain_bytes=2811006;all_plain_equal=$true;all_proof_equal=$true;proof_fields=14;CDF_as_bits=$true;repeat_frame_compared=($i -ge 2);size_gate_limit_bytes=483599};if(($r.encode_stats|ConvertTo-Json -Compress -Depth 5) -cne ($r.decode_stats|ConvertTo-Json -Compress -Depth 5)){throw 'All encode/decode stats differ'};if($r.encode_elapsed_ns -le 0 -or $r.decode_elapsed_ns -le 0){throw 'Timer evidence missing'};if($i -eq 0 -or $i -eq 3){Require $r @{frame_bytes=478750;status='passed';size_gate_passed=$true}}else{Require $r @{status=$(if($a.status -eq 'size-rejected'){'size-rejected'}else{'passed'});size_gate_passed=($a.status -eq 'passed')}}}
    if($a.status -eq 'passed'){$adopt=$a.records[1].frame_bytes -le 483599 -and $a.new_encode_total_ns -lt $a.old_encode_total_ns -and $a.new_decode_total_ns -lt $a.old_decode_total_ns;if($a.candidate_adoption_gates_passed -ne $adopt){throw 'Adoption arithmetic differs'}}
}
function Static-Graph{
    $root=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'probe.rs') -Raw
    foreach($line in @('use reference_cts as integer_cts;','mod old_pool;','mod new_cts;','mod integer_pool;')){if(!$root.Contains($line)){throw "Missing alias boundary: $line"}}
    $pool=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'integer_pool.rs') -Raw;$oracle=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'oracle.rs') -Raw
    if($pool -notmatch 'new_cts as c' -or $oracle -match '\b(new_cts|integer_cts|integer_pool|reference_cts|baseline_cts)::|crate::\{'){throw 'Numeric oracle/old/new aliases shared'}
    $compiled=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$edges=[Collections.Generic.List[object]]::new()
    function Visit([string]$Path){$Path=[IO.Path]::GetFullPath($Path);if(!$compiled.Add($Path)){return};if(!(Test-Path -LiteralPath $Path)){throw "Missing source: $Path"};$text=Get-Content -LiteralPath $Path -Raw;foreach($m in [regex]::Matches($text,'#\[path\s*=\s*"([^"]+)"\]\s*(?:pub\(crate\)\s+)?mod\s+(\w+)')){$dest=[IO.Path]::GetFullPath((Join-Path (Split-Path $Path) $m.Groups[1].Value));$edges.Add([pscustomobject]@{source=$Path;module=$m.Groups[2].Value;target=$dest});Visit $dest}}
    Visit (Join-Path $PSScriptRoot 'probe.rs')
    if($compiled.Count -ne 17 -or $edges.Count -ne 17){throw "Unexpected graph nodes=$($compiled.Count) edges=$($edges.Count)"}
    foreach($path in $compiled){if($path -match 'quaternary-cts-(alpha|pool-qcancel|pool-math-u64)'){throw 'Unadopted optimization connected'};if(@($sources|Where-Object {$_.path -eq $path}).Count -ne 1){throw "Graph not covered by identity: $path"}}
    $template=(Get-Content -LiteralPath (Join-Path $PSScriptRoot '../quaternary-cts-alpha/codec.rs') -Raw).Replace("`r`n","`n")
    $numeric=[regex]::Match($template,'(?s)fn payload_limit\(.*?(?=fn stats_json\()').Value
    foreach($name in @('baseline_codec.rs','codec.rs')){$text=(Get-Content -LiteralPath (Join-Path $PSScriptRoot $name) -Raw).Replace("`r`n","`n");$actual=[regex]::Match($text,'(?s)fn payload_limit\(.*?(?=fn stats_json\()').Value;if(!$numeric -or $actual -cne $numeric){throw "Frozen numerical codec body changed: $name"};foreach($timer in [regex]::Matches($template,'let begin=std::time::Instant::now\(\);let result=(encode\(input,depth\)|decode\(frame\));let elapsed_ns=.*?;')){if(!$text.Contains($timer.Value)){throw "Frozen timer changed: $name"}}}
    $base=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'baseline_codec.rs') -Raw;$new=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'codec.rs') -Raw
    if($base -notmatch 'old_pool as integer_pool,baseline_cts as integer_cts' -or $new -notmatch 'integer_pool,new_cts as integer_cts' -or $base -notmatch 'b"KHQCID01"' -or $new -notmatch 'b"KHQCMQ21"' -or $new -match 'depth8 fixed numerical audit mismatch'){throw 'Codec policy/baseline aliases changed'}
    $report.compiled_graph=@{sources=@($compiled|Sort-Object);source_count=$compiled.Count;edge_count=$edges.Count;edges=$edges;old_pool_root_alias='reference_cts';candidate_CTS='new_cts';candidate_pool='integer_pool';oracle_independent=$true;Math_only_shared=$true;numeric_timer_bodies_unchanged=$true;baseline_e2e_path_switched=$true}
}
try{
    $tokens=$null;$parseErrors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$parseErrors);if($parseErrors.Count){throw ($parseErrors.Message -join '; ')}
    if($PSVersionTable.PSVersion.ToString() -ne '7.6.5' -or [IO.Path]::GetFullPath((Get-Process -Id $PID).Path) -ne [IO.Path]::GetFullPath($runtime)){throw 'Dedicated PowerShell7.6.5 required'}
    $report.runtime=Identity $runtime;$report.compiler=Identity $compiler
    if($report.runtime.sha256 -ne '362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139' -or $report.compiler.sha256 -ne 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'){throw 'Runtime/compiler SHA differs'}
    $null=Safe-Path $work;if(Test-Path -LiteralPath $work){throw 'Fresh work directory already exists'}
    $priorPath=Join-Path $project 'build/khc-quaternary-cts-alpha-20261003/report.json';$priorIdentity=Identity $priorPath
    if($priorIdentity.sha256 -ne '66CAFD4526241B1A13C83754FCE142F976344ECBC0E817405CCC68DFEA26E663' -or $priorIdentity.bytes -ne 362487){throw 'Alpha report identity differs'}
    $prior=Get-Content -LiteralPath $priorPath -Raw|ConvertFrom-Json -DateKind String
    if($prior.status -ne 'passed' -or $prior.sources.Count -ne 149 -or $prior.sources_after.Count -ne 149 -or !$prior.abba_validated -or !$prior.alpha_comparison_validated){throw 'Alpha report basis shape/status'}
    for($i=0;$i -lt 149;$i++){$b=$prior.sources[$i];$a=$prior.sources_after[$i];Schema $b @('path','sha256','bytes','mtime_utc');Same-Identity $b $a;$now=Identity $b.path;Same-Identity $b $now;$sources.Add($now)}
    $pins=@(@('../QUATERNARY_CTS_MIXED_Q21_CONTRACT_20261003.md',$contractSha),@('../QUATERNARY_CTS_ALPHA_ABBA_RESULT_20261003.md','F3FE919A18CD98A2C735A4B8502110DF30E37C95BE1104229E6A26D8E5872067'),@('../QUATERNARY_CTS_MIXED_Q21_FEASIBILITY_20261003.md','44FB4B26E1F40DFD376E568DBD17F65878885ED322B74A0AA9ED49EB1FD39DF2'))
    foreach($pin in $pins){$id=Identity (Join-Path $PSScriptRoot $pin[0]);if($id.sha256 -ne $pin[1]){throw 'Pinned contract/result/feasibility differs'};$sources.Add($id)}
    $newbytes=0;foreach($file in $files){$id=Identity (Join-Path $PSScriptRoot $file);$newbytes+=$id.bytes;$sources.Add($id)}
    if($sources.Count -ne 163 -or @($sources.path|Sort-Object -Unique).Count -ne 163 -or $newbytes -gt 300KB){throw 'Source count/uniqueness/300KiB budget'}
    if((Identity (Join-Path $PSScriptRoot 'FAILURE_PLAN.md')).sha256 -ne $planSha){throw 'Final failure plan SHA differs'}
    foreach($id in $sources){$null=Safe-Path $id.path;$locks.Add([IO.File]::Open($id.path,'Open','Read','Read'))}
    $report.basis=@{prior_report_identity=$priorIdentity;old_source_count=149;new_source_count=11;new_source_bytes=$newbytes;total_identity_count=163;mtime_comparison='ISO string→Roundtrip DateTime UTC ticks';prior_Execute_repeated=$false;contract_sha256=$contractSha;plan_sha256=$planSha}
    Static-Graph
    $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8
    if($report.disk_before.used_bytes+1536KB -gt 8MB){throw 'Capacity reserve exceeds8MiB'}
    $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($work));if($drive.AvailableFreeSpace -lt 5GB+8MB){throw 'Free space below5GiB+8MiB'}
    foreach($file in $files|Where-Object {$_ -like '*.rs'}){$r=Child $formatter @('--edition','2024','--config','skip_children=true','--emit','stdout',(Join-Path $PSScriptRoot $file)) -Formatting;Success $r;if($r.stderr){throw 'Rustfmt stderr'};if($r.stdout_bytes -le 0){throw 'Rustfmt empty stdout'}}
    # identity三組、固定CLIの解析結果、失敗stderrを含むreport見積りを出力前に検査する。
    $identityBytes=[Text.Encoding]::UTF8.GetByteCount(($sources|ConvertTo-Json -Depth 5))
    $currentBytes=[Text.Encoding]::UTF8.GetByteCount(($report|ConvertTo-Json -Depth 30))
    $report.capacity_plan.projected_report_bytes=$currentBytes+2*$identityBytes+128KB+32KB+4KB
    if($report.capacity_plan.projected_report_bytes -gt 512KB){throw 'Projected report exceeds512KiB'}
    if($Execute){
        $null=New-Item -ItemType Directory -Path $work;$created=$true;Save-Report
        $v=Child $compiler @('--version');Success $v;if($v.stdout -ne 'rustc 1.98.1 (48a229cea 2026-09-01)'){throw 'Compiler version differs'}
        $exe=Join-Path $work 'q21-o2-yes.exe';$report.compile_calls=1
        $b=Child $compiler @((Join-Path $PSScriptRoot 'probe.rs'),'--edition=2024','--cfg','frame_audit','--cfg','primitive_audit','-C','opt-level=2','-C','overflow-checks=yes','-C','panic=abort','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE','-o',$exe);Success $b
        $report.executable_before=Identity $exe;if($report.executable_before.bytes -gt 1MB){throw 'EXE exceeds1MiB'};$locks.Add([IO.File]::Open($exe,'Open','Read','Read'))
        $parsedBytes=0
        foreach($cli in @('compare','selfcheck-old','selfcheck-new','abba')){$argv=if($cli -eq 'abba'){@('abba',(Join-Path $project 'build/khc-current-source-native-solid-20260923-group/all.group'))}else{@($cli)};$report.candidate_cli_calls++;$r=Child $exe $argv;$parsed=Capture $r;$report[('parsed_'+$cli.Replace('-','_'))]=$parsed;$parsedBytes+=[Text.Encoding]::UTF8.GetByteCount(($parsed|ConvertTo-Json -Depth 20));if($parsedBytes -gt 128KB){throw 'Parsed CLI results exceed report reserve'};$r.stdout_truncated=$r.stdout_bytes -gt 1024;$r.stdout=Preview $r.stdout 1024;Save-Report
            if($cli -eq 'abba'){Validate-ABBA $parsed $r;$report.status=$parsed.status}else{Success $r;if($cli -eq 'compare'){Validate-Compare $parsed}else{Validate-Selfcheck $parsed ($cli -eq 'selfcheck-old')}}
        }
        if($report.candidate_cli_calls -ne 4){throw 'Codec CLI count differs'};$report.executable_after=Identity $exe;Same-Identity $report.executable_before $report.executable_after
        $entries=@(Get-ChildItem -LiteralPath $work -Force);if($entries.Count -ne 2 -or @($entries|Where-Object {$_.Name -notin @('q21-o2-yes.exe','report.json')}).Count){throw 'Unexpected output entries'}
        $running=@(Get-Process|Where-Object {try{$_.Path -and [IO.Path]::GetFullPath($_.Path) -eq [IO.Path]::GetFullPath($exe)}catch{$false}});$report.owned_codec_processes_at_end=$running.Count;if($running.Count){throw 'Owned codec process remains'}
    }
}catch{$report.status='failed';$report.error=Preview $_.Exception.Message 4096;throw}
finally{
    try{
        if($sources.Count -eq 163){$report.sources_after=@($sources|ForEach-Object {$id=Identity $_.path;Same-Identity $_ $id;$id});$report.sources_live=@($report.sources_after|ForEach-Object {$id=Identity $_.path;Same-Identity $_ $id;$id})}
        if($report.basis){Same-Identity $report.basis.prior_report_identity (Identity $report.basis.prior_report_identity.path)}
        $report.disk_after=& $guard -WorkDirectory $work -MaxRunMiB 8;$report.ended_utc=[DateTime]::UtcNow.ToString('o');Save-Report
    }finally{foreach($s in $locks){$s.Dispose()}}
}
if($Execute){[pscustomobject]@{status=$report.status;report=(Identity (Join-Path $work 'report.json'));source_count=163;candidate_cli_calls=$report.candidate_cli_calls;compile_calls=$report.compile_calls}|ConvertTo-Json -Depth 4}
else{[pscustomobject]@{status=$report.status;source_count=$sources.Count;after_count=$report.sources_after.Count;live_count=$report.sources_live.Count;new_source_bytes=$report.basis.new_source_bytes;compiled_graph=$report.compiled_graph;runtime=$report.runtime;compiler=$report.compiler;records=$records;basis=$report.basis;disk_before=$report.disk_before;disk_after=$report.disk_after;fresh_output_created=$false;compile_calls=0;candidate_cli_calls=0}|ConvertTo-Json -Depth 8}
