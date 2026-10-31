#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$NewHelperExe,[Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$NewHelperSha256,[ValidatePattern('^[a-z0-9][a-z0-9-]{0,31}$')][string]$Attempt='initial',[string]$BaselineHelperExe='',[ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$BaselineHelperSha256='DAB84057869264AAD41E1AE8BD4CB01B97EB604BDBBBCB636706F6AEEAC971C3',[ValidateSet('paid','low')][string]$HistoryMode='paid',[switch]$AllowDifferentFrames,[ValidateSet('khc','lzma2')][string]$BaselineKind='khc',[ValidateSet('seven','canterbury')][string]$CorpusSet='seven',[ValidateRange(0,15)][int]$FirstFixture=0,[ValidateRange(0,15)][int]$LastFixture=15)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$Root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$Work=Join-Path $Root "build/khc-forest-public-compare-20261006-$Attempt";$ReportPath=Join-Path $Work 'report.json'
$OldHelper=Join-Path $Root 'build/cargo/x86_64-pc-windows-msvc/release/examples/khc_block_io.exe'
if($BaselineHelperExe){$OldHelper=[IO.Path]::GetFullPath($BaselineHelperExe)}
$Suite=[Diagnostics.Stopwatch]::StartNew();$NativeCalls=0;$Created=$false
$Pins=[Collections.Generic.List[object]]::new();$Locks=[Collections.Generic.List[IO.FileStream]]::new();$Samples=[Collections.Generic.List[object]]::new();$Inputs=[Collections.Generic.List[object]]::new();$Quiet=[Collections.Generic.List[object]]::new();$Cross=[Collections.Generic.List[object]]::new();$Summary=[Collections.Generic.List[object]]::new()
$Report=[ordered]@{kind='khc_crc_before_after_process_io';status='starting';attempt=$Attempt;timing_scope='process startup + binary IO + progress pump; NOT pure codec CPU';memory_scope='kernel PeakWorkingSet and max PrivateMemorySize64/PeakPagedMemorySize64 polled each iteration; short-lived final private peak may be missed';old_compiled_source_provenance='parent separate frozen ledger; current source pins describe NEW build only';mode='paid';warmup=1;measured=9;order='reverse before/after on alternate rounds';limits=@{input=1048576;stdout=1052672;stderr=16384;WS_private=67108864;child_seconds=60;suite_seconds=900;report=262144;output=8388608;free=5368709120;CPU_percent=15};inputs=$Inputs;samples=$Samples;quiet=$Quiet;cross_decode=$Cross;summary=$Summary;pins=$Pins;native_calls=0;raw_frame_disk_files=0;all_group_blocks='not selected: bounded seven-fixture scope';seven_zip_superiority_verified=$false;live_pins_unchanged=$false;failure=$null;elapsed_ms=0;sample_columns=@('input','round_minus1_warm','side_0before_1after','order','encoded_bytes','encode_ns','decode_ns','encode_WS','encode_private','encode_observations','decode_WS','decode_private','decode_observations')}
function Guard {if($Suite.Elapsed.TotalSeconds -ge 900){throw 'suite deadline'}}
$Report.mode=$HistoryMode
$Report.kind='khc_before_after_process_io'
$Report.require_same_frames=-not $AllowDifferentFrames
$Report.frame_equal_pairs=0
$Report.frame_different_pairs=0
$SevenEncode=@('a','-an','-txz','-si','-so','-m0=LZMA2','-mmt1','-mx9','-md4m','-mfb273','-bd','-bso0','-bsp0')
$SevenDecode=@('e','-an','-txz','-si','-so','-bd','-bso0','-bsp0')
$Report.corpus_set=$CorpusSet
$Report.baseline_kind=$BaselineKind
$Report.methods=@(@{side=0;kind=$BaselineKind;encode=$(if($BaselineKind -eq 'lzma2'){$SevenEncode}else{@($HistoryMode)});decode=$(if($BaselineKind -eq 'lzma2'){$SevenDecode}else{@('decode')})},@{side=1;kind='khc';encode=@($HistoryMode);decode=@('decode')})
if($BaselineKind -eq 'lzma2'){$Report.old_compiled_source_provenance='official 7-Zip 26.03 x64 executable; pinned SHA';$Report.kind='khc_vs_seven_zip_process_io';$Report.cross_decode_applicability='not applicable: different formats'}
function Chain([string]$Path){$p=[IO.Path]::GetFullPath($Path);while($p){if(Test-Path -LiteralPath $p){if(((Get-Item -LiteralPath $p).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw "reparse ancestor $p"}};$p=[IO.Path]::GetDirectoryName($p)}}
function Pin([string]$Path,[string]$Expected=''){$p=[IO.Path]::GetFullPath($Path);Chain $p;$f=Get-Item -LiteralPath $p;$l=[IO.File]::Open($p,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$Locks.Add($l);$h=(Get-FileHash -LiteralPath $p).Hash;if($Expected -and $h -ne $Expected){throw "SHA mismatch $p"};$Pins.Add(@{path=$p;bytes=$f.Length;mtimeUtc=$f.LastWriteTimeUtc.ToString('o');SHA256=$h})}
function Hash([byte[]]$Bytes){$h=[Security.Cryptography.SHA256]::Create();try{return [BitConverter]::ToString($h.ComputeHash($Bytes)).Replace('-','')}finally{$h.Dispose()}}
function Equal([byte[]]$A,[byte[]]$B){return $A.Length -eq $B.Length -and [Convert]::ToBase64String($A) -ceq [Convert]::ToBase64String($B)}
function Quiet([int]$Fi,[int]$Round){$w=[Diagnostics.Stopwatch]::StartNew();$n=0;while($true){Guard;$n++;$cpu=Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'";if($null -eq $cpu){throw 'CPU metric unavailable'};$v=[double]$cpu.PercentProcessorTime;if($v -le 15){$Quiet.Add(@($Fi,$Round,$v,$n,$w.Elapsed.TotalMilliseconds,'quiet'));return};if($w.Elapsed.TotalSeconds -ge 60){$Quiet.Add(@($Fi,$Round,$v,$n,$w.Elapsed.TotalMilliseconds,'timeout'));throw 'CPU quiet timeout'};Start-Sleep -Milliseconds 500}}
function Child([string]$Exe,[string[]]$Arguments,[byte[]]$Data){
    Guard;if($Data.Length -gt 1048616){throw 'stdin bound'}
    $p=[Diagnostics.Process]::new();$si=[Diagnostics.ProcessStartInfo]::new();$si.FileName=$Exe;$si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardInput=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true;foreach($argument in $Arguments){$si.ArgumentList.Add($argument)};$p.StartInfo=$si
    $o=[IO.MemoryStream]::new();$e=[IO.MemoryStream]::new();$ob=[byte[]]::new(65536);$eb=[byte[]]::new(4096);$w=[Diagnostics.Stopwatch]::StartNew();$ws=0L;$priv=0L;$obs=0;$ic=$false;$od=$false;$ed=$false;$status='ok';$reason='';$exit=$null;$started=$false
    try{
        if(-not $p.Start()){throw 'child start'};$started=$true;$script:NativeCalls++;$p.Refresh();$ws=$p.PeakWorkingSet64;$priv=[math]::Max($p.PrivateMemorySize64,$p.PeakPagedMemorySize64);$obs++
        $ot=$p.StandardOutput.BaseStream.ReadAsync($ob,0,$ob.Length);$et=$p.StandardError.BaseStream.ReadAsync($eb,0,$eb.Length);$it=$p.StandardInput.BaseStream.WriteAsync($Data,0,$Data.Length)
        while($true){
            Guard;$progress=$false
            if($it.IsCompleted -and -not $ic){$null=$it.GetAwaiter().GetResult();$p.StandardInput.Close();$ic=$true;$progress=$true}
            if(-not $od -and $ot.IsCompleted){$n=$ot.GetAwaiter().GetResult();$progress=$true;if($n -eq 0){$od=$true}else{if($o.Length+$n -gt 1052672){throw 'stdout bound'};$o.Write($ob,0,$n);$ot=$p.StandardOutput.BaseStream.ReadAsync($ob,0,$ob.Length)}}
            if(-not $ed -and $et.IsCompleted){$n=$et.GetAwaiter().GetResult();$progress=$true;if($n -eq 0){$ed=$true}else{if($e.Length+$n -gt 16384){throw 'stderr bound'};$e.Write($eb,0,$n);$et=$p.StandardError.BaseStream.ReadAsync($eb,0,$eb.Length)}}
            $p.Refresh();try{$ws=[math]::Max($ws,$p.PeakWorkingSet64);$priv=[math]::Max($priv,[math]::Max($p.PrivateMemorySize64,$p.PeakPagedMemorySize64));$obs++}catch{if(-not $p.HasExited){throw}}
            if($ws -gt 67108864 -or $priv -gt 67108864){throw 'child resource bound'}
            if($w.Elapsed.TotalSeconds -ge 60){throw 'child deadline'}
            if($p.HasExited -and $od -and $ed -and $ic){$exit=$p.ExitCode;if($exit -ne 0){throw "child exit $exit"};break}
            if(-not $progress){Start-Sleep -Milliseconds 10}
        }
    }catch{$status='failed';$reason=$_.Exception.Message}
    finally{if($started){try{if(-not $p.HasExited){$p.Kill($true)};if(-not $p.WaitForExit(1000)){$status='failed';$reason+='; termination timeout'}}catch{$status='failed';$reason+='; '+$_.Exception.Message}};$w.Stop();$bytes=$o.ToArray();$stderr=[Text.Encoding]::UTF8.GetString($e.ToArray());$o.Dispose();$e.Dispose();$p.Dispose()}
    return [pscustomobject]@{status=$status;reason=$reason;exit=$exit;bytes=$bytes;ns=[long]($w.Elapsed.TotalMilliseconds*1000000);WS=$ws;private=$priv;observations=$obs;stderr=$stderr}
}
function Ok($Result){if($Result.status -ne 'ok'){$Report.failure=@{reason=$Result.reason;exit=$Result.exit;stderr=$Result.stderr;WS=$Result.WS;private=$Result.private;ns=$Result.ns};throw $Result.reason}}
function Side([int]$Index,[bool]$Encode,[byte[]]$Data){$arguments=if($Index -eq 0 -and $BaselineKind -eq 'lzma2'){if($Encode){$SevenEncode}else{$SevenDecode}}else{if($Encode){@($HistoryMode)}else{@('decode')}};return Child $Exes[$Index] $arguments $Data}
function Fixture([int]$Fi){switch($Fi){
    0{$b=[byte[]]::new(0)} 1{$b=[byte[]]@(165)} 2{$b=[byte[]]::new(4096);[Array]::Fill[byte]($b,7)} 3{$b=[byte[]]::new(2048);for($i=0;$i -lt $b.Length;$i++){$b[$i]=[byte]($i -band 255)}}
    4{$b=[byte[]]::new(65536);$x=[uint32]0x6d2b79f5;for($i=0;$i -lt $b.Length;$i++){$x=[uint32](($x -bxor ([uint64]$x -shl 13)) -band 4294967295L);$x=[uint32]($x -bxor ($x -shr 17));$x=[uint32](($x -bxor ([uint64]$x -shl 5)) -band 4294967295L);$b[$i]=[byte]($x -band 255)}}
    default{$p=$Corpus[$Fi-5];$f=Get-Item -LiteralPath $p;if($f.Length -gt 1048576){throw 'corpus input bound'};$b=[byte[]]::new([int]$f.Length);$s=[IO.File]::OpenRead($p);try{$at=0;while($at -lt $b.Length){$n=$s.Read($b,$at,$b.Length-$at);if(-not $n){throw 'input truncated'};$at+=$n}}finally{$s.Dispose()}}
};return ,$b}
function TimeStats([object[]]$Values){$v=@($Values|Sort-Object);return @{min_ns=$v[0];median_ns=$v[4];max_ns=$v[-1]}}
try{
    if($BaselineKind -eq 'lzma2' -and (-not $BaselineHelperExe -or -not $AllowDifferentFrames)){throw 'LZMA2 comparison requires explicit baseline executable/SHA and AllowDifferentFrames'}
    Chain $Work;if(Test-Path -LiteralPath $Work){throw 'output must be unused'}
    if([IO.DriveInfo]::new([IO.Path]::GetPathRoot($Work)).AvailableFreeSpace -lt (5368709120L+8388608)){throw 'free space budget'}
    $NewHelperExe=[IO.Path]::GetFullPath($NewHelperExe);$allowed=[IO.Path]::GetFullPath((Join-Path $Root 'build/khc-forest-public-io-public-e-20261006/public_io.exe'));if(-not $NewHelperExe.Equals($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'new helper must be exact verified public-e executable'};if($NewHelperSha256 -ne '020ACFC3E9DFC5400EA99928B4ED33EAA619CA886D7D53DE67829FEDF48EED9D'){throw 'fixed public-e SHA required'};if($NewHelperExe -eq $OldHelper){throw 'helpers must be distinct'}
    Pin $OldHelper $BaselineHelperSha256;Pin $NewHelperExe $NewHelperSha256
    Pin (Join-Path $Root 'examples/khc_compact_io.rs') '7D55EF60641C01D9883106A182DA24B32518368F307A845A695798D73A50C656'
    $buildReportPath=Join-Path $Root 'build/khc-forest-public-io-public-e-20261006/report.json'
    Pin $buildReportPath '1A59EBD20ED029E9647B352318568CC8F23CCFDD76629F746087AADECF101D04'
    $buildEvidence=Get-Content -LiteralPath $buildReportPath -Raw|ConvertFrom-Json
    if($buildEvidence.status -ne 'completed' -or -not $buildEvidence.live_pins_unchanged -or $null -ne $buildEvidence.failure){throw 'public helper build evidence'}
    foreach($buildPin in $buildEvidence.pins){Pin $buildPin.path $buildPin.SHA256}
    Pin (Join-Path $Root 'experiments/khc/forest-layout/compare-public.ps1')
    Pin (Join-Path $Root 'experiments/khc/forest-layout/INTEGRATION_PLAN.md')
    $Report.public_build_report_SHA256='1A59EBD20ED029E9647B352318568CC8F23CCFDD76629F746087AADECF101D04'
    $Report.new_compiled_source_provenance='unchanged public API IO source; real Cargo-built libunlhare.rlib; standalone rustc opt3 codegen1 thinLTO panic-unwind; not diagnostic namespace'
    $Report.harness_derivation='frozen cpu-measurement-v2/run.ps1; only dedicated executable acceptance, build/source pins, metadata and work prefix changed; timing, safety, order and equality contracts unchanged'
    if([IO.Path]::GetFileNameWithoutExtension($NewHelperExe) -eq 'khc_direct_probe'){Pin (Join-Path $Root 'experiments/khc/cpu-measurement-v2/DIRECT_PARSE_PLAN_20261005.md')}
    if([IO.Path]::GetFileNameWithoutExtension($NewHelperExe) -eq 'khc_default_probe'){Pin (Join-Path $Root 'experiments/khc/cpu-measurement-v2/DEFAULT_PLAN_20261005.md')}
    if([IO.Path]::GetFileNameWithoutExtension($NewHelperExe) -eq 'khc_fill_probe'){Pin (Join-Path $Root 'experiments/khc/cpu-measurement-v2/FILL_PLAN_20261005.md')}
    if([IO.Path]::GetFileNameWithoutExtension($NewHelperExe) -eq 'khc_empty_probe'){Pin (Join-Path $Root 'experiments/khc/cpu-measurement-v2/EMPTY_BRANCH_PLAN_20261005.md')}
    foreach($f in Get-ChildItem -LiteralPath (Join-Path $Root 'src/khc') -Recurse -File -Filter '*.rs'){Pin $f.FullName}
    foreach($f in @('src/lib.rs','Cargo.toml','Cargo.lock','examples/khc_block_io.rs','examples/khc_speed_probe.rs','examples/khc_active_probe.rs','experiments/khc/cpu-measurement-v2/INACTIVE_PLAN_20261005.md','experiments/khc/cpu-measurement-v2/FAILURE_PLAN.md','experiments/khc/cpu-measurement-v2/run.ps1')){Pin (Join-Path $Root $f)}
    if($AllowDifferentFrames){Pin (Join-Path $Root 'examples/khc_leaf_probe.rs');Pin (Join-Path $Root 'experiments/khc/cpu-measurement-v2/LEAF_PLAN_20261005.md')}
    if($BaselineKind -eq 'lzma2'){Pin (Join-Path $Root 'experiments/khc/cpu-measurement-v2/SEVEN_ZIP_PLAN_20261005.md')}
    if($BaselineKind -eq 'lzma2' -and [IO.Path]::GetFileNameWithoutExtension($NewHelperExe) -eq 'khc_empty_probe'){Pin (Join-Path $Root 'experiments/khc/cpu-measurement-v2/SEVEN_EMPTY_PLAN_20261005.md')}
    if($BaselineKind -eq 'lzma2' -and [IO.Path]::GetFileNameWithoutExtension($NewHelperExe) -eq 'khc_direct_probe'){Pin (Join-Path $Root 'experiments/khc/cpu-measurement-v2/SEVEN_DIRECT_PLAN_20261005.md')}
    $Names=@('empty','one_byte','repeat4KiB','all256_times8','seeded_random64KiB')
    if($CorpusSet -eq 'canterbury'){
        Pin (Join-Path $Root 'experiments/khc/CORPUS_MANIFEST.json');$manifest=Get-Content -LiteralPath (Join-Path $Root 'experiments/khc/CORPUS_MANIFEST.json') -Raw|ConvertFrom-Json;$development=@($manifest|Where-Object {$_.name -eq 'canterbury-development'});if($development.Count -ne 1 -or $development[0].files.Count -ne 11){throw 'fixed development manifest shape'}
        $Corpus=@();foreach($entry in $development[0].files){$path=Join-Path $Root ('build/khc-corpus/canterbury-development/'+$entry.name);if((Get-Item -LiteralPath $path).Length -ne $entry.bytes -or $entry.bytes -gt 1048576){throw 'fixed development size'};Pin $path $entry.sha256;$Corpus+=@($path);$Names+=@($entry.name)}
    }else{$Corpus=@((Join-Path $Root 'build/khc-corpus/canterbury-development/alice29.txt'),(Join-Path $Root 'build/khc-corpus/canterbury-development/kennedy.xls'));Pin $Corpus[0] '7467306EE0FEED4971260F3C87421154A05BE571D944E9CB021A5713700C38F0';Pin $Corpus[1] '9AF47239CA29DFE20E633F80BBBB9A4CC9783D0803D7B2B5626F42E4C3790420';$Names+=@('alice29','kennedy')}
    $last=[math]::Min($LastFixture,$Names.Count-1);if($FirstFixture -gt $last){throw 'fixture range'}
    $count=$last-$FirstFixture+1;$Report.fixture_count=$count;$Report.fixture_range=@($FirstFixture,$last)
    Pin (Join-Path $Root 'experiments/khc/cpu-measurement-v2/EMPTY_BRANCH_PARTITION_PLAN_20261005.md')
    $null=New-Item -ItemType Directory -Path $Work;$Created=$true;$Exes=@($OldHelper,$NewHelperExe)
    for($fi=$FirstFixture;$fi -le $last;$fi++){
        $raw=Fixture $fi;$Inputs.Add(@{index=$fi;name=$Names[$fi];bytes=$raw.Length;SHA256=(Hash $raw);window_offset=0;window_bytes=$raw.Length;source=$(if($fi -ge 5){$Corpus[$fi-5]}else{'RAM generated'});seed=$(if($fi -eq 4){'6D2B79F5'}else{$null})})
        for($round=-1;$round -lt 9;$round++){
            Quiet $fi $round;$order=if(($round+$fi)%2 -eq 0){@(1,0)}else{@(0,1)};$frames=@($null,$null)
            for($oi=0;$oi -lt 2;$oi++){$side=$order[$oi];$enc=Side $side $true $raw;Ok $enc;$dec=Side $side $false $enc.bytes;Ok $dec;if(-not (Equal $raw $dec.bytes)){throw 'self decode byte mismatch'};$frames[$side]=$enc.bytes;$Samples.Add(@($fi,$round,$side,$oi,$enc.bytes.Length,$enc.ns,$dec.ns,$enc.WS,$enc.private,$enc.observations,$dec.WS,$dec.private,$dec.observations));$dec=$null;$enc=$null}
            if(Equal $frames[0] $frames[1]){$Report.frame_equal_pairs++}else{$Report.frame_different_pairs++;if(-not $AllowDifferentFrames){throw 'old/new encoded bytes mismatch'}}
            if($round -eq -1 -and $BaselineKind -eq 'khc'){for($target=0;$target -lt 2;$target++){$d=Side $target $false $frames[1-$target];Ok $d;if(-not (Equal $raw $d.bytes)){throw 'cross decode byte mismatch'};$Cross.Add(@($fi,(1-$target),$target,'byte_equal'));$d=$null}}
            $frames=$null
        };$raw=$null
    }
    foreach($fi in $FirstFixture..$last){foreach($side in 0..1){$rows=@($Samples|Where-Object {$_[0] -eq $fi -and $_[2] -eq $side});$m=@($rows|Where-Object {$_[1] -ge 0});if($rows.Count -ne 10 -or $m.Count -ne 9){throw 'sample count'};$sizes=@($rows|ForEach-Object {$_[4]}|Select-Object -Unique);if($sizes.Count -ne 1){throw 'encoded size unstable'};$Summary.Add(@{input=$fi;side=$side;raw_bytes=$Inputs[$fi-$FirstFixture].bytes;frame_bytes=$sizes[0];encode=(TimeStats @($m|ForEach-Object {$_[5]}));decode=(TimeStats @($m|ForEach-Object {$_[6]}));max_WS=(@($rows|ForEach-Object {[math]::Max($_[7],$_[10])}|Measure-Object -Maximum).Maximum);max_private=(@($rows|ForEach-Object {[math]::Max($_[8],$_[11])}|Measure-Object -Maximum).Maximum)})}}
    $expectedCross=if($BaselineKind -eq 'khc'){$count*2}else{0};Guard;if($Samples.Count -ne $count*20 -or $Cross.Count -ne $expectedCross -or $NativeCalls -ne ($count*40+$expectedCross)){throw 'completed counter contract'};$Report.status='completed'
}catch{$Report.status='failed';if(-not $Report.failure){$Report.failure=@{reason=$_.Exception.Message}}}
finally{
    $unchanged=$true;foreach($pin in $Pins){try{$f=Get-Item -LiteralPath $pin.path;if($f.Length -ne $pin.bytes -or $f.LastWriteTimeUtc.ToString('o') -ne $pin.mtimeUtc -or (Get-FileHash -LiteralPath $pin.path).Hash -ne $pin.SHA256){$unchanged=$false}}catch{$unchanged=$false}};$Report.live_pins_unchanged=$unchanged;if(-not $unchanged){$Report.status='pin_mismatch'};$Report.native_calls=$NativeCalls;$Report.elapsed_ms=$Suite.Elapsed.TotalMilliseconds
    foreach($l in $Locks){$l.Dispose()}
    if($Created){try{$bytes=[Text.Encoding]::UTF8.GetBytes(($Report|ConvertTo-Json -Depth 12 -Compress));if($bytes.Length -gt 262144){throw 'report bound'};if([IO.DriveInfo]::new([IO.Path]::GetPathRoot($Work)).AvailableFreeSpace -lt 5368709120L){throw 'post free space bound'};$s=[IO.File]::Open($ReportPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$s.Write($bytes,0,$bytes.Length)}finally{$s.Dispose()};[ordered]@{status=$Report.status;report=$ReportPath;bytes=$bytes.Length;SHA256=(Hash $bytes);native_calls=$NativeCalls;summary=$Summary;failure=$Report.failure}|ConvertTo-Json -Depth 6 -Compress}catch{$prior=$Report.status;$Report.status='report_save_failed';[ordered]@{status=$Report.status;reason=$_.Exception.Message;runner_status=$prior}|ConvertTo-Json -Compress}}
    else{[ordered]@{status=$Report.status;native_calls=$NativeCalls;failure=$Report.failure;writes=0}|ConvertTo-Json -Depth 4 -Compress}
}
if($Report.status -ne 'completed'){exit 1}
