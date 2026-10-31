#Requires -Version 7.5
[CmdletBinding()]
param([string]$ReportPath=(Join-Path $PSScriptRoot '../../../build/khc-product-comparison-20261005-repair2/report.json'))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$Root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$Errors=[Collections.Generic.List[string]]::new()
$Lock=$null
$r=$null
function Check([bool]$Condition,[string]$Message){if(-not $Condition){$Errors.Add($Message)}}
function Whole([object]$Value){return $null -ne $Value -and $Value -is [ValueType] -and [double]::IsFinite([double]$Value) -and [double]$Value -eq [math]::Truncate([double]$Value)}
function Hash-Bytes([byte[]]$Bytes){$h=[Security.Cryptography.SHA256]::Create();try{return [BitConverter]::ToString($h.ComputeHash($Bytes)).Replace('-','')}finally{$h.Dispose()}}
function Median([object[]]$Values){$s=@($Values|Sort-Object);return [double]$s[[int][math]::Floor($s.Count/2)]}
function Range-Time([object[]]$Values){$s=@($Values|Sort-Object);return @{median_ns=(Median $Values);min_ns=[double]$s[0];max_ns=[double]$s[-1]}}
try{
    $path=[IO.Path]::GetFullPath($ReportPath);$file=Get-Item -LiteralPath $path
    if($file.Length -gt 262144){throw 'report byte bound'}
    $Lock=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $identity=@{path=$path;bytes=$file.Length;mtimeUtc=$file.LastWriteTimeUtc.ToString('o');SHA256=(Get-FileHash -LiteralPath $path).Hash}
    $r=Get-Content -Raw -LiteralPath $path|ConvertFrom-Json -DateKind String
    $complete=$r.status -eq 'completed'
    Check ($r.kind -eq 'product_block_comparison') 'report kind'
    Check ($r.live_pins_unchanged -eq $true) 'runner live pins'
    Check ($r.raw_frame_disk_files -eq 0) 'raw frame disk claim'
    Check ($r.warmups_per_fixture_algorithm -eq 1 -and $r.measured_samples_per_fixture_algorithm -eq 9) 'sampling contract'
    Check ($r.limits.block_bytes -eq 1048576 -and $r.limits.stdout_bytes -eq 1052672 -and $r.limits.stderr_bytes -eq 16384 -and $r.limits.child_seconds -eq 60 -and $r.limits.suite_seconds -eq 1800 -and $r.limits.child_WS_private_bytes -eq 167772160 -and $r.limits.cpu_quiet_percent -eq 15) 'limits'
    Check ($r.suite_elapsed_ms -ge 0 -and $r.suite_elapsed_ms -le 1800000) 'suite time'
    $pinNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($pin in $r.pins){
        Check ($pinNames.Add($pin.path)) "duplicate pin $($pin.path)"
        $f=Get-Item -LiteralPath $pin.path
        Check ($f.Length -eq $pin.bytes -and $f.LastWriteTimeUtc.ToString('o') -eq $pin.mtimeUtc -and (Get-FileHash -LiteralPath $pin.path).Hash -eq $pin.SHA256) "live identity $($pin.path)"
    }
    foreach($f in Get-ChildItem -LiteralPath (Join-Path $Root 'src/khc') -File -Recurse -Filter '*.rs'){Check ($pinNames.Contains($f.FullName)) "source pin missing $($f.Name)"}
    foreach($name in @('src/lib.rs','src/directory.rs','src/writer.rs','src/reader.rs','src/pathname.rs','src/error.rs','src/operation.rs','Cargo.toml','Cargo.lock','.cargo/config.toml','examples/khc_block_io.rs','experiments/khc/product-comparison/run.ps1','experiments/khc/product-comparison/FAILURE_PLAN.md')){Check ($pinNames.Contains([IO.Path]::GetFullPath((Join-Path $Root $name)))) "required pin $name"}
    $tc=Join-Path ([Environment]::GetFolderPath('UserProfile')) '.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin'
    foreach($n in @('rustc.exe','cargo.exe')){Check ($pinNames.Contains([IO.Path]::GetFullPath((Join-Path $tc $n)))) "tool pin $n"}
    $helperPins=@($r.pins|Where-Object {$_.path.EndsWith('khc_block_io.exe',[StringComparison]::OrdinalIgnoreCase)});Check ($helperPins.Count -ge 1) 'helper binary pin'
    $ids=@('KHC_paid','KHC_low','Zstd3','LZMA2_4m','LZMA2_8m','Zstd19','LZMA2_64m')
    Check ($r.algorithms.Count -in @(7,8)) 'algorithm count'
    $candidateIndices=[Collections.Generic.List[int]]::new()
    $activeCount=0
    for($ai=0;$ai -lt 7;$ai++){
        $a=$r.algorithms[$ai];Check ($a.id -eq $ids[$ai]) "algorithm identity $ai"
        if($ai -lt 5){$candidateIndices.Add($ai);$bound=if($ai -eq 4){167772160}else{67108864};Check ($a.memory_limit_bytes -eq $bound) "algorithm memory $ai";if($a.state -eq 'active'){$activeCount++};if($complete){Check ($a.state -eq 'active') "interrupted algorithm $ai"};Check ($pinNames.Contains($a.exe)) "algorithm executable pin $ai"}
    }
    if($r.algorithms.Count -eq 8){$a=$r.algorithms[7];$ids+=@($a.id);$candidateIndices.Add(7);Check ($a.id -notin $ids[0..6] -and $a.tier -eq 'matched' -and $a.memory_limit_bytes -eq 67108864) 'old block comparison contract';Check ($pinNames.Contains($a.exe)) 'old helper executable pin';if($a.state -eq 'active'){$activeCount++};if($complete){Check ($a.state -eq 'active') 'interrupted old block algorithm'}}
    $expectedRows=13*$activeCount*10
    Check ($r.algorithms[5].state -eq 'unexecuted_memory_estimate_unavailable' -and $r.algorithms[6].state -eq 'unexecuted_budget_exceeded') 'unexecuted classifications'
    $expectedNames=@('empty','one_byte','repeat4KiB','seeded_random64KiB','Japanese_JSON4KiB','AES_CBC64KiB','Zstd3_repeat4KiB_frame','alice29','kennedy','dickens','mozilla','osdb','x-ray')
    if($complete){Check ($r.inputs.Count -eq 13) '13 fixtures';Check ($r.samples.Count -eq $expectedRows) 'complete row count';Check ($r.failures.Count -eq 0) 'unexpected failures';Check ($r.native_calls -eq (2*$expectedRows+3)) 'complete native call count';Check ($r.quiet_checks.Count -eq 132) '132 quiet checks'}
    $corpus=@('build/khc-corpus/canterbury-development/alice29.txt','build/khc-corpus/canterbury-development/kennedy.xls','build/khc-corpus/silesia-holdout/dickens','build/khc-corpus/silesia-holdout/mozilla','build/khc-corpus/silesia-holdout/osdb','build/khc-corpus/silesia-holdout/x-ray')
    for($fi=0;$fi -lt $r.inputs.Count;$fi++){
        $input=$r.inputs[$fi];Check ($fi -lt 13 -and $input.name -eq $expectedNames[$fi]) "input order $fi";Check ($input.bytes -le 1048576 -and $input.bytes -ge 0 -and (Whole $input.bytes)) "input bound $fi";Check ($input.window_offset -eq 0 -and $input.window_bytes -eq $input.bytes) "window metadata $fi";Check ($input.SHA256 -match '^[0-9A-F]{64}$') "input SHA $fi"
        if($fi -ge 7 -and $fi -lt 13){
            $expected=$corpus[$fi-7];Check ($input.source -eq $expected) "corpus source $fi";$source=Join-Path $Root $expected;$f=Get-Item -LiteralPath $source;$window=if($fi -lt 9){1048576}else{262144};$n=[int][math]::Min($f.Length,$window)
            Check ($input.bytes -eq $n -and $input.source_bytes -eq $f.Length -and (Get-FileHash -LiteralPath $source).Hash -eq $input.source_SHA256) "source identity $fi"
            Check ($input.role -eq $(if($fi -lt 9){'development'}else{'holdout_window'})) "corpus role $fi"
            $b=[byte[]]::new($n);$fs=[IO.File]::OpenRead($source);try{$at=0;while($at -lt $n){$got=$fs.Read($b,$at,$n-$at);if($got -eq 0){throw 'window truncated'};$at+=$got}}finally{$fs.Dispose()}
            Check ((Hash-Bytes $b) -eq $input.SHA256) "window SHA $fi"
        }
    }
    if($complete){Check ($r.pipeline_probe.passed -eq $true -and $r.pipeline_probe.actual_byte_equal -eq $true -and $r.pipeline_probe.calls -eq 2 -and $r.pipeline_probe.encode_status -eq 'ok' -and $r.pipeline_probe.decode_status -eq 'ok') 'pipeline byte equality';Check ($r.preparation.Count -eq 1 -and $r.preparation[0].status -eq 'ok') 'precompressed preparation'}
    $qUnique=[Collections.Generic.HashSet[string]]::new()
    foreach($q in $r.quiet_checks){Check ($q.Count -eq 6 -and (Whole $q[0]) -and (Whole $q[1]) -and $q[5] -eq 'quiet' -and [double]::IsFinite([double]$q[2]) -and $q[2] -ge 0 -and $q[2] -le 15 -and (Whole $q[3]) -and $q[3] -ge 1 -and $q[4] -is [ValueType] -and [double]::IsFinite([double]$q[4]) -and $q[4] -ge 0 -and $q[4] -le 61000) 'quiet values';Check ($qUnique.Add("$($q[0])/$($q[1])")) 'duplicate quiet'}
    if($complete){for($fi=0;$fi -lt 13;$fi++){for($round=-1;$round -lt 9;$round++){Check ($qUnique.Contains("$fi/$round")) "missing quiet $fi/$round"}};Check ($qUnique.Contains('-1/-1') -and $qUnique.Contains('-2/-1')) 'probe/preparation quiet'}
    $unique=[Collections.Generic.HashSet[string]]::new();$warm=0;$measured=0
    foreach($row in $r.samples){
        Check ($row.Count -eq 14) 'sample width'
        $fi=[int]$row[0];$ai=[int]$row[1];$round=[int]$row[2]
        Check ((Whole $row[0]) -and (Whole $row[1]) -and (Whole $row[2]) -and $fi -ge 0 -and $fi -lt $r.inputs.Count -and $candidateIndices.Contains($ai) -and $round -ge -1 -and $round -le 8) 'sample indices'
        Check ($unique.Add("$fi/$ai/$round")) "duplicate row $fi/$ai/$round"
        if($round -eq -1){$warm++}else{$measured++}
        $position=$candidateIndices.IndexOf($ai);$order=if(($round+$fi)%2 -eq 0){$candidateIndices.Count-1-$position}else{$position};Check ((Whole $row[3]) -and $row[3] -eq $order) "sample order $fi/$ai/$round"
        if($complete){Check ($row[4] -eq 'ok') "sample status $fi/$ai/$round"}
        if($row[4] -eq 'ok'){
            $bound=if($ai -eq 4){167772160}else{67108864}
            Check ((Whole $row[5]) -and $row[5] -ge 0 -and $row[5] -le 1052672) 'sample encoded bound'
            foreach($i in @(6,7)){Check ((Whole $row[$i]) -and $row[$i] -gt 0 -and $row[$i] -le 60000000000L) 'sample child wall'}
            foreach($i in @(8,9,11,12)){Check ((Whole $row[$i]) -and $row[$i] -gt 0 -and $row[$i] -le $bound) "sample memory $fi/$ai"}
            foreach($i in @(10,13)){Check ((Whole $row[$i]) -and $row[$i] -ge 1) 'memory observations'}
        }
    }
    if($complete){Check ($warm -eq (13*$activeCount) -and $measured -eq (13*$activeCount*9)) 'warm/measured count'}
    $summary=[Collections.Generic.List[object]]::new();$pairs=[Collections.Generic.List[object]]::new();$winners=[Collections.Generic.List[object]]::new();$totals=[Collections.Generic.List[object]]::new()
    for($fi=0;$fi -lt $r.inputs.Count;$fi++){foreach($ai in $candidateIndices){
        $all=[Collections.Generic.List[object]]::new();$rows=[Collections.Generic.List[object]]::new()
        foreach($row in $r.samples){if($row[0] -eq $fi -and $row[1] -eq $ai -and $row[4] -eq 'ok'){$all.Add($row);if($row[2] -ge 0){$rows.Add($row)}}}
        if($complete){Check ($all.Count -eq 10 -and $rows.Count -eq 9) "missing measured group $fi/$ai"}
        if($rows.Count -ne 9){continue}
        $size=$all[0][5];foreach($row in $all){Check ($row[5] -eq $size) "size changed $fi/$ai"}
        $enc=[Collections.Generic.List[object]]::new();$dec=[Collections.Generic.List[object]]::new();$ws=0L;$priv=0L
        foreach($row in $rows){$enc.Add($row[6]);$dec.Add($row[7])}
        foreach($row in $all){$ws=[math]::Max($ws,[math]::Max($row[8],$row[11]));$priv=[math]::Max($priv,[math]::Max($row[9],$row[12]))}
        $e=Range-Time $enc.ToArray();$d=Range-Time $dec.ToArray();$raw=$r.inputs[$fi].bytes
        $summary.Add(@{input_index=$fi;algorithm=$ids[$ai];raw_bytes=$raw;frame_bytes=$size;measured_count=9;encode=$e;decode=$d;max_peak_WS=$ws;max_polled_private=$priv;encode_MiB_s=$(if($raw){$raw*1e9/1048576/$e.median_ns}else{$null});decode_MiB_s=$(if($raw){$raw*1e9/1048576/$d.median_ns}else{$null})})
    }}
    foreach($ai in $candidateIndices){$raw=0L;$frames=0L;$nonempty=0L;$et=0.0;$dt=0.0;$groups=0;foreach($s in $summary){if($s.algorithm -eq $ids[$ai]){$groups++;$raw+=$s.raw_bytes;$frames+=$s.frame_bytes;if($s.raw_bytes){$nonempty+=$s.raw_bytes;$et+=$s.encode.median_ns;$dt+=$s.decode.median_ns}}};$totals.Add(@{algorithm=$ids[$ai];fixture_groups=$groups;complete=($groups -eq 13);raw_bytes=$raw;frame_bytes=$frames;nonempty_raw_bytes=$nonempty;nonempty_encode_MiB_s=$(if($et -gt 0){$nonempty*1e9/1048576/$et}else{$null});nonempty_decode_MiB_s=$(if($dt -gt 0){$nonempty*1e9/1048576/$dt}else{$null})})}
    for($fi=0;$fi -lt $r.inputs.Count;$fi++){$paid=$null;$low=$null;$group=[Collections.Generic.List[object]]::new();foreach($s in $summary){if($s.input_index -eq $fi){$group.Add($s);if($s.algorithm -eq 'KHC_paid'){$paid=$s};if($s.algorithm -eq 'KHC_low'){$low=$s}}}
        if($paid -and $low){$pairs.Add(@{input_index=$fi;low_minus_paid_bytes=$low.frame_bytes-$paid.frame_bytes;low_to_paid_size_ratio=$low.frame_bytes/$paid.frame_bytes;low_encode_speedup=$paid.encode.median_ns/$low.encode.median_ns;low_decode_speedup=$paid.decode.median_ns/$low.decode.median_ns})}
        if($group.Count){$sorted=@($group|Sort-Object frame_bytes);$best=$sorted[0].frame_bytes;$win=@($group|Where-Object {$_.frame_bytes -eq $best}|ForEach-Object {$_.algorithm});$winners.Add(@{input_index=$fi;comparison_complete=($group.Count -eq $candidateIndices.Count);smallest_frame_bytes=$best;size_winners=$win;encode_process_time_winner=(@($group|Sort-Object {$_.encode.median_ns})[0].algorithm);decode_process_time_winner=(@($group|Sort-Object {$_.decode.median_ns})[0].algorithm)})}
    }
    $now=Get-Item -LiteralPath $path;Check ($now.Length -eq $identity.bytes -and $now.LastWriteTimeUtc.ToString('o') -eq $identity.mtimeUtc -and (Get-FileHash -LiteralPath $path).Hash -eq $identity.SHA256) 'report changed during verification'
    $status=if(-not $complete){'incomplete'}elseif($Errors.Count){'invalid'}else{'readonly_verified_complete'}
    [ordered]@{status=$status;runner_status=$r.status;report=$identity;errors=$Errors;runner_failures=$r.failures;complete=$complete -and $Errors.Count -eq 0;warmups=$warm;measured=$measured;native_calls_recorded=$r.native_calls;summary=$summary;totals=$totals;paired_low_ablation=$pairs;fixture_winners=$winners;byte_check_source='runner ok status and pipeline actual_byte_equal; verifier does not decode';memory_scope=$r.memory_scope;timing_scope=$r.timing_scope;native_calls=0;writes=0;network=0;compile=0}|ConvertTo-Json -Depth 12 -Compress
    if($Errors.Count -or -not $complete){exit 1}
}catch{[ordered]@{status=$(if($r -and $r.status -ne 'completed'){'incomplete'}else{'verification_error'});runner_status=$(if($r){$r.status}else{$null});error=$_.Exception.Message;native_calls=0;writes=0;network=0;compile=0}|ConvertTo-Json -Compress;exit 1}
finally{if($Lock){$Lock.Dispose()}}
