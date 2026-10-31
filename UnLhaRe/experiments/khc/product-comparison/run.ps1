#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$HelperExe,
    [ValidatePattern('^([0-9A-Fa-f]{64})?$')][string]$HelperSha256='',
    [string]$CurrentHelperExe,
    [ValidatePattern('^([0-9A-Fa-f]{64})?$')][string]$CurrentHelperSha256='',
    [ValidateSet('initial','repair1','repair2','final1')][string]$Attempt='initial',
    [ValidatePattern('^([a-z0-9][a-z0-9-]{0,31})?$')][string]$ReplayLabel='',
    [switch]$PreflightOnly
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$Root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$AttemptSuffix=if($Attempt -eq 'initial'){''}else{"-$Attempt"}
if($ReplayLabel){$AttemptSuffix+="-$ReplayLabel"}
$Work=Join-Path $Root "build/khc-product-comparison-20261005$AttemptSuffix"
$ReportPath=Join-Path $Work 'report.json'
$CreatedOutput=$false
$Suite=[Diagnostics.Stopwatch]::StartNew()
$Locks=[Collections.Generic.List[IO.FileStream]]::new()
$Pins=[Collections.Generic.List[object]]::new()
$Samples=[Collections.Generic.List[object]]::new()
$Failures=[Collections.Generic.List[object]]::new()
$Inputs=[Collections.Generic.List[object]]::new()
$Quiet=[Collections.Generic.List[object]]::new()
$Preparation=[Collections.Generic.List[object]]::new()
$NativeCalls=0
$MaxChild=167772160L
$MaxOutput=1048576+4096
$Report=[ordered]@{
    status='starting';kind='product_block_comparison';attempt=$Attempt;timing_scope='process startup + binary IO + polling; not isolated codec CPU';
    replay_label=$ReplayLabel;
    limits=@{block_bytes=1048576;stdout_bytes=$MaxOutput;stderr_bytes=16384;child_seconds=60;suite_seconds=1800;child_WS_private_bytes=$MaxChild;report_bytes=262144;output_bytes=8388608;cpu_quiet_percent=15};
    warmups_per_fixture_algorithm=1;measured_samples_per_fixture_algorithm=9;order='alternate forward/reverse each round';
    memory_scope='kernel PeakWorkingSet and max(PrivateMemorySize64,PeakPagedMemorySize64) polled every10ms; short-lived final peak may be missed';
    tool_versions_declared=@{zstd='1.5.7';seven_zip='26.03';source='task-fixed tool identity, no separate version native run'};
    quiet_columns=@('input_index','round','CPU_percent','attempts','wait_ms','status');
    sample_columns=@('input_index','algorithm_index','round_minus1_warmup','order_index','status','encoded_bytes','encode_wall_ns','decode_wall_ns','encode_peak_WS','encode_polled_peak_private','encode_observations','decode_peak_WS','decode_polled_peak_private','decode_observations');
    samples=$Samples;failures=$Failures;inputs=$Inputs;quiet_checks=$Quiet;preparation=$Preparation;pins=$Pins;
    raw_frame_disk_files=0;DLL_benchmark_verified=$false;zstd19_superiority_verified=$false;seven_zip_superiority_claimed=$false;
    AES_fixture_note='AES-CBC NoPadding fixed public test key/IV, RAM only, not user secrets or authenticated encryption';
    AES_fixture_key_hex='000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F';AES_fixture_IV_hex='000102030405060708090A0B0C0D0E0F';
    algorithms=$null;pipeline_probe=$null;suite_elapsed_ms=0;live_pins_unchanged=$false
}
function Check-Suite { if($Suite.Elapsed.TotalSeconds -gt 1800){throw 'suite deadline'} }
function Assert-PathChain([string]$Path){$p=[IO.Path]::GetFullPath($Path);while($p){if(Test-Path -LiteralPath $p){$item=Get-Item -LiteralPath $p;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw "reparse ancestor $p"}};$next=[IO.Path]::GetDirectoryName($p);if($next -eq $p){break};$p=$next}}
function Digest([byte[]]$Bytes){$sha=[Security.Cryptography.SHA256]::Create();try{return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','')}finally{$sha.Dispose()}}
function Pin([string]$Path,[string]$Expected=''){
    $p=[IO.Path]::GetFullPath($Path);Assert-PathChain $p;$f=Get-Item -LiteralPath $p
    if(($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw "reparse pin $p"}
    $lock=[IO.File]::Open($p,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$Locks.Add($lock)
    $sha=(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
    if($Expected -and $sha -ne $Expected){throw "SHA pin mismatch $p"}
    $record=[pscustomobject]@{path=$p;bytes=$f.Length;mtimeUtc=$f.LastWriteTimeUtc.ToString('o');SHA256=$sha}
    $Pins.Add($record);return $record
}
function Same-Bytes([byte[]]$A,[byte[]]$B){
    if($A.Length -ne $B.Length){return $false}
    # Base64は全byteに対し単射。hashだけで一致判定せず、比較をnative childの計時外で行う。
    return [Convert]::ToBase64String($A) -ceq [Convert]::ToBase64String($B)
}
function Wait-Quiet([int]$InputIndex,[int]$Round){
    $watch=[Diagnostics.Stopwatch]::StartNew();$attempts=0
    do{Check-Suite;$attempts++;$c=Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
       if($null -eq $c){throw 'CPU quiet metric unavailable'};$percent=[double]$c.PercentProcessorTime
       if($percent -le 15){$Quiet.Add(@($InputIndex,$Round,$percent,$attempts,[math]::Round($watch.Elapsed.TotalMilliseconds,3),'quiet'));return}
       if($watch.Elapsed.TotalSeconds -ge 60){$Quiet.Add(@($InputIndex,$Round,$percent,$attempts,[math]::Round($watch.Elapsed.TotalMilliseconds,3),'timeout'));throw 'CPU quiet timeout'};Start-Sleep -Milliseconds 500
    }while($true)
}
function Invoke-Binary([string]$Exe,[string[]]$Arguments,[byte[]]$Data,[long]$MemoryLimit=$MaxChild){
    Check-Suite
    $p=[Diagnostics.Process]::new();$si=[Diagnostics.ProcessStartInfo]::new()
    $si.FileName=$Exe;$si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardInput=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
    foreach($a in $Arguments){$si.ArgumentList.Add($a)};$p.StartInfo=$si
    $out=[IO.MemoryStream]::new();$err=[IO.MemoryStream]::new();$ob=[byte[]]::new(65536);$eb=[byte[]]::new(4096)
    $status='ok';$reason='';$exit=$null;$peakWS=0L;$peakPrivate=0L;$observations=0;$inClosed=$false;$outDone=$false;$errDone=$false
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try{
        if(-not $p.Start()){throw 'process start'};$script:NativeCalls++
        $p.Refresh();$peakWS=$p.PeakWorkingSet64;$peakPrivate=[math]::Max($p.PrivateMemorySize64,$p.PeakPagedMemorySize64);$observations++
        $ot=$p.StandardOutput.BaseStream.ReadAsync($ob,0,$ob.Length);$et=$p.StandardError.BaseStream.ReadAsync($eb,0,$eb.Length)
        $it=$p.StandardInput.BaseStream.WriteAsync($Data,0,$Data.Length)
        while($true){
            Check-Suite
            if($it.IsCompleted -and -not $inClosed){$null=$it.GetAwaiter().GetResult();$p.StandardInput.Close();$inClosed=$true}
            if(-not $outDone -and $ot.IsCompleted){$n=$ot.GetAwaiter().GetResult();if($n -eq 0){$outDone=$true}else{
                if($out.Length+$n -gt $MaxOutput){$status='stdout_limit';break};$out.Write($ob,0,$n);$ot=$p.StandardOutput.BaseStream.ReadAsync($ob,0,$ob.Length)
            }}
            if(-not $errDone -and $et.IsCompleted){$n=$et.GetAwaiter().GetResult();if($n -eq 0){$errDone=$true}else{
                if($err.Length+$n -gt 16384){$status='stderr_limit';break};$err.Write($eb,0,$n);$et=$p.StandardError.BaseStream.ReadAsync($eb,0,$eb.Length)
            }}
            if(-not $p.HasExited){$p.Refresh();$peakWS=[math]::Max($peakWS,$p.PeakWorkingSet64);$peakPrivate=[math]::Max($peakPrivate,[math]::Max($p.PrivateMemorySize64,$p.PeakPagedMemorySize64));$observations++
                if($peakWS -gt $MemoryLimit -or $peakPrivate -gt $MemoryLimit){$status='resource_exceeded';break}
            }
            if($p.HasExited -and $outDone -and $errDone -and $inClosed){$exit=$p.ExitCode;if($exit -ne 0){$status='child_error'};break}
            if($watch.Elapsed.TotalSeconds -ge 60){$status='timeout';break};Start-Sleep -Milliseconds 10
        }
    }catch{$status='execution_error';$reason=$_.Exception.Message}
    finally{
        try{if(-not $p.HasExited){$p.Kill($true)}}catch{}
        try{if(-not $p.WaitForExit(1000)){$reason+='; child did not terminate'}}catch{}
        $watch.Stop()
        $stderr=[Text.Encoding]::UTF8.GetString($err.ToArray());if($stderr.Length -gt 160){$stderr=$stderr.Substring(0,160)}
        $bytes=$out.ToArray();$out.Dispose();$err.Dispose();$p.Dispose()
    }
    if($peakWS -gt $MemoryLimit -or $peakPrivate -gt $MemoryLimit){$status='resource_exceeded'}
    return [pscustomobject]@{status=$status;reason=$reason;exit=$exit;bytes=$bytes;wall_ns=[long]($watch.Elapsed.TotalMilliseconds*1000000);peak_WS=$peakWS;polled_peak_private=$peakPrivate;observations=$observations;stderr=$stderr}
}
function Seeded([int]$Length){
    $bytes=[byte[]]::new($Length);$x=[uint32]0x6d2b79f5
    for($i=0;$i -lt $Length;$i++){$x=[uint32](($x -bxor ([uint64]$x -shl 13)) -band 4294967295L);$x=[uint32]($x -bxor ($x -shr 17));$x=[uint32](($x -bxor ([uint64]$x -shl 5)) -band 4294967295L);$bytes[$i]=[byte]($x -band 255)}
    return ,$bytes
}
function Get-Fixture([object]$Spec){
    if($Spec.path){
        $fs=[IO.File]::OpenRead((Join-Path $Root $Spec.path));try{$n=[int][math]::Min($fs.Length,$Spec.window);$bytes=[byte[]]::new($n);$at=0;while($at -lt $n){$got=$fs.Read($bytes,$at,$n-$at);if($got -eq 0){throw 'corpus truncated'};$at+=$got}}finally{$fs.Dispose()}
    }else{switch($Spec.kind){
        'empty'{$bytes=[byte[]]::new(0)}
        'one'{$bytes=[byte[]]@(165)}
        'repeat'{$bytes=[byte[]]::new(4096);for($i=0;$i -lt $bytes.Length;$i++){$bytes[$i]=7}}
        'random'{$bytes=Seeded 65536}
        'json'{$prefix='{"名前":"ゆーくん","種別":"圧縮比較","padding":"';$suffix='"}';$padding=4096-[Text.Encoding]::UTF8.GetByteCount($prefix+$suffix);$bytes=[Text.Encoding]::UTF8.GetBytes($prefix+('a'*$padding)+$suffix)}
        'aes'{$plain=Seeded 65536;$key=[byte[]](0..31);$iv=[byte[]](0..15);$aes=[Security.Cryptography.Aes]::Create();try{$aes.Key=$key;$aes.IV=$iv;$aes.Mode=[Security.Cryptography.CipherMode]::CBC;$aes.Padding=[Security.Cryptography.PaddingMode]::None;$transform=$aes.CreateEncryptor();try{$bytes=$transform.TransformFinalBlock($plain,0,$plain.Length)}finally{$transform.Dispose()}}finally{$aes.Dispose()}}
        'precompressed'{if($algorithms[2].state -ne 'active'){throw 'precompressed fixture unavailable: Zstd3 interrupted'};Wait-Quiet -2 -1;$plain=[byte[]]::new(4096);for($i=0;$i -lt $plain.Length;$i++){$plain[$i]=7};$prep=Invoke-Binary $Zstd @('-T1','-3','-q','-c') $plain;$Preparation.Add(@{kind='zstd3_repeat4KiB';status=$prep.status;input_bytes=$plain.Length;output_bytes=$prep.bytes.Length;wall_ns=$prep.wall_ns;peak_WS=$prep.peak_WS;polled_peak_private=$prep.polled_peak_private;observations=$prep.observations});if($prep.status -ne 'ok'){throw 'precompressed fixture preparation failed'};$bytes=$prep.bytes}
        default{throw 'fixture kind'}
    }}
    if($bytes.Length -gt 1048576){throw 'fixture exceeds block'};return ,$bytes
}
try{
    Assert-PathChain $Work
    if(-not $PreflightOnly -and (Test-Path -LiteralPath $Work)){throw 'comparison output already exists'}
    $drive=Get-PSDrive -Name ([IO.Path]::GetPathRoot($Work).TrimEnd('\').TrimEnd(':'));if($drive.Free -lt 5GB+8MB){throw 'free space budget'}
    if(-not $PreflightOnly){$null=New-Item -ItemType Directory -Path $Work;$CreatedOutput=$true}
    if($HelperExe){$HelperExe=[IO.Path]::GetFullPath($HelperExe)
        $allowed=[IO.Path]::GetFullPath((Join-Path $Root 'build/cargo'))+[IO.Path]::DirectorySeparatorChar
        if(-not $HelperExe.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'helper outside shared cargo'}
        if(-not $HelperSha256){throw 'helper SHA required'};$null=Pin $HelperExe $HelperSha256
    }elseif(-not $PreflightOnly){throw 'native run requires helper path and SHA'}
    if($CurrentHelperExe){
        $CurrentHelperExe=[IO.Path]::GetFullPath($CurrentHelperExe)
        $allowed=[IO.Path]::GetFullPath((Join-Path $Root 'build/cargo'))+[IO.Path]::DirectorySeparatorChar
        if(-not $CurrentHelperExe.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or -not $CurrentHelperSha256){throw 'current helper path/SHA'}
        $null=Pin $CurrentHelperExe $CurrentHelperSha256
        $null=Pin (Join-Path $Root 'examples/khc_current_io.rs')
        $null=Pin (Join-Path $PSScriptRoot 'CURRENT_BASELINE_PLAN.md')
        foreach($name in @('mod','bt','context','frontier_dp','hybrid','lz','prices','profile','range','rans','rep_frontier_dp','row','suffix_probe')){
            $null=Pin (Join-Path $Root "experiments/khc/$name.rs")
        }
    }
    if($Attempt -eq 'final1' -and -not $CurrentHelperExe){throw 'final1 requires paired current helper'}
    $Zstd=Join-Path $Root 'build/khc-bench-tools-20261005/zstd.exe';$Seven=Join-Path $Root 'build/khc-baseline-20260918/x64/7za.exe'
    $null=Pin $Zstd '8076AAE03FEAC7C66B319579E82172EED168DEED2A3F25E5E2D3C60F55E84111'
    $null=Pin $Seven 'EDBEE35370E14030E4C785CF88200F42DC651C1EB4217C1E3963C38A12F099B0'
    $null=Pin $PSCommandPath;$null=Pin (Join-Path $PSScriptRoot 'FAILURE_PLAN.md');$null=Pin (Join-Path $Root 'examples/khc_block_io.rs')
    foreach($f in Get-ChildItem -LiteralPath (Join-Path $Root 'src/khc') -Recurse -File -Filter '*.rs'){$null=Pin $f.FullName}
    foreach($name in @('src/lib.rs','src/directory.rs','src/writer.rs','src/reader.rs','src/pathname.rs','src/error.rs','src/operation.rs','Cargo.toml','Cargo.lock','.cargo/config.toml')){$null=Pin (Join-Path $Root $name)}
    $toolchain=Join-Path ([Environment]::GetFolderPath('UserProfile')) '.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin'
    foreach($name in @('rustc.exe','cargo.exe')){$null=Pin (Join-Path $toolchain $name)}
    $astTokens=$null;$astErrors=$null;[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$astTokens,[ref]$astErrors)|Out-Null
    if($astErrors.Count){throw 'runner AST failed'}
    $specs=@(
        @{name='empty';kind='empty';path='';role='synthetic'},@{name='one_byte';kind='one';path='';role='synthetic'},
        @{name='repeat4KiB';kind='repeat';path='';role='synthetic'},@{name='seeded_random64KiB';kind='random';path='';role='synthetic_not_encrypted'},
        @{name='Japanese_JSON4KiB';kind='json';path='';role='synthetic'},@{name='AES_CBC64KiB';kind='aes';path='';role='synthetic_encrypted_public_test_key'},
        @{name='Zstd3_repeat4KiB_frame';kind='precompressed';path='';role='synthetic_precompressed'},
        @{name='alice29';kind='corpus';path='build/khc-corpus/canterbury-development/alice29.txt';window=1048576;role='development'},
        @{name='kennedy';kind='corpus';path='build/khc-corpus/canterbury-development/kennedy.xls';window=1048576;role='development'},
        @{name='dickens';kind='corpus';path='build/khc-corpus/silesia-holdout/dickens';window=262144;role='holdout_window'},
        @{name='mozilla';kind='corpus';path='build/khc-corpus/silesia-holdout/mozilla';window=262144;role='holdout_window'},
        @{name='osdb';kind='corpus';path='build/khc-corpus/silesia-holdout/osdb';window=262144;role='holdout_window'},
        @{name='x-ray';kind='corpus';path='build/khc-corpus/silesia-holdout/x-ray';window=262144;role='holdout_window'}
    )
    foreach($spec in $specs){if($spec.path){$null=Pin (Join-Path $Root $spec.path)}}
    if($PreflightOnly){$Report.status='readonly_preflight_passed';$Report['native_calls']=0;$Report['compiled_provenance']='parent separate ledger';return}
    $algorithms=@(
        @{id='KHC_paid';exe=$HelperExe;encode=@('paid');decode=@('decode');tier='matched';estimate_bytes=67108864;estimate_source='product codec 64MiB bound plus process measured guard';state='active'},
        @{id='KHC_low';exe=$HelperExe;encode=@('low');decode=@('decode');tier='ablation';estimate_bytes=67108864;estimate_source='product codec bound';state='active'},
        @{id='Zstd3';exe=$Zstd;encode=@('-T1','-3','-q','-c');decode=@('-T1','-d','-q','-c');tier='matched';estimate_bytes=67108864;estimate_source='conservative registration for <=1MiB stream, actual child guard required';state='active'},
        @{id='LZMA2_4m';exe=$Seven;encode=@('a','-txz','-si','-so','-m0=LZMA2','-mmt1','-mx9','-md4m','-bd','-bso0','-bsp0');decode=@('e','-txz','-si','-so','-bd','-bso0','-bsp0');tier='matched';estimate_bytes=67108864;estimate_source='conservative 4MiB dict multiplier+overhead, actual child guard required';state='active'},
        @{id='LZMA2_8m';exe=$Seven;encode=@('a','-txz','-si','-so','-m0=LZMA2','-mmt1','-mx9','-md8m','-bd','-bso0','-bsp0');decode=@('e','-txz','-si','-so','-bd','-bso0','-bsp0');tier='rate_priority';estimate_bytes=134217728;estimate_source='conservative 8MiB dict multiplier+overhead, actual child guard required';state='active'},
        @{id='Zstd19';encode=@('-T1','-19');tier='rate_priority';estimate_bytes=$null;state='unexecuted_memory_estimate_unavailable'},
        @{id='LZMA2_64m';encode=@('a','-txz','-si','-so','-m0=LZMA2','-mmt1','-mx9','-md64m');tier='rate_priority';estimate_bytes=805306368;state='unexecuted_budget_exceeded'}
    )
    if($CurrentHelperExe){$algorithms+=@(@{
        id='KHC0_Standard';exe=$CurrentHelperExe;encode=@('encode');decode=@('decode');tier='matched';
        estimate_bytes=67108864;estimate_source='old experimental Standard: 8*n+fixed codec estimate, 64MiB policy/actual child guard';state='active';
        dictionary_bytes=1048576;entropy_backend='Range';max_output_bytes=1048576;public_LHA_API=$false
    })}
    $Report.algorithms=$algorithms
    # バイナリpipe専用：archive名の必須解析を無効化する。圧縮設定は変更しない。
    foreach($index in @(3,4)){
        $algorithms[$index].encode+=@('-an')
        $algorithms[$index].decode+=@('-an')
    }
    # 実消費量が同じと主張せず、matchedは同じ64MiB/60s ceilingで比較する。
    foreach($algorithm in $algorithms){
        $algorithm['memory_limit_bytes']=if($algorithm.tier -in @('matched','ablation')){67108864L}else{$MaxChild}
    }
    $Report['matched_definition']='same single-worker, 64MiB WS/private ceiling and 60s child deadline; actual consumed resources differ'
    Wait-Quiet -1 -1
    $tiny=[Text.Encoding]::ASCII.GetBytes("KHC xz pipeline capability")
    $a=Invoke-Binary $Seven $algorithms[3].encode $tiny $algorithms[3].memory_limit_bytes
    $b=if($a.status -eq 'ok'){Invoke-Binary $Seven $algorithms[3].decode $a.bytes $algorithms[3].memory_limit_bytes}else{$null}
    $capable=$a.status -eq 'ok' -and $null -ne $b -and $b.status -eq 'ok' -and (Same-Bytes $tiny $b.bytes)
    $Report.pipeline_probe=@{passed=$capable;encode_status=$a.status;encode_exit=$a.exit;encode_stderr=$a.stderr;decode_status=$(if($b){$b.status}else{'not_executed'});actual_byte_equal=$capable;calls=$(if($b){2}else{1})}
    if(-not $capable){$Report.status='pipeline_capability_unavailable';throw 'xz stdin/stdout capability unavailable; no changed conditions'}
    for($fi=0;$fi -lt $specs.Count;$fi++){
        Check-Suite;$spec=$specs[$fi];$raw=Get-Fixture $spec
        $sourcePin=if($spec.path){$Pins|Where-Object {$_.path -eq [IO.Path]::GetFullPath((Join-Path $Root $spec.path))}|Select-Object -First 1}else{$null}
        $Inputs.Add(@{name=$spec.name;role=$spec.role;kind=$spec.kind;bytes=$raw.Length;SHA256=(Digest $raw);source=$spec.path;source_bytes=$(if($sourcePin){$sourcePin.bytes}else{$null});source_SHA256=$(if($sourcePin){$sourcePin.SHA256}else{$null});window_offset=0;window_bytes=$raw.Length;test_seed=$(if($spec.kind -in @('random','aes')){'6D2B79F5'}else{$null})})
        for($round=-1;$round -lt 9;$round++){
            Wait-Quiet $fi $round
            $order=if($CurrentHelperExe){@(0,1,2,3,4,7)}else{0..4};if(($round+$fi)%2 -eq 0){[array]::Reverse($order)}
            for($oi=0;$oi -lt $order.Length;$oi++){
                $ai=$order[$oi];$alg=$algorithms[$ai];if($alg.state -ne 'active'){continue}
                $enc=Invoke-Binary $alg.exe $alg.encode $raw $alg.memory_limit_bytes
                $dec=if($enc.status -eq 'ok'){Invoke-Binary $alg.exe $alg.decode $enc.bytes $alg.memory_limit_bytes}else{$null}
                $status=$enc.status;if($status -eq 'ok'){$status=$dec.status};if($status -eq 'ok' -and -not (Same-Bytes $raw $dec.bytes)){$status='byte_mismatch'}
                $Samples.Add(@($fi,$ai,$round,$oi,$status,$enc.bytes.Length,$enc.wall_ns,$(if($dec){$dec.wall_ns}else{0}),$enc.peak_WS,$enc.polled_peak_private,$enc.observations,$(if($dec){$dec.peak_WS}else{0}),$(if($dec){$dec.polled_peak_private}else{0}),$(if($dec){$dec.observations}else{0})))
                if($status -ne 'ok'){$alg.state='interrupted_'+$status;$Failures.Add(@{input_index=$fi;algorithm_index=$ai;round=$round;status=$status;encode_exit=$enc.exit;encode_reason=$enc.reason;encode_stderr=$enc.stderr;decode_exit=$(if($dec){$dec.exit}else{$null});decode_reason=$(if($dec){$dec.reason}else{'not_executed'});decode_stderr=$(if($dec){$dec.stderr}else{''})})}
                $enc=$null;$dec=$null
            }
        };$raw=$null
    }
    $Report.status=if($Failures.Count -eq 0){'completed'}else{'completed_with_interrupted_candidates'}
}catch{
    if($Report.status -eq 'starting'){$Report.status='failed'}
    $Report.failure_reason=$_.Exception.Message
    $Report.failure_location=$_.ScriptStackTrace
}finally{
    $Report.suite_elapsed_ms=[math]::Round($Suite.Elapsed.TotalMilliseconds,3)
    $Report['native_calls']=$NativeCalls
    $unchanged=$true
    foreach($pin in $Pins){$f=Get-Item -LiteralPath $pin.path;if($f.Length -ne $pin.bytes -or $f.LastWriteTimeUtc.ToString('o') -ne $pin.mtimeUtc -or (Get-FileHash -LiteralPath $pin.path).Hash -ne $pin.SHA256){$unchanged=$false}}
    $Report.live_pins_unchanged=$unchanged;if(-not $unchanged){$Report.status='pin_mismatch'}
    foreach($lock in $Locks){$lock.Dispose()}
    $Report.suite_elapsed_ms=[math]::Round($Suite.Elapsed.TotalMilliseconds,3)
    if($Suite.Elapsed.TotalSeconds -gt 1800){$Report.status='suite_timeout'}
    if($CreatedOutput){
        $json=$Report|ConvertTo-Json -Depth 15 -Compress;$bytes=[Text.Encoding]::UTF8.GetBytes($json)
        if($bytes.Length -gt 262144){throw 'report prewrite size budget'}
        $reportFile=[IO.File]::Open($ReportPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$reportFile.Write($bytes,0,$bytes.Length)}finally{$reportFile.Dispose()}
        $used=(Get-ChildItem -LiteralPath $Work -File|Measure-Object Length -Sum).Sum
        if($used -gt 8388608){throw 'output budget exceeded'}
        [pscustomobject]@{status=$Report.status;report=$ReportPath;report_bytes=$bytes.Length;SHA256=(Digest $bytes);samples=$Samples.Count;raw_frame_disk_files=0}|ConvertTo-Json -Compress
    }elseif($PreflightOnly){
        [pscustomobject]@{status=$Report.status;attempt=$Attempt;pins=$Pins.Count;live_pins_unchanged=$unchanged;native_calls=0;writes=0;failure=$(if($Report.Contains('failure_reason')){$Report['failure_reason']}else{$null})}|ConvertTo-Json -Compress
    }
}
if($Report.status -notin @('completed','completed_with_interrupted_candidates','readonly_preflight_passed')){exit 1}
